#!/usr/bin/env python3
"""Can the 4B reliably report the VISUAL FEATURES that drive triage?

The naming approach failed: asked to name conditions from real photos the
model says "Red rash" for shingles and "Insect bite" for a Lyme bullseye,
and over-constraining it into a menu makes it confidently wrong ("sunburn"
for cellulitis). But *unconstrained description* worked well in the
diagnostics ("a red, circular rash on the inner elbow"). So the question
for a feature-based photo path is narrower and testable:

  Given a real clinical photo, can it reliably report colour, shape,
  texture, distribution, and body area — the observations a curated rule
  table could then reason over (the model is the eyes; the table keeps
  severity)?

This measures exactly that on the 10-image battery. Two extraction styles,
head to head, so we build on evidence:

  X  checklist   one prompt, five labelled short answers
  Y  freeform    "describe in one or two sentences", then keyword-scan it

Read the output and judge accuracy against what each image actually is
(printed as the ground-truth tag). If features are reliable -> build the
rule table. If not -> the photo path's ceiling is real and we reframe.
"""

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import brain_harness as h  # noqa: E402

# ground truth for eyeballing (stem -> what it actually is)
TRUTH = {
    "bullseye": "early Lyme — expanding target/bullseye rash (URGENT)",
    "ringworm": "ringworm — a single scaly ring, benign (ROUTINE)",
    "cellulitis": "cellulitis — spreading red warm swelling (URGENT)",
    "shingles": "shingles — one-sided band of blisters (URGENT)",
    "melanoma": "melanoma — dark irregular lesion (URGENT)",
    "poisonivy": "poison ivy — streaky blistering itchy rash (ROUTINE/WATCH)",
    "burn2nd": "second-degree burn — blistered (SOON)",
    "hives": "hives — raised welts (WATCH)",
    "stye": "stye — red bump on the eyelid (minor)",
    "notabody": "a mountain landscape — NOT a body (must be refused)",
}

CHECKLIST = """\
Look at the photo. If it is not a person's skin or body, answer only: NOT A BODY
Otherwise fill this checklist about the visible finding. One short answer each, \
copy the format exactly:
COLOR: <red / pink / brown / black / purple / yellow / skin-colored>
SHAPE: <round / ring or target / irregular / patch / streak / raised bump / line>
TEXTURE: <flat / scaly / blistered / crusty / oozing / smooth>
SPREAD: <single spot / spreading outward / one-sided band / streaks / scattered>
AREA: <skin / mole or spot / nail / eye / mouth or lip>"""

FREEFORM = """\
If this is not a person's skin or body, answer only: NOT A BODY. Otherwise \
describe the visible skin or body finding in one or two plain sentences — its \
colour, shape, texture, and whether it looks like it is spreading. Do not name \
a disease and do not say whether it is serious."""


def generate(brain, image, instructions, max_tokens):
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
                 max_tokens=max_tokens, temperature=0.4, top_p=0.9,
                 repetition_penalty=1.05, repetition_context_size=20, verbose=False)
    text = result.text if hasattr(result, "text") else result
    return re.sub(r"<think>.*?</think>", "", text, flags=re.S).strip()


def main():
    brain = h.Brain()
    photos = ROOT / "build" / "photos"
    for stem, truth in TRUTH.items():
        image = str(photos / f"{stem}.jpg")
        print(f"\n{'='*70}\n{stem}  —  {truth}")
        print("\n-- X checklist --")
        print(generate(brain, image, CHECKLIST, 90))
        print("\n-- Y freeform --")
        print(generate(brain, image, FREEFORM, 80).replace("\n", " "))


if __name__ == "__main__":
    main()
