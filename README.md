# Local MD — NOT A DOCTOR. A private first look, entirely on your phone.

Noticed something on your skin — a rash, a mole, a bite, a burn — and your
first instinct is to photograph it and ask the internet? Don't. That photo of
your body should not live in your camera roll, your iCloud, or somebody's
server logs.

Local MD gives you a **private first look**: take a photo *inside the app*
and a **vision-language model running entirely on your iPhone** takes a look:

> **GET CARE NOW** 🔴 — Bullseye rash. An expanding ring around a tick bite
> fits erythema migrans, the classic early sign of Lyme disease. Early
> antibiotics are highly effective, so see a clinician promptly…

The photo **never leaves your phone, never touches your photo library, and
is never written to disk** — it lives in memory, goes through the on-device
model, and is gone when you close the app. No API keys, no server, no signal
needed. The app downloads
[`mlx-community/Qwen3-VL-4B-Instruct-4bit`](https://huggingface.co/mlx-community/Qwen3-VL-4B-Instruct-4bit)
(~2.7 GB) once on first launch, then all inference happens on the iPhone's
GPU via [MLX Swift](https://github.com/ml-explore/mlx-swift-lm). Airplane
mode is the intended operating condition.

Every first look opens with a parseable verdict line the UI renders as a
colored banner. There is deliberately **no "you're fine" level** — a photo
can't rule anything out:

- 🔴 **GET CARE NOW** (`URGENT`) — waiting is the mistake: shingles near the
  72-hour antiviral window, cellulitis, a bullseye rash, an animal bite
- 🟠 **SEE A DOCTOR SOON** (`SOON`) — next day or two: an atypical mole, a
  blistering burn, impetigo, a dark streak under a nail
- 🟡 **WORTH A LOOK** (`WATCH`) — get a professional opinion; keep an eye on
  it: an ordinary mole (always with the ABCDE self-check), hives, a lipoma
- 🔵 **USUALLY MINOR** (`ROUTINE`) — self-care guidance, always ending with
  the specific triggers that mean see a clinician after all

**This app is NOT A DOCTOR.** It never diagnoses. It tells you what the
finding *fits*, what self-care is standard, and — most importantly — what a
clinician would want you to escalate for. Every verdict carries that
disclaimer, and emergencies are always routed to 911 / Poison Control.

## The model never decides how serious anything is

This is the core design, inherited from a real failure in the parent app
([good-guy-bad-guy](https://github.com/clawdbotatg/good-guy-bad-guy)): a
4-bit 4B model identified a daylily perfectly and then declared it "safe for
cats" — lethally wrong. Small models have excellent eyes and a lossy memory.
Freestyle medicine from *any* LLM's weights is a bad idea; from a quantized
4B it's dangerous.

So the app is two stages:

1. **The model is the eyes.** It sees the photo and returns only a short
   name of the visible finding ("ringworm", "blistering burn", "dark raised
   mole"). It is forbidden from saying anything is serious or harmless.
2. **A curated triage corpus is the encyclopedia.** ~90 entries bundled in
   the app (works at zero bars) map findings → triage level → a
   hand-written note, drawn from public AAD / Mayo Clinic / CDC / AAO
   guidance, printed verbatim. Each entry carries its source.

The corpus's safety posture, in order:

- The **most specific** match wins ("fever blister" — a cold sore — doesn't
  trip the *blister* entry), and ties break **toward care**.
- An ambiguous ID ("cold sore **or** impetigo") escalates to the **worst**
  matched level — a photo can't tell look-alikes apart.
- **No match is never ROUTINE.** Unrecognized bites, burns, wounds, and eye
  findings default to SEE A DOCTOR SOON; everything else to WORTH A LOOK.
  A small model failing to recognize something is *not* evidence it's minor.
- **Moles are never ROUTINE**, even on a match — no photo rules out
  melanoma, so every pigmented verdict carries the ABCDE self-check.
- A hedged `(uncertain)` identification downgrades ROUTINE to WATCH; hedging
  never *rescues* a serious match ("possibly melanoma" stays URGENT).
- If the corpus ever fails to load, *everything* falls through to the
  cautious defaults.

`python3 tools/check_triage_table.py` runs 55 safety cases against the
corpus with no phone or GPU required.

Also on board: on-device speech-to-text (mic button), and a `get_location`
tool the model can call for regional context on bites (location never leaves
the phone).

## An offline medical library the model can look things up in

Follow-up questions ("what actually is ringworm?", "how do I keep a burn
clean?") deserve better than a 4-bit model's memory. So the app bundles a
**second, much larger reference corpus**: all ~1,000 English
[MedlinePlus](https://medlineplus.gov) health-topic summaries (NIH's
consumer-health encyclopedia), packed into a ~4 MB SQLite **FTS5** database
at build time by `tools/build_corpus.py`.

During text follow-ups the model gets two MCP-style local tools —
`search_health_topics(query)` (BM25 full-text search over titles, aliases,
and bodies) and `get_health_topic(title)` (the plain-language summary, with
its medlineplus.gov provenance URL) — and is instructed to ground factual
answers in what it reads there, citing MedlinePlus. Zero bars required:
lookups are pure on-device SQLite.

The severity firewall still holds: the library is **reference, not
triage**. The tools are only offered on follow-up turns (never during
identification), they know nothing about the verdict, and the model is told
the printed verdict always wins over anything it reads.
`python3 tools/check_corpus.py` regression-tests the bundled DB — schema,
provenance on every row, retrieval quality, and FTS-injection safety —
with no phone or GPU required.

## Privacy is the product

- A photo taken in-app uses the system camera **without saving to your
  photo library** and is held only in memory.
- Chats are not persisted. Closing the app forgets everything.
- No accounts, no analytics, no ads, no third-party SDKs, no network calls
  after the one-time model download. See [PRIVACY.md](PRIVACY.md).

## Stack

- **SwiftUI** (iOS 17+) — photo-first chat UI with streaming tokens +
  triage banners
- **[mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm)** — model
  implementations + `ChatSession` (multi-turn history, streaming, tools)
- **swift-huggingface / swift-transformers** — weights download + tokenizer
- **XcodeGen** — `project.yml` is the source of truth; the `.xcodeproj` is
  generated (and committed for convenience)

Forked from [good-guy-bad-guy](https://github.com/clawdbotatg/good-guy-bad-guy)
(same architecture pointed at wildlife), itself forked from
[clawd-mobile-app](https://github.com/clawdbotatg/clawd-mobile-app).

## Build & run

1. **Install Xcode** (App Store; 16.3 or newer — the packages need Swift 6.1
   toolchain). Then make sure the full Xcode is active:
   ```sh
   sudo xcode-select -s /Applications/Xcode.app
   ```
2. **Generate the project** (only needed after editing `project.yml`; a
   generated `LocalMD.xcodeproj` is already committed):
   ```sh
   brew install xcodegen
   xcodegen generate
   ```
3. **Open `LocalMD.xcodeproj`**, select the *LocalMD* target →
   *Signing & Capabilities* → pick your team.
4. **Run on a real iPhone** (plugged in, or Wi-Fi debugging). MLX needs an
   Apple-silicon GPU — the simulator is not a useful target. iPhone 13 or
   newer recommended; first launch downloads the weights, so be on Wi-Fi.

> If signing complains about the *Increased Memory Limit* entitlement on your
> account, delete it in Signing & Capabilities (or from
> `LocalMD/LocalMD.entitlements`).

## Agent loop (build → run → see, no hands)

`tools/simloop.sh [out.png]` builds the app, boots an iPhone simulator,
installs + launches the app, and writes a screenshot — so an agent (or CI)
can verify changes visually without a human clicking Run. The simulator uses
`MockEngine` (canned bullseye-rash reply through the real triage table);
real-model verification needs a physical iPhone. `tools/pulllog.sh` pulls
the on-device debug log off a paired phone without a console attach.

## How it works

- `ChatStore` (`@Observable`) owns the message list and model lifecycle on
  top of an `LLMEngine` protocol with two implementations:
  - **`MLXEngine`** (device builds): `#huggingFaceLoadModelContainer`
    downloads/caches weights and returns a `ModelContainer`. A photo turn
    collects the identification, runs `TriageTable.verdict()`, and emits the
    composed verdict; text turns stream normally.
  - **`MockEngine`** (simulator builds): MLX can't run in the simulator (no
    Metal GPU), so the *vision* stage is faked — but its canned
    identification goes through the same `TriageTable`, making the simulator
    a real regression test for the verdict logic.
- `TriageTable` + `TriageData` are the medical authority; `MLXEngine` is
  forbidden from making severity claims. The app composes the
  `VERDICT: URGENT | SOON | WATCH | ROUTINE` line, so the model can't
  garble it.
- Qwen's `<think>…</think>` reasoning blocks are stripped before parsing.
- `MLX.GPU.set(cacheLimit:)` + the increased-memory-limit entitlement keep
  the model inside iOS's per-app memory budget.

## Roadmap ideas

On-device-offline is the product. Nothing may ever downgrade a verdict
without curated backing shipped in the app.

- **Grow the corpus** — the knowledge bank is the product; hundreds more
  sourced entries (pediatric findings, wound-care depth, medication rashes)
- **Private timeline** — opt-in, Face-ID-gated, encrypted local storage to
  compare a mole or a healing wound over time (the one feature cloud apps
  can't do honestly)
- App-switcher snapshot blurring for sensitive content
- "What to tell your doctor" export — a text summary (never the photo) you
  choose to share
- Symptom-context follow-ups: curated question flows ("does it itch?") that
  refine the triage level using table rules, not model opinions
