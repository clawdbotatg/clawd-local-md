# App art — generated, not hand-drawn

The icon and loading scene are generated with **gpt-image-2** (via the
Bankr OpenAI-compatible API — creds in `~/clawd/clawd-harness/.clawd-harness.env`,
endpoint `https://llm.bankr.bot/v1/images/generations`, auth header
`X-API-Key`). The old hand-authored SVGs looked like programmer art and
were retired (git history has them).

To regenerate, POST `{"model": "gpt-image-2", "prompt": ..., "size":
"1024x1024"}` and decode `data[0].b64_json`.

## AppIcon (1024×1024)

> iOS app icon, modern polished flat illustration with soft gradients and
> depth: a cute friendly holographic robot doctor — translucent glowing
> cyan, faint scanlines, wearing a doctor head mirror and stethoscope with
> a small red cross badge — projected as a hologram beaming up out of a
> smartphone that lies on a grassy sunlit hill, blue sky. Clean bold
> centered composition, square, no text, no border.

Post-process: the model bakes rounded corners; center-crop to 960×960 and
resize back to 1024 (`sips -c 960 960` then `-z 1024 1024`) so nothing
white can peek through iOS's own icon mask.

## ExplorerScene / loading art (1024×1024)

> Modern polished flat illustration with soft gradients, warm light and
> gentle depth: a hiker with a small backpack stands on a mountain trail
> among pine trees and rolling green hills, holding up a smartphone; a
> friendly holographic robot doctor — translucent glowing cyan with faint
> scanlines, doctor head mirror, stethoscope, small red cross badge — is
> projected out of the phone into the air, waving warmly at the hiker.
> Sunny sky, a few soft clouds. Storybook app-illustration quality, square
> composition, no text.

## DemoPhoto (800×800)

Still the hand-drawn cartoon bullseye-rash forearm (`tools/demophoto.svg`)
— it feeds the simulator's canned Lyme demo and needs to look like an
illustration, not a real photo, on purpose.
