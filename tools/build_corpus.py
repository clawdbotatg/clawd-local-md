#!/usr/bin/env python3
"""Build the bundled offline health reference corpus (HealthCorpus.db).

Fetches the latest MedlinePlus Health Topics bulk XML (NLM/NIH — the daily
file published at https://medlineplus.gov/xml.html), cleans each English
topic's summary to plain text, and writes a SQLite database with an FTS5
index that ships inside the app bundle. The on-device model queries it
through the search_health_topics / get_health_topic tools — fully offline.

The DB is REFERENCE material only. Triage verdicts never come from it —
they stay in TriageData.swift / TriageTable (see CLAUDE.md, "the model
never decides severity").

Usage:
    python3 tools/build_corpus.py              # fetch latest + build
    python3 tools/build_corpus.py --xml FILE   # build from a local XML file

Attribution: MedlinePlus is a service of the National Library of Medicine.
NLM asks reusers to identify MedlinePlus as the source and keep copies
fresh — every row carries its medlineplus.gov URL, and this script should
be re-run (and the DB recommitted) with each app release.
"""

import argparse
import datetime
import html.parser
import io
import os
import re
import sqlite3
import sys
import urllib.request
import zipfile

# Homebrew Python 3.14 on this machine has a pyexpat that can't load against
# the system libexpat; the system Python parses XML fine. Re-exec once.
try:
    import pyexpat  # noqa: F401
except ImportError:
    if sys.executable != "/usr/bin/python3" and os.path.exists("/usr/bin/python3"):
        os.execv("/usr/bin/python3", ["/usr/bin/python3"] + sys.argv)
    raise

import xml.etree.ElementTree as ET

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB_PATH = os.path.join(REPO, "LocalMD", "Resources", "HealthCorpus.db")
CACHE_DIR = os.path.join(REPO, "build", "corpus")
INDEX_URL = "https://medlineplus.gov/xml.html"

# Refuse to ship a corpus that lost a big chunk of its topics — a partial
# fetch or format change must fail the build, not quietly shrink the app's
# knowledge.
MIN_TOPICS = 900
MAX_DB_MB = 40


class SummaryText(html.parser.HTMLParser):
    """MedlinePlus full-summary HTML -> readable plain text.

    Paragraphs and headings become blank-line-separated blocks; list items
    become "- " bullets; links keep their text and drop their targets.
    """

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []

    def handle_starttag(self, tag, attrs):
        if tag in ("p", "ul", "ol", "h2", "h3", "h4"):
            self.parts.append("\n\n")
        elif tag == "li":
            self.parts.append("\n- ")
        elif tag == "br":
            self.parts.append("\n")

    def handle_data(self, data):
        self.parts.append(data)

    def text(self):
        raw = "".join(self.parts)
        raw = re.sub(r"[ \t]+", " ", raw)
        raw = re.sub(r" ?\n ?", "\n", raw)
        raw = re.sub(r"\n{3,}", "\n\n", raw)
        return raw.strip()


def clean_summary(summary_html):
    parser = SummaryText()
    parser.feed(summary_html)
    return parser.text()


def latest_zip_url():
    with urllib.request.urlopen(INDEX_URL, timeout=60) as response:
        page = response.read().decode("utf-8", "replace")
    files = re.findall(
        r"https://medlineplus\.gov/xml/mplus_topics_compressed_(\d{4}-\d{2}-\d{2})\.zip", page
    )
    if not files:
        sys.exit("no mplus_topics_compressed zip found on " + INDEX_URL)
    date = max(files)
    return (
        f"https://medlineplus.gov/xml/mplus_topics_compressed_{date}.zip",
        date,
    )


def fetch_latest_xml():
    url, date = latest_zip_url()
    os.makedirs(CACHE_DIR, exist_ok=True)
    cached = os.path.join(CACHE_DIR, f"mplus_topics_{date}.xml")
    if os.path.exists(cached):
        print(f"using cached {cached}")
        return cached
    print(f"downloading {url}")
    with urllib.request.urlopen(url, timeout=300) as response:
        payload = response.read()
    archive = zipfile.ZipFile(io.BytesIO(payload))
    xml_names = [n for n in archive.namelist() if n.endswith(".xml")]
    if len(xml_names) != 1:
        sys.exit(f"expected one xml in the zip, got {xml_names}")
    with open(cached, "wb") as out:
        out.write(archive.read(xml_names[0]))
    return cached


def parse_topics(xml_path):
    root = ET.parse(xml_path).getroot()
    generated = root.get("date-generated", "")
    topics = []
    for node in root.findall("health-topic"):
        if node.get("language") != "English":
            continue
        summary_node = node.find("full-summary")
        body = clean_summary(summary_node.text or "") if summary_node is not None else ""
        if not body:
            print(f"  skipping (empty summary): {node.get('title')}")
            continue
        aliases = [child.text.strip() for child in node.findall("also-called") if child.text]
        aliases += [child.text.strip() for child in node.findall("see-reference") if child.text]
        mesh = [child.text.strip() for child in node.findall("mesh-heading") if child.text]
        groups = [child.text.strip() for child in node.findall("group") if child.text]
        institute = node.find("primary-institute")
        topics.append(
            {
                "id": int(node.get("id")),
                "title": node.get("title", "").strip(),
                "aliases": "; ".join(dict.fromkeys(aliases + mesh)),
                "groups": "; ".join(groups),
                "body": body,
                "url": node.get("url", ""),
                "institute": (institute.text or "").strip() if institute is not None else "",
                "date_created": node.get("date-created", ""),
            }
        )
    return generated, topics


def build_db(generated, topics, xml_name):
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    if os.path.exists(DB_PATH):
        os.remove(DB_PATH)
    db = sqlite3.connect(DB_PATH)
    db.executescript(
        """
        CREATE TABLE topics (
            id INTEGER PRIMARY KEY,
            title TEXT NOT NULL,
            aliases TEXT NOT NULL,
            groups TEXT NOT NULL,
            body TEXT NOT NULL,
            url TEXT NOT NULL,
            institute TEXT NOT NULL,
            date_created TEXT NOT NULL
        );
        CREATE VIRTUAL TABLE topics_fts USING fts5(
            title, aliases, body,
            content='topics', content_rowid='id',
            tokenize='porter unicode61 remove_diacritics 2'
        );
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        """
    )
    db.executemany(
        "INSERT INTO topics VALUES (:id, :title, :aliases, :groups, :body, :url,"
        " :institute, :date_created)",
        sorted(topics, key=lambda t: t["id"]),
    )
    db.execute(
        "INSERT INTO topics_fts(rowid, title, aliases, body)"
        " SELECT id, title, aliases, body FROM topics"
    )
    db.execute("INSERT INTO topics_fts(topics_fts) VALUES('optimize')")
    db.executemany(
        "INSERT INTO meta VALUES (?, ?)",
        [
            ("source", "MedlinePlus Health Topics, National Library of Medicine (NIH)"),
            ("source_file", xml_name),
            ("source_generated", generated),
            ("built", datetime.date.today().isoformat()),
            ("topic_count", str(len(topics))),
            (
                "attribution",
                "Reference content from MedlinePlus (medlineplus.gov), a service of"
                " the National Library of Medicine. Not medical advice.",
            ),
        ],
    )
    db.commit()
    db.execute("VACUUM")
    db.close()


def main():
    args = argparse.ArgumentParser(description=__doc__)
    args.add_argument("--xml", help="build from a local mplus_topics XML instead of fetching")
    options = args.parse_args()

    xml_path = options.xml or fetch_latest_xml()
    generated, topics = parse_topics(xml_path)
    if len(topics) < MIN_TOPICS:
        sys.exit(f"only {len(topics)} topics parsed (< {MIN_TOPICS}) — refusing to build")

    build_db(generated, topics, os.path.basename(xml_path))

    size_mb = os.path.getsize(DB_PATH) / (1024 * 1024)
    if size_mb > MAX_DB_MB:
        sys.exit(f"HealthCorpus.db is {size_mb:.1f} MB (> {MAX_DB_MB} MB) — refusing to ship")
    body_chars = sum(len(t["body"]) for t in topics)
    print(
        f"built {DB_PATH}\n"
        f"  topics: {len(topics)} (XML generated {generated})\n"
        f"  text: {body_chars / 1e6:.1f} M chars, db: {size_mb:.1f} MB"
    )


if __name__ == "__main__":
    main()
