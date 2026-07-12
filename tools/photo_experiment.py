#!/usr/bin/env python3
"""Measure why the photo naming pass degenerates on real clinical images.

The first photo battery came back 5/10 with the model emitting an empty
string for a bullseye rash, "Scanned by" for ringworm and "In" for shingles.
Two suspects, so test them head to head on the same images instead of
guessing:

  A  current      temp 0.7, repetition penalty 1.15 (what ships today)
  B  cold         temp 0.0, no repetition penalty
  C  cold + menu  temp 0.0, closed vocabulary of the table's own names

C is the move that rescued the TEXT pipeline: a 4B invents an endless supply
of synonyms, so hand it the table's words and make it choose.

    build/brainenv/bin/python tools/photo_experiment.py
"""

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import check_triage_table as triage  # noqa: E402
import brain_harness as h  # noqa: E402

IMAGES = ["bullseye", "ringworm", "cellulitis", "shingles", "melanoma",
          "poisonivy", "burn2nd", "hives", "stye", "notabody"]


def vocabulary(entries):
    """Every finding the table can judge — photos need the benign names too
    (a ringworm must come back ROUTINE), unlike the text menu which only
    needs the banner-worthy ones."""
    return [e["names"][0] for e in entries]


def menu_prompt(entries):
    return (
        "Look at the photo and decide which item from the LIST below best "
        "describes the visible skin or body finding.\n\nLIST:\n"
        + ", ".join(vocabulary(entries))
        + "\n\nAnswer with the ONE item from the LIST that best matches, copied "
        "exactly, and nothing else. If the photo does not show a person's skin "
        "or body, answer: not a body part\nIf it shows a body but nothing on the "
        "LIST fits, answer with a short plain name of what you see (two to four "
        "words).\nNever say whether it is serious or harmless, and never give advice."
    )


def generate(brain, image, instructions, **params):
    from mlx_vlm import generate as gen
    from mlx_vlm.prompt_utils import apply_chat_template
    import re

    prompt = apply_chat_template(
        brain.processor, brain.model.config,
        [{"role": "system", "content": instructions},
         {"role": "user", "content": "What is this?"}],
        num_images=1,
    )
    result = gen(brain.model, brain.processor, prompt, image=[image],
                 max_tokens=24, verbose=False, **params)
    text = result.text if hasattr(result, "text") else result
    return re.sub(r"<think>.*?</think>", "", text, flags=re.S).strip().replace("\n", " ⏎ ")[:70]


def main():
    entries = triage.load_entries()
    brain = h.Brain()
    photos = ROOT / "build" / "photos"
    menu = menu_prompt(entries)

    configs = [
        ("A current   ", h.NAME_PROMPT, dict(temperature=0.7, top_p=0.8,
                                             repetition_penalty=1.15,
                                             repetition_context_size=64)),
        ("B cold      ", h.NAME_PROMPT, dict(temperature=0.0)),
        ("C cold+menu ", menu, dict(temperature=0.0)),
    ]
    for stem in IMAGES:
        image = str(photos / f"{stem}.jpg")
        print(f"\n=== {stem}")
        for label, instructions, params in configs:
            name = generate(brain, image, instructions, **params)
            got = ("NONE" if "not a body part" in name.lower()
                   else triage.verdict(entries, triage.sanitize_name(name), None,
                                       triage.is_hedged(name)))
            print(f"  {label} {got:8} {name!r}")


if __name__ == "__main__":
    main()
