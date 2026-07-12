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

    /// Text turns get the same two-stage shape as photos: this tiny pass
    /// only NAMES what the user is describing — in the vocabulary the
    /// triage table speaks — and `TriageTable` judges it. It must never
    /// assess severity itself.
    private static let textNameInstructions = """
        The user typed a message to a health app. If it describes a health \
        event or finding happening to them or someone with them — an \
        injury, a bite, a burn, a symptom, something on their body — answer \
        with its short common medical name only. Two to four words, no \
        sentence. Like: snake bite. Or: chemical burn. Or: puncture wound. \
        Or: testicle pain. A ring or target shaped rash where a tick was \
        removed or attached is: bullseye rash

        If it is a general knowledge question, a follow-up about earlier \
        advice, or not about a health event, answer exactly: none
        Never add explanation or advice.
        """

    /// Pass 2, and only when the name isn't already in the triage table: one
    /// word, to pick the safe default.
    private static let categoryInstructions = """
        Answer with exactly one word from this list and nothing else:
        rash, mole, growth, bite, burn, wound, blister, swelling, nail, eye, mouth, scalp, other
        """

    /// Text turns: health questions from the first message on, and
    /// follow-ups once a photo verdict has been rendered.
    ///
    /// The library lookup is MANDATORY for symptom questions. A 4B model
    /// freestyling medicine is the failure mode this app exists to avoid —
    /// and without the hard rule it dodges into "take a photo" instead of
    /// answering (watched on device 2026-07-11: "my balls hurt" → "why not
    /// photograph it"). Look it up, answer from the source, then triage.
    private var followupInstructions: String {
        """
        You are Local MD, a private health helper running fully on-device \
        on the user's iPhone (\(modelName) via MLX — no cloud, nothing \
        leaves the phone). You are NOT A DOCTOR and you never diagnose, \
        but you always give a useful first look.

        You have an offline medical library on this phone: MedlinePlus, \
        from the NIH. When the user mentions ANY symptom, pain, body part, \
        condition, medicine, or treatment, you MUST look it up BEFORE \
        answering: call search_health_topics using proper medical terms \
        (translate slang first — "balls hurt" means testicle pain), then \
        get_health_topic on the best matching title. Base your answer on \
        what the library says and mention MedlinePlus as the source.

        Answer in 2 to 6 sentences: what this symptom most often means \
        according to the library, then how seriously to take it — always \
        repeat the library's when-to-get-care and emergency signs. Err \
        toward care: sudden, severe, or worsening symptoms deserve a \
        clinician today. Never tell the user it is nothing, and never \
        answer a symptom question with only "see a doctor" — say what the \
        library says first.

        If a VERDICT from a photo appears earlier in this conversation, it \
        is authoritative: do not contradict or soften it, and the library \
        never overrides it.

        Only suggest taking a photo when the concern is visible on the \
        skin, and only AFTER you have answered — never instead of \
        answering. Pain and internal symptoms cannot be photographed.

        If they mention severe pain, trouble breathing, fainting, or \
        feeling very unwell, tell them to seek care now. For possible \
        poisoning mention Poison Control; for emergencies, 911.
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
            toolDispatch: { call in await Self.dispatchTool(call) }
        )
    }

    /// One dispatcher for both paths: the library's native tool loop, and
    /// the engine's recovery of leaked tool calls (see `ToolCallRecovery`).
    /// A stuck tool must never hang the whole reply (the model waits on
    /// this result), so every tool races a 30s deadline.
    private static func dispatchTool(_ call: ToolCall) async -> String {
        DebugLog.log("tool call: \(call.function.name) args: \(call.function.arguments)")
        let result = await withDeadline(seconds: 30) {
            if let corpusResult = await CorpusTools.dispatch(call) { return corpusResult }
            if let moreResult = await MoreTools.dispatch(call) { return moreResult }
            return await PhoneTools.dispatch(call)
        } ?? #"{"error": "tool timed out after 30 seconds"}"#
        DebugLog.log("tool result: \(result.prefix(300))")
        return result
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

    /// Run one short, tool-free, history-free question — against the photo
    /// for the identification passes, or text-only for the naming pass.
    private func ask(
        instructions: String, prompt: String, image: CIImage? = nil, maxTokens: Int,
        container: ModelContainer
    ) async throws -> String {
        let session = makeSession(container, instructions: instructions, maxTokens: maxTokens)
        let message = Chat.Message.user(prompt, images: image.map { [.ciImage($0)] } ?? [])
        var raw = ""
        for try await chunk in session.streamResponse(to: [message]) { raw += chunk }
        return Self.stripThinking(raw)
    }

    // MARK: text follow-ups

    private func followUp(_ prompt: String, container: ModelContainer) -> AsyncThrowingStream<
        String, Error
    > {
        let userMessage = Chat.Message.user(prompt)
        DebugLog.log("follow-up (history: \(history.count) msgs)")

        return AsyncThrowingStream { continuation in
            Task { @MainActor in
                // What the user actually sees; committed to history at the
                // end. Raw tool-call text never reaches it (Scrubber), and
                // leaked calls are dispatched here with the turn continued —
                // up to two recovery rounds, then we stop retrying.
                var visible = ""
                // Model-authored prose only (status lines excluded) — if a
                // turn ends with none, the deterministic library fallback
                // below fires. A status line alone must not count as an
                // answer (watched on device 2026-07-11: "snake bite" turn
                // ended after the 🔎 line and looked hung).
                var answer = ""
                // Best topic seen while dispatching, for the fallback.
                var fallbackTopic: String?
                var conversation = self.history + [userMessage]
                do {
                    // Curated text triage FIRST — two stages, general by
                    // construction:
                    // 1. Literal match of the user's words against the whole
                    //    alias table (instant, free).
                    // 2. If that misses, the model NAMES what's being
                    //    described (tiny pass, the text twin of the photo
                    //    naming pass — "a rattler tagged me" → "snake bite")
                    //    and the table judges the name. The model never
                    //    decides severity; it only translates phrasing into
                    //    the table's vocabulary.
                    // Only urgent/soon banners, deduped across the chat.
                    var curated = TriageTable.textVerdict(prompt)
                    if curated?.verdict != .urgent {
                        // Run the naming stage unless the literal stage
                        // already maxed out, and keep the WORSE of the two —
                        // a sub-urgent literal match must not mask a worse
                        // normalized one.
                        let named = (try? await self.ask(
                            instructions: Self.textNameInstructions, prompt: prompt,
                            maxTokens: 16, container: container)) ?? ""
                        DebugLog.log("text-name pass: \(named.debugDescription)")
                        if named.range(of: "none", options: .caseInsensitive) == nil,
                            let name = TriageTable.sanitizeName(named)
                        {
                            curated = TriageTable.worse(
                                curated, TriageTable.findingVerdict(named: name))
                        }
                    }
                    if let curated,
                        !self.history.contains(where: { $0.content.contains(curated.text) })
                    {
                        let lead = curated.text + "\n\n"
                        visible += lead
                        answer += lead
                        continuation.yield(lead)
                        conversation.append(.assistant(curated.text))
                    }
                    for round in 1...3 {
                        // 512: a lookup turn spends tokens on tool calls
                        // before the answer; 300 truncated mid-sentence.
                        let session = self.makeSession(
                            container, instructions: self.followupInstructions,
                            maxTokens: 512, withTools: true)
                        var raw = ""
                        var scrubber = ToolCallRecovery.Scrubber()
                        for try await chunk in session.streamResponse(to: conversation) {
                            raw += chunk
                            if let clean = scrubber.pass(chunk), !clean.isEmpty {
                                visible += clean
                                answer += clean
                                continuation.yield(clean)
                            }
                        }
                        if let tail = scrubber.finish(), !tail.isEmpty {
                            visible += tail
                            answer += tail
                            continuation.yield(tail)
                        }
                        DebugLog.log(
                            "round \(round): raw \(raw.count) chars, visible \(answer.count): \(raw.prefix(160).replacingOccurrences(of: "\n", with: "⏎"))"
                        )

                        let leaked = ToolCallRecovery.leakedCalls(in: raw)
                        guard !leaked.isEmpty, round < 3 else { break }

                        // Show the lookup instead of tag spam, run the tools
                        // ourselves, and replay the turn the way the library
                        // does natively: assistant tool-call + tool results.
                        var followup: [Chat.Message] = [
                            .assistant(ToolCallRecovery.canonicalBlock(for: leaked))
                        ]
                        for call in leaked {
                            let status = ToolCallRecovery.statusLine(for: call) + "\n"
                            visible += status
                            continuation.yield(status)
                            let result = await Self.dispatchTool(call)
                            fallbackTopic =
                                ToolCallRecovery.topicTitle(call: call, result: result)
                                ?? fallbackTopic
                            followup.append(.tool(result))
                        }
                        conversation += followup
                    }
                    // The model went quiet without answering (EOS straight
                    // after a lookup, or a truncated tool call). Never leave
                    // the user hanging: print the library entry itself.
                    if answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let fallback = Self.libraryFallback(
                            topicTitle: fallbackTopic, query: prompt)
                        visible += fallback
                        continuation.yield(fallback)
                    }
                    self.commit(user: userMessage, reply: visible)
                    continuation.finish()
                } catch {
                    DebugLog.log("stream error: \(error)")
                    if !visible.isEmpty { self.commit(user: userMessage, reply: visible) }
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// When the model ends a turn without composing any prose, answer from
    /// the library directly — deterministic, sourced, and always ends with
    /// an escalation line. Reference text, not a verdict: severity language
    /// stays MedlinePlus's own.
    private static func libraryFallback(topicTitle: String?, query: String) -> String {
        guard let topicTitle, let topic = HealthCorpus.topic(named: topicTitle) else {
            return
                "I couldn't finish looking that up — ask me once more. If this is severe, sudden, or getting worse, don't wait on an app: get medical care now."
        }
        let excerpt = relevantExcerpt(from: topic.summary, query: query)
        return
            "Here's what MedlinePlus (NIH) says about \(topic.title):\n\n\(excerpt)\n\nIf this is severe, sudden, or getting worse, get medical care now — don't wait on an app."
    }

    /// The paragraphs of a topic that actually bear on the user's question,
    /// not just the top of the article — a topic opens with background and
    /// prevention, which is exactly wrong for "I just got bit" (watched on
    /// device 2026-07-11: a snakebite got "leave snakes alone"). Paragraphs
    /// are scored by overlap with the user's words, with a heavy boost for
    /// seek-care language, and kept in original order.
    private static func relevantExcerpt(from body: String, query: String, cap: Int = 900)
        -> String
    {
        let paragraphs = body.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard paragraphs.count > 1 else {
            return body.count > cap ? String(body.prefix(cap)) + "…" : body
        }
        let careSignals = [
            "911", "poison control", "emergency", "call your", "get medical", "seek",
            "right away", "immediately", "if you are bitten", "if you have been", "doctor if",
        ]
        let terms = Set(
            query.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 })
        let scored = paragraphs.enumerated().map { index, paragraph in
            let lower = paragraph.lowercased()
            let overlap = terms.filter { lower.contains($0) }.count
            let care = careSignals.filter { lower.contains($0) }.count * 3
            return (index: index, score: overlap + care, text: paragraph)
        }
        var chosen: [(index: Int, text: String)] = []
        var total = 0
        for candidate in scored.sorted(by: { $0.score > $1.score }) {
            if total + candidate.text.count > cap, !chosen.isEmpty { continue }
            chosen.append((candidate.index, candidate.text))
            total += candidate.text.count
            if total >= cap { break }
        }
        return chosen.sorted { $0.index < $1.index }.map(\.text).joined(separator: "\n\n")
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
