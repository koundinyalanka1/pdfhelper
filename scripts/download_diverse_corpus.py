#!/usr/bin/env python3
"""
Adds a few hundred varied PDFs to test_corpus for the PDF Helper PVS suite.

Three sources, none of them guessed URLs:

  1. The test suites of open-source PDF libraries (pdf.js, qpdf, PDFBox, pypdf,
     pikepdf, pdfplumber, pdfminer.six, veraPDF). Their file trees are listed
     through the GitHub API and sorted into categories by file name: broken and
     fuzzed files, fonts, graphics, image codecs, encryption, forms,
     annotations, document structure, page layout, PDF/A.
  2. Wikimedia Commons, by search: sheet music, maps, comics, newspapers,
     blueprints, spreadsheets, posters, manuscripts, scanned books, slides,
     invoices, manuals, theses and more.
  3. arXiv papers (LaTeX, two columns, equations) and a few government forms.

Files land in test_corpus/<category>/. Nothing is downloaded twice, files that
duplicate one already in the corpus are dropped, and what was added is listed
in test_corpus/manifest_diverse.json (including each file's Producer).

    python3 scripts/download_diverse_corpus.py --dry-run   # plan only
    python3 scripts/download_diverse_corpus.py             # download
    python3 scripts/download_diverse_corpus.py --only malformed fonts

Set GITHUB_TOKEN to raise the GitHub API limit (60 requests an hour).
"""

import argparse
import concurrent.futures
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
TARGET_DIR = os.path.join(ROOT, "test_corpus")
CACHE_DIR = os.path.join(TARGET_DIR, ".cache")
MANIFEST = os.path.join(TARGET_DIR, "manifest_diverse.json")

USER_AGENT = "pdfhelper-corpus-builder/1.0 (PDF test corpus; github.com/koundinyalanka1/pdfhelper)"
BROWSER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
)

# -----------------------------------------------------------------------------
# 1. Test suites of PDF libraries
# -----------------------------------------------------------------------------

# (short name, GitHub repo, path must contain, category for files no rule claims)
REPOS = [
    ("pdfjs", "mozilla/pdf.js", "test/pdfs/", "regressions"),
    ("qpdf", "qpdf/qpdf", "qtest/", "structure"),
    ("pdfbox", "apache/pdfbox", "src/test/resources", "documents"),
    ("pypdf", "py-pdf/pypdf", "resources/", "documents"),
    ("samples", "py-pdf/sample-files", "", "documents"),
    ("pikepdf", "pikepdf/pikepdf", "resources/", "documents"),
    ("plumber", "jsvine/pdfplumber", "pdfs/", "documents"),
    ("pdfminer", "pdfminer/pdfminer.six", "samples/", "documents"),
    ("vera", "veraPDF/veraPDF-corpus", "", "pdfa"),
]


def rule(category, sub="", word=""):
    """A name rule: `sub` matches anywhere, `word` only as a whole word."""
    parts = []
    if sub:
        parts.append("(?:%s)" % sub)
    if word:
        parts.append("(?<![a-z])(?:%s)(?![a-z])" % word)
    return category, re.compile("|".join(parts))


# Matched against the lowercased path; the first rule that matches wins.
RULES = [
    rule("malformed",
         sub=r"fuzz|corrupt|damaged|truncat|malform|invalid|garbage|junk|bomb|evil|broken|"
             r"recover|circular|recurs|loop|clusterfuzz|no-?(xref|trailer|header|root|eof)|"
             r"missing|zero-?length|/\d{10,}\.pdf$",
         word=r"bad\d*|trailing"),
    rule("encryption",
         sub=r"encrypt|password|crypt|rc4|owner|locked",
         word=r"r[2-6]|aes\d*|pw"),
    rule("codecs",
         sub=r"jbig2|jpx|jp2|jpeg|ccitt|fax|dct|lzw|runlength|ascii85|asciihex|predictor|"
             r"inline-?image|tiff|bitmap|flate|halftone",
         word=r"jpg|mmr"),
    rule("fonts",
         sub=r"font|truetype|type1|type3|type0|opentype|cmap|glyph|ligature|bidi|arab|hebrew|"
             r"vertical|symbol|encoding|unicode|thai|devanagari|indic|cjk|japan|chinese|korean|"
             r"tounicode|helvetica|courier|simfang|tamil",
         word=r"cid|cff|otf|ttf|vert"),
    rule("graphics",
         sub=r"shading|gradient|pattern|blend|transparen|smask|softmask|alpha|clip|devicen|"
             r"separation|colorspace|colour|color|icc|cmyk|calrgb|calgray|indexed|tiling|mesh|"
             r"coons|tensor|knockout|overprint|stroke|dash|linecap|linejoin|miter|curve|vector|"
             r"canvas|svg|image|picture|photo",
         word=r"lab|ctm|cap|join|path|rgb"),
    rule("forms",
         sub=r"acroform|widget|checkbox|radiobutton|combo|listbox|signature|xfa|textfield|"
             r"calculation|formfield|/form/",
         word=r"field|fields|form|forms|fillform"),
    rule("annotations",
         sub=r"annot|highlight|squiggly|underline|strikeout|freetext|popup|fileattach|stamp|"
             r"polygon|polyline|caret|comment",
         word=r"ink|inks|link|links|note"),
    rule("structure",
         sub=r"outline|bookmark|pagelabel|attachment|portfolio|tagged|struct|linearized|objstm|"
             r"objectstream|xref|incremental|metadata|xmp|pdfa|pdf-a|pdf2|optional|layer|ocg|"
             r"javascript|destination|thread|mcid|trailer|pagetree|pages-tree|catalog|"
             r"embeddedfile|collection",
         word=r"toc|js|dest|dests|names|action|actions|info"),
    rule("layout",
         sub=r"rotat|cropbox|mediabox|userunit|page-?size|inherit|mixed|portrait|landscape|"
             r"bleed|trimbox|artbox|boxes|scaled|oversize|giant|tiny|huge",
         word=r"rot\d*|crop|cropped|scale|a[0-9]|letter|legal"),
]

# How many files each category may take from the library test suites.
CAPS = {
    "malformed": 90, "encryption": 40, "codecs": 50, "fonts": 60, "graphics": 60,
    "forms": 40, "annotations": 40, "structure": 60, "layout": 30, "pdfa": 90,
    "documents": 50, "regressions": 50,
}

# -----------------------------------------------------------------------------
# 2. Wikimedia Commons searches: category -> queries (up to PER_QUERY files each)
# -----------------------------------------------------------------------------

# Wikimedia lets a client fetch only a handful of files per ten minutes, so ask
# for one small file per search: the topics matter more than the count.
PER_QUERY = 1
COMMONS_MAX_MB = 3

COMMONS = {
    "music": ["sheet music score", "piano sheet music", "hymn book", "choir part"],
    "maps": ["map", "topographic map", "city map", "transit map", "nautical chart", "atlas"],
    "comics": ["comic book", "comic strip", "illustrated children's book"],
    "newspapers": ["newspaper", "magazine issue", "gazette"],
    "technical": ["blueprint", "engineering drawing", "circuit schematic", "floor plan",
                  "datasheet", "patent"],
    "tables": ["spreadsheet", "statistics table", "timetable", "calendar", "price list"],
    "posters": ["poster", "infographic", "brochure", "flyer", "certificate", "menu"],
    "manuscripts": ["handwritten manuscript", "medieval manuscript", "letter handwritten"],
    "scanned_books": ["Internet Archive scanned book", "full text scanned volume"],
    "slides": ["presentation slides", "conference talk slides"],
    "business": ["invoice", "curriculum vitae", "contract", "annual report"],
    "manuals": ["user manual", "handbook", "instruction guide"],
    "legal": ["court opinion", "act of parliament", "treaty"],
    "science": ["thesis", "lecture notes mathematics", "chemistry", "anatomy atlas",
                "botanical illustration"],
    "typography": ["typeface specimen", "font sample", "emoji", "calligraphy"],
}

# -----------------------------------------------------------------------------
# 3. arXiv papers and government forms
# -----------------------------------------------------------------------------

ARXIV = [
    ("1706.03762", "Attention Is All You Need (two columns, equations, figures)"),
    ("1512.03385", "ResNet (two columns, diagrams)"),
    ("2005.14165", "GPT-3 (75 pages, tables)"),
    ("1810.04805", "BERT"),
    ("1412.6980", "Adam (algorithms, plots)"),
    ("math/0211159", "Perelman, the entropy formula (older TeX, Type 1 fonts)"),
    ("hep-th/9711200", "Maldacena, large N limit (older TeX)"),
    ("astro-ph/9805201", "Riess et al., accelerating universe"),
    ("1602.03837", "LIGO gravitational waves (many authors)"),
    ("1207.7214", "ATLAS Higgs observation (thousands of authors)"),
    ("quant-ph/9508027", "Shor, polynomial-time factoring"),
    ("2010.11929", "Vision Transformer (figures, tables)"),
]

# (category, filename, url, description)
DIRECT = [
    ("government", "irs_fw9.pdf", "https://www.irs.gov/pub/irs-pdf/fw9.pdf", "IRS W-9 (fillable)"),
    ("government", "irs_f1040.pdf", "https://www.irs.gov/pub/irs-pdf/f1040.pdf", "IRS 1040 (fillable)"),
    ("government", "irs_fw4.pdf", "https://www.irs.gov/pub/irs-pdf/fw4.pdf", "IRS W-4"),
    ("government", "irs_i1040gi.pdf", "https://www.irs.gov/pub/irs-pdf/i1040gi.pdf", "IRS 1040 instructions (long, dense)"),
    ("government", "uscis_i9.pdf", "https://www.uscis.gov/sites/default/files/document/forms/i-9.pdf", "USCIS I-9"),
    ("structure", "iso32000_1_pdf_reference.pdf",
     "https://opensource.adobe.com/dc-acrobat-sdk-docs/pdfstandards/PDF32000_2008.pdf",
     "ISO 32000-1 (the PDF specification: 750 pages, outlines, links)"),
]


# -----------------------------------------------------------------------------
# Plumbing
# -----------------------------------------------------------------------------

# Hosts that told us to come back later: host -> time.time() when to retry.
THROTTLED = {}


def http_get(url, headers=None, timeout=90, retries=5, max_bytes=None):
    """Returns the body, or None after the retries. A body past max_bytes is None."""
    host = urllib.parse.urlparse(url).netloc
    if THROTTLED.get(host, 0) > time.time():
        return None
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, **(headers or {})})
    last = None
    for attempt in range(1, retries + 1):
        wait = 2 * attempt
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                chunks, size = [], 0
                while True:
                    chunk = resp.read(256 * 1024)
                    if not chunk:
                        return b"".join(chunks)
                    size += len(chunk)
                    if max_bytes and size > max_bytes:
                        return None
                    chunks.append(chunk)
        except urllib.error.HTTPError as e:
            last = e
            if e.code in (400, 401, 403, 404, 410):
                break
            if e.code in (429, 503):  # told to slow down: do as the server says
                retry_after = e.headers.get("Retry-After", "")
                wait = int(retry_after) if retry_after.isdigit() else 15 * attempt
                if wait > 90:  # not worth sitting through; stop asking this host
                    THROTTLED[host] = time.time() + wait
                    print(f"  [THROTTLED] {host} asks for {wait} s; skipping its files this run. "
                          "Run the script again later to fetch the rest.")
                    return None
        except Exception as e:  # network hiccup, timeout, reset
            last = e
        time.sleep(wait)
    print(f"  [FAILED] {url}: {last}")
    return None


def cached_json(key, url):
    """GET a JSON API response, cached for a day so reruns do not repeat searches."""
    os.makedirs(CACHE_DIR, exist_ok=True)
    cache = os.path.join(CACHE_DIR, "q_" + hashlib.sha1(key.encode()).hexdigest() + ".json")
    if os.path.exists(cache) and time.time() - os.path.getmtime(cache) < 86400:
        with open(cache, encoding="utf-8") as f:
            return json.load(f)
    body = http_get(url)
    time.sleep(1.5)  # Wikimedia rate-limits bursts of API calls
    if body is None:
        return None
    with open(cache, "wb") as f:
        f.write(body)
    return json.loads(body)


def github_tree(repo):
    """Every file in the repo as {path, size}, cached for a day."""
    os.makedirs(CACHE_DIR, exist_ok=True)
    cache = os.path.join(CACHE_DIR, repo.replace("/", "_") + ".json")
    if os.path.exists(cache) and time.time() - os.path.getmtime(cache) < 86400:
        with open(cache, encoding="utf-8") as f:
            return json.load(f)
    headers = {"Accept": "application/vnd.github+json"}
    if os.environ.get("GITHUB_TOKEN"):
        headers["Authorization"] = "Bearer " + os.environ["GITHUB_TOKEN"]
    body = http_get(f"https://api.github.com/repos/{repo}/git/trees/HEAD?recursive=1", headers)
    if body is None:
        return []
    tree = json.loads(body).get("tree", [])
    files = [{"path": t["path"], "size": t.get("size", 0)} for t in tree if t["type"] == "blob"]
    with open(cache, "w", encoding="utf-8") as f:
        json.dump(files, f)
    return files


def safe_name(text, limit=70):
    text = re.sub(r"[^A-Za-z0-9._-]+", "_", text).strip("._")
    return text[:limit] or "file"


def looks_like_pdf(data, category):
    if len(data) < 8:
        return False
    head = data[:1024]
    if b"%PDF-" in head:
        return True
    # Broken files may have lost their header; keep them if they still have PDF objects.
    return category == "malformed" and b" obj" in data[:65536]


def producer_of(data):
    """Best-effort Producer/Creator from the Info dictionary or XMP."""
    found = []
    for pattern in (rb"/Producer\s*\(([^)]{1,80})\)", rb"/Creator\s*\(([^)]{1,80})\)",
                    rb"<pdf:Producer>([^<]{1,80})</pdf:Producer>",
                    rb"<xmp:CreatorTool>([^<]{1,80})</xmp:CreatorTool>"):
        m = re.search(pattern, data[:2_000_000]) or re.search(pattern, data[-200_000:])
        if m:
            found.append(m.group(1).decode("latin-1").strip())
    return " / ".join(dict.fromkeys(found))


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def existing_hashes():
    seen = {}
    for dirpath, dirs, files in os.walk(TARGET_DIR):
        dirs[:] = [d for d in dirs if d != ".cache"]
        for name in files:
            if name.lower().endswith(".pdf"):
                path = os.path.join(dirpath, name)
                with open(path, "rb") as f:
                    seen[sha256(f.read())] = os.path.relpath(path, TARGET_DIR)
    return seen


def classify(path, default):
    low = path.lower()
    for category, pattern in RULES:
        if pattern.search(low):
            return category
    return default


def plan_repo_files(max_bytes, only):
    """Chooses files from the library test suites: [{category, name, url, ...}]."""
    buckets = {}  # category -> bucket -> [candidate]
    for short, repo, must_contain, default in REPOS:
        files = github_tree(repo)
        print(f"  {repo}: {len(files)} files")
        for entry in files:
            path = entry["path"]
            if not path.lower().endswith(".pdf") or must_contain not in path:
                continue
            if entry["size"] == 0 or entry["size"] > max_bytes:
                continue
            digest = int(hashlib.sha1(path.encode()).hexdigest(), 16)
            if short == "vera":
                # Conformance suites are mostly valid files; keep every fifth failing one.
                if "fail" in path.lower() and "pass" not in path.lower() and digest % 5:
                    continue
                category, bucket = "pdfa", "/".join(path.split("/")[:2])
            else:
                category, bucket = classify(path, default), short
            if only and category not in only:
                continue
            name = safe_name(f"{short}__{os.path.splitext(os.path.basename(path))[0]}") + ".pdf"
            url = f"https://raw.githubusercontent.com/{repo}/HEAD/" + urllib.parse.quote(path)
            buckets.setdefault(category, {}).setdefault(bucket, []).append({
                "category": category, "filename": name, "url": url, "size": entry["size"],
                "source": repo, "description": path, "_order": digest,
            })
    chosen = []
    for category, by_bucket in buckets.items():
        lists = [sorted(v, key=lambda c: c["_order"]) for _, v in sorted(by_bucket.items())]
        picked, depth = [], 0
        while len(picked) < CAPS.get(category, 40) and any(depth < len(l) for l in lists):
            for l in lists:  # round-robin so no single suite dominates a category
                if depth < len(l) and len(picked) < CAPS.get(category, 40):
                    picked.append(l[depth])
            depth += 1
        chosen += picked
    return chosen


def plan_commons(max_bytes, only):
    """Searches Wikimedia Commons for PDFs: [{category, name, url, ...}]."""
    max_bytes = min(max_bytes, int(COMMONS_MAX_MB * 1024 * 1024))
    chosen, taken = [], set()
    for category, queries in COMMONS.items():
        if only and category not in only:
            continue
        for query in queries:
            params = {
                "action": "query", "format": "json", "generator": "search",
                "gsrsearch": "filemime:application/pdf " + query, "gsrnamespace": "6",
                "gsrlimit": "30", "prop": "imageinfo", "iiprop": "url|size|mime",
            }
            url = "https://commons.wikimedia.org/w/api.php?" + urllib.parse.urlencode(params)
            result = cached_json(query, url)
            if result is None:
                continue
            pages = sorted(result.get("query", {}).get("pages", {}).values(),
                           key=lambda p: p.get("index", 0))
            count = 0
            for page in pages:
                info = (page.get("imageinfo") or [{}])[0]
                title = page["title"]
                if info.get("mime") != "application/pdf" or not info.get("url"):
                    continue
                if not 0 < info.get("size", 0) <= max_bytes or title in taken:
                    continue
                taken.add(title)
                stem = re.sub(r"^File:|\.pdf$", "", title, flags=re.I)
                chosen.append({
                    "category": category, "filename": "commons__" + safe_name(stem, 60) + ".pdf",
                    "url": info["url"], "size": info["size"], "source": "commons.wikimedia.org",
                    "description": f"{query}: {title}",
                })
                count += 1
                if count >= PER_QUERY:
                    break
    return chosen


def plan_web(only, max_bytes):
    chosen = []
    if not only or "papers" in only:
        for arxiv_id, description in ARXIV:
            chosen.append({
                "category": "papers", "filename": "arxiv_" + safe_name(arxiv_id) + ".pdf",
                "url": f"https://arxiv.org/pdf/{arxiv_id}", "size": 0, "source": "arxiv.org",
                "description": description, "delay": 3,  # arXiv asks for 3 s between requests
            })
    for category, filename, url, description in DIRECT:
        if not only or category in only:
            chosen.append({"category": category, "filename": filename, "url": url, "size": 0,
                           "source": urllib.parse.urlparse(url).netloc, "description": description,
                           "headers": {"User-Agent": BROWSER_AGENT}, "big_ok": True})
    return chosen


def fetch(item, max_bytes):
    """Downloads one planned file; returns (item, data or None)."""
    if item.get("delay"):
        time.sleep(item["delay"])
    limit = None if item.get("big_ok") else max_bytes * 2 if item["size"] == 0 else None
    data = http_get(item["url"], headers=item.get("headers"), max_bytes=limit)
    if item["source"] == "commons.wikimedia.org" and data is not None:
        time.sleep(3)  # one file at a time, politely spaced
    return item, data


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true", help="list what would be downloaded")
    parser.add_argument("--only", nargs="+", metavar="CATEGORY", help="only these categories")
    parser.add_argument("--max-mb", type=float, default=5, help="largest single file (default 5)")
    parser.add_argument("--budget-mb", type=float, default=400, help="stop planning past this total")
    parser.add_argument("--skip-web", action="store_true", help="library test suites only")
    args = parser.parse_args()
    sys.stdout.reconfigure(line_buffering=True)
    max_bytes = int(args.max_mb * 1024 * 1024)
    only = set(args.only or [])

    print(f"Planning from library test suites -> {TARGET_DIR}")
    plan = plan_repo_files(max_bytes, only)
    if not args.skip_web:
        print("Searching Wikimedia Commons ...")
        plan += plan_commons(max_bytes, only)
        plan += plan_web(only, max_bytes)

    # Trim to the budget, keeping every category represented.
    budget, total, trimmed = int(args.budget_mb * 1024 * 1024), 0, []
    for item in sorted(plan, key=lambda i: i.get("_order", 0)):
        if total + item["size"] <= budget:
            total += item["size"]
            trimmed.append(item)
    plan = trimmed

    by_category = {}
    for item in plan:
        by_category.setdefault(item["category"], []).append(item)
    print(f"\nPlanned {len(plan)} files, about {total / 1024 / 1024:.0f} MB (sizes unknown for some):")
    for category, items in sorted(by_category.items()):
        print(f"  {category:14} {len(items):4}")
    if args.dry_run:
        for item in plan:
            print(f"  {item['category']}/{item['filename']}  <- {item['description'][:80]}")
        return

    seen = existing_hashes()
    manifest = {}
    if os.path.exists(MANIFEST):
        with open(MANIFEST, encoding="utf-8") as f:
            manifest = {m["relative_path"]: m for m in json.load(f)}

    def save_manifest():
        with open(MANIFEST, "w", encoding="utf-8") as f:
            json.dump(sorted(manifest.values(), key=lambda m: m["relative_path"]), f, indent=2)

    def record(item, relative, data):
        manifest[relative] = {
            "category": item["category"], "filename": item["filename"], "relative_path": relative,
            "size_bytes": len(data), "sha256": sha256(data), "description": item["description"],
            "source": item["source"], "source_url": item["url"], "producer": producer_of(data),
        }

    todo = []
    for item in plan:
        relative = f"{item['category']}/{item['filename']}"
        path = os.path.join(TARGET_DIR, relative)
        if not os.path.exists(path):
            todo.append(item)
        elif relative not in manifest:  # fetched by an earlier run that never saved its manifest
            with open(path, "rb") as f:
                record(item, relative, f.read())
    save_manifest()
    print(f"\n{len(plan) - len(todo)} already present; downloading {len(todo)}.\n")

    # arXiv wants a single slow stream and Wikimedia one file at a time;
    # everything else can overlap freely.
    slow = [i for i in todo if i.get("delay")]
    wikimedia = [i for i in todo if i["source"] == "commons.wikimedia.org"]
    fast = [i for i in todo if not i.get("delay") and i["source"] != "commons.wikimedia.org"]
    added, skipped = 0, {"duplicate": 0, "not a pdf": 0, "failed": 0}

    def accept(item, data):
        nonlocal added
        if data is None:
            skipped["failed"] += 1
            return
        if not looks_like_pdf(data, item["category"]):
            skipped["not a pdf"] += 1
            print(f"  [SKIP] {item['filename']}: not a PDF")
            return
        digest = sha256(data)
        if digest in seen:
            skipped["duplicate"] += 1
            print(f"  [DUPLICATE] {item['filename']} = {seen[digest]}")
            return
        relative = f"{item['category']}/{item['filename']}"
        os.makedirs(os.path.join(TARGET_DIR, item["category"]), exist_ok=True)
        target = os.path.join(TARGET_DIR, relative)
        with open(target + ".part", "wb") as f:  # renamed when whole, so a test run never reads half a file
            f.write(data)
        os.replace(target + ".part", target)
        seen[digest] = relative
        added += 1
        record(item, relative, data)
        print(f"  [OK] {relative} ({len(data) / 1024:.0f} KB)")

    for items, workers in ((fast, 8), (wikimedia, 1)):
        with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
            for item, data in pool.map(lambda i: fetch(i, max_bytes), items):
                accept(item, data)
        save_manifest()
    for item in slow:
        accept(*fetch(item, max_bytes))
    save_manifest()
    print(f"\nAdded {added} files; skipped {skipped}. Manifest: {MANIFEST}")

    producers = {}
    for entry in manifest.values():
        key = (entry["producer"] or "(none)").split(" / ")[0]
        key = re.sub(r"[\d.]+", "", key).strip()[:40]
        producers[key] = producers.get(key, 0) + 1
    print("\nProducers across the added files:")
    for key, count in sorted(producers.items(), key=lambda kv: -kv[1])[:25]:
        print(f"  {count:4}  {key}")


if __name__ == "__main__":
    sys.exit(main())
