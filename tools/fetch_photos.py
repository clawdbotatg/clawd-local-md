#!/usr/bin/env python3
"""Fetch the photo-suite test images from Wikimedia Commons.

The photo pipeline is the app's headline feature and the hardest thing to
test: it needs REAL clinical photographs, not renders — a VLM naming a
cartoon rash proves nothing about naming a real one. Commons carries
public-domain (mostly CDC) and CC-licensed clinical images.

Images are downloaded to `build/photos/` (gitignored) rather than committed:
the suite is about *behavior*, and keeping third-party images out of the repo
keeps the licensing story simple. Every file's licence and source URL is
recorded in the manifest it writes, so results stay attributable.

    python3 tools/fetch_photos.py        # download / refresh
"""

import json
import os
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "build", "photos")
SUITE = os.path.join(ROOT, "tools", "photo_suite.json")
API = "https://commons.wikimedia.org/w/api.php?"
AGENT = "LocalMD-photo-suite/1.0 (clawd@buidlguidl.com)"


def api(params):
    url = API + urllib.parse.urlencode(params)
    request = urllib.request.Request(url, headers={"User-Agent": AGENT})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def image_info(title):
    data = api({
        "action": "query", "format": "json", "titles": title,
        "prop": "imageinfo", "iiprop": "url|extmetadata",
        "iiurlwidth": "1024",  # scale down: the phone sends a camera frame, not a 4000px plate
    })
    pages = data.get("query", {}).get("pages", {})
    page = next(iter(pages.values()))
    if "imageinfo" not in page:
        raise SystemExit(f"no imageinfo for {title!r} — has it been renamed?")
    info = page["imageinfo"][0]
    meta = info.get("extmetadata", {})
    return {
        "url": info.get("thumburl") or info["url"],
        "descriptionurl": info["descriptionurl"],
        "license": meta.get("LicenseShortName", {}).get("value", "unknown"),
        "artist": meta.get("Artist", {}).get("value", ""),
    }


def main():
    os.makedirs(OUT, exist_ok=True)
    cases = json.load(open(SUITE))
    manifest = []
    for case in cases:
        title = case["commons"]
        info = image_info(title)
        path = os.path.join(OUT, case["file"])
        if not os.path.exists(path):
            print(f"downloading {case['file']} …  [{info['license']}]")
            request = urllib.request.Request(info["url"], headers={"User-Agent": AGENT})
            with urllib.request.urlopen(request, timeout=120) as response:
                with open(path, "wb") as out:
                    out.write(response.read())
        else:
            print(f"have {case['file']}  [{info['license']}]")
        manifest.append({
            "file": case["file"], "commons": title,
            "license": info["license"], "source": info["descriptionurl"],
        })
    with open(os.path.join(OUT, "ATTRIBUTION.json"), "w") as out:
        json.dump(manifest, out, indent=1)
    print(f"\n{len(manifest)} images in {OUT} (attribution written)")


if __name__ == "__main__":
    main()
