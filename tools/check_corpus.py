#!/usr/bin/env python3
"""Regression test for the bundled health corpus (HealthCorpus.db).

Mirrors the Swift `HealthCorpus` query builder (alphanumeric tokens, quoted,
OR-joined, bm25 weights title=8 aliases=6 body=1) over the committed DB, so
retrieval behavior is testable without a phone or GPU — the same posture as
check_triage_table.py. Run before shipping any pipeline or corpus change.

Checks: schema + provenance completeness, topic count floor, size ceiling,
FTS retrieval sanity (the queries a user actually asks after a verdict),
FTS-syntax injection safety, and that no topic pretends to diagnose.
"""

import os
import re
import sqlite3
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB_PATH = os.path.join(REPO, "LocalMD", "Resources", "HealthCorpus.db")

MIN_TOPICS = 900
MAX_DB_MB = 40

# query -> a title expected among the top 3 hits. These mirror the app's
# real flow: a verdict names a finding, the user asks about it.
RETRIEVAL = {
    "ringworm": "Tinea Infections",
    "fever blister": "Cold Sores",
    "tick bite bullseye rash": "Lyme Disease",
    "melanoma warning signs": "Melanoma",
    "poison ivy": "Poison Ivy, Oak, and Sumac",
    "cellulitis": "Cellulitis",
    "shingles": "Shingles",
    "what's a stye???": "Eyelid Disorders",
    "can I take ibuprofen with tylenol": "Pain Relievers",
    "impetigo": "Impetigo",
    "hives": "Hives",
    "sunburn": "Sun Exposure",
    "spider bite": "Spider Bites",
    "ingrown toenail": "Nail Diseases",
}

# Queries that must not crash or leak FTS5 syntax errors.
HOSTILE = ['AND OR NEAR(', '"unbalanced', "topics_fts MATCH", "*: ^", "!!! ???", ""]


def fts_expression(query):
    """Mirror of HealthCorpus.ftsExpression — keep the two in sync."""
    words = re.sub(r"[^0-9a-z]+", " ", query.lower()).split()
    if not words:
        return None
    return " OR ".join(f'"{w}"' for w in words[:12])


def search(db, query, limit=3):
    match = fts_expression(query)
    if match is None:
        return []
    return db.execute(
        "SELECT t.title FROM topics_fts JOIN topics t ON t.id = topics_fts.rowid"
        " WHERE topics_fts MATCH ? ORDER BY bm25(topics_fts, 8.0, 6.0, 1.0) LIMIT ?",
        (match, limit),
    ).fetchall()


def main():
    failures = []

    def check(ok, label):
        print(("PASS " if ok else "FAIL ") + label)
        if not ok:
            failures.append(label)

    check(os.path.exists(DB_PATH), "HealthCorpus.db exists")
    if not os.path.exists(DB_PATH):
        sys.exit("no database to test")

    size_mb = os.path.getsize(DB_PATH) / (1024 * 1024)
    check(size_mb <= MAX_DB_MB, f"size {size_mb:.1f} MB <= {MAX_DB_MB} MB")

    db = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True)

    count = db.execute("SELECT count(*) FROM topics").fetchone()[0]
    check(count >= MIN_TOPICS, f"topic count {count} >= {MIN_TOPICS}")

    empty = db.execute(
        "SELECT count(*) FROM topics WHERE title = '' OR body = '' OR url = ''"
    ).fetchone()[0]
    check(empty == 0, "every topic has title, body, and url")

    bad_url = db.execute(
        "SELECT count(*) FROM topics WHERE url NOT LIKE 'https://medlineplus.gov/%'"
    ).fetchone()[0]
    check(bad_url == 0, "every url is a medlineplus.gov provenance link")

    meta = dict(db.execute("SELECT key, value FROM meta"))
    for key in ("source", "source_generated", "built", "attribution", "topic_count"):
        check(bool(meta.get(key)), f"meta.{key} present")
    check(meta.get("topic_count") == str(count), "meta.topic_count matches rows")

    fts = db.execute("SELECT count(*) FROM topics_fts").fetchone()[0]
    check(fts == count, "FTS index covers every topic")

    for query, expected in RETRIEVAL.items():
        titles = [row[0] for row in search(db, query)]
        check(expected in titles, f"retrieval: {query!r} -> {expected} (got {titles})")

    for query in HOSTILE:
        try:
            search(db, query)
            check(True, f"hostile query safe: {query!r}")
        except sqlite3.Error as error:
            check(False, f"hostile query safe: {query!r} ({error})")

    # The library must read as reference, never as this app diagnosing the
    # user. MedlinePlus text is third-person educational, so first-person
    # diagnosis phrasing appearing in a body means our cleaning broke.
    diagnosing = db.execute(
        "SELECT count(*) FROM topics WHERE body LIKE '%you have been diagnosed by this app%'"
        " OR body LIKE '%this app diagnoses%'"
    ).fetchone()[0]
    check(diagnosing == 0, "no diagnosis claims injected into bodies")

    print()
    if failures:
        sys.exit(f"{len(failures)} FAILURES: " + "; ".join(failures))
    print(f"all checks passed ({count} topics, {size_mb:.1f} MB)")


if __name__ == "__main__":
    main()
