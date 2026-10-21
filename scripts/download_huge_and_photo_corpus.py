#!/usr/bin/env python3
"""
Downloads 100MB+ huge documents (historical phone book/directory) and
historical multilingual scans, and generates pure photo PDFs in various
languages for comprehensive OCR benchmarking.
"""

import os
import sys
import time
import urllib.request
import urllib.error
from PIL import Image, ImageDraw, ImageFont

TARGET_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "test_corpus"))
USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"

HUGE_DOWNLOADS = [
    # -------------------------------------------------------------
    # 1. HUGE 100MB+ DOCUMENT (Historical City Directory / Phone Book)
    # -------------------------------------------------------------
    ("huge", "huge_143mb_san_francisco_directory_phonebook.pdf",
     "https://upload.wikimedia.org/wikipedia/commons/3/34/San_Francisco_Directory_for_the_Year_commencing_April%2C_1874.pdf",
     "Huge - 143.3 MB San Francisco City Directory & Phone Book (1874)"),

    # -------------------------------------------------------------
    # 2. HISTORICAL MULTILINGUAL SCANS
    # -------------------------------------------------------------
    ("scans", "scan_de_german_army.pdf",
     "https://upload.wikimedia.org/wikipedia/commons/3/39/Notes_on_the_German_army_in_the_war._Translated_at_the_Army_war_college%2C_from_a_French_official_document_of_April%2C_1917_%28IA_notesongermanarm00franrich%29.pdf",
     "Scan - German Army military scan document (2.9 MB)"),
    ("scans", "scan_fr_french_defense.pdf",
     "https://upload.wikimedia.org/wikipedia/commons/2/26/Infantry_in_the_defense_-_translated_at_the_Army_War_College_from_a_French_document_%28IA_infantryindefens00armyiala%29.pdf",
     "Scan - French official historical military scan (1.16 MB)"),
    ("scans", "scan_ar_arabic_calligraphy.pdf",
     "https://upload.wikimedia.org/wikipedia/commons/d/d7/Arabic_Primer_of_Calligraphy_WDL3058.pdf",
     "Scan - Arabic Calligraphy manuscript photo scan (4.97 MB)"),
    ("scans", "scan_hi_hindi_manuscripts.pdf",
     "https://upload.wikimedia.org/wikipedia/commons/3/31/Catalogue_of_the_Hindi%2C_Panjabi_and_Hindustani_manuscripts_in_the_library_of_the_British_museum%3B_%28IA_catalogueofhindi00brituoft%29.pdf",
     "Scan - Hindi and Hindustani manuscript catalogue scan (11.77 MB)"),
]


def download(category, filename, url, description):
    cat_dir = os.path.join(TARGET_DIR, category)
    os.makedirs(cat_dir, exist_ok=True)
    target = os.path.join(cat_dir, filename)

    if os.path.exists(target) and os.path.getsize(target) > 500 * 1024:
        print(f"[EXISTS] {filename} ({round(os.path.getsize(target)/1024/1024, 2)} MB)")
        return target

    print(f"[DOWNLOADING] {filename} -> {description}")
    print(f"  URL: {url}")
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})

    for attempt in range(1, 4):
        try:
            with urllib.request.urlopen(req, timeout=180) as resp, open(target, "wb") as f:
                downloaded = 0
                t0 = time.time()
                while True:
                    chunk = resp.read(128 * 1024)
                    if not chunk:
                        break
                    f.write(chunk)
                    downloaded += len(chunk)
                    if time.time() - t0 > 5:
                        print(f"    ... {round(downloaded/1024/1024, 1)} MB downloaded")
                        t0 = time.time()

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


def create_language_photo_pdfs():
    """
    Creates pure image/photo PDFs (bitmap-only, zero text stream)
    bearing printed text in diverse languages for OCR evaluation.
    """
    photo_dir = os.path.join(TARGET_DIR, "photo_languages")
    os.makedirs(photo_dir, exist_ok=True)

    samples = [
        ("photo_lang_en.pdf", "English Scanned Letter", [
            "COMMERCIAL INVOICE AND PACKING SLIP",
            "Account Number: 9874-5120-4412",
            "Date: 12 October 2026",
            "Customer: Antigravity Systems Corporation",
            "Description: High-Performance On-Device PDF Engine",
            "Total Amount Due: $4,500.00 USD",
            "Terms: Net 30 days upon receipt.",
            "Authorized Signature: Johnathan Doe"
        ]),
        ("photo_lang_de.pdf", "German Scanned Document", [
            "RECHNUNG UND LIEFERSCHEIN",
            "Rechnungsnummer: DE-2026-9941",
            "Datum: 12. Oktober 2026",
            "Empfänger: Deutsche Digitaltechnik GmbH",
            "Beschreibung: Softwareentwicklung und Pruefung",
            "Betrag netto: 3.800,00 EUR",
            "Umsatzsteuer 19%: 722,00 EUR",
            "Gesamtbetrag: 4.522,00 EUR zahlbar innerhalb 14 Tagen"
        ]),
        ("photo_lang_fr.pdf", "French Scanned Document", [
            "FACTURE COMMERCIALE ET BORDEREAU",
            "Numéro de facture: FR-2026-8812",
            "Date: 12 octobre 2026",
            "Client: Société Française d'Informatique",
            "Prestation: Traitement et validation de documents PDF",
            "Montant hors taxes: 4.200,00 EUR",
            "TVA 20%: 840,00 EUR",
            "Montant total à payer: 5.040,00 EUR"
        ]),
        ("photo_lang_es.pdf", "Spanish Scanned Document", [
            "FACTURA COMERCIAL Y ALBARAN",
            "Número de factura: ES-2026-7734",
            "Fecha: 12 de octubre de 2026",
            "Cliente: Soluciones Tecnológicas de España",
            "Concepto: Servicios de ingeniería de software",
            "Base imponible: 3.500,00 EUR",
            "IVA 21%: 735,00 EUR",
            "Total a pagar: 4.235,00 EUR vencimiento a 30 días"
        ]),
        ("photo_lang_ru.pdf", "Russian Scanned Document", [
            "СЧЕТ-ФАКТУРА И АКТ ВЫПОЛНЕННЫХ РАБОТ",
            "Номер документа: RU-2026-5521",
            "Дата: 12 октября 2026 года",
            "Заказчик: Общество с ограниченной ответственностью",
            "Услуги: Тестирование программного обеспечения",
            "Сумма к оплате: 350 000 рублей",
            "Без налога на добавленную стоимость"
        ]),
        ("photo_lang_hi.pdf", "Hindi Scanned Document", [
            "वाणिज्यिक चालान और रसीद",
            "चालान संख्या: HI-2026-4411",
            "दिनांक: 12 अक्टूबर 2026",
            "ग्राहक: भारतीय प्रौद्योगिकी सेवाएँ",
            "विवरण: पीडीएफ सॉफ्टवेयर सत्यापन और परीक्षण",
            "कुल राशि: 75,000 भारतीय रुपये",
            "धन्यवाद!"
        ]),
        ("photo_lang_zh.pdf", "Chinese Scanned Document", [
            "商业发票及交付凭证",
            "发票编号: ZH-2026-3399",
            "开票日期: 2026年10月12日",
            "客户名称: 现代信息技术服务有限公司",
            "项目名称: PDF引擎性能测试与质量验证",
            "应收金额: 28,000 人民币",
            "请在收到本发票后三十天内付清"
        ]),
        ("photo_lang_ar.pdf", "Arabic Scanned Document", [
            "فاتورة تجارية وإيصال تسليم",
            "رقم الفاتورة: AR-2026-1102",
            "التاريخ: 12 أكتوبر 2026",
            "العميل: شركة التقنية الحديثة",
            "الخدمات: فحص واختبار محرك المستندات",
            "المبلغ الإجمالي: 15,000 ريال",
            "شكراً لتعاملكم معنا"
        ]),
    ]

    for filename, title, lines in samples:
        target_path = os.path.join(photo_dir, filename)
        if os.path.exists(target_path):
            continue

        # Create high-resolution letter-sized image (1200 x 1600 px)
        width, height = 1200, 1600
        img = Image.new("RGB", (width, height), color=(252, 252, 250))
        draw = ImageDraw.Draw(img)

        # Add decorative paper border / header line
        draw.rectangle([50, 50, width - 50, height - 50], outline=(200, 200, 200), width=2)
        draw.line([80, 160, width - 80, 160], fill=(120, 120, 120), width=2)

        # Draw title and lines
        # Using default font, scaled up by drawing coordinates
        y = 100
        draw.text((80, y), title.upper(), fill=(20, 20, 20))
        y = 200
        for line in lines:
            draw.text((100, y), line, fill=(30, 30, 30))
            y += 80

        # Save purely as an image PDF
        img.save(target_path, "PDF", resolution=150.0)
        size_kb = round(os.path.getsize(target_path) / 1024, 1)
        print(f"[CREATED] {filename} ({size_kb} KB pure photo PDF)")


def main():
    print(f"Target directory: {TARGET_DIR}")

    # 1. Download Huge 100MB+ PDF and historical scans
    for cat, fn, url, desc in HUGE_DOWNLOADS:
        download(cat, fn, url, desc)

    # 2. Generate pure photo PDFs across languages
    create_language_photo_pdfs()

    print("\nDownload & Photo PDF generation complete.")


if __name__ == "__main__":
    main()
