# The photo path: what it can and cannot do

A hard-won, evidence-backed conclusion about the app's headline feature.
Everything here was measured against **10 real clinical photographs** from
Wikimedia Commons (`tools/photo_suite.json`, fetched by
`tools/fetch_photos.py`), not renders — a VLM naming a cartoon proves
nothing about naming a real rash.

## The finding: a 4B-4bit VLM cannot triage from a photo

Three experiments, all against the same 10 images
(`tools/photo_experiment.py`, `tools/photo_features_experiment.py`):

1. **Naming (what ships).** Asked to name the finding, the model describes
   appearance but names conditions badly: shingles → "Red rash",
   cellulitis → "Red leg swelling", a Lyme bullseye → **"Insect bite"**.

2. **Not sampling, not resolution, not the template.** Greedy decoding
   degenerates into token loops ("ScScScSc", "InInInIn"); downscaling to
   512–768px doesn't fix it; the image lands in the correct chat turn.
   Plain *unconstrained* "describe this image" works well ("a red, circular
   rash on the inner elbow") — but over-constraining into a name or a menu
   is what breaks it.

3. **Closed vocabulary makes it confidently wrong.** The trick that rescued
   the TEXT path (pick from the table's own names) made the photo model call
   **cellulitis "sunburn"** and a **Lyme bullseye "bullseye rash" only for
   the melanoma image** — i.e. it picks a plausible menu item unmoored from
   what's actually there.

4. **Feature extraction is not reliable either.** Asked for structured
   visual features (colour / shape / texture / spread / area), the model:
   reported **bullseye, plain ringworm, AND an irregular melanoma all as
   shape "ring or target"** — blind to the single most triage-relevant
   distinction (target vs plain ring = Lyme vs ringworm); false-refused real
   photos as "NOT A BODY" (shingles, stye); and echoed the template unfilled
   for others. An escape-clause instruction ("if not a body, say NOT A
   BODY") poisoned the free-form pass into refusing all 10 images.

**Conclusion: the model is the eyes, but its eyes are not good enough to
drive triage from a photo.** It cannot reliably distinguish the shapes,
distributions, and textures that separate benign from dangerous, and it is
fragile to prompt phrasing. A feature-rule engine built on these outputs
would be garbage-in, and unpredictably so.

## What we do instead

- **A photo verdict is never an all-clear.** `TriageTable.verdict` floors
  every photo match at WATCH (the mole floor generalized): the curated
  self-care note still prints, but the banner never claims "usually minor"
  on a name the model can't be trusted to have gotten right. A Lyme
  bullseye misread as "Insect bite" now renders WATCH, not ROUTINE.
- **The photo is a triage-toward-care first look, not a detector.** It
  reliably refuses obvious non-body photos, escalates when it *does*
  recognize something, and never falsely reassures — but it will miss real
  cellulitis. That is the honest ceiling.
- **The text path is the strong one** (100/100 on the live batteries,
  table-authoritative) and should carry the product. Photos are context.

## If you want to revisit this

The ceiling is the model, not the architecture. Re-run the batteries
(`brain_harness.py --photos`) against any new on-device VLM — a
medical-tuned small vision model, or whatever succeeds Qwen3-VL-4B as the
phone ceiling. The test harness is in place to give a decisive answer in
one run. Until then, do not present the photo path as diagnosis.
