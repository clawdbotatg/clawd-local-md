import CoreImage
import Foundation

/// Abstraction over the generation backend so the app runs everywhere:
/// on device it's MLX + Qwen (`MLXEngine`); in the iOS Simulator — where MLX
/// has no Metal GPU — it's a canned `MockEngine`, keeping the full UI
/// testable in automated simulator runs.
@MainActor
protocol LLMEngine {
    var modelName: String { get }
    /// Download/prepare the current model. `onProgress` reports 0...1.
    func load(onProgress: @escaping @MainActor (Double) -> Void) async throws
    /// Switch which model the brain runs. Drops the loaded model so the next
    /// `load()` downloads/loads the new one. No-op if already selected.
    func setModel(_ id: String)
    /// Drop conversation history (new identification).
    func reset()
    /// With an `image`: identify it and stream the composed verdict.
    /// Without: answer a text follow-up about the last verdict.
    func respond(to prompt: String, image: CIImage?) -> AsyncThrowingStream<String, Error>
}

/// Simulator/test stand-in: MLX needs a real GPU, so the vision stage is
/// faked. Everything downstream is the real thing — the canned identification
/// goes through the same `TriageTable` the device uses, which makes the
/// simulator a genuine regression test for the verdict logic. The stand-in
/// finding is a bullseye rash, because early Lyme disease is exactly the
/// case where a curated URGENT verdict earns its keep.
@MainActor
final class MockEngine: LLMEngine {
    private var modelID = BrainCatalog.defaultID
    /// Models the sim has already "downloaded" this launch — a switch back is
    /// then instant, mirroring the device's on-disk cache.
    private var downloaded: Set<String> = []

    /// What the device's naming pass would return; runs the real TriageTable.
    private static let cannedName = "Bullseye rash"

    var modelName: String { BrainCatalog.displayName(for: modelID) }

    func setModel(_ id: String) { modelID = id }

    func load(onProgress: @escaping @MainActor (Double) -> Void) async throws {
        if downloaded.contains(modelID) {
            onProgress(1)
            return
        }
        for step in 1...20 {
            try await Task.sleep(for: .milliseconds(80))
            onProgress(Double(step) / 20)
        }
        downloaded.insert(modelID)
    }

    func reset() {}

    func respond(to prompt: String, image: CIImage?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream<String, Error> { continuation in
            let task = Task { @MainActor in
                guard image != nil else {
                    // Exercise the real bundled corpus, so a simulator run
                    // proves HealthCorpus.db ships and FTS5 answers — the
                    // same lookup the device model reaches via its tools.
                    let hits = HealthCorpus.search(prompt, limit: 3)
                    if let best = hits.first, let topic = HealthCorpus.topic(named: best.title) {
                        continuation.yield(
                            "Mock engine — offline library lookup for “\(prompt)”:\n"
                                + "Matches: \(hits.map(\.title).joined(separator: " · "))\n\n"
                                + "\(topic.title)\n\(topic.summary.prefix(400))…\n\n"
                                + "Source: MedlinePlus (NIH), \(topic.url)")
                    } else {
                        continuation.yield(
                            "Mock engine — no offline library match for “\(prompt)”. "
                                + "On an iPhone the on-device model answers follow-ups here.")
                    }
                    continuation.finish()
                    return
                }
                // Mirror the device's two passes: name it, show the name,
                // then judge it.
                try? await Task.sleep(for: .milliseconds(700))
                continuation.yield("ID: \(Self.cannedName)\n")
                try? await Task.sleep(for: .milliseconds(900))
                continuation.yield(
                    TriageTable.verdict(name: Self.cannedName, category: "rash").text)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
