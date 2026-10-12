#!/usr/bin/env python3
"""
Downloads a comprehensive PDF test corpus across all languages, weights,
and feature categories for PDF Helper validation (PVS test).
"""

import os
import sys
import time
import urllib.request
import urllib.error
import urllib.parse
import json

TARGET_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "test_corpus"))

USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"

# Catalog of PDFs to download: (category, filename, url, description)
CORPUS = [
    # -------------------------------------------------------------
    # 1. ALL LANGUAGES (Global Script Coverage)
    # -------------------------------------------------------------
    # Latin (English, German, French, Spanish)
    ("languages", "lang_en_w3c_dummy.pdf",
     "https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf",
     "English - W3C Standard Accessibility Sample"),
    ("languages", "lang_de_german_progit.pdf",
     "https://github.com/progit/progit2-de/releases/download/2.1.308/progit.pdf",
     "German - Full Pro Git Book with Umlauts (ä, ö, ü, ß)"),
    ("languages", "lang_fr_french_progit.pdf",
     "https://github.com/progit/progit2-fr/releases/download/2.1.78/progit.pdf",
     "French - Pro Git Book with accents, cedillas, ligatures"),
    ("languages", "lang_es_spanish_progit.pdf",
     "https://github.com/progit/progit2-es/releases/download/2.1.23/progit.pdf",
     "Spanish - Pro Git Book with tildes and inverted punctuation"),

    # Cyrillic (Russian)
    ("languages", "lang_ru_russian_progit.pdf",
     "https://github.com/progit/progit2-ru/releases/download/2.1.125/progit.pdf",
     "Russian - Pro Git Book in Cyrillic script"),

    # CJK (Chinese, Japanese, Korean)
    ("languages", "lang_zh_chinese_progit.pdf",
     "https://github.com/progit/progit2-zh/releases/download/2.1.79/progit.pdf",
     "Chinese Simplified - Pro Git Book in CJK Hanzi"),
    ("languages", "lang_ja_japanese_progit.pdf",
     "https://github.com/progit/progit2-ja/releases/download/2.1.7/progit.pdf",
     "Japanese - Pro Git Book in Kanji, Hiragana, Katakana"),
    ("languages", "lang_ja_kampo_medical.pdf",
     "https://raw.githubusercontent.com/pdfminer/pdfminer.six/master/samples/nonfree/kampo.pdf",
     "Japanese - Kampo medical report with vertical/Identity CJK font"),
    ("languages", "lang_ko_korean_progit.pdf",
     "https://github.com/progit/progit2-ko/releases/download/2.1.80/progit.pdf",
     "Korean - Pro Git Book in Hangul script"),

    # Indic Scripts (Hindi, Tamil, Telugu, Bengali)
    ("languages", "lang_hi_hindi_syllabus.pdf",
     "https://upload.wikimedia.org/wikipedia/commons/a/ac/M.A._Hindi_Syllabus_Mizoram_University.pdf",
     "Hindi - Devanagari script university syllabus"),
    ("languages", "lang_ta_tamil_oli.pdf",
     "https://upload.wikimedia.org/wikipedia/commons/a/a8/Tamil_Oli_Books_Digitelization_Appreciation.pdf",
     "Tamil - Dravidian Tamil script appreciation letter"),
    ("languages", "lang_he_hebrew_abulafia.pdf",
     "https://upload.wikimedia.org/wikipedia/commons/9/93/Abulafia-Parable_of_the_Pearl_in_the_original_Hebrew.pdf",
     "Hebrew - RTL Hebrew script document"),
    ("languages", "lang_th_thai_declaration.pdf",
     "https://upload.wikimedia.org/wikipedia/commons/f/f1/Joint_Declaration_by_the_Prime_Minister_of_the_Kingdom_of_Cambodia_and_the_Prime_Minister_of_the_Kingdom_of_Thailand_on_the_outcomes_of_their_meeting_in_Kuala_Lumpur%2C_Malaysia.pdf",
     "Thai - Southeast Asian Thai script official declaration"),
    ("languages", "lang_vi_vietnamese_ease.pdf",
     "https://upload.wikimedia.org/wikipedia/commons/4/44/Demo_Vietnamese_with_Ease_1%28H%E1%BB%8Dc_ti%E1%BA%BFng_Vi%E1%BB%87t_d%E1%BB%85_d%C3%A0ng%29.pdf",
     "Vietnamese - Latin with complex stacked tone diacritics"),

    # Arabic (RTL Arabic script)
    ("languages", "lang_ar_arabic_habibi.pdf",
     "https://raw.githubusercontent.com/py-pdf/sample-files/main/015-arabic/habibi.pdf",
     "Arabic - WeasyPrint RTL Arabic ligature test"),
    ("languages", "lang_ar_arabic_cid_truetype.pdf",
     "https://raw.githubusercontent.com/mozilla/pdf.js/master/test/pdfs/ArabicCIDTrueType.pdf",
     "Arabic - Mozilla PDF.js Arabic CID TrueType font test"),

    # -------------------------------------------------------------
    # 2. LIGHTWEIGHT PDFS (< 50 KB, Minimal Objects)
    # -------------------------------------------------------------
    ("light", "light_minimal_1kb.pdf",
     "https://raw.githubusercontent.com/py-pdf/sample-files/main/001-trivial/minimal-document.pdf",
     "Light - Minimal single-page PDFTeX document (1.4 KB)"),
    ("light", "light_simple1_849b.pdf",
     "https://raw.githubusercontent.com/pdfminer/pdfminer.six/master/samples/simple1.pdf",
     "Light - Extremely compact 849-byte single page"),
    ("light", "light_simple2_1kb.pdf",
     "https://raw.githubusercontent.com/pdfminer/pdfminer.six/master/samples/simple2.pdf",
     "Light - 1.1 KB two-object document"),
    ("light", "light_jo_3kb.pdf",
     "https://raw.githubusercontent.com/pdfminer/pdfminer.six/master/samples/jo.pdf",
     "Light - 3.3 KB small flyer"),
    ("light", "light_libreoffice_2page.pdf",
     "https://raw.githubusercontent.com/py-pdf/sample-files/main/002-trivial-libre-office-writer/002-trivial-libre-office-writer.pdf",
     "Light - LibreOffice minimal writer document"),

    # -------------------------------------------------------------
    # 3. HEAVY PDFS (Multi-MB, Dense Vectors, Hundreds of Pages)
    # -------------------------------------------------------------
    ("heavy", "heavy_cad_plans_6mb.pdf",
     "https://raw.githubusercontent.com/mozilla/pdf.js/master/test/pdfs/22060_A1_01_Plans.pdf",
     "Heavy - 6.2 MB complex architectural CAD plans (dense paths)"),
    ("heavy", "heavy_geotopo_117pages.pdf",
     "https://raw.githubusercontent.com/py-pdf/sample-files/main/009-pdflatex-geotopo/GeoTopo.pdf",
     "Heavy - 117 pages math & geometry book with 500+ hyperlinks"),
    ("heavy", "heavy_progit_en_18mb.pdf",
     "https://github.com/progit/progit2/releases/download/2.1.450/progit.pdf",
     "Heavy - 18 MB complete Pro Git English book (500+ pages)"),

    # -------------------------------------------------------------
    # 4. FEATURE VARIETY & EDGE CASES
    # -------------------------------------------------------------
    # Forms (AcroForms)
    ("features", "form_irs_f1040nr.pdf",
     "https://raw.githubusercontent.com/pdfminer/pdfminer.six/master/samples/nonfree/f1040nr.pdf",
     "Forms - Official IRS 1040-NR interactive tax form"),
    ("features", "form_acroform_test.pdf",
     "https://raw.githubusercontent.com/pdfminer/pdfminer.six/master/samples/acroform/AcroForm_TEST.pdf",
     "Forms - AcroForm calculation & widget appearance test"),
    ("features", "form_libreoffice_widgets.pdf",
     "https://raw.githubusercontent.com/py-pdf/sample-files/main/012-libreoffice-form/libreoffice-form.pdf",
     "Forms - LibreOffice interactive form with 9 widgets"),

    # Passwords & Encryption
    ("features", "encrypt_aes128.pdf",
     "https://raw.githubusercontent.com/pdfminer/pdfminer.six/master/samples/encryption/aes-128.pdf",
     "Encryption - AES-128 encrypted document"),
    ("features", "encrypt_aes256.pdf",
     "https://raw.githubusercontent.com/pdfminer/pdfminer.six/master/samples/encryption/aes-256.pdf",
     "Encryption - AES-256 standard encrypted document"),
    ("features", "encrypt_rc4_128.pdf",
     "https://raw.githubusercontent.com/pdfminer/pdfminer.six/master/samples/encryption/rc4-128.pdf",
     "Encryption - RC4-128 standard security handler"),
    ("features", "encrypt_libreoffice_pw.pdf",
     "https://raw.githubusercontent.com/py-pdf/sample-files/main/005-libreoffice-writer-password/libreoffice-writer-password.pdf",
     "Encryption - LibreOffice password-protected PDF"),

    # Codecs & Image Encodings
    ("features", "codec_ccitt_fax.pdf",
     "https://raw.githubusercontent.com/py-pdf/sample-files/main/007-imagemagick-images/imagemagick-CCITTFaxDecode.pdf",
     "Codecs - CCITT Group 4 fax encoding"),
    ("features", "codec_ascii85.pdf",
     "https://raw.githubusercontent.com/py-pdf/sample-files/main/007-imagemagick-images/imagemagick-ASCII85Decode.pdf",
     "Codecs - ASCII85Decode stream filter"),
    ("features", "codec_lzw.pdf",
     "https://raw.githubusercontent.com/py-pdf/sample-files/main/007-imagemagick-images/imagemagick-lzw.pdf",
     "Codecs - LZWDecode stream filter"),
    ("features", "codec_jbig2.pdf",
     "https://raw.githubusercontent.com/pdfminer/pdfminer.six/master/samples/contrib/pdf-with-jbig2.pdf",
     "Codecs - JBIG2 image stream codec"),
    ("features", "codec_cmyk_jpeg.pdf",
     "https://raw.githubusercontent.com/mozilla/pdf.js/master/test/pdfs/cmykjpeg.pdf",
     "Codecs - CMYK JPEG image colorspace"),

    # Graphics, Shadings, Layers & Structure
    ("features", "graphics_axial_shading.pdf",
     "https://raw.githubusercontent.com/mozilla/pdf.js/master/test/pdfs/axial_shading_many_inputs.pdf",
     "Graphics - Type 2 Axial Shading with multiple inputs"),
    ("features", "graphics_function_shading.pdf",
     "https://raw.githubusercontent.com/mozilla/pdf.js/master/test/pdfs/function_based_shading.pdf",
     "Graphics - Type 1 Function-based shading pattern"),
    ("features", "graphics_ocg_layers.pdf",
     "https://raw.githubusercontent.com/py-pdf/sample-files/main/029-optional-content-groups/ocg_map_test.pdf",
     "Graphics - Optional Content Groups (OCG layers)"),
    ("features", "graphics_annotated.pdf",
     "https://raw.githubusercontent.com/py-pdf/sample-files/main/024-annotations/annotated_pdf.pdf",
     "Annotations - Text, Highlight, and Ink vector annotations"),
    ("features", "structure_outlines.pdf",
     "https://raw.githubusercontent.com/py-pdf/sample-files/main/006-pdflatex-outline/pdflatex-outline.pdf",
     "Structure - PDF Outlines / Table of Contents / Bookmarks"),
    ("features", "structure_pdfa.pdf",
     "https://raw.githubusercontent.com/py-pdf/sample-files/main/021-pdfa/crazyones-pdfa.pdf",
     "Structure - PDF/A archival standard compliance"),
]


def download_file(category, filename, url, description):
    cat_dir = os.path.join(TARGET_DIR, category)
    os.makedirs(cat_dir, exist_ok=True)
    target_path = os.path.join(cat_dir, filename)

    if os.path.exists(target_path) and os.path.getsize(target_path) > 100:
        print(f"[SKIP] {filename} already exists ({round(os.path.getsize(target_path)/1024, 1)} KB)")
        return target_path

    print(f"[DOWNLOADING] {filename} -> {description}")
    print(f"  URL: {url}")
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})

    for attempt in range(1, 4):
        try:
            with urllib.request.urlopen(req, timeout=60) as resp, open(target_path, "wb") as f:
                total_bytes = 0
                while True:
                    chunk = resp.read(64 * 1024)
                    if not chunk:
                        break
                    f.write(chunk)
                    total_bytes += len(chunk)

            # Validate PDF magic header
            with open(target_path, "rb") as f:
                header = f.read(10)
                if not header.startswith(b"%PDF-"):
                    print(f"  [WARN] {filename} did not start with %PDF- (got {header[:5]!r})")
                    # If it's an error page or redirect, delete it
                    if b"<html" in header.lower() or b"<!doc" in header.lower():
                        os.remove(target_path)
                        raise ValueError("Downloaded file is HTML error page, not PDF")

            size_kb = round(os.path.getsize(target_path) / 1024, 1)
            print(f"  [SUCCESS] {filename} ({size_kb} KB)")
            return target_path
        except Exception as e:
            print(f"  [RETRY {attempt}/3] Failed: {e}")
            if os.path.exists(target_path):
                try:
                    os.remove(target_path)
                except OSError:
                    pass
            time.sleep(2 * attempt)

    print(f"  [FAILED] Could not download {filename}")
    return None


def main():
    print(f"Target Directory: {TARGET_DIR}")
    os.makedirs(TARGET_DIR, exist_ok=True)

    manifest = []
    success_count = 0
    fail_count = 0

    for category, filename, url, description in CORPUS:
        path = download_file(category, filename, url, description)
        if path and os.path.exists(path):
            success_count += 1
            manifest.append({
                "category": category,
                "filename": filename,
                "relative_path": os.path.relpath(path, TARGET_DIR),
                "size_bytes": os.path.getsize(path),
                "description": description,
                "source_url": url,
            })
        else:
            fail_count += 1

    # Write manifest.json
    manifest_path = os.path.join(TARGET_DIR, "manifest.json")
    with open(manifest_path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)

    print("\n" + "=" * 60)
    print(f"Download complete: {success_count} succeeded, {fail_count} failed.")
    print(f"Manifest written to: {manifest_path}")
    print("=" * 60)


if __name__ == "__main__":
    main()
