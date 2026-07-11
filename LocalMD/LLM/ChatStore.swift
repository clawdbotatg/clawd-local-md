import CoreImage
import Foundation
import UIKit

/// Coarse state of the *selected* brain, for the UI's content gate: photos can
/// only be answered when the brain is `.ready` (there is no network fallback —
/// the app is fully on-device).
enum ModelState: Equatable {
    case idle
    /// Downloading or loading, with progress 0...1.
    case downloading(Double)
    case ready
    case failed(String)
}

/// Owns the model lifecycle and the message list the UI renders.
///
/// **Brains prepare in the background.** On-device downloads run through a
/// **serial queue** — one at a time, because two multi-GB fetches only
/// throttle each other and MLX can hold just one model in memory. Tapping any
/// brain is always allowed, even mid-download; it becomes the selection and
/// joins the queue.
@Observable
@MainActor
final class ChatStore {
    private(set) var messages: [ChatMessage] = []
    private(set) var isGenerating = false

    /// The selected brain (what answers photos) and which brains have finished
    /// downloading at least once (persisted, so a re-select loads from the
    /// on-disk cache instead of re-fetching).
    private(set) var currentModelID: String
    private(set) var downloadedModelIDs: Set<String>

    /// Per-brain download/load progress (0...1) while a brain is being
    /// prepared. Absent = not in flight. A queued-but-not-started brain sits at
    /// 0 until the worker reaches it.
    private(set) var prepareProgress: [String: Double] = [:]
    /// Brains whose most recent prepare attempt failed, with the error text
    /// (offer a retry).
    private(set) var failureMessages: [String: String] = [:]
    /// Which brain is actually loaded in the MLX engine right now (nil if
    /// none, or if a background prepare of a different brain evicted it).
    private(set) var loadedModelID: String?

    private let engine: LLMEngine

    /// Serial prepare queue: brain ids waiting to download/load, plus the one
    /// in flight. Only one runs at a time.
    private var prepareQueue: [String] = []
    private var preparing: String?
    private var workerRunning = false
    private var generationTask: Task<Void, Never>?
    /// When the last token arrived — the stall watchdog's heartbeat.
    private var lastChunkAt = Date()

    private static let modelKey = "brain.currentModelID"
    private static let downloadedKey = "brain.downloadedModelIDs"

    init() {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: Self.modelKey)
        currentModelID =
            (saved.flatMap { id in BrainCatalog.all.first { $0.id == id }?.id })
            ?? BrainCatalog.defaultID
        downloadedModelIDs = Set(defaults.stringArray(forKey: Self.downloadedKey) ?? [])

        #if targetEnvironment(simulator)
        engine = MockEngine()
        #else
        engine = MLXEngine()
        #endif
    }

    var availableModels: [BrainModel] { BrainCatalog.all }
    var currentModel: BrainModel { BrainCatalog.model(for: currentModelID) }
    var modelName: String { currentModel.name }

    /// State of the selected brain, driving the content area.
    var modelState: ModelState {
        if loadedModelID == currentModelID { return .ready }
        if let fraction = prepareProgress[currentModelID] { return .downloading(fraction) }
        if let message = failureMessages[currentModelID] { return .failed(message) }
        return .idle
    }

    /// True while any brain is downloading/loading (BrainView shows progress).
    var isPreparing: Bool { preparing != nil }

    /// Kicked off on appear: start preparing the selected brain (download it
    /// if it isn't cached yet; load it if it is).
    func activate() {
        prepare(currentModelID)
    }

    // MARK: - brain selection (never blocks)

    /// Switch brains. Always allowed — even while another brain downloads. The
    /// new pick becomes current immediately and joins the prepare queue.
    func selectModel(_ id: String) {
        guard id != currentModelID, !id.isEmpty else { return }
        DebugLog.log("selectModel: \(currentModelID) -> \(id)")
        currentModelID = id
        UserDefaults.standard.set(id, forKey: Self.modelKey)
        clear()
        prepare(id)
    }

    /// Explicitly (re)download a brain without necessarily using it — the
    /// row's download button, and the failure screen's Retry. Same queue;
    /// doesn't change the selection.
    func downloadModel(_ id: String) {
        prepare(id)
    }

    /// Ensure a brain is on its way to ready: enqueue a background prepare
    /// (download if missing, else a fast load from cache) unless it's already
    /// the loaded/in-flight one.
    private func prepare(_ id: String) {
        if loadedModelID == id, preparing == nil { return }  // already ready
        enqueuePrepare(id)
    }

    private func enqueuePrepare(_ id: String) {
        guard preparing != id, !prepareQueue.contains(id) else { return }
        if !downloadedModelIDs.contains(id) { prepareProgress[id] = 0 }
        prepareQueue.append(id)
        startWorker()
    }

    private func startWorker() {
        guard !workerRunning else { return }
        workerRunning = true
        Task { await runWorker() }
    }

    /// Process the queue one brain at a time. Each prepare downloads (if
    /// needed) then loads the brain into MLX — so the *last* one prepared is
    /// what's resident. Because the current selection is always enqueued last
    /// (it's the most recent tap), it normally ends up the loaded one; if a
    /// later background prepare of a different brain evicted it, the tail
    /// check reloads it.
    private func runWorker() async {
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            workerRunning = false
        }
        while !prepareQueue.isEmpty {
            let id = prepareQueue.removeFirst()
            preparing = id
            failureMessages[id] = nil
            let cached = downloadedModelIDs.contains(id)
            if prepareProgress[id] == nil { prepareProgress[id] = cached ? 0.9 : 0 }
            engine.setModel(id)
            // The downloader's byte fraction is useless for the bar: the
            // snapshot is one giant safetensors file and its Progress sits
            // near 0% for most of the transfer, then jumps straight to 1
            // (watched on device 2026-07-11: stuck at 14 MB/3.1 GB, done 12s
            // later). So a time-based estimate keeps the bar honest-ish and
            // always moving — asymptotic toward 92%, tuned so a medium-slow
            // connection (~8 min for 3 GB) tracks roughly: never claims done,
            // and the real fraction wins whenever it's actually ahead.
            let started = Date()
            let estimator: Task<Void, Never>? =
                cached
                ? nil
                : Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(400))
                        guard let self, self.preparing == id else { return }
                        let elapsed = Date().timeIntervalSince(started)
                        let estimate = 0.92 * (1 - exp(-elapsed / 180))
                        self.prepareProgress[id] = max(self.prepareProgress[id] ?? 0, estimate)
                    }
                }
            defer { estimator?.cancel() }
            do {
                try await engine.load { frac in
                    self.prepareProgress[id] = max(self.prepareProgress[id] ?? 0, frac)
                }
                downloadedModelIDs.insert(id)
                persistDownloaded()
                loadedModelID = id
            } catch {
                DebugLog.log("prepare failed \(id): \(error)")
                failureMessages[id] = error.localizedDescription
                if loadedModelID == id { loadedModelID = nil }
            }
            prepareProgress[id] = nil
            preparing = nil
        }
        // Make sure the brain the user actually has selected ends up resident,
        // in case pre-staging another brain evicted it.
        if downloadedModelIDs.contains(currentModelID),
            loadedModelID != currentModelID
        {
            enqueuePrepare(currentModelID)
        }
    }

    private func persistDownloaded() {
        UserDefaults.standard.set(Array(downloadedModelIDs), forKey: Self.downloadedKey)
    }

    // MARK: - status the UI reads

    func isDownloaded(_ id: String) -> Bool { downloadedModelIDs.contains(id) }

    /// Fraction (0...1) while a brain is downloading/loading, else nil.
    func prepareFraction(_ id: String) -> Double? { prepareProgress[id] }

    func isCurrent(_ id: String) -> Bool { id == currentModelID }
    func didFail(_ id: String) -> Bool { failureMessages[id] != nil }

    // MARK: - conversation

    func send(_ text: String, image: UIImage? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isGenerating, !trimmed.isEmpty || image != nil else { return }
        let prompt = trimmed.isEmpty ? "Should I worry about this?" : trimmed

        messages.append(ChatMessage(role: .user, text: prompt, image: image))
        messages.append(ChatMessage(role: .assistant, text: ""))
        let index = messages.count - 1
        isGenerating = true
        // Keep the screen awake for the whole turn: 30s auto-lock suspends
        // the app mid-generation and the reply freezes forever with no
        // error (watched on device 2026-07-11 — "it never finished").
        UIApplication.shared.isIdleTimerDisabled = true
        let ciImage = image.flatMap { CIImage(image: $0) }
        DebugLog.log("send: \"\(prompt)\"\(image != nil ? " +image" : "") via \(engine.modelName)")

        lastChunkAt = Date()
        generationTask = Task {
            do {
                for try await chunk in engine.respond(to: prompt, image: ciImage) {
                    lastChunkAt = Date()
                    messages[index].text += chunk
                }
                DebugLog.log("reply done (\(messages[index].text.count) chars)")
            } catch is CancellationError {
                DebugLog.log("generation cancelled")
            } catch {
                DebugLog.log("generation error: \(error)")
                messages[index].text += "\n\n⚠️ \(error.localizedDescription)"
            }
            isGenerating = false
            UIApplication.shared.isIdleTimerDisabled = false
        }
        // Watchdog: a turn that stops streaming and never errors (GPU work
        // frozen by a suspension, a wedged generation) must not spin
        // forever — kill it and say so, so the user can just ask again.
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(20))
                guard let self, self.isGenerating else { return }
                if Date().timeIntervalSince(self.lastChunkAt) > 150 {
                    DebugLog.log("watchdog: generation stalled >150s, cancelling")
                    self.generationTask?.cancel()
                    self.messages[index].text +=
                        "\n\n⚠️ That reply stalled — likely the screen locked or the app went to the background mid-answer. Ask again."
                    return
                }
            }
        }
    }

    func stopGenerating() {
        generationTask?.cancel()
    }

    /// New conversation: drop UI messages and the engine's history.
    func clear() {
        stopGenerating()
        messages.removeAll()
        engine.reset()
    }
}
