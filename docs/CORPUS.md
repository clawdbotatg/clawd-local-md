# The offline health library (HealthCorpus)

How Local MD gives its on-device model an encyclopedia it can look things up
in with zero bars — and why the sources it's built from are legal to bundle.
Distilled from a 104-agent deep-research run (2026-07-11: 5 search angles,
15 sources fetched, every claim adversarially verified 3-vote; licensing
findings below were unanimous unless noted).

## What ships

`LocalMD/Resources/HealthCorpus.db` (~4 MB SQLite) — all ~1,016 English
MedlinePlus health-topic summaries, plain-texted from NLM's daily bulk XML
by `tools/build_corpus.py`, indexed with FTS5 (`porter unicode61`,
BM25-ranked, column weights title=8 / aliases=6 / body=1). Every row keeps
its provenance: title, `also-called` aliases + MeSH headings, topic groups,
medlineplus.gov URL, primary NIH institute, dates. A `meta` table records
the source file, build date, and attribution line.

At runtime `HealthCorpus.swift` opens it read-only (system SQLite3, no new
dependencies) and two MCP-style tools expose it to the model during **text
follow-ups only** (never during photo identification):

- `search_health_topics(query)` → top-3 titles + snippets. Free text is
  reduced to quoted alphanumeric tokens OR-joined, so FTS5 syntax can't be
  injected and natural-language questions rank by overlap.
- `get_health_topic(title)` → the plain-language summary (capped at ~2,400
  chars for the 4B model's context) + source URL + attribution.

**The severity firewall is untouched.** Verdicts come from
`TriageTable`/`TriageData` only. The library tools know nothing about the
verdict; the follow-up instructions tell the model the printed verdict wins
over anything it reads. Nothing in the corpus can downgrade triage.

## Licensing (the part that had to be researched, with citations)

| Source | Verdict | Basis |
|---|---|---|
| **MedlinePlus health-topic summaries** | ✅ shipped | Public domain; NLM lists them as content you "may reproduce, redistribute" — bulk XML published daily. Requested courtesy: say it's "from MedlinePlus.gov", no logo, no implied endorsement. ([using content](https://medlineplus.gov/about/using/usingcontent/), [XML files](https://medlineplus.gov/xml.html)) |
| A.D.A.M. encyclopedia, ASHP drug monographs (also on MedlinePlus) | ❌ excluded | Copyrighted third-party content; NLM explicitly forbids ingesting it into health IT systems. The pipeline reads only the NLM-written `full-summary`/`also-called`/`mesh-heading` fields — the `site` link entries that point at A.D.A.M./ASHP are never ingested. |
| NCI text (PDQ patient summaries) | 🟡 future | Public domain unless marked; credit + link-back requested; third-party graphics must be stripped. ([copyright & reuse](https://www.cancer.gov/policies/copyright-reuse)) |
| CDC content | 🟡 future | Mostly public domain via the **v2** syndication API (v1 is dead — verified live 2026-07-11); four reuse conditions: attribution, non-endorsement disclaimer, no substantive alteration, note free availability. ([agency materials](https://www.cdc.gov/other/agencymaterials.html), [API](https://tools.cdc.gov/api/docs/info.aspx)) |
| StatPearls | ❌ never | CC BY-NC-ND 4.0 — no-derivatives kills chunking/RAG, non-commercial risks App Store distribution. Verbatim redistribution is *not* a safe harbor (that counterclaim was refuted 0–3). ([NCBI Bookshelf](https://www.ncbi.nlm.nih.gov/books/NBK430685/)) |
| Wikipedia medical | 🟡 reserve | Workable under CC BY-SA 4.0 but copyleft + attribution plumbing; only if government sources ever fall short. |

App Store precedent: **WikiMed** (Kiwix/Wikimedia CH) ships 51k+ offline
medical articles on iOS, last updated Nov 2025 — Apple accepts bundled
offline medical *reference* in a consumer app. Local MD stays on the right
side of guideline 1.4.1 the same way it always has: reference + first look,
no diagnosis claims, standing disclaimer, 911/Poison Control routing. The
in-app disclaimer now also carries the MedlinePlus credit +
non-endorsement line.

## Operations

- **Refresh each release**: NLM asks that redistributed copies stay fresh.
  `python3 tools/build_corpus.py` fetches the latest daily XML and rewrites
  the DB — re-run it and commit the DB alongside any release. (On this
  machine it auto-re-execs under `/usr/bin/python3`; Homebrew 3.14's expat
  is broken.)
- **Regression test**: `python3 tools/check_corpus.py` — schema/provenance
  completeness, ≥900-topic floor, ≤40 MB ceiling, 14 retrieval-quality
  cases mirroring the Swift query builder, FTS-injection safety. Run it
  (plus `check_triage_table.py`) before shipping any corpus or matcher
  change. Its `fts_expression` mirrors `HealthCorpus.ftsExpression` — keep
  them in sync.
- **Sim proof**: `SIMCTL_CHILD_LMD_ASK="what is ringworm" tools/simloop.sh
  out.png` — MockEngine answers text follow-ups from the real bundled DB,
  so the screenshot proves resource bundling + FTS5 end-to-end without a
  phone.

## Why FTS5 and not embeddings

At ~1,000 documents on-phone, BM25 over title/alias/body with MedlinePlus's
own synonym lists ("fever blister" → Cold Sores via `also-called`) resolves
every query class the app actually sees, in microseconds, with zero extra
model weights or new dependencies. A vector index would add an embedding
model download + RAM alongside a 2.7 GB VLM to solve a recall problem this
corpus doesn't have. If the corpus grows 10× multi-source, revisit hybrid
(FTS5 candidate set → small reranker).
