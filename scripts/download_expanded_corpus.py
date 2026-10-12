#!/usr/bin/env python3
"""
Downloads picture-heavy PDFs and massive epic texts (Ramayana, Mahabharata, Iliad)
for the expanded PDF Helper PVS test suite.
"""

import os
import sys
import time
import urllib.request
import urllib.error

TARGET_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "test_corpus"))
USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"

EXPANDED_CORPUS = [
    # -------------------------------------------------------------
    # 1. HUGE EPIC TEXTS (Massive literature)
    # -------------------------------------------------------------
    ("epics", "epic_iliad_homer_22mb.pdf",
     "https://upload.wikimedia.org/wikipedia/commons/3/38/The_Iliad_of_Homer_%28IA_iliadofhomer00homeiala%29.pdf",
     "Epic - Homer's Iliad (22.5 MB complete text)"),
    ("epics", "epic_ramayana_11mb.pdf",
     "https://upload.wikimedia.org/wikipedia/commons/f/f6/Adhyatma-Ramayana-Keertanalu.pdf",
     "Epic - Ramayana (11.1 MB complete epic scripture)"),
    ("epics", "epic_mahabharata_21mb.pdf",
     "https://upload.wikimedia.org/wikipedia/commons/7/71/Age_Of_The_Mahabharata_War.pdf",
     "Epic - Mahabharata treatise (21.5 MB complete text)"),

    # -------------------------------------------------------------
    # 2. PICTURE HEAVY PDFS (High-res Photos, Multiple Bitmaps)
    # -------------------------------------------------------------
    ("pictures", "pic_images_embedded_1_5mb.pdf",
     "https://raw.githubusercontent.com/mozilla/pdf.js/master/test/pdfs/images.pdf",
     "Pictures - High-resolution embedded photography (1.5 MB)"),
    ("pictures", "pic_64_images_collection.pdf",
     "https://raw.githubusercontent.com/py-pdf/sample-files/main/027-cropped-rotated-scaled/cropped-rotated-scaled.pdf",
     "Pictures - Document containing 64 embedded images"),
    ("pictures", "pic_imagemagick_multipage.pdf",
     "https://raw.githubusercontent.com/py-pdf/sample-files/main/007-imagemagick-images/imagemagick-images.pdf",
     "Pictures - 6-page pure image presentation document"),
    ("pictures", "pic_base64_highres_scan_2mb.pdf",
     "https://raw.githubusercontent.com/py-pdf/sample-files/main/018-base64-image/base64image.pdf",
     "Pictures / Scans - 2.26 MB high-resolution page scan"),
]


def download(category, filename, url, description):
    cat_dir = os.path.join(TARGET_DIR, category)
    os.makedirs(cat_dir, exist_ok=True)
    target = os.path.join(cat_dir, filename)

    if os.path.exists(target) and os.path.getsize(target) > 100:
        print(f"[EXISTS] {filename} ({round(os.path.getsize(target)/1024/1024, 2)} MB)")
        return target

    print(f"[DOWNLOADING] {filename} -> {description}")
    print(f"  URL: {url}")
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})

    for attempt in range(1, 4):
        try:
            with urllib.request.urlopen(req, timeout=90) as resp, open(target, "wb") as f:
                while True:
                    chunk = resp.read(64 * 1024)
                    if not chunk:
                        break
                    f.write(chunk)

            size_mb = round(os.path.getsize(target) / 1024 / 1024, 2)
            print(f"  [SUCCESS] {filename} ({size_mb} MB)")
            return target
        except Exception as e:
            print(f"  [RETRY {attempt}/3] {e}")
            if os.path.exists(target):
                try:
                    os.remove(target)
                except OSError:
                    pass
            time.sleep(2 * attempt)

    print(f"  [FAILED] {filename}")
    return None


def main():
    print(f"Downloading expanded corpus to: {TARGET_DIR}")
    # Also ensure local scanned fixture is copied into ocr/ folder
    ocr_dir = os.path.join(TARGET_DIR, "ocr")
    os.makedirs(ocr_dir, exist_ok=True)
    local_scan = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "packages", "flutter_pdf_core", "rust", "fixtures", "scanned.pdf"))
    if os.path.exists(local_scan):
        with open(local_scan, "rb") as src, open(os.path.join(ocr_dir, "ocr_scanned_invoice.pdf"), "wb") as dst:
            dst.write(src.read())
        print(f"[COPIED] ocr_scanned_invoice.pdf from internal fixture")

    for cat, fn, url, desc in EXPANDED_CORPUS:
        download(cat, fn, url, desc)

    print("\nExpanded download complete.")


if __name__ == "__main__":
    main()
