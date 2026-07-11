# Local MD — orientation for Claude

iOS app that gives one thing from a photo: **a private, on-device medical
first look — NOT a diagnosis.** A fork of
[good-guy-bad-guy](https://github.com/clawdbotatg/good-guy-bad-guy) (same
SwiftUI + [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) 3.x
on-device stack, downloads `mlx-community/Qwen3-VL-4B-Instruct-4bit`
(~2.7 GB) on first launch, then runs fully offline), pointed at health
findings instead of critters. `README.md` has the architecture; this file is
the working state.

## The one architectural rule: the model never decides severity

**The model is the eyes; the triage corpus is the encyclopedia.** A 4-bit 4B
VLM sees well and recalls long-tail facts badly — the parent app watched it
declare a daylily "safe for cats" (lethally wrong). In a medical app that
failure mode is a missed melanoma or a reassured cellulitis. So:

- **Stage 1 (`MLXEngine.nameInstructions`)**: the model gets the photo and
  returns ONLY a short name of the visible finding. It is explicitly
  forbidden from saying anything is serious or harmless, or giving advice.
- **Stage 2 (`TriageTable.verdict`)**: pure Swift + curated data decides the
  verdict and prints its `note` verbatim. Four levels, worst first: URGENT >
  SOON > WATCH > ROUTINE — and **there is deliberately no "all clear"**.
  Rules: most **specific** alias wins ("fever blister" ≠ the `blister`
  entry) with severity breaking ties toward care; an ambiguous ID ("X or Y")
  spanning levels escalates to the worst match; no match is never ROUTINE
  (bite/burn/wound/eye miss → SOON, everything else → WATCH); **moles are
  never ROUTINE** even on a match (ABCDE self-check is appended — the
  mushroom rule of dermatology); a hedged ROUTINE downgrades to WATCH but
  hedging never rescues a serious match; a JSON decode failure empties the
  table and everything falls to the cautious defaults.
- Text follow-ups use `followupInstructions` (the NOT A DOCTOR persona) and
  are told the printed verdict is authoritative — never soften it, never
  invent diagnoses or treatments.

**Never route a severity claim through the model.** Richer verdicts mean
more entries in `TriageData.swift` — with a `source` tag (AAD, Mayo Clinic,
CDC, AAO) on every entry — never a looser prompt. Anything that could
downgrade a verdict must have curated backing shipped in the app.

`python3 tools/check_triage_table.py` is the regression test (55 cases, no
phone/GPU needed — it mirrors the Swift matcher over the embedded JSON). It
encodes the safety posture: mole floor, look-alike escalation, hedge rules,
specificity traps ("cystic acne" vs "cyst", "pimple with pus" vs "pus").
**Run it before shipping any corpus or matcher change**, and add the case
that motivated your change. Corpus alias hygiene: lowercase, ≥3 chars, no
duplicates, and never a generic bare word ("rash", "bump", "cut", "burn") —
generics must fall to the category default, not a random entry.

## Why this app exists (positioning — keep it honest)

"NOT A DOCTOR, a private first look." The photo never leaves the phone,
never touches the photo library (in-app camera → memory → MLX → gone), and
nothing is persisted. That's a claim cloud health apps structurally can't
make, and it's also the App Review strategy: guideline 1.4.1 scrutinizes
diagnosis claims — this app makes none, shows a standing disclaimer under
every verdict, and routes emergencies to 911/Poison Control. Don't add
diagnosis language anywhere (UI, prompts, App Store copy), and don't name a
specific disease as a conclusion — the corpus says what a finding "fits" and
when to be seen.

## What differs from the good-guy-bad-guy parent

- **Verdict UI**: `ChatMessage.Verdict` = urgent/soon/watch/routine; parser
  checks URGENT first so muddled lines err toward care. `MessageBubble`
  banners: GET CARE NOW (red) / SEE A DOCTOR SOON (orange) / WORTH A LOOK
  (yellow, black text) / USUALLY MINOR (blue — deliberately not green).
  Standing NOT A DOCTOR disclaimer with 911/Poison Control numbers.
- **Corpus** (`TriageData.swift`): ~93 entries across rash / mole / growth /
  bite / burn / wound / blister / swelling / nail / eye / mouth / scalp /
  other. Every note ends with escalation triggers. This corpus IS the
  product — growing it (sourced, conservative, tested) is the roadmap.
- **Mock/demo**: `MockEngine` cans "Bullseye rash" → real TriageTable →
  URGENT banner (early Lyme is the flagship curation case). Demo hooks:
  `LMD_DEMO=1` auto-sends a photo, `LMD_BRAIN_OPEN=1` starts the Brain
  expanded. The DemoPhoto asset is cartoon bullseye-rash art matching the
  canned reply (source: `tools/demophoto.svg`).
- **Offline reference library** (`docs/CORPUS.md` is the deep doc): all
  ~1,016 English MedlinePlus health-topic summaries in a bundled ~4 MB
  SQLite FTS5 DB (`LocalMD/Resources/HealthCorpus.db`, built by
  `tools/build_corpus.py`, re-run + recommit each release — NLM asks that
  copies stay fresh). The model reaches it in **text follow-ups only** via
  two MCP-style tools (`CorpusTools`: `search_health_topics`,
  `get_health_topic` over `HealthCorpus.swift`, system SQLite3, read-only).
  It is REFERENCE, not triage — the tools know nothing about the verdict
  and the follow-up prompt says the verdict always wins. Licensing:
  MedlinePlus summaries are public domain (A.D.A.M./ASHP content is
  copyrighted and never ingested; StatPearls is CC BY-NC-ND — never use).
  `python3 tools/check_corpus.py` is its regression test (retrieval
  quality, provenance, FTS-injection safety); its query builder mirrors
  `HealthCorpus.ftsExpression` — keep them in sync. In the sim, MockEngine
  answers text follow-ups from the real DB (`SIMCTL_CHILD_LMD_ASK="..."`
  demo hook), proving bundling + FTS end-to-end.
- Names: target `LocalMD`, bundle `com.clawd.localmd`, display name
  "Local MD", debug log `Documents/localmd.log`.
- **Chat-first** (departs from the parent's image-first flow): the composer
  is live as soon as the brain is ready — text/dictation/photo from message
  one. `followupInstructions` covers both the no-verdict case and the
  verdict-is-authoritative case, and makes the library lookup MANDATORY for
  symptom questions (with slang→medical translation: "balls hurt" →
  "testicle pain") — answer first, photo suggestion only for visible
  findings, never instead of answering.
- **Tool-call recovery** (`ToolCallRecovery.swift`): the 4-bit model
  sometimes stutters the opening tag (`<tool_call>` twice), which makes
  mlx-swift-lm's `ToolCallProcessor` flush the whole block as plain text —
  the user saw raw tags and no answer (device, 2026-07-11). `followUp` now
  scrubs tool-call text from the visible stream, re-parses leaked calls,
  dispatches them itself (`dispatchTool` is shared with the native path),
  shows a clean "🔎 Searching the medical library — …" status line, and
  continues the turn by replaying assistant-tool-call + tool-result
  messages (same shape the library uses natively). Two recovery rounds
  max. Verified on device: "my balls hurt" → search("testicle pain") →
  get_health_topic("Testicular Disorders") → grounded answer.
- Test a text turn headless on the phone:
  `xcrun devicectl device process launch --terminate-existing
  --environment-variables '{"LMD_ASK":"my balls hurt"}' --device <udid>
  com.clawd.localmd`, then `tools/pulllog.sh` shows the tool-call trace.
- Everything else (Brain switcher via `BrainCatalog`, offline-only tools
  `get_location` + `get_device_status`, fresh-ChatSession-per-turn) is
  inherited unchanged — see the parent's CLAUDE.md notes below.

## Fully on-device — no cloud, ever

Inherited as a hard rule: **do not introduce any network path for
identification or verdicts.** For a health app this is doubly binding — a
photo of someone's body must never leave the device. The only acceptable
seam for enrichment is `TriageTable.verdict` over curated local data.

## Build / deploy loop (all CLI, no Xcode GUI)

Identical to the parent — same device, same team, same flags:

- Prefix everything with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
  (xcode-select still points at CommandLineTools; that's fine).
- **Simulator**: `tools/simloop.sh out.png` — build, boot, install, launch,
  screenshot (MockEngine in the sim; MLX needs a real GPU). Read the
  screenshot to verify UI. The mock streams a canned URGENT verdict when an
  image is attached, so the banner is testable in the sim.
- **Device build**: `xcodebuild -project LocalMD.xcodeproj -scheme LocalMD
  -destination 'generic/platform=iOS' -derivedDataPath build
  -skipPackagePluginValidation -skipMacroValidation -allowProvisioningUpdates
  DEVELOPMENT_TEAM=XX7QP5899Z build`
  (the two -skip flags are required headless: mlx-swift's CudaBuild plugin and
  the `#huggingFaceLoadModelContainer` macro can't show their trust prompts).
- **Install + launch**: `xcrun devicectl device install app --device
  8B053FBC-B638-548F-B045-F5DDE25D3BDD <path>.app` then
  `… device process launch --terminate-existing --device <udid>
  com.clawd.localmd`. **Both fail while the phone is locked** — ask the
  user to unlock, retry in a loop. `tools/pulllog.sh` pulls the debug log.
- This app has its own container: first launch re-downloads the weights even
  if ClawdChat/GGBG is installed (HF cache is per-app). Reinstalling over
  the top preserves them.

## Conventions / gotchas (inherited — still true)

- `project.yml` (XcodeGen) is the source of truth; `xcodegen generate` after
  editing and **commit the regenerated `.xcodeproj` together with it** — a
  stale project file silently drops new source files.
- Model swaps: `MLXEngine.modelID` via `BrainCatalog`. 4B-4bit is the
  practical phone model — the 8B loads on a 12 GB phone but jetsam kills it
  at first generation (verified 2026-07-07 in the grandparent).
- Fresh `ChatSession` per turn + replayed `history`: KV-cache reuse across
  turns is broken for Qwen3-VL in mlx-swift-lm 3.31.4 (hangs/corruption).
  Don't "optimize" it back.
- Download progress: the HF snapshot is one giant safetensors file, so the
  real byte fraction sits near 0% for most of the transfer then jumps to 1
  (watched on device 2026-07-11). `ChatStore.runWorker` therefore shows
  `max(real, 0.92·(1−e^(−t/180s)))` — a time-based estimate that always
  moves and never claims done; real progress wins if it's ahead. Don't
  "fix" it back to the raw fraction.
- Do not add an API-based fallback; on-device-offline is the entire point.
- Verdict format changes must update `MLXEngine` prompts, the `ChatMessage`
  parser, `TriageTable.compose`, `MockEngine`'s canned reply, AND
  `tools/check_triage_table.py` — they are one contract.
- App icon + loading art (`ExplorerScene`) + DemoPhoto are robot-doctor /
  bullseye-rash cartoons. SVG sources live in `tools/` (`icon.svg`,
  `scene.svg`, `demophoto.svg`); re-render with headless Chrome:
  `"/Applications/Google Chrome.app/…/Google Chrome" --headless=new
  --window-size=1024,1024 --screenshot=out.png file://$PWD/tools/icon.svg`
  (800×800 for the demo photo), then copy into the asset catalogs.

Keep the fork lean: if a change isn't about photo → private first look, it
probably belongs in the parent repo instead.
