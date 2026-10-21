#!/usr/bin/env python3
"""
Builds a corpus of real-world office documents for DocHelper's engines:
spreadsheets, word-processing documents and presentations, in Microsoft,
OpenDocument and legacy binary formats.

The files come from the test suites of open-source office libraries, listed
through the GitHub API (no guessed URLs):

  * Apache POI (spreadsheet, document and slideshow test data: decades of
    bug-report files, Excel/Word/PowerPoint 97-2003 and OOXML).
  * XlsxWriter (workbooks saved by Excel itself, used as its reference).
  * calamine (xlsx, xls, xlsb and ods readers' tests).
  * python-docx and python-pptx (documents and decks from Word/PowerPoint).
  * LibreOffice (OpenDocument and OOXML import/export test data).

Files land in test_corpus/office/<extension>/, named <source>__<name>.
Nothing is downloaded twice, duplicates (by content hash) are dropped, and
test_corpus/office/manifest.json lists what was added and where it came from.

    python3 scripts/download_office_corpus.py --dry-run
    python3 scripts/download_office_corpus.py
    python3 scripts/download_office_corpus.py --only xlsx csv --per-type 150

Set GITHUB_TOKEN to raise the GitHub API limit (60 requests an hour).
"""

import argparse
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
TARGET = os.path.join(ROOT, "test_corpus", "office")
CACHE = os.path.join(TARGET, ".cache")
MANIFEST = os.path.join(TARGET, "manifest.json")
USER_AGENT = "dochelper-corpus-builder/1.0 (office test corpus; github.com/koundinyalanka1/pdfhelper)"

EXTENSIONS = {
    "xlsx", "xlsm", "xltx", "xls", "xlsb", "ods", "fods", "csv",
    "docx", "docm", "dotx", "doc", "odt", "fodt", "rtf",
    "pptx", "pptm", "ppsx", "potx", "ppt", "odp", "fodp",
}

# (short name, repository, path prefix to list); a None prefix lists the
# whole tree in one request, a prefix lists that directory through the
# contents API (for repositories too large for one tree listing).
SOURCES = [
    ("poi", "apache/poi", "test-data/spreadsheet"),
    ("poi", "apache/poi", "test-data/document"),
    ("poi", "apache/poi", "test-data/slideshow"),
    ("xlsxwriter", "jmcnamara/XlsxWriter", "xlsxwriter/test/comparison/xlsx_files"),
    ("calamine", "tafia/calamine", "tests"),
    ("pydocx", "python-openxml/python-docx", "tests/test_files"),
    ("pypptx", "scanny/python-pptx", "tests/test_files"),
    ("lo-sc", "LibreOffice/core", "sc/qa/unit/data/ods"),
    ("lo-sc", "LibreOffice/core", "sc/qa/unit/data/xlsx"),
    ("lo-sc", "LibreOffice/core", "sc/qa/unit/data/xls"),
    ("lo-sc", "LibreOffice/core", "sc/qa/unit/data/csv"),
    ("lo-sw", "LibreOffice/core", "sw/qa/extras/odfexport/data"),
    ("lo-sw", "LibreOffice/core", "sw/qa/extras/ooxmlexport/data"),
    ("lo-sw", "LibreOffice/core", "sw/qa/extras/ww8export/data"),
    ("lo-sw", "LibreOffice/core", "sw/qa/extras/rtfexport/data"),
    ("lo-sd", "LibreOffice/core", "sd/qa/unit/data/odp"),
    ("lo-sd", "LibreOffice/core", "sd/qa/unit/data/pptx"),
    ("lo-sd", "LibreOffice/core", "sd/qa/unit/data/ppt"),
]


def http_get(url, headers=None, retries=4, max_bytes=None):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, **(headers or {})})
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(req, timeout=90) as response:
                if max_bytes is not None:
                    length = response.headers.get("Content-Length")
                    if length and int(length) > max_bytes:
                        return None
                    data = response.read(max_bytes + 1)
                    return None if len(data) > max_bytes else data
                return response.read()
        except urllib.error.HTTPError as e:
            if e.code in (403, 429):
                wait = int(e.headers.get("Retry-After", "60"))
                print(f"  rate limited, waiting {wait}s", file=sys.stderr)
                time.sleep(min(wait, 600))
                continue
            if e.code == 404:
                return None
            time.sleep(2 * (attempt + 1))
        except (urllib.error.URLError, TimeoutError):
            time.sleep(2 * (attempt + 1))
    return None


def github_headers():
    token = os.environ.get("GITHUB_TOKEN")
    headers = {"Accept": "application/vnd.github+json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return headers


def cached_json(key, url):
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, key + ".json")
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    body = http_get(url, github_headers())
    if body is None:
        return None
    data = json.loads(body)
    with open(path, "w") as f:
        json.dump(data, f)
    return data


def list_files(repo, prefix):
    """(path, size) of every file under prefix, recursing through the
    contents API (one request per directory)."""
    out = []
    pending = [prefix]
    while pending:
        directory = pending.pop()
        key = (repo + "__" + directory).replace("/", "_")
        url = f"https://api.github.com/repos/{repo}/contents/{urllib.parse.quote(directory)}"
        listing = cached_json(key, url)
        if not isinstance(listing, list):
            print(f"  could not list {repo}/{directory}", file=sys.stderr)
            continue
        for entry in listing:
            if entry.get("type") == "dir":
                pending.append(entry["path"])
            elif entry.get("type") == "file":
                out.append((entry["path"], entry.get("size", 0)))
    return out


def extension_of(path):
    name = path.rsplit("/", 1)[-1]
    return name.rsplit(".", 1)[-1].lower() if "." in name else ""


def safe_name(text, limit=90):
    keep = "".join(c if c.isalnum() or c in "-_." else "_" for c in text)
    return keep[-limit:]


def existing_hashes():
    hashes = {}
    for root, _dirs, files in os.walk(TARGET):
        if ".cache" in root:
            continue
        for name in files:
            if name == "manifest.json":
                continue
            path = os.path.join(root, name)
            with open(path, "rb") as f:
                hashes[hashlib.sha256(f.read()).hexdigest()] = path
    return hashes


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--only", nargs="*", help="only these extensions")
    parser.add_argument("--per-type", type=int, default=250, help="most new files per extension and source")
    parser.add_argument("--max-mb", type=float, default=8.0, help="skip files larger than this")
    args = parser.parse_args()

    only = set(args.only or EXTENSIONS)
    max_bytes = int(args.max_mb * 1024 * 1024)
    os.makedirs(TARGET, exist_ok=True)
    manifest = {}
    if os.path.exists(MANIFEST):
        with open(MANIFEST) as f:
            manifest = json.load(f)
    hashes = existing_hashes()

    plan = []
    for short, repo, prefix in SOURCES:
        files = list_files(repo, prefix)
        counts = {}
        for path, size in sorted(files):
            ext = extension_of(path)
            if ext not in EXTENSIONS or ext not in only or size > max_bytes:
                continue
            if counts.get(ext, 0) >= args.per_type:
                continue
            counts[ext] = counts.get(ext, 0) + 1
            name = f"{short}__{safe_name(path.rsplit('/', 1)[-1])}"
            dest = os.path.join(TARGET, ext, name)
            if os.path.exists(dest):
                continue
            url = f"https://raw.githubusercontent.com/{repo}/HEAD/{urllib.parse.quote(path)}"
            plan.append((dest, url, repo, path))
        print(f"{repo}/{prefix}: {sum(counts.values())} candidates", file=sys.stderr)

    print(f"{len(plan)} files to fetch", file=sys.stderr)
    if args.dry_run:
        return

    added = 0
    for i, (dest, url, repo, path) in enumerate(plan):
        data = http_get(url, max_bytes=max_bytes)
        if not data:
            continue
        digest = hashlib.sha256(data).hexdigest()
        if digest in hashes:
            continue
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "wb") as f:
            f.write(data)
        hashes[digest] = dest
        manifest[os.path.relpath(dest, TARGET)] = {"repo": repo, "path": path, "sha256": digest, "bytes": len(data)}
        added += 1
        if added % 50 == 0:
            with open(MANIFEST, "w") as f:
                json.dump(manifest, f, indent=1, sort_keys=True)
            print(f"  {added} added ({i + 1}/{len(plan)})", file=sys.stderr)
    with open(MANIFEST, "w") as f:
        json.dump(manifest, f, indent=1, sort_keys=True)
    print(f"done: {added} files added", file=sys.stderr)


if __name__ == "__main__":
    main()
