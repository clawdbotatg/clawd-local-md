import Foundation
import MLXLMCommon

/// Recovery for tool calls the library's parser gives up on.
///
/// mlx-swift-lm's `ToolCallProcessor` intercepts well-formed
/// `<tool_call>{json}</tool_call>` blocks, but when a 4-bit model stutters
/// the opening tag (`<tool_call>\n<tool_call>\n{json}` — watched on device
/// 2026-07-11), the tag-content JSON parse fails and the processor flushes
/// the whole block to the stream as plain text: the user sees raw tags and
/// the turn dies without an answer. These helpers (1) keep any tool-call
/// text out of the visible stream, and (2) re-parse the leaked call so the
/// engine can dispatch it and continue the turn itself.
enum ToolCallRecovery {

    static let startTag = "<tool_call>"
    static let endTag = "</tool_call>"

    /// Streaming filter: passes normal text through, holds back anything
    /// from a (possibly partial) `<tool_call>` opener until the block
    /// closes, and drops the block itself. The engine keeps the raw text
    /// separately for `leakedCalls(in:)`.
    struct Scrubber {
        private var buffer = ""
        private var suppressing = false

        mutating func pass(_ chunk: String) -> String? {
            buffer += chunk
            var out = ""
            while true {
                if suppressing {
                    if let end = buffer.range(of: ToolCallRecovery.endTag) {
                        buffer = String(buffer[end.upperBound...])
                        suppressing = false
                        continue
                    }
                    return out.isEmpty ? nil : out
                }
                if let start = buffer.range(of: ToolCallRecovery.startTag) {
                    out += String(buffer[..<start.lowerBound])
                    buffer = String(buffer[start.upperBound...])
                    suppressing = true
                    continue
                }
                // Hold back a partial opener at the tail ("<tool_ca") so a
                // tag split across chunks never flashes on screen.
                let hold = ToolCallRecovery.partialSuffix(buffer, of: ToolCallRecovery.startTag)
                let cut = buffer.index(buffer.endIndex, offsetBy: -hold)
                out += String(buffer[..<cut])
                buffer = String(buffer[cut...])
                return out.isEmpty ? nil : out
            }
        }

        /// End of stream: emit what's held back — unless it's (part of) a
        /// tool-call block, which is never shown.
        mutating func finish() -> String? {
            defer {
                buffer = ""
                suppressing = false
            }
            if suppressing { return nil }
            let tail = buffer
            return tail.isEmpty ? nil : tail
        }
    }

    /// Longest k such that the buffer ends with the first k characters of
    /// the tag (k < tag length) — i.e. a possible tag split by chunking.
    static func partialSuffix(_ buffer: String, of tag: String) -> Int {
        var k = min(buffer.count, tag.count - 1)
        while k > 0 {
            if buffer.hasSuffix(String(tag.prefix(k))) { return k }
            k -= 1
        }
        return 0
    }

    /// Tool calls the processor leaked into the text: every top-level JSON
    /// object after a `<tool_call>` marker that decodes as {name, arguments}.
    static func leakedCalls(in raw: String) -> [ToolCall] {
        guard raw.contains(startTag) else { return [] }
        var calls: [ToolCall] = []
        var search = raw.startIndex
        while let brace = raw[search...].firstIndex(of: "{"), calls.count < 4 {
            if let object = topLevelObject(in: raw, from: brace),
                let function = try? JSONDecoder().decode(
                    ToolCall.Function.self, from: Data(object.text.utf8))
            {
                calls.append(ToolCall(function: function))
                search = object.end
            } else {
                search = raw.index(after: brace)
            }
        }
        return calls
    }

    /// The complete `{…}` starting at `start`, brace-counted and
    /// string-aware, or nil if unterminated.
    private static func topLevelObject(in text: String, from start: String.Index)
        -> (text: String, end: String.Index)?
    {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                switch character {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        let end = text.index(after: index)
                        return (String(text[start..<end]), end)
                    }
                default: break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// A canonical, well-formed tool-call block for replaying into the
    /// conversation as the assistant turn (what the model *meant* to emit).
    static func canonicalBlock(for calls: [ToolCall]) -> String {
        calls.map { call in
            let json =
                (try? JSONEncoder().encode(call.function))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return "\(startTag)\n\(json)\n\(endTag)"
        }.joined(separator: "\n")
    }

    /// One-line status shown to the user while a recovered lookup runs —
    /// the clean version of what used to be raw tag spam.
    static func statusLine(for call: ToolCall) -> String {
        let subject =
            (call.function.arguments["query"]?.anyValue as? String)
            ?? (call.function.arguments["title"]?.anyValue as? String)
        switch call.function.name {
        case "search_health_topics":
            return "🔎 Searching the medical library\(subject.map { " — \($0)" } ?? "")…"
        case "get_health_topic":
            return "📖 Reading\(subject.map { ": \($0)" } ?? " the topic")…"
        default:
            return "⚙️ Using \(call.function.name)…"
        }
    }
}
