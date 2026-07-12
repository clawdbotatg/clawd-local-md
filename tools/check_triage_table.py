#!/usr/bin/env python3
"""Regression test for the safety-critical triage logic.

`TriageTable.verdict(name:category:hedged:)` is the one part of this app that
must never be wrong, and it is pure data + string matching — so it is testable
without a phone, a GPU, or a model. This script extracts the embedded JSON from
TriageData.swift, checks its invariants, and mirrors the Swift matching rules
over cases that encode the safety posture (and, over time, bugs we've shipped).

    python3 tools/check_triage_table.py     # exit 0 = safe to ship

The app takes a photo through two minimal model passes — "what is this?" then
(only if the name is unknown) "one word: what category?" — and everything
after that is the logic mirrored here. If you change TriageTable.swift, change
the mirror below to match, and add the case that motivated the change.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "LocalMD" / "LLM" / "TriageData.swift"

CATEGORIES = {
    "rash", "mole", "growth", "bite", "burn", "wound", "blister",
    "swelling", "nail", "eye", "mouth", "scalp", "other",
}
# Categories where no match means SOON, not just WATCH.
SOON_ON_MISS = {"bite", "burn", "wound", "eye"}
SEVERITY = {"urgent": 3, "soon": 2, "watch": 1, "routine": 0}


def load_entries():
    src = DATA.read_text()
    m = re.search(r'static let json = """\n(.*?)\n        """', src, re.S)
    if not m:
        sys.exit(f"could not find the JSON literal in {DATA}")
    # Swift strips the closing delimiter's indentation from every line.
    lines = [l[8:] if l.startswith(" " * 8) else l for l in m.group(1).split("\n")]
    return json.loads("\n".join(lines))


# --- mirror of TriageTable.swift -------------------------------------------


def sanitize_name(reply):
    """Mirrors sanitizeName + displayName: rejects placeholders and 'unknown'."""
    line = reply.strip().split("\n")[0].strip(" \t*-#•>\"'.,;:")
    if not line or len(line) > 60:
        return None
    if re.search(r"unknown", line, re.I):
        return None
    if "<" in line or ">" in line:
        return None
    if re.search(r"common name|scientific name", line, re.I):
        return None
    name = re.sub(r"\((?:uncertain|not sure|unknown)\)", "", line, flags=re.I).strip(" .,;")
    return name or None


def is_hedged(reply):
    return bool(re.search(r"uncertain|not sure|unknown|possibly|might be", reply, re.I))


def _pattern(alias):
    """Word-bounded, plural-tolerant — mirrors TriageTable.contains."""
    stem = re.escape(alias)
    body = stem[:-1] + "(?:y|ies)" if alias.endswith("y") else stem + "(?:s|es)?"
    return r"\b" + body + r"\b"


def lookup(entries, name):
    """Most specific alias wins; severity only breaks ties."""
    best = None  # (entry, specificity)
    for entry in entries:
        lengths = [len(n) for n in entry["names"] if re.search(_pattern(n), name, re.I)]
        if not lengths:
            continue
        longest = max(lengths)
        if best is None:
            best = (entry, longest)
            continue
        more_specific = longest > best[1]
        tie_by_severity = (
            longest == best[1] and SEVERITY[entry["level"]] > SEVERITY[best[0]["level"]]
        )
        if more_specific or tie_by_severity:
            best = (entry, longest)
    return best[0] if best else None


def all_matches(entries, name):
    return [e for e in entries if any(re.search(_pattern(n), name, re.I) for n in e["names"])]


_AMBIGUOUS_RE = re.compile(
    r"\bor\b|/|possibly|mimic|look[- ]?alike|either|\bvs\b|could be|not sure|uncertain|\?",
    re.I,
)


def verdict(entries, name, category=None, hedged=False):
    category = category if category in CATEGORIES else "other"
    if not name:
        return "WATCH"
    # Look-alike escalation: the ID names alternatives at different levels;
    # the worst matched level wins.
    if _AMBIGUOUS_RE.search(name):
        matches = all_matches(entries, name)
        if len({m["level"] for m in matches}) > 1:
            worst = max(matches, key=lambda m: SEVERITY[m["level"]])
            return worst["level"].upper()
    best = lookup(entries, name)
    if best:
        # Moles never render better than WATCH, even on a match.
        if (best["category"] == "mole" or category == "mole") and SEVERITY[best["level"]] <= SEVERITY["watch"]:
            return "WATCH"
        if hedged and best["level"] == "routine":
            return "WATCH"
        return best["level"].upper()
    if category in SOON_ON_MISS:
        return "SOON"
    return "WATCH"


def pipeline(entries, raw_name, category=None):
    """The whole post-model path: sanitize the naming pass, then judge."""
    if re.search("not a body part", raw_name, re.I):
        return "NONE"
    return verdict(entries, sanitize_name(raw_name), category, is_hedged(raw_name))


# (raw naming-pass reply, category from pass 2 (or None), expected, why)
CASES = [
    # The flagship posture: a photo can't rule things out, so misses and
    # hedges always land on the side of care.
    ("Some strange rash", "rash", "WATCH", "unmatched rash is never ROUTINE"),
    ("A burn of some kind", "burn", "SOON", "unmatched burn means be seen, not reassured"),
    ("Odd wound", "wound", "SOON", "unmatched wound defaults SOON"),
    ("Weird bite mark", "bite", "SOON", "unmatched bite defaults SOON"),
    ("Red eye thing", "eye", "SOON", "unmatched eye finding defaults SOON"),
    ("Something on the skin", "other", "WATCH", "unmatched anything is at least WATCH"),

    # Mole floor: nothing pigmented is ever ROUTINE, matched or not.
    ("Mole", "mole", "WATCH", "a matched benign mole is still WATCH + ABCDE"),
    ("Beauty mark", None, "WATCH", "alias of mole — floored at WATCH"),
    ("Some dark spot", "mole", "WATCH", "unmatched mole category still gets ABCDE"),
    ("Atypical mole", None, "SOON", "ABCDE features escalate past the floor"),
    ("Melanoma", None, "URGENT", "the word melanoma is never watched"),
    ("Changing mole", None, "SOON", "change is the key ABCDE feature"),

    # Specificity beats severity (the wolf-spider lesson, medical edition).
    ("Fever blister", None, "ROUTINE", "a cold sore must not hit the blister entries"),
    ("Blood blister", None, "ROUTINE", "specific blister entry wins"),
    ("Cold sore", None, "ROUTINE", "harmless and common"),
    ("Blistering burn", None, "SOON", "burn with blisters is at least partial thickness"),
    ("Pimple with pus", None, "ROUTINE", "'pimple' (acne) must out-rank bare 'pus'"),
    ("Cystic acne", None, "ROUTINE", "'cystic acne' must not hit the 'cyst' entry"),

    # Look-alike escalation: alternatives resolve to the worse level.
    ("Cold sore or impetigo", None, "SOON", "routine + soon alternatives -> soon"),
    ("Hives or cellulitis", None, "URGENT", "watch + urgent alternatives -> urgent"),
    ("Ringworm or eczema", None, "ROUTINE", "same-level alternatives don't escalate"),

    # Hedging: downgrades ROUTINE, never rescues a serious match.
    ("Ringworm (uncertain)", None, "WATCH", "a hedged ROUTINE is downgraded"),
    ("Possibly melanoma", None, "URGENT", "hedging never rescues a serious match"),
    ("Shingles (not sure)", None, "URGENT", "72-hour antiviral window beats the hedge"),

    # Naming-pass hygiene (the model parroting or failing).
    ("<common name>", "rash", "WATCH", "parroted placeholder is never a name"),
    ("unknown", "rash", "WATCH", "model admits it can't tell"),
    ("not a body part", None, "NONE", "no banner for a photo of a desk"),

    # Plural tolerance.
    ("Hives", None, "WATCH", "plural alias must match"),
    ("Styes", None, "ROUTINE", "plural of stye"),
    ("Bed bug bites", None, "ROUTINE", "plural of a multi-word alias"),
    ("Mosquito bites", None, "ROUTINE", "plural bite alias"),

    # The urgent tier: things where waiting is the mistake.
    ("Bullseye rash", None, "URGENT", "early Lyme — the whole reason for curation"),
    ("Shingles", None, "URGENT", "antivirals are time-critical"),
    ("Cellulitis", None, "URGENT", "spreading infection"),
    ("Petechiae", None, "URGENT", "non-blanching dots can be an emergency"),
    ("Dog bite", None, "URGENT", "infection + rabies assessment"),
    ("Snake bite", None, "URGENT", "ER, always"),
    ("Chemical burn", None, "URGENT", "rinse + poison control"),
    ("Jaundice", None, "URGENT", "yellow skin is never a skin problem"),
    ("Swollen calf", None, "URGENT", "one-sided leg swelling = DVT question"),
    ("Swollen lips", None, "URGENT", "angioedema threatens the airway"),
    ("Deep cut", None, "URGENT", "stitches are time-limited"),

    # The soon tier.
    ("Tick bite", None, "SOON", "30-day watch + possible prophylaxis"),
    ("Actinic keratosis", None, "SOON", "precancerous"),
    ("Pearly bump", None, "SOON", "basal cell language"),
    ("Dark line under the nail", None, "SOON", "subungual melanoma must be excluded"),
    ("Impetigo", None, "SOON", "contagious, needs prescription"),
    ("Oral thrush", None, "SOON", "needs antifungals and a why"),

    # The routine tier still ends with escalation triggers in its notes.
    ("Ringworm", None, "ROUTINE", "OTC antifungal territory"),
    ("Sunburn", None, "ROUTINE", "self-care"),
    ("Canker sore", None, "ROUTINE", "heals within two weeks"),
    ("Dandruff", None, "ROUTINE", "medicated shampoo"),
    ("Minor cut", None, "ROUTINE", "clean and cover"),
    ("Skin tag", None, "ROUTINE", "growth category is allowed routine"),

    # A matched entry keys off its own category, not the pass-2 guess.
    ("Stye", "rash", "ROUTINE", "matched entry wins over a wrong category pass"),
]


def text_verdict(entries, text):
    """Mirrors TriageTable.textVerdict: curated triage over TYPED symptom
    text — fires only when the worst matching entry is urgent/soon."""
    matches = all_matches(entries, text)
    if not matches:
        return None
    worst = max(matches, key=lambda m: SEVERITY[m["level"]])
    if SEVERITY[worst["level"]] < SEVERITY["soon"]:
        return None
    return worst["level"].upper()


# (typed message, expected banner or None, why)
TEXT_CASES = [
    ("i just got bit by a snake", "URGENT", "snakebite text is an emergency, not a chat"),
    ("a rattlesnake got me on the ankle", "URGENT", "named venomous snakes match"),
    ("my dog bit me pretty bad", "URGENT", "dog bite needs same-day care"),
    ("bitten by a cat last night", "URGENT", "cat bites infect fastest"),
    ("i think a brown recluse bit me", "SOON", "named venomous spider escalates past generic"),
    ("a spider bit me", None, "generic spider bite (watch) stays conversational"),
    ("what is ringworm", None, "routine topics never banner a text chat"),
    ("my balls hurt", None, "no curated match -> model + library path"),
    ("i have shingles near my eye", "URGENT", "urgent entries fire from text too"),
    ("my dog bit a hole in my shoe", None, "'dog bit me' must not fire on the shoe"),
]


CATEGORY_WORDS = [
    ("burn", "burn"), ("scald", "burn"), ("bite", "bite"), ("sting", "bite"),
    ("wound", "wound"), ("laceration", "wound"), ("puncture", "wound"),
]


def finding_verdict_entry(entries, name):
    """Mirrors TriageTable.findingVerdict: the model normalizes free text to
    a finding name ('a rattler tagged me' -> 'snake bite'); the table judges
    the name — urgent/soon banners, everything else stays conversational.
    An unmatched burn/bite/wound name falls to the soon-on-miss default,
    same posture as the photo pipeline. Returns (LEVEL, note) or None."""
    best = lookup(entries, name)
    if best:
        if SEVERITY[best["level"]] < SEVERITY["soon"]:
            return None
        return best["level"].upper(), best["note"]
    lower = name.lower()
    for word, category in CATEGORY_WORDS:
        if word in lower:
            return "SOON", (
                f"I can't match this exactly in my curated list — and with a {category} "
                "finding, that's a reason to be seen, not reassured. Have a clinician "
                "look at it in the next day or two, sooner if it's getting worse."
            )
    return None


def finding_verdict(entries, name):
    result = finding_verdict_entry(entries, name)
    return result[0] if result else None


# (normalized name from the model, expected banner or None, why)
FINDING_CASES = [
    ("snake bite", "URGENT", "any snakebite phrasing normalizes here"),
    ("chemical burn", "URGENT", "rinse + poison control, now"),
    ("deep cut", "URGENT", "stitches are time-limited"),
    ("dog bite", "URGENT", "same-day care"),
    ("tick bite", "SOON", "soon tier banners too"),
    ("thermal burn", "SOON", "unmatched burn name -> soon-on-miss, like photos"),
    ("scald", "SOON", "unmatched burn synonym -> soon-on-miss"),
    ("nail injury", None, "not a wound word — conversational path handles it"),
    ("ringworm", None, "routine findings never banner a text chat"),
    ("sunburn", None, "sunburn is routine — the burn fallback must not out-rank a real match"),
    ("testicle pain", None, "not in the table -> model + library path"),
    ("none", None, "the normalizer's no-event answer matches nothing"),
]


def main():
    entries = load_entries()
    print(f"{len(entries)} entries decode OK")

    aliases, problems = {}, 0
    for entry in entries:
        if entry["level"] not in SEVERITY:
            print(f"  BAD LEVEL {entry['level']!r} in {entry['names'][0]}")
            problems += 1
        if not entry["note"].strip():
            print(f"  EMPTY NOTE in {entry['names'][0]}")
            problems += 1
        if not entry.get("source", "").strip():
            print(f"  MISSING SOURCE in {entry['names'][0]}")
            problems += 1
        if entry["category"] not in CATEGORIES:
            print(f"  UNKNOWN CATEGORY {entry['category']!r} in {entry['names'][0]}")
            problems += 1
        for name in entry["names"]:
            if name != name.lower():
                print(f"  ALIAS NOT LOWERCASE: {name!r}")
                problems += 1
            if len(name) < 3:
                print(f"  ALIAS TOO SHORT (false-match risk): {name!r}")
                problems += 1
            if name in aliases:
                print(f"  DUPLICATE ALIAS {name!r}: {aliases[name]} vs {entry['names'][0]}")
                problems += 1
            aliases[name] = entry["names"][0]
    print(f"{len(aliases)} aliases, {problems} invariant problems\n")

    failures = 0
    for raw_name, category, want, why in CASES:
        got = pipeline(entries, raw_name, category)
        ok = got == want
        failures += not ok
        print(f"  {'ok  ' if ok else 'FAIL'} {got:8} {raw_name!r} [{category}]")
        if not ok:
            print(f"       wanted {want} ({why})")

    print()
    for text, want, why in TEXT_CASES:
        got = text_verdict(entries, text)
        ok = got == want
        failures += not ok
        print(f"  {'ok  ' if ok else 'FAIL'} {str(got):8} text: {text!r}")
        if not ok:
            print(f"       wanted {want} ({why})")

    print()
    for name, want, why in FINDING_CASES:
        got = finding_verdict(entries, name)
        ok = got == want
        failures += not ok
        print(f"  {'ok  ' if ok else 'FAIL'} {str(got):8} finding: {name!r}")
        if not ok:
            print(f"       wanted {want} ({why})")

    total = problems + failures
    print(f"\n{'ALL PASS' if not total else f'{total} PROBLEM(S)'}")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
