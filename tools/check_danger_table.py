#!/usr/bin/env python3
"""Regression test for the safety-critical verdict pipeline.

`DangerTable.verdict()` is the one part of this app that must never be wrong,
and it is pure text parsing + data lookup — so it is testable without a phone,
a GPU, or a model. This script extracts the embedded JSON from
DangerData.swift, checks its invariants, and mirrors the Swift pipeline
(template stripping -> parse -> match -> verdict) over raw model outputs that
encode bugs we have actually shipped.

    python3 tools/check_danger_table.py     # exit 0 = safe to ship

If you change DangerTable.swift, change the mirror below to match, and add the
case that motivated the change.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "GoodGuyBadGuy" / "LLM" / "DangerData.swift"

KNOWN = {"snake", "spider", "scorpion", "insect", "plant", "mushroom", "mammal", "bird", "other"}
# Categories where no match means CAUTION, not safety.
CAUTION_ON_MISS = {"snake", "spider", "scorpion", "plant", "mushroom", "other"}
SEVERITY = {"bad": 2, "caution": 1, "good": 0}


def load_entries():
    src = DATA.read_text()
    m = re.search(r'static let json = """\n(.*?)\n        """', src, re.S)
    if not m:
        sys.exit(f"could not find the JSON literal in {DATA}")
    # Swift strips the closing delimiter's indentation from every line.
    lines = [l[8:] if l.startswith(" " * 8) else l for l in m.group(1).split("\n")]
    return json.loads("\n".join(lines))


# --- mirror of DangerTable.swift ------------------------------------------


def strip_echoed_template(text):
    """Drop lines that are the prompt's template, not an answer."""
    keep = [
        l for l in text.split("\n")
        if "<" not in l and ">" not in l and not re.search(r"one of:", l, re.I)
    ]
    return "\n".join(keep).strip()


def _value(key, line):
    stripped = line.strip(" \t*-#•>")
    if not stripped.lower().startswith(key.lower() + ":"):
        return None
    return stripped[len(key) + 1:].strip(" \t*")


def parse(text):
    category = ident = features = None
    for line in text.split("\n"):
        line = line.strip()
        if (v := _value("CATEGORY", line)) is not None:
            category = re.sub(r"[^a-z]", "", v.lower())
        elif (v := _value("ID", line)) is not None:
            ident = v
        elif (v := _value("FEATURES", line)) is not None:
            features = v
    return category, ident, features


def display_name(ident):
    if not ident or not ident.strip():
        return None
    if "<" in ident or ">" in ident:
        return None
    if re.search(r"common name|scientific name", ident, re.I):
        return None
    name = re.sub(r"\((?:uncertain|not sure|unknown)\)", "", ident, flags=re.I)
    name = name.strip(" .,;")
    return name or None


def _pattern(alias):
    """Word-bounded, plural-tolerant — mirrors DangerTable.contains."""
    stem = re.escape(alias)
    body = stem[:-1] + "(?:y|ies)" if alias.endswith("y") else stem + "(?:s|es)?"
    return r"\b" + body + r"\b"


def _best_match(entries, text):
    """Most specific alias wins; severity only breaks ties."""
    best = None  # (entry, specificity)
    for entry in entries:
        lengths = [len(n) for n in entry["names"] if re.search(_pattern(n), text, re.I)]
        if not lengths:
            continue
        longest = max(lengths)
        if best is None:
            best = (entry, longest)
            continue
        more_specific = longest > best[1]
        tie_by_severity = (
            longest == best[1] and SEVERITY[entry["verdict"]] > SEVERITY[best[0]["verdict"]]
        )
        if more_specific or tie_by_severity:
            best = (entry, longest)
    return best


def verdict(entries, raw):
    """Returns (verdict, identification-shown-to-user)."""
    cleaned = strip_echoed_template(raw)
    category, ident, features = parse(cleaned)
    category = category if category in KNOWN else "other"

    if re.search("not a plant or animal", ident or cleaned, re.I):
        return "NONE", None

    id_text = ident if ident is not None else (cleaned if len(cleaned) <= 200 else None)
    name = display_name(id_text)
    if not name:
        return "CAUTION", None  # never guess from stray words

    uncertain = bool(re.search(r"uncertain|not sure|unknown", id_text, re.I))
    best = _best_match(entries, id_text) or (
        _best_match(entries, features) if features else None
    )
    if best:
        entry = best[0]
        if uncertain and entry["verdict"] == "good":
            return "CAUTION", name
        if category == "mushroom" and entry["verdict"] == "good":
            return "CAUTION", name
        return entry["verdict"].upper(), name
    if uncertain or category in CAUTION_ON_MISS:
        return "CAUTION", name
    return "GOOD", name


# --- cases ----------------------------------------------------------------

def ident_lines(category, ident, features="visible features"):
    return f"CATEGORY: {category}\nID: {ident}\nFEATURES: {features}"


# The prompt template the model parroted back verbatim on device, 2026-07-09.
ECHOED_TEMPLATE = (
    "CATEGORY: <one of: snake, spider, scorpion, insect, plant, mushroom, mammal, bird, other>\n"
    "ID: <common name> (<scientific name or genus, if you know it>)\n"
    "FEATURES: <one short sentence naming the visible features behind your ID>"
)

# (raw model output, expected verdict, expected shown ID, why this case exists)
CASES = [
    (ident_lines("plant", "Daylily (Hemerocallis)"), "BAD", "Daylily (Hemerocallis)",
     "the bug that started this: model called it safe for cats"),
    (ident_lines("plant", "This is a daylily, Lilium (genus)"), "BAD", None,
     "model's exact on-device wording"),
    (ident_lines("plant", "Daylilies growing in a bed"), "BAD", None, "plural must still match"),
    (ident_lines("plant", "Easter lilies in a vase"), "BAD", None, "plural of a multi-word alias"),
    (ident_lines("plant", "Peace lily (Spathiphyllum)"), "CAUTION", None,
     "not a true lily: specificity must beat severity"),
    (ident_lines("spider", "Wolf spider (Lycosidae)"), "GOOD", None,
     "must not match the 'wolf' mammal entry"),
    (ident_lines("snake", "Milk snake, a coral snake mimic"), "BAD", None,
     "equal specificity ties break toward danger"),
    (ident_lines("mammal", "An elephant standing near a plant"), "GOOD", None,
     "'ant' must not fire inside other words"),

    # --- the two bugs visible in the 2026-07-09 device screenshots ---
    (ECHOED_TEMPLATE, "CAUTION", None,
     "parroted template: must not show placeholders, and 'scorpion' in the echoed "
     "CATEGORY list must not match the scorpion entry"),
    (ident_lines("spider", "Cellar spider (Pholcus phalangioides)", "very long thin legs"),
     "GOOD", "Cellar spider (Pholcus phalangioides)",
     "the actual spider on the wall: harmless, and it was called a scorpion"),
    ("CATEGORY: other\n**ID:** Leopard gecko (Eublepharis macularius)\nFEATURES: spotted lizard",
     "GOOD", "Leopard gecko (Eublepharis macularius)",
     "markdown-decorated label must parse, not fall back to the name 'This'"),
    ("- ID: Garter snake (Thamnophis)\n- CATEGORY: snake", "GOOD", "Garter snake (Thamnophis)",
     "bulleted labels in any order"),
    ("This is a leopard gecko.", "GOOD", "This is a leopard gecko",
     "short unlabeled freeform reply is accepted as the ID"),
    ("CATEGORY: spider\nFEATURES: long legs on a wall", "CAUTION", None,
     "no ID line: refuse to guess, fall to CAUTION"),

    (ident_lines("mushroom", "Death cap (Amanita phalloides)"), "BAD", None, "deadliest mushroom"),
    (ident_lines("mushroom", "Some little brown mushroom"), "CAUTION", None,
     "unmatched mushroom is never GOOD"),
    (ident_lines("mushroom", "Chanterelle (Cantharellus)"), "CAUTION", None,
     "wild mushrooms are never GOOD, even edibles"),
    (ident_lines("snake", "Garter snake (Thamnophis sirtalis)"), "GOOD", None, "harmless snake"),
    (ident_lines("snake", "Eastern coral snake (Micrurus fulvius)"), "BAD", None, "neurotoxic"),
    (ident_lines("snake", "Some snake I cannot place"), "CAUTION", None,
     "unmatched snake is never GOOD"),
    (ident_lines("snake", "Garter snake (uncertain)"), "CAUTION", None,
     "a hedged GOOD is downgraded"),
    (ident_lines("mushroom", "Fly agaric (Amanita muscaria) (uncertain)"), "BAD", None,
     "hedging never rescues a dangerous species"),
    (ident_lines("spider", "Black widow (Latrodectus mactans)"), "BAD", None, "medically significant"),
    (ident_lines("spider", "Brown recluse (Loxosceles reclusa)"), "BAD", None, "necrotic bite"),
    (ident_lines("spider", "Jumping spider (Salticidae)"), "GOOD", None, "harmless"),
    (ident_lines("insect", "Ticks on a dog"), "BAD", None, "disease vector, plural"),
    (ident_lines("insect", "Ladybug (Coccinellidae)"), "GOOD", None, "harmless"),
    (ident_lines("insect", "Honey bee (Apis mellifera)"), "CAUTION", None, "sting risk if allergic"),
    (ident_lines("plant", "Sago palm (Cycas revoluta)"), "BAD", None, "liver failure in dogs"),
    (ident_lines("plant", "Poison ivy (Toxicodendron radicans)"), "BAD", None, "urushiol"),
    (ident_lines("plant", "Oleander (Nerium oleander)"), "BAD", None, "cardiac glycosides"),
    (ident_lines("plant", "Water hemlock (Cicuta maculata)"), "BAD", None, "most poisonous in N.A."),
    (ident_lines("plant", "Dandelion (Taraxacum officinale)"), "GOOD", None, "matched harmless"),
    (ident_lines("plant", "Some weed I don't recognize"), "CAUTION", None,
     "unmatched plant is never GOOD"),
    (ident_lines("other", "Cane toad (Rhinella marina)"), "BAD", None, "kills dogs that mouth it"),
    (ident_lines("other", "Gila monster (Heloderma suspectum)"), "BAD", None, "venomous lizard"),
    (ident_lines("other", "Box turtle (Terrapene)"), "GOOD", None, "matched harmless"),
    ("CATEGORY: other\nID: not a plant or animal", "NONE", None, "no banner for a photo of a rock"),
    (ident_lines("mammal", "Grizzly bear (Ursus arctos)"), "BAD", None, "large predator"),
    (ident_lines("mammal", "Eastern gray squirrel"), "GOOD", None, "unmatched mammal defaults GOOD"),
]


def main():
    entries = load_entries()
    print(f"{len(entries)} entries decode OK")

    aliases, problems = {}, 0
    for entry in entries:
        if entry["verdict"] not in SEVERITY:
            print(f"  BAD VERDICT {entry['verdict']!r} in {entry['names'][0]}")
            problems += 1
        if not entry["note"].strip():
            print(f"  EMPTY NOTE in {entry['names'][0]}")
            problems += 1
        if entry["category"] not in KNOWN:
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
    for raw, want, want_id, why in CASES:
        got, got_id = verdict(entries, raw)
        ok = got == want and (want_id is None or got_id == want_id)
        failures += not ok
        label = raw.replace("\n", " | ")[:64]
        print(f"  {'ok  ' if ok else 'FAIL'} {got:8} {label}")
        if not ok:
            print(f"       wanted {want}" + (f" / id={want_id!r}" if want_id else "")
                  + f", got {got} / id={got_id!r} ({why})")

    total = problems + failures
    print(f"\n{'ALL PASS' if not total else f'{total} PROBLEM(S)'}")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
