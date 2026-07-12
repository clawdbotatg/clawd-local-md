import Foundation

/// The app's triage authority.
///
/// **The model never decides how serious something is.** A 4-bit 4B VLM is
/// good at *seeing* ("that's a ring-shaped rash") and bad at *recalling*
/// long-tail medical facts — the parent app watched the same model class
/// confidently invert a life-or-death toxicity fact. So the model only names
/// what it sees, and the triage level is looked up here, in curated data that
/// ships inside the app and works with zero bars.
///
/// Levels, worst first: URGENT (get care now) > SOON (see a clinician in the
/// next day or two) > WATCH (worth a professional look; keep an eye on it) >
/// ROUTINE (usually minor, self-care, with explicit escalation triggers).
/// There is deliberately no "you're fine" level: a photo cannot rule
/// anything out, and this app is NOT A DOCTOR.
///
/// Safety posture, in order:
/// 1. A table hit decides the level. The most **specific** alias wins (so
///    "blood blister" doesn't hit the `blister` entry), and severity breaks
///    ties toward care.
/// 2. An ambiguous ID ("cold sore or impetigo") that matches entries at
///    different levels escalates to the worst matched level — a photo can't
///    tell look-alikes apart, so treat it as the more serious possibility.
/// 3. No hit → never ROUTINE. Bites, burns, wounds, and eye findings default
///    to SOON; everything else to WATCH. A small model failing to recognize
///    something is NOT evidence that it is minor.
/// 4. Moles and pigmented spots are never ROUTINE, even on a match — no photo
///    can rule out melanoma, so a matched mole is floored at WATCH with the
///    ABCDE self-check appended.
/// 5. A hedged identification downgrades ROUTINE to WATCH. Hedging never
///    *rescues* a serious match — "possible melanoma" stays URGENT.
/// 6. If decoding the table ever fails, `entries` is empty and everything
///    falls through to the category defaults — i.e. it fails toward care.
///
/// Adding an entry: put every name the model might say in `names` — the
/// common condition name AND plain visual descriptions ("ringworm",
/// "ring-shaped rash"). Matching is word-boundary and case-insensitive, so
/// short/generic aliases like "rash", "bump", "cut", or "burn" are unsafe on
/// their own — an unmatched generic should fall to the category default, not
/// a random entry. Keep `note` to a few factual sentences ending with the
/// escalation triggers; it is printed verbatim as the authoritative answer.
struct TriageEntry: Decodable {
    let names: [String]
    let category: String
    let level: String  // "urgent" | "soon" | "watch" | "routine"
    let note: String
    /// Short provenance tag ("AAD", "Mayo Clinic", "CDC") — the methodology
    /// behind every claim, kept with the claim.
    let source: String
}

struct VerdictResult {
    /// `nil` renders no banner (e.g. the photo isn't of a body part).
    let verdict: ChatMessage.Verdict?
    /// The `VERDICT:` line plus the authoritative note. The identification is
    /// streamed to the UI separately, before this, by the engine.
    let text: String
}

enum TriageTable {

    /// Categories where failing to match means SOON, not just WATCH: an
    /// unidentifiable burn, wound, bite, or eye problem is a reason to be
    /// seen, not reassured.
    private static let soonOnMiss: Set<String> = ["bite", "burn", "wound", "eye"]

    /// The only categories the category pass may emit; anything else is `other`.
    static let categories: Set<String> = [
        "rash", "mole", "growth", "bite", "burn", "wound", "blister",
        "swelling", "nail", "eye", "mouth", "scalp", "other",
    ]

    static let entries: [TriageEntry] = {
        do {
            return try JSONDecoder().decode([TriageEntry].self, from: Data(json.utf8))
        } catch {
            // Fails safe: an empty table sends every category to its default,
            // which is WATCH or SOON — never ROUTINE.
            DebugLog.log("TriageTable decode FAILED: \(error) — falling back to defaults")
            return []
        }
    }()

    /// Appended whenever the mole floor fires: the one self-check worth
    /// teaching, verbatim from dermatology guidance.
    /// Rides along with every photo match that would otherwise read "usually
    /// minor" — see the floor in `verdict`.
    private static let photoCaveat =
        " But a photo can't confirm this: the on-device model reads appearance, not diagnosis, and serious conditions can look like minor ones. Treat this as a first look, not an all-clear — if it spreads, changes, worsens, or you feel unwell, have a clinician see it."

    private static let abcde =
        " A photo can never rule out skin cancer. Check ABCDE — Asymmetry, uneven Border, more than one Color, Diameter over 6 mm, Evolving — and show a clinician anything new, changing, or that looks different from your other spots."

    // MARK: reading the naming pass

    /// True when the model says the photo isn't of a body part at all.
    static func isNotBodyPhoto(_ reply: String) -> Bool {
        reply.range(of: "not a body part", options: .caseInsensitive) != nil
    }

    /// Pull a usable name out of the naming pass's reply, or nil.
    ///
    /// Rejects the placeholders a 4B model parrots back from a prompt (the
    /// parent app watched "<common name>" get matched against the table and
    /// produce a nonsense warning).
    static func sanitizeName(_ reply: String) -> String? {
        guard let line = firstMeaningfulLine(reply), line.count <= 60 else { return nil }
        if line.range(of: "unknown", options: .caseInsensitive) != nil { return nil }
        return displayName(line)
    }

    /// True when the model hedged its identification.
    static func isHedged(_ reply: String) -> Bool {
        ["uncertain", "not sure", "unknown", "possibly", "might be"].contains {
            reply.range(of: $0, options: .caseInsensitive) != nil
        }
    }

    /// The table entry a name resolves to, if any. Used by the engine to skip
    /// the category pass when the finding is already known.
    static func lookup(name: String) -> TriageEntry? {
        bestMatch(in: name)?.entry
    }

    // MARK: verdict

    /// Decide the triage level for an identified finding. `category` only
    /// matters when the name isn't in the table — it selects the safe default.
    static func verdict(name: String?, category: String?, hedged: Bool = false) -> VerdictResult {
        let category = categories.contains(category ?? "") ? category! : "other"

        // Without a name we have nothing to look up, and we will not guess.
        guard let name else {
            return compose(
                .watch,
                "I couldn't make out what's in the photo, so I can't offer a first look. Try again in good light, close up, with the area in focus. And if something feels wrong, don't wait on an app — have a clinician look at it."
            )
        }

        // Look-alike escalation: the ID names alternatives ("cold sore or
        // impetigo") that sit at different triage levels. A photo can't
        // resolve it, so the safe answer is the more serious possibility.
        let matches = allMatches(in: name)
        if isAmbiguous(name), Set(matches.map(\.level)).count > 1,
            let worst = matches.max(by: { severity($0.level) < severity($1.level) })
        {
            let worstName = worst.names
                .filter { contains(name, word: $0) }
                .max(by: { $0.count < $1.count }) ?? worst.names[0]
            return compose(
                uiVerdict(worst.level),
                "This could be more than one thing, and a photo can't tell look-alikes apart — so treat it as the more serious possibility, \(worstName). \(worst.note)"
            )
        }

        if let best = lookup(name: name) {
            // Moles/pigmented spots never render better than WATCH, and the
            // ABCDE self-check always rides along.
            if best.category == "mole" || category == "mole" {
                let floored = severity(best.level) <= severity("watch") ? "watch" : best.level
                return compose(uiVerdict(floored), best.note + abcde)
            }
            // A hedged ROUTINE is downgraded — we may be looking at the wrong
            // thing entirely. Hedging never rescues a serious match.
            if hedged, best.level == "routine" {
                return compose(
                    .watch,
                    "The model isn't confident about what this is. It resembles \(best.names[0]), which is usually minor — but that's not certain enough to lean on. If it doesn't clearly improve in a few days, or it worsens at all, have a clinician look at it."
                )
            }
            // A PHOTO IS NEVER AN ALL-CLEAR. Measured against real clinical
            // photographs, the model names appearance well but conditions
            // badly: it called shingles "Red rash", cellulitis "Red leg
            // swelling", and a Lyme bullseye "Insect bite" — which resolved
            // to ROUTINE, "usually minor" (photo battery, 2026-07-11). The
            // table cannot rescue a confidently wrong name, so a photo match
            // is floored at WATCH: the self-care note still prints, but the
            // banner never claims minor on evidence the model can't supply.
            if best.level == "routine" {
                return compose(.watch, best.note + photoCaveat)
            }
            return compose(uiVerdict(best.level), best.note)
        }

        // No match. Silence from a small model is not reassurance.
        if soonOnMiss.contains(category) {
            return compose(
                .soon,
                "I can't match this to my curated list — and with a \(category) finding, that's a reason to be seen, not reassured. Have a clinician look at it in the next day or two, sooner if it's getting worse."
            )
        }
        if category == "mole" {
            return compose(.watch, "I can't match this to my curated list." + abcde)
        }
        return compose(
            .watch,
            "This isn't something I can match in my curated list, so the honest answer is: worth keeping an eye on. If it grows, spreads, hurts, bleeds, doesn't fade over a couple of weeks, or simply worries you, have a clinician look at it."
        )
    }

    /// Curated triage for a TYPED symptom description — the photo pipeline's
    /// authority extended to text. Matches the user's own words against the
    /// same alias table (entries carry natural phrasings like "bit by a
    /// snake") and fires only for URGENT/SOON matches: emergencies get the
    /// curated banner and note before the model says a word, while minor and
    /// unmatched messages stay conversational. Multiple matches escalate to
    /// the worst, same as look-alikes.
    static func textVerdict(_ text: String) -> VerdictResult? {
        guard let worst = textMatch(text), severity(worst.level) >= severity("soon")
        else { return nil }
        return compose(uiVerdict(worst.level), worst.note)
    }

    /// The worst entry matching the user's typed words, at ANY level — or nil
    /// if the words match nothing in the table.
    ///
    /// The engine uses `nil` as the sole trigger for the model naming pass:
    /// a match here (even a benign, non-bannering one) means the table has
    /// spoken and the model must not overrule it. Handed a closed menu of
    /// banner-worthy conditions, a 4B force-picks the scariest near-neighbor
    /// rather than saying none — a nosebleed became "severe bleeding", a
    /// concussion "thunderclap headache" (harness, 2026-07-11). The table is
    /// the authority; the model only fills genuine gaps.
    static func textMatch(_ text: String) -> TriageEntry? {
        (allMatches(in: text) + [lymeEscalation(text)].compactMap { $0 })
            .max(by: { severity($0.level) < severity($1.level) })
    }

    /// The one look-alike that contiguous aliases cannot express, and the most
    /// important curated case in the app: a ring/target/expanding rash means
    /// ordinary **ringworm** on its own, but early **Lyme** when a tick is also
    /// mentioned — and the two sit at opposite ends of the severity scale.
    /// Aliases match phrases, not co-occurrence, so "a ring shaped rash a week
    /// after pulling a tick off me" matched only the tick-bite entry (SOON) and
    /// the bullseye rash (URGENT) was masked (harness, 2026-07-11). Checked
    /// explicitly, and deliberately narrow: it needs a tick AND a ring-ish word
    /// AND a rash word.
    private static func lymeEscalation(_ text: String) -> TriageEntry? {
        guard contains(text, word: "tick") else { return nil }
        let ringWords = ["ring", "ring-shaped", "circular", "target", "bullseye", "bull's-eye", "expanding"]
        let rashWords = ["rash", "spot", "mark", "patch", "redness"]
        guard ringWords.contains(where: { contains(text, word: $0) }),
            rashWords.contains(where: { contains(text, word: $0) })
        else { return nil }
        return entries.first { $0.names.first == "bullseye rash" }
    }

    /// The closed vocabulary the text-naming pass chooses from: the primary
    /// name of every entry that can banner (urgent/soon).
    ///
    /// Open-vocabulary naming could not be made to work. The model invented a
    /// new clinically-correct synonym every single run — "melena", then "upper
    /// GI bleed"; "ingestion poison", then "chemical ingestion"; "water
    /// inhalation", then "pool water aspiration" — and the alias list could
    /// never catch up (device + harness, 2026-07-11). So the model is handed
    /// the table's OWN words and must pick one or say none, exactly like the
    /// photo pipeline's closed category list. New entries join the menu
    /// automatically, so this can't drift.
    static var bannerVocabulary: [String] {
        entries
            .filter { severity($0.level) >= severity("soon") }
            .map { $0.names[0] }
    }

    /// Verdict for a NORMALIZED finding name — the text pipeline's general
    /// path. `textVerdict` is the zero-latency literal matcher; when it
    /// misses, the engine asks the model to *name* what the user is
    /// describing ("a rattler tagged me" → "snake bite") and that name is
    /// looked up here. Same gate: only urgent/soon banners. The model names,
    /// the table judges — severity never comes from the model.
    static func findingVerdict(named name: String) -> VerdictResult? {
        if let entry = lookup(name: name) {
            guard severity(entry.level) >= severity("soon") else { return nil }
            return compose(uiVerdict(entry.level), entry.note)
        }
        // The photo pipeline's soon-on-miss posture, for text: the model
        // named something the table can't place ("thermal burn"), but the
        // name itself says it's a burn/bite/wound — and an unplaceable one
        // of those is a reason to be seen, not to chat.
        let lower = name.lowercased()
        // Deliberately NOT "eye": eyes now have specific entries (pink eye,
        // stye, chemical splash, snow blindness), and a soon-on-miss eye
        // fallback over-called benign goopy eyes (device, 2026-07-11).
        let categoryWords = [
            ("burn", "burn"), ("scald", "burn"), ("bite", "bite"), ("sting", "bite"),
            ("wound", "wound"), ("laceration", "wound"), ("puncture", "wound"),
        ]
        guard let (_, category) = categoryWords.first(where: { lower.contains($0.0) })
        else { return nil }
        return compose(
            .soon,
            "I can't match this exactly in my curated list — and with a \(category) finding, that's a reason to be seen, not reassured. Have a clinician look at it in the next day or two, sooner if it's getting worse."
        )
    }

    private static func compose(_ verdict: ChatMessage.Verdict, _ note: String) -> VerdictResult {
        let label =
            switch verdict {
            case .urgent: "URGENT"
            case .soon: "SOON"
            case .watch: "WATCH"
            case .routine: "ROUTINE"
            }
        return VerdictResult(verdict: verdict, text: "VERDICT: \(label)\n\n\(note)")
    }

    private static func uiVerdict(_ raw: String) -> ChatMessage.Verdict {
        switch raw {
        case "urgent": .urgent
        case "soon": .soon
        case "routine": .routine
        default: .watch
        }
    }

    private static func severity(_ level: String) -> Int {
        switch level {
        case "urgent": 3
        case "soon": 2
        case "watch": 1
        default: 0
        }
    }

    // MARK: matching

    /// Every entry whose alias appears in the text (used for look-alike
    /// escalation).
    private static func allMatches(in text: String) -> [TriageEntry] {
        entries.filter { entry in entry.names.contains { contains(text, word: $0) } }
    }

    /// Whether the text names alternatives ("cold sore OR impetigo") rather
    /// than one finding that merely contains a shared word ("blood blister").
    /// Only then is a multi-level match a genuine look-alike.
    private static func isAmbiguous(_ text: String) -> Bool {
        let lower = text.lowercased()
        // Whole-word markers.
        let words = ["or", "possibly", "mimic", "either", "vs", "uncertain"]
        if words.contains(where: {
            lower.range(of: "\\b\($0)\\b", options: .regularExpression) != nil
        }) { return true }
        // Substring markers (phrases / punctuation).
        let phrases = ["look-alike", "lookalike", "could be", "not sure", "/", "?"]
        return phrases.contains { lower.contains($0) }
    }

    /// The **most specific** alias wins, and severity only breaks ties.
    ///
    /// Severity-first would be wrong in both directions: "fever blister" (a
    /// cold sore) would trip scarier blister guidance, and "blood blister"
    /// would miss its own entry. Specificity-first keeps the safety bias
    /// where it belongs: a name citing two findings of equal specificity
    /// still resolves to the more serious one.
    private static func bestMatch(in text: String) -> (entry: TriageEntry, specificity: Int)? {
        var best: (entry: TriageEntry, specificity: Int)?
        for entry in entries {
            let longest = entry.names
                .filter { contains(text, word: $0) }
                .map(\.count).max()
            guard let longest else { continue }
            guard let current = best else {
                best = (entry, longest)
                continue
            }
            let moreSpecific = longest > current.specificity
            let tieBrokenBySeverity =
                longest == current.specificity
                && severity(entry.level) > severity(current.entry.level)
            if moreSpecific || tieBrokenBySeverity { best = (entry, longest) }
        }
        return best
    }

    /// Whole-word, case-insensitive containment, tolerant of plurals.
    ///
    /// Substring matching would let "sting" fire inside "stinging", so the
    /// match is word-bounded. But a bare `\bstye\b` misses "styes" — so each
    /// alias also matches its regular plural forms.
    private static func contains(_ haystack: String, word: String) -> Bool {
        let stem = NSRegularExpression.escapedPattern(for: word)
        // stye → stye(s); berry → berr(y|ies); rash → rash(es)
        let body =
            word.hasSuffix("y")
            ? String(stem.dropLast()) + "(?:y|ies)"
            : stem + "(?:s|es)?"
        guard
            let regex = try? NSRegularExpression(
                pattern: "\\b" + body + "\\b", options: [.caseInsensitive])
        else { return false }
        let range = NSRange(haystack.startIndex..., in: haystack)
        return regex.firstMatch(in: haystack, range: range) != nil
    }

    // MARK: text hygiene

    /// First non-empty line, stripped of the quotes, bullets, labels, and
    /// trailing punctuation a small model wraps a bare answer in.
    static func firstMeaningfulLine(_ text: String) -> String? {
        for line in stripEchoedTemplate(text).split(separator: "\n") {
            var trimmed = line.trimmingCharacters(
                in: CharacterSet(charactersIn: " \t*-#•>\"'.,;:"))
            // "Answer: Ringworm" / "ID: Ringworm" → "Ringworm"
            for label in ["answer", "id", "name", "it is", "this is a", "this is"] {
                if trimmed.lowercased().hasPrefix(label + ":")
                    || trimmed.lowercased().hasPrefix(label + " ")
                {
                    trimmed = String(trimmed.dropFirst(label.count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: " \t:*"))
                }
            }
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// Drop any line that is a prompt template rather than an answer:
    /// placeholders carry angle brackets, and list instructions read "one of:".
    private static func stripEchoedTemplate(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                !line.contains("<") && !line.contains(">")
                    && line.range(of: "one of:", options: .caseInsensitive) == nil
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strips the hedge and rejects a parroted placeholder, which must never
    /// be shown to the user as an identification or fed to the matcher.
    private static func displayName(_ id: String?) -> String? {
        guard var name = id?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return nil
        }
        let isPlaceholder =
            name.contains("<") || name.contains(">")
            || name.range(of: "common name", options: .caseInsensitive) != nil
            || name.range(of: "scientific name", options: .caseInsensitive) != nil
        guard !isPlaceholder else { return nil }

        for hedge in ["(uncertain)", "(not sure)", "(unknown)"] {
            name = name.replacingOccurrences(
                of: hedge, with: "", options: .caseInsensitive)
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " .,;"))
        return name.isEmpty ? nil : name
    }
}
