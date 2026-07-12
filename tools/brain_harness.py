#!/usr/bin/env python3
"""Chat with the app's EXACT brain on this Mac — no phone required.

Runs the same model the phone runs (lmstudio-community/Qwen3-VL-4B-Instruct-
MLX-4bit via MLX), with the same system prompts (extracted live from
MLXEngine.swift so they cannot drift), the same sampling parameters, the same
two-stage text triage (mirrored from check_triage_table.py), the same corpus
tools over the same bundled HealthCorpus.db, and the same round loop with
tool-call recovery and library fallback. Iterate on prompts here in seconds;
put it on the device only when this says it behaves.

Setup (once):   /opt/homebrew/bin/python3.12 -m venv build/brainenv
                build/brainenv/bin/pip install mlx-vlm

Usage:
    build/brainenv/bin/python tools/brain_harness.py --ask "i got bit by a snake"
    build/brainenv/bin/python tools/brain_harness.py --repl
    build/brainenv/bin/python tools/brain_harness.py --suite tools/brain_suite.json
"""

import argparse
import json
import re
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import check_triage_table as triage  # noqa: E402  (the safety-logic mirror)

ENGINE = ROOT / "LocalMD" / "LLM" / "MLXEngine.swift"
DB = ROOT / "LocalMD" / "Resources" / "HealthCorpus.db"
MODEL_ID = "lmstudio-community/Qwen3-VL-4B-Instruct-MLX-4bit"
MODEL_NAME = "Qwen3-VL 4B"  # what \(modelName) interpolates to on device

START_TAG, END_TAG = "<tool_call>", "</tool_call>"
SUMMARY_CAP = 2400
MAX_ROUNDS = 3


# --- prompts, extracted from the Swift source ------------------------------


def swift_string(anchor):
    """Pull a Swift triple-quoted string that follows `anchor` in
    MLXEngine.swift, resolving line-continuation backslashes, indentation,
    and the \\(modelName) interpolation — byte-for-byte what the device
    sends as the system prompt."""
    src = ENGINE.read_text()
    at = src.index(anchor)
    start = src.index('"""', at) + 3
    end = src.index('"""', start)
    lines = src[start:end].split("\n")
    closing_indent = len(lines[-1]) - len(lines[-1].lstrip())
    body_lines = [line[closing_indent:] if line[:closing_indent].isspace() or not line.strip() else line
                  for line in lines[1:-1]]
    text = ""
    for line in body_lines:
        if line.endswith("\\"):
            text += line[:-1]
        else:
            text += line + "\n"
    text = text.replace("\\(modelName)", MODEL_NAME)
    return text.strip()


FOLLOWUP_PROMPT = swift_string("private var followupInstructions: String {")


def banner_vocabulary(entries):
    """Mirror of TriageTable.bannerVocabulary — the closed menu the naming
    pass picks from: primary name of every urgent/soon entry."""
    return [e["names"][0] for e in entries
            if triage.SEVERITY[e["level"]] >= triage.SEVERITY["soon"]]


def textname_prompt(entries):
    """The naming prompt with the table's own vocabulary injected, exactly as
    MLXEngine builds it at run time."""
    raw = swift_string("private static var textNameInstructions: String {")
    return raw.replace(
        '\\(TriageTable.bannerVocabulary.joined(separator: ", "))',
        ", ".join(banner_vocabulary(entries)),
    )


# --- the corpus tools, mirroring CorpusTools.swift -------------------------


def fts_expression(query):
    words = re.sub(r"[^0-9a-z]+", " ", query.lower()).split()
    return " OR ".join(f'"{w}"' for w in words[:12]) or None


def db_connect():
    return sqlite3.connect(f"file:{DB}?mode=ro", uri=True)


def search_health_topics(query):
    match = fts_expression(query)
    hits = []
    if match:
        with db_connect() as db:
            hits = db.execute(
                "SELECT t.title, snippet(topics_fts, 2, '', '', ' … ', 14)"
                " FROM topics_fts JOIN topics t ON t.id = topics_fts.rowid"
                " WHERE topics_fts MATCH ? ORDER BY bm25(topics_fts, 8.0, 6.0, 1.0) LIMIT 3",
                (match,),
            ).fetchall()
    return {
        "results": [{"title": t, "snippet": s} for t, s in hits],
        "note": (
            "Call get_health_topic with one of these titles to read its summary."
            if hits
            else "No offline topic matched. Answer honestly that the library has nothing on this, and point to a clinician if it matters."
        ),
    }


def truncate_summary(text):
    if len(text) <= SUMMARY_CAP:
        return text
    head = text[:SUMMARY_CAP]
    cut = max(head.rfind("\n"), head.rfind(". ") + 2)
    return (head[:cut] if cut > 0 else head).strip() + " …"


def get_health_topic(title):
    with db_connect() as db:
        row = db.execute(
            "SELECT title, body, url FROM topics WHERE title = ? COLLATE NOCASE", (title,)
        ).fetchone()
        if row is None:
            result = search_health_topics(title)["results"]
            if result:
                row = db.execute(
                    "SELECT title, body, url FROM topics WHERE title = ? COLLATE NOCASE",
                    (result[0]["title"],),
                ).fetchone()
        if row is None:
            return {"error": f"No topic named '{title}' in the offline library. Try search_health_topics first."}
        attribution = dict(db.execute("SELECT key, value FROM meta"))["attribution"]
    return {
        "title": row[0],
        "summary": truncate_summary(row[1]),
        "source": f"MedlinePlus (NIH), {row[2]} — {attribution}",
    }


def get_device_status(**_):
    return {"battery_percent": 80, "battery_state": "on battery",
            "ios_version": "26.0", "current_date_time": "Friday Jul 11 2026, 5:00 PM"}


def get_location(**_):
    return {"latitude": 40.0, "longitude": -105.0, "place": "Denver, Colorado, United States"}


TOOL_IMPLS = {
    "search_health_topics": lambda a: search_health_topics(a.get("query", "")),
    "get_health_topic": lambda a: get_health_topic(a.get("title", "")),
    "get_device_status": lambda a: get_device_status(),
    "get_location": lambda a: get_location(),
}

TOOL_SPECS = [
    {"type": "function", "function": {
        "name": "search_health_topics",
        "description": "Search the offline MedlinePlus (NIH) health reference library bundled on this phone. Returns matching topic titles with a snippet. Use it to answer factual questions about conditions, symptoms, treatments, or prevention. Reference only — it never changes the triage verdict already shown.",
        "parameters": {"type": "object", "properties": {"query": {"type": "string", "description": "Keywords for the condition, symptom, or question, e.g. 'ringworm treatment' or 'tick bite'."}}, "required": ["query"]}}},
    {"type": "function", "function": {
        "name": "get_health_topic",
        "description": "Read one topic's plain-language summary from the offline MedlinePlus (NIH) library. Pass a title returned by search_health_topics, or a plain condition name.",
        "parameters": {"type": "object", "properties": {"title": {"type": "string", "description": "The topic title, e.g. 'Tinea Infections' or 'ringworm'."}}, "required": ["title"]}}},
    {"type": "function", "function": {
        "name": "get_device_status",
        "description": "Get the phone's battery level and charging state, iOS version, and the current date and time.",
        "parameters": {"type": "object", "properties": {}, "required": []}}},
    {"type": "function", "function": {
        "name": "get_location",
        "description": "Get the user's current location (coordinates and city).",
        "parameters": {"type": "object", "properties": {}, "required": []}}},
]


# --- tool-call extraction (mirror of ToolCallRecovery) ---------------------


def top_level_objects(text):
    """Yield every complete top-level {...} in the text, string-aware."""
    i = 0
    while True:
        start = text.find("{", i)
        if start < 0:
            return
        depth, in_string, escaped = 0, False, False
        for j in range(start, len(text)):
            c = text[j]
            if in_string:
                if escaped:
                    escaped = False
                elif c == "\\":
                    escaped = True
                elif c == '"':
                    in_string = False
            elif c == '"':
                in_string = True
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    yield text[start : j + 1]
                    i = j + 1
                    break
        else:
            return


def extract_tool_calls(raw):
    calls = []
    for obj in top_level_objects(raw):
        try:
            data = json.loads(obj)
        except json.JSONDecodeError:
            continue
        if isinstance(data, dict) and "name" in data and data["name"] in TOOL_IMPLS:
            calls.append({"name": data["name"], "arguments": data.get("arguments") or {}})
        if len(calls) >= 4:
            break
    return calls


def strip_tool_text(raw):
    """Visible text = raw minus tool-call tags/JSON (the Scrubber's job)."""
    text = raw
    for obj in top_level_objects(raw):
        try:
            data = json.loads(obj)
            if isinstance(data, dict) and "name" in data:
                text = text.replace(obj, "")
        except json.JSONDecodeError:
            pass
    text = text.replace(START_TAG, "").replace(END_TAG, "")
    return re.sub(r"\n{3,}", "\n\n", text).strip()


# --- library fallback (mirror of MLXEngine.libraryFallback) ----------------

CARE_SIGNALS = ["911", "poison control", "emergency", "call your", "get medical",
                "seek", "right away", "immediately", "if you are bitten",
                "if you have been", "doctor if"]


def relevant_excerpt(body, query, cap=900):
    paragraphs = [p.strip() for p in body.split("\n\n") if p.strip()]
    if len(paragraphs) <= 1:
        return body[:cap] + ("…" if len(body) > cap else "")
    terms = {w for w in re.sub(r"[^0-9a-z]+", " ", query.lower()).split() if len(w) > 2}
    scored = []
    for index, paragraph in enumerate(paragraphs):
        lower = paragraph.lower()
        score = sum(1 for t in terms if t in lower) + 3 * sum(1 for c in CARE_SIGNALS if c in lower)
        scored.append((score, index, paragraph))
    chosen, total = [], 0
    for score, index, paragraph in sorted(scored, key=lambda x: -x[0]):
        if total + len(paragraph) > cap and chosen:
            continue
        chosen.append((index, paragraph))
        total += len(paragraph)
        if total >= cap:
            break
    return "\n\n".join(p for _, p in sorted(chosen))


def library_fallback(topic_title, query):
    if topic_title:
        with db_connect() as db:
            row = db.execute(
                "SELECT title, body FROM topics WHERE title = ? COLLATE NOCASE", (topic_title,)
            ).fetchone()
        if row:
            return (f"Here's what MedlinePlus (NIH) says about {row[0]}:\n\n"
                    f"{relevant_excerpt(row[1], query)}\n\n"
                    "If this is severe, sudden, or getting worse, get medical care now — don't wait on an app.")
    return ("I couldn't finish looking that up — ask me once more. If this is severe, sudden, "
            "or getting worse, don't wait on an app: get medical care now.")


# --- the brain --------------------------------------------------------------


class Brain:
    """The device's generation stack: same weights, same sampling."""

    def __init__(self):
        from mlx_vlm import load

        print(f"loading {MODEL_ID} …", file=sys.stderr)
        self.model, self.processor = load(MODEL_ID)

    def generate(self, messages, max_tokens, tools=None):
        from mlx_vlm import generate

        prompt = self.processor.apply_chat_template(
            messages, tools=tools, add_generation_prompt=True, tokenize=False
        )
        result = generate(
            self.model, self.processor, prompt,
            max_tokens=max_tokens, temperature=0.7, top_p=0.8,
            repetition_penalty=1.15, repetition_context_size=64,
            verbose=False,
        )
        text = result.text if hasattr(result, "text") else result
        return re.sub(r"<think>.*?</think>", "", text, flags=re.S).strip()


def run_turn(brain, entries, prompt, history, trace=print):
    """Mirror of MLXEngine.followUp: two-stage triage, rounds with recovery,
    library fallback. Returns (visible_text, banner_level_or_None)."""
    visible, answer = "", ""
    banner = None
    fallback_topic = None
    conversation = list(history) + [{"role": "user", "content": prompt}]

    # Stage 1: literal curated triage — the table is the authority.
    level = triage.text_verdict(entries, prompt)
    note = None
    match = triage.text_match(entries, prompt)
    if match:
        note = match["note"]
    if match is None:
        # Stage 2 ONLY when the words match nothing: the model names from the
        # table's closed menu, the table judges. It fills gaps; it never
        # overrules a match the table already made (a forced-choice 4B
        # over-picks the scariest menu item).
        named = brain.generate(
            [{"role": "system", "content": textname_prompt(entries)},
             {"role": "user", "content": prompt}],
            max_tokens=16,
        )
        trace(f"  [name-pass] {named!r}")
        if not re.search(r"\bnone\b", named, re.I):
            name = triage.sanitize_name(named)
            if name:
                result = triage.finding_verdict_entry(entries, name)
                if result:
                    level, note = result
    if level and not any(note in m.get("content", "") for m in history):
        banner = level
        lead = f"VERDICT: {level}\n\n{note}\n\n"
        visible += lead
        answer += lead
        trace(f"  [triage] {level}")
        conversation.append({"role": "assistant", "content": f"VERDICT: {level}\n\n{note}"})

    for round_number in range(1, MAX_ROUNDS + 1):
        raw = brain.generate(
            [{"role": "system", "content": FOLLOWUP_PROMPT}] + conversation,
            max_tokens=512, tools=TOOL_SPECS,
        )
        clean = strip_tool_text(raw)
        if clean:
            visible += clean + "\n"
            answer += clean + "\n"
        calls = extract_tool_calls(raw)
        trace(f"  [round {round_number}] raw {len(raw)} chars, prose {len(clean)}, calls {[c['name'] for c in calls]}")
        if not calls or round_number == MAX_ROUNDS:
            break
        conversation.append({"role": "assistant", "content": "\n".join(
            f"{START_TAG}\n{json.dumps({'name': c['name'], 'arguments': c['arguments']})}\n{END_TAG}"
            for c in calls)})
        for call in calls:
            result = TOOL_IMPLS[call["name"]](call["arguments"])
            trace(f"    [tool] {call['name']}({call['arguments']}) -> {json.dumps(result)[:160]}")
            if call["name"] == "get_health_topic":
                fallback_topic = call["arguments"].get("title") or fallback_topic
            elif call["name"] == "search_health_topics" and result["results"]:
                fallback_topic = result["results"][0]["title"]
            status = ("🔎 Searching MedlinePlus — " + call["arguments"].get("query", "") + "…"
                      if call["name"] == "search_health_topics"
                      else f"📖 Reading MedlinePlus: {call['arguments'].get('title', 'the topic')}…"
                      if call["name"] == "get_health_topic" else f"⚙️ Using {call['name']}…")
            visible += status + "\n"
            conversation.append({"role": "tool", "content": json.dumps(result)})

    if not answer.strip():
        fallback = library_fallback(fallback_topic, prompt)
        visible += fallback
        trace("  [fallback] library text used")

    return visible.strip(), banner


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ask", help="one question, full trace")
    parser.add_argument("--repl", action="store_true", help="interactive chat")
    parser.add_argument("--suite", help="JSON test battery to run")
    args = parser.parse_args()

    entries = triage.load_entries()
    brain = Brain()

    if args.ask:
        text, banner = run_turn(brain, entries, args.ask, [])
        print(f"\n=== banner: {banner} ===\n{text}")
        return

    if args.repl:
        history = []
        while True:
            try:
                prompt = input("\nyou> ").strip()
            except EOFError:
                return
            if not prompt or prompt in {"exit", "quit"}:
                return
            text, _ = run_turn(brain, entries, prompt, history)
            print(f"\nlocalmd> {text}")
            history += [{"role": "user", "content": prompt},
                        {"role": "assistant", "content": text}]
        return

    if args.suite:
        cases = json.loads(Path(args.suite).read_text())
        failures = 0
        for case in cases:
            print(f"\n### {case['prompt']!r}")
            text, banner = run_turn(brain, entries, case["prompt"], [])
            problems = []
            if "banner" in case and banner != case["banner"]:
                problems.append(f"banner {banner} != {case['banner']}")
            for needle in case.get("contains", []):
                if needle.lower() not in text.lower():
                    problems.append(f"missing {needle!r}")
            for needle in case.get("excludes", []):
                if needle.lower() in text.lower():
                    problems.append(f"must not say {needle!r}")
            if problems:
                failures += 1
                print(f"  FAIL: {'; '.join(problems)}")
                print("  ---\n  " + text.replace("\n", "\n  ")[:800])
            else:
                print("  ok")
        print(f"\n{'ALL PASS' if not failures else f'{failures} FAILURE(S)'}")
        sys.exit(1 if failures else 0)

    parser.print_help()


if __name__ == "__main__":
    main()
