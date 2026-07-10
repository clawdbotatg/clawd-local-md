import Foundation
import UIKit

struct ChatMessage: Identifiable, Equatable {
    enum Role {
        case user
        case assistant
    }

    /// The app (not the model) composes every verdict; see `DangerTable`.
    enum Verdict {
        case goodGuy
        case badGuy
        case caution
    }

    let id = UUID()
    let role: Role
    var text: String
    /// Photo the user attached (camera or library), shown in the bubble and
    /// sent to the vision model.
    var image: UIImage?

    init(role: Role, text: String, image: UIImage? = nil) {
        self.role = role
        self.text = text
        self.image = image
    }

    /// Qwen 3.x models can emit `<think>…</think>` reasoning blocks before the
    /// answer. Strip them for display; an unclosed tag means it is still thinking.
    var displayText: String {
        var s = text
        while let start = s.range(of: "<think>") {
            if let end = s.range(of: "</think>", range: start.upperBound..<s.endIndex) {
                s.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                s.removeSubrange(start.lowerBound..<s.endIndex)
                break
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isThinking: Bool {
        text.contains("<think>") && !text.contains("</think>")
    }

    /// Verdict banner. `nil` for follow-up answers and non-organism photos.
    var verdict: Verdict? { header.verdict }

    /// What the model said the thing *is* — shown so the user can check the
    /// identification themselves. A right verdict about the wrong species is
    /// still wrong, and only the person holding the phone can see both.
    var identification: String? { header.identification }

    /// The visible features the model based its identification on.
    var observed: String? { header.observed }

    /// The message body with the `VERDICT:`/`ID:`/`SAW:` header removed.
    var bodyText: String { header.body }

    /// Splits the composed header off the note. Header lines only count while
    /// they lead the message, so a follow-up answer that happens to mention
    /// "ID:" mid-paragraph is untouched.
    private var header: (verdict: Verdict?, identification: String?, observed: String?, body: String) {
        var verdict: Verdict?
        var identification: String?
        var observed: String?
        var body: [Substring] = []
        var inHeader = true

        for line in displayText.split(separator: "\n", omittingEmptySubsequences: false) {
            if inHeader {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                if let value = Self.value(of: "VERDICT", in: trimmed) {
                    verdict = Self.verdict(from: value)
                    continue
                }
                if let value = Self.value(of: "ID", in: trimmed) {
                    identification = value
                    continue
                }
                if let value = Self.value(of: "SAW", in: trimmed) {
                    observed = value
                    continue
                }
                inHeader = false
            }
            body.append(line)
        }
        return (
            verdict, identification, observed,
            body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func value(of key: String, in line: String) -> String? {
        guard line.lowercased().hasPrefix(key.lowercased() + ":") else { return nil }
        let value = String(line.dropFirst(key.count + 1))
            .trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// BAD is checked first so a muddled line errs toward the red banner.
    private static func verdict(from line: String) -> Verdict? {
        if line.contains("BAD") { return .badGuy }
        if line.contains("CAUTION") { return .caution }
        if line.contains("GOOD") { return .goodGuy }
        return nil
    }
}
