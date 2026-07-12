# App art — generated, not hand-drawn

The icon and loading scene are generated with **gpt-image-2** (via the
Bankr OpenAI-compatible API — creds in `~/clawd/clawd-harness/.clawd-harness.env`,
endpoint `https://llm.bankr.bot/v1/images/generations`, auth header
`X-API-Key`). The old hand-authored SVGs looked like programmer art and
were retired (git history has them).

To regenerate, POST `{"model": "gpt-image-2", "prompt": ..., "size":
"1024x1024"}` and decode `data[0].b64_json`.

## AppIcon (1024×1024)

> Photorealistic cinematic render, iOS app icon composition: a modern
> smartphone lying in real dewy grass on a sunlit hillside, projecting a
> volumetric hologram upward — a friendly medical robot doctor made of
> translucent glowing cyan light with subtle scan lines and light falloff,
> wearing a physician head mirror and a stethoscope, small red cross
> emblem on its chest. Shallow depth of field, golden-hour sunlight,
> realistic materials and reflections on the phone glass, soft volumetric
> light rays. Centered square composition, no text, no border, no rounded
> corners.

Post-process: if the model bakes rounded corners, center-crop to 960×960
and resize back to 1024 (`sips -c 960 960` then `-z 1024 1024`) so
nothing can peek through iOS's own icon mask. The photoreal prompt above
came back full-bleed and needed none.

## ExplorerScene / loading art (1024×1024)

> Photorealistic cinematic photograph-style render: a hiker with a
> backpack stands on a mountain trail at golden hour, pine forest and
> misty peaks behind, holding a smartphone up in one hand; from the phone
> screen a volumetric hologram is projected into the air — a friendly
> medical robot doctor of translucent glowing cyan light with subtle scan
> lines, physician head mirror, stethoscope, small red cross emblem,
> waving warmly. Realistic skin, fabric and light; the hologram casts a
> soft cyan glow on the hiker face and hand. Shallow depth of field,
> cinematic color grade. Square composition, no text.

## DemoPhoto (800×800)

Still the hand-drawn cartoon bullseye-rash forearm (`tools/demophoto.svg`)
— it feeds the simulator's canned Lyme demo and needs to look like an
illustration, not a real photo, on purpose.
