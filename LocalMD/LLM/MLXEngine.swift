#if !targetEnvironment(simulator)

import CoreImage
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// Real on-device backend: downloads the model from Hugging Face once,
/// then runs inference on the GPU via MLX.
///
/// **A photo is answered in two minimal passes, never one big one.**
///
/// 1. *Name it.* Image + a one-line prompt: "in very few words, what is
///    this?" Nothing else — no format, no categories, no severity talk. The
///    answer goes straight to the screen. Asking a 4B model to identify a
///    finding *and* fill in a template in one shot degrades both jobs: the
///    parent app watched it parrot the template back and stop naming things
///    it had previously named correctly (device, 2026-07-09).
/// 2. *Judge it.* `TriageTable` looks the name up. Only if the finding isn't
///    in the table does the model get a second, equally tiny question — one
///    word for the category — which selects the safe default.
///
/// The model is the eyes; the table is the encyclopedia. This model class
/// confidently inverts long-tail medical facts, so it is never asked how
/// serious anything is — that separation is the whole app.
@MainActor
final class MLXEngine: LLMEngine {
    /// Which brain runs, as a `BrainCatalog` repo id. The UI switches it via
    /// `setModel`; `BrainCatalog` is the curated set of models that actually
    /// fit and load (the 8B Qwen loads on a 12 GB phone but jetsam-kills the
    /// instant it generates — verified 2026-07-07; 4B is the ceiling).
    private var modelID = BrainCatalog.defaultID

    /// Build a real `ModelConfiguration` for a catalog id. The stop tokens
    /// matter: without them a Qwen model never emits EOS and runs to the token
    /// cap every turn, and Gemma likewise. Keyed off the id so any catalog
    /// model works without a per-model table here.
    private static func configuration(for id: String) -> ModelConfiguration {
        let eos: Set<String>
        if id.contains("Qwen") {
            eos = ["<|im_end|>"]
        } else if id.lowercased().contains("gemma") {
            eos = ["<end_of_turn>"]
        } else {
            eos = []
        }
        return ModelConfiguration(id: id, extraEOSTokens: eos)
    }

    /// Pass 1. As little context as possible: look, and name it.
    private static let nameInstructions = """
        Look at the photo and name the visible skin or body finding in it.

        Answer with the name only — no sentence, no punctuation, no \
        explanation. Two to six words. Like: Ringworm. Or: Hives. Or: \
        Blistering burn. Or: Dark raised mole.

        If the photo does not show a person's skin or body, answer: not a body part
        If you truly cannot tell, answer: unknown
        Never say whether it is serious or harmless, and never give advice.
        """

    /// Pass 2, and only when the name isn't already in the triage table: one
    /// word, to pick the safe default.
    private static let categoryInstructions = """
        Answer with exactly one word from this list and nothing else:
        rash, mole, growth, bite, burn, wound, blister, swelling, nail, eye, mouth, scalp, other
        """

    /// Follow-up questions after a verdict has been rendered.
    private var followupInstructions: String {
        """
        You are Local MD, a private first-look helper running fully \
        on-device on the user's iPhone (\(modelName) via MLX — no cloud, \
        photos never leave the phone). You are NOT A DOCTOR and you never \
        diagnose. The user photographed a health concern and already \
        received a triage verdict, shown earlier in this conversation.

        Answer their follow-up briefly — a few sentences, no filler. The \
        verdict and the guidance already given are authoritative: do not \
        contradict them, do not soften them, and do not invent new medical \
        claims, diagnoses, or treatments. If you don't know, say so and \
        tell them a clinician is the right next step.

        Never tell the user something is safe to ignore. If they mention \
        fever, spreading, severe pain, trouble breathing, or feeling very \
        unwell, tell them to seek medical care now. For possible poisoning \
        mention Poison Control; for emergencies, 911.

        You have an offline reference library on this phone: MedlinePlus, \
        from the NIH. For factual questions — what a condition is, what \
        usually helps, how to prevent it — call search_health_topics, then \
        get_health_topic on the best title, and base your answer on what it \
        says, mentioning MedlinePlus as the source. The library is \
        reference material only: it never overrides or softens the verdict \
        above, and if it seems to conflict, the verdict wins.
        """
    }

    private var container: ModelContainer?
    /// Conversation so far (user + assistant turns, think-blocks stripped).
    /// Kept here because each turn runs in a FRESH ChatSession — reusing a
    /// session's KV cache across turns is broken for Qwen3-VL in
    /// mlx-swift-lm 3.31.4 (turn 2+ hangs or emits corrupted text, verified
    /// on device 2026-07-07); replaying history costs a short prefill and
    /// stays correct.
    private var history: [Chat.Message] = []

    var modelName: String { BrainCatalog.displayName(for: modelID) }

    func setModel(_ id: String) {
        guard id != modelID else { return }
        DebugLog.log("setModel: \(modelID) -> \(id)")
        modelID = id
        // Drop the loaded brain so the next load() downloads/loads the new
        // one; ARC frees the old ModelContainer's weights.
        container = nil
        history = []
    }

    func load(onProgress: @escaping @MainActor (Double) -> Void) async throws {
        guard container == nil else { return }

        // Cap MLX's GPU buffer cache so inference stays inside the iOS
        // per-app memory budget.
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)

        let configuration = Self.configuration(for: modelID)
        DebugLog.log("load() starting, model: \(modelID)")
        let container = try await #huggingFaceLoadModelContainer(
            configuration: configuration,
            progressHandler: { progress in
                let fraction = progress.fractionCompleted
                DebugLog.log("download progress: \(fraction) (\(progress.completedUnitCount)/\(progress.totalUnitCount))")
                Task { @MainActor in
                    onProgress(fraction)
                }
            }
        )
        DebugLog.log("model container loaded")
        self.container = container
        reset()
    }

    func reset() {
        history = []
    }

    /// One fresh ChatSession per turn (see `history` comment). The two
    /// identification passes get no tools: they should look at the photo and
    /// answer, not reach for the phone.
    private func makeSession(
        _ container: ModelContainer, instructions: String, maxTokens: Int,
        withTools: Bool = false
    ) -> ChatSession {
        ChatSession(
            container,
            instructions: instructions,
            // Qwen's recommended sampling for instruct models; the repetition
            // penalty stops the degenerate "2023 and 2024. 2023 and 2024. …"
            // loops a 4-bit 4B model falls into. Keep the window at 64: at 128
            // a keyword the answer needs is still in-window when it starts,
            // the penalty vetoes completing the word, and the model stutters
            // (seen on device 2026-07-09). maxTokens is the hard stop when EOS
            // never fires.
            generateParameters: GenerateParameters(
                maxTokens: maxTokens,
                temperature: 0.7,
                topP: 0.8,
                repetitionPenalty: 1.15,
                repetitionContextSize: 64
            ),
            tools: withTools ? CorpusTools.specs + PhoneTools.specs + MoreTools.specs : [],
            toolDispatch: { call in
                DebugLog.log("tool call: \(call.function.name) args: \(call.function.arguments)")
                // A stuck tool must never hang the whole reply (the model
                // waits on this result), so every tool races a 30s deadline.
                let result = await Self.withDeadline(seconds: 30) {
                    if let corpusResult = await CorpusTools.dispatch(call) { return corpusResult }
                    if let moreResult = await MoreTools.dispatch(call) { return moreResult }
                    return await PhoneTools.dispatch(call)
                } ?? #"{"error": "tool timed out after 30 seconds"}"#
                DebugLog.log("tool result: \(result.prefix(300))")
                return result
            }
        )
    }

    private static func withDeadline(
        seconds: Double, _ body: @escaping @Sendable () async -> String
    ) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask { await body() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    func respond(to prompt: String, image: CIImage?) -> AsyncThrowingStream<String, Error> {
        guard let container else {
            return AsyncThrowingStream { $0.finish(throwing: EngineError.notLoaded) }
        }
        if let image {
            return identify(image, container: container)
        }
        return followUp(prompt, container: container)
    }

    // MARK: photo → name, then name → verdict

    private func identify(_ image: CIImage, container: ModelContainer) -> AsyncThrowingStream<
        String, Error
    > {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                do {
                    // ---- Pass 1: what is it? ----
                    let reply = try await self.ask(
                        instructions: Self.nameInstructions, prompt: "What is this?",
                        image: image, maxTokens: 32, container: container)
                    DebugLog.log("name pass: \(reply.debugDescription)")

                    if TriageTable.isNotBodyPhoto(reply) {
                        continuation.yield(
                            "That doesn't look like a photo of skin or a body area. Retake it with the spot you're wondering about filling the frame, in good light."
                        )
                        self.history = []
                        continuation.finish()
                        return
                    }

                    let name = TriageTable.sanitizeName(reply)
                    let hedged = TriageTable.isHedged(reply)

                    // Show the identification immediately — the user asked
                    // what it is, and the triage pass may take a moment.
                    continuation.yield("ID: \(name ?? "Couldn't identify it")\n")

                    // ---- Pass 2: how seriously should it be taken? ----
                    // The table answers directly for anything it knows. Only
                    // an unknown name needs the model's category, and only to
                    // pick the safe default.
                    var category: String?
                    if let name, TriageTable.lookup(name: name) == nil {
                        category = try await self.categorize(name, image: image, container: container)
                        DebugLog.log("category pass: \(category ?? "nil")")
                    }

                    let result = TriageTable.verdict(
                        name: name, category: category, hedged: hedged)
                    DebugLog.log(
                        "id=\(name ?? "none") verdict=\(result.verdict.map(String.init(describing:)) ?? "none")")
                    continuation.yield(result.text)

                    // History carries the verdict the user saw, so follow-ups
                    // reason from those facts.
                    self.history = [
                        .user("[photo of a health concern the user noticed]"),
                        .assistant("ID: \(name ?? "unidentified")\n\(result.text)"),
                    ]
                    continuation.finish()
                } catch {
                    DebugLog.log("identify error: \(error)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// One-word category, used only to pick the safe default for a name the
    /// triage table doesn't know.
    private func categorize(_ name: String, image: CIImage, container: ModelContainer)
        async throws -> String?
    {
        let reply = try await ask(
            instructions: Self.categoryInstructions,
            prompt: "This looks like: \(name). Which one word describes it?",
            image: image, maxTokens: 8, container: container)
        let word = TriageTable.firstMeaningfulLine(reply)?
            .lowercased()
            .trimmingCharacters(in: CharacterSet.letters.inverted)
        return word.flatMap { TriageTable.categories.contains($0) ? $0 : nil }
    }

    /// Run one short, tool-free, history-free question against the photo.
    private func ask(
        instructions: String, prompt: String, image: CIImage, maxTokens: Int,
        container: ModelContainer
    ) async throws -> String {
        let session = makeSession(container, instructions: instructions, maxTokens: maxTokens)
        let message = Chat.Message.user(prompt, images: [.ciImage(image)])
        var raw = ""
        for try await chunk in session.streamResponse(to: [message]) { raw += chunk }
        return Self.stripThinking(raw)
    }

    // MARK: text follow-ups

    private func followUp(_ prompt: String, container: ModelContainer) -> AsyncThrowingStream<
        String, Error
    > {
        let session = makeSession(
            container, instructions: followupInstructions, maxTokens: 300, withTools: true)
        let userMessage = Chat.Message.user(prompt)
        let upstream = session.streamResponse(to: history + [userMessage])
        DebugLog.log("follow-up (history: \(history.count) msgs)")

        return AsyncThrowingStream { continuation in
            Task { @MainActor in
                var reply = ""
                do {
                    for try await chunk in upstream {
                        reply += chunk
                        continuation.yield(chunk)
                    }
                    self.commit(user: userMessage, reply: reply)
                    continuation.finish()
                } catch {
                    DebugLog.log("stream error: \(error)")
                    if !reply.isEmpty { self.commit(user: userMessage, reply: reply) }
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Append a finished exchange to the replayed history. Think-blocks are
    /// dropped (Qwen convention: prior-turn reasoning is not replayed).
    private func commit(user: Chat.Message, reply: String) {
        history.append(user)
        history.append(
            .assistant(
                Self.stripThinking(reply).trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    /// Qwen 3.x emits `<think>…</think>`; strip it before parsing or replaying.
    private static func stripThinking(_ text: String) -> String {
        var s = text
        while let start = s.range(of: "<think>") {
            guard let end = s.range(of: "</think>", range: start.upperBound..<s.endIndex) else {
                s.removeSubrange(start.lowerBound..<s.endIndex)
                break
            }
            s.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum EngineError: LocalizedError {
        case notLoaded
        var errorDescription: String? { "The model is not loaded yet." }
    }
}

#endif
