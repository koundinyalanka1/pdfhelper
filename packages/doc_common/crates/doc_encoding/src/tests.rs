use super::*;

fn page(label: &str) -> Encoding {
    Encoding::from_label(label).unwrap_or_else(|| panic!("no encoding {label}"))
}

#[test]
fn labels_and_code_pages() {
    assert_eq!(Encoding::from_label(" UTF-8 "), Some(Encoding::Utf8));
    assert_eq!(Encoding::from_label("Latin1").map(Encoding::name), Some("iso-8859-1"));
    assert_eq!(Encoding::from_label("cp1251").map(Encoding::name), Some("windows-1251"));
    assert_eq!(Encoding::from_label("us-ascii"), Some(Encoding::WINDOWS_1252));
    assert_eq!(Encoding::from_label("shift_jis"), None);
    assert_eq!(Encoding::from_code_page(1252), Some(Encoding::WINDOWS_1252));
    assert_eq!(Encoding::from_code_page(866).map(Encoding::name), Some("ibm866"));
    assert_eq!(Encoding::from_code_page(10000).map(Encoding::name), Some("macintosh"));
    assert_eq!(Encoding::from_code_page(65001), Some(Encoding::Utf8));
    assert_eq!(Encoding::from_code_page(0), None);
    assert_eq!(page("tis-620").code_page(), None);
    assert_eq!(page("windows-1250").code_page(), Some(1250));
    // Every encoding is reachable by its own name.
    for encoding in Encoding::all() {
        assert_eq!(Encoding::from_label(encoding.name()), Some(encoding), "{}", encoding.name());
    }
}

#[test]
fn windows_1252_round_trips_every_byte() {
    let all: Vec<u8> = (0..=255u8).collect();
    let decoded = Encoding::WINDOWS_1252.decode(&all);
    assert_eq!(decoded.errors, 0);
    assert!(decoded.text.contains('€'));
    assert!(decoded.text.contains('\u{2019}'));
    let encoded = Encoding::WINDOWS_1252.encode(&decoded.text);
    assert_eq!(encoded.unmappable, 0);
    assert_eq!(encoded.bytes, all);
}

#[test]
fn code_pages_decode_known_text() {
    assert_eq!(page("windows-1251").decode(&[0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2]).text, "Привет");
    assert_eq!(page("koi8-r").decode(&[0xF0, 0xD2, 0xC9, 0xD7, 0xC5, 0xD4]).text, "Привет");
    assert_eq!(page("ibm866").decode(&[0x8F, 0xE0, 0xA8, 0xA2, 0xA5, 0xE2]).text, "Привет");
    assert_eq!(page("windows-1253").decode(&[0xE1, 0xE2, 0xE3]).text, "αβγ");
    assert_eq!(page("iso-8859-15").decode(&[0xA4]).text, "€");
    assert_eq!(page("iso-8859-1").decode(&[0xA4]).text, "¤");
    assert_eq!(page("macintosh").decode(&[0x8E]).text, "é");
    assert_eq!(page("ibm437").decode(&[0x82]).text, "é");
    // An undefined ISO-8859-3 byte is an error, not a guess.
    let decoded = page("iso-8859-3").decode(&[0xA5]);
    assert_eq!((decoded.text.as_str(), decoded.errors), ("\u{FFFD}", 1));
}

#[test]
fn encoding_reports_unmappable_characters() {
    let encoded = Encoding::WINDOWS_1252.encode("naïve € ₹ ok");
    assert_eq!(encoded.unmappable, 1);
    assert_eq!(Encoding::WINDOWS_1252.decode(&encoded.bytes).text, "naïve € ? ok");
    assert!(!Encoding::WINDOWS_1252.can_encode("తెలుగు"));
    assert!(Encoding::Utf16Le.can_encode("తెలుగు"));
}

#[test]
fn unicode_round_trips() {
    let text = "Hello, తెలుగు, 漢字, 😀";
    for encoding in [Encoding::Utf8, Encoding::Utf16Le, Encoding::Utf16Be, Encoding::Utf32Le, Encoding::Utf32Be] {
        let encoded = encoding.encode(text);
        let decoded = encoding.decode(&encoded.bytes);
        assert_eq!(decoded.text, text, "{}", encoding.name());
        assert_eq!(decoded.errors, 0);
    }
}

#[test]
fn malformed_unicode_is_replaced_and_counted() {
    let decoded = Encoding::Utf8.decode(b"ok \xFF\xFE end \xEF\xBF\xBD");
    assert_eq!(decoded.errors, 2);
    assert!(decoded.text.ends_with('\u{FFFD}'));
    // A lone surrogate and an odd trailing byte.
    let decoded = Encoding::Utf16Le.decode(&[0x41, 0x00, 0x00, 0xD8, 0x42]);
    assert_eq!(decoded.text, "A\u{FFFD}\u{FFFD}");
    assert_eq!(decoded.errors, 2);
}

#[test]
fn detection() {
    let fallback = Encoding::WINDOWS_1252;
    let with_bom = [&[0xEF, 0xBB, 0xBF][..], "héllo".as_bytes()].concat();
    assert_eq!(detect(&with_bom, fallback), Detection { encoding: Encoding::Utf8, bom_len: 3, confident: true });
    let utf16 = Encoding::Utf16Le.encode("plain old text in UTF-16").bytes;
    assert_eq!(detect(&utf16, fallback).encoding, Encoding::Utf16Le);
    let utf16be = Encoding::Utf16Be.encode("plain old text in UTF-16").bytes;
    assert_eq!(detect(&utf16be, fallback).encoding, Encoding::Utf16Be);
    let with_bom16 = [&[0xFF, 0xFE][..], &utf16].concat();
    assert_eq!(detect(&with_bom16, fallback).bom_len, 2);
    assert_eq!(detect(&[0xFF, 0xFE, 0, 0, 0x41, 0, 0, 0], fallback).encoding, Encoding::Utf32Le);
    assert_eq!(detect("ascii only".as_bytes(), fallback).encoding, Encoding::Utf8);
    assert_eq!(detect("తెలుగు".as_bytes(), fallback).encoding, Encoding::Utf8);
    // A UTF-8 character cut off by sampling still counts as UTF-8.
    let cut = &"abc తె".as_bytes()[..5];
    assert_eq!(detect_sample(cut, fallback).encoding, Encoding::Utf8);
    // ...but a whole file ending in a lone lead byte is not UTF-8.
    assert_eq!(detect(b"caf\xE9", fallback).encoding, Encoding::WINDOWS_1252);

    let latin = page("windows-1252").encode("Crème brûlée à la française, déjà vu").bytes;
    let detected = detect(&latin, fallback);
    assert_eq!((detected.encoding, detected.confident), (Encoding::WINDOWS_1252, false));

    let russian = page("windows-1251").encode("Съешь же ещё этих мягких французских булок, да выпей чаю").bytes;
    assert_eq!(detect(&russian, fallback).encoding.name(), "windows-1251");
    let (decoded, _) = decode_detected(&russian, fallback);
    assert!(decoded.text.starts_with("Съешь"));
}

#[test]
fn binary_detection() {
    assert!(!looks_binary(b"plain text\r\nsecond line\twith tab"));
    assert!(looks_binary(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D]));
    assert!(!looks_binary(&Encoding::Utf16Le.encode("text in utf-16").bytes));
    assert!(!looks_binary(b""));
    assert!(looks_binary(&[1, 2, 3, 4, 5, 6, 7, 8, b'a', b'b']));
}
