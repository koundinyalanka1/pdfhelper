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
fn lossless_round_trip_of_every_byte_in_every_code_page() {
    let bytes: Vec<u8> = (0..=255).collect();
    for encoding in Encoding::all().into_iter().filter(|e| !e.is_unicode()) {
        let decoded = encoding.decode_lossless(&bytes);
        let encoded = encoding.encode_lossless(&decoded.text, encoding);
        assert_eq!(encoded.bytes, bytes, "{}", encoding.name());
        assert_eq!(encoded.unmappable, 0, "{}", encoding.name());
        assert_eq!(encoding.unmappable_lossless(&decoded.text, encoding), 0);
        for byte in 0..=255 {
            let decoded = encoding.decode_lossless(&[byte]);
            assert_eq!(encoding.encode_lossless(&decoded.text, encoding).bytes, [byte], "{} {byte}", encoding.name());
        }
    }
}

#[test]
fn malformed_unicode_and_private_characters_are_lossless() {
    let bytes: Vec<u8> = (0..=255).collect();
    for encoding in Encoding::all().into_iter().filter(|e| e.is_unicode()) {
        for tail in 0..4 {
            let input = &bytes[..bytes.len() - tail];
            let decoded = encoding.decode_lossless(input);
            assert_eq!(encoding.encode_lossless(&decoded.text, encoding).bytes, input, "{} {tail}", encoding.name());
        }
        let literal: String = [0xF0000, 0xF00FF, 0xF0100, 0xF0100, 0xFFFD, 0, 0x10FFFF]
            .into_iter().filter_map(char::from_u32).collect();
        let input = encoding.encode(&literal).bytes;
        let decoded = encoding.decode_lossless(&input);
        assert_eq!(decoded.errors, 0);
        assert_eq!(encoding.encode_lossless(&decoded.text, encoding).bytes, input);
    }
    for encoding in [Encoding::Utf16Le, Encoding::Utf16Be] {
        let input: Vec<u8> = [0xD800u16, 0x41, 0xDC00, 0xDFFF, 0xDBFF, 0x42].into_iter()
            .flat_map(|unit| if encoding == Encoding::Utf16Le { unit.to_le_bytes() } else { unit.to_be_bytes() }).collect();
        let decoded = encoding.decode_lossless(&input);
        assert_eq!(decoded.errors, 4);
        assert_eq!(encoding.encode_lossless(&decoded.text, encoding).bytes, input);
    }
    let bad = Encoding::Utf8.decode_lossless(b"a\xF0\x9F\xFFb");
    assert_eq!(bad.errors, Encoding::Utf8.decode(b"a\xF0\x9F\xFFb").errors);
    assert_eq!(Encoding::Utf16Le.encode_lossless(&bad.text, Encoding::Utf8).unmappable, 3);
    assert_eq!(Encoding::Utf16Le.unmappable_lossless(&bad.text, Encoding::Utf8), 3);
}

#[test]
fn text_typed_after_a_cut_off_character_stays_aligned() {
    for (encoding, unit) in [(Encoding::Utf16Le, 2), (Encoding::Utf16Be, 2), (Encoding::Utf32Le, 4), (Encoding::Utf32Be, 4)] {
        let mut input = encoding.encode("kept").bytes;
        input.push(0x63);
        let decoded = encoding.decode_lossless(&input);
        assert_eq!(encoding.encode_lossless(&decoded.text, encoding).bytes, input, "{}", encoding.name());
        let edited = format!("{}\nadded \u{e9}", decoded.text);
        let written = encoding.encode_lossless(&edited, encoding).bytes;
        assert_eq!(&written[..input.len()], &input[..], "{}: the original bytes come first", encoding.name());
        assert_eq!(written.len() % unit, 0);
        let again = encoding.decode_lossless(&written);
        assert!(again.text.ends_with("\nadded \u{e9}"), "{}: {:?}", encoding.name(), again.text);
        assert!(again.text.starts_with("kept"));
    }
}

#[test]
fn lossless_decoding_respects_its_output_budget() {
    assert!(Encoding::Utf8.decode_lossless_limited(b"abc", 2).is_err());
    assert!(Encoding::Utf8.decode_lossless_limited(&[0xFF], 3).is_err());
    assert_eq!(Encoding::Utf8.decode_lossless_limited(&[0xFF], 4).unwrap().text.len(), 4);
}

#[test]
fn bounded_encoding_mutations_preserve_bytes() {
    let (send, receive) = std::sync::mpsc::channel();
    let worker = std::thread::Builder::new().stack_size(512 << 10).spawn(move || {
        let mut state = 0xB8D0_C0DE_1234_5678u64;
        let encodings = Encoding::all();
        for step in 0..4_096 {
            let mut bytes = Vec::new();
            for _ in 0..step % 257 {
                state ^= state << 13;
                state ^= state >> 7;
                state ^= state << 17;
                bytes.push(state as u8);
            }
            let encoding = encodings[step % encodings.len()];
            let decoded = encoding.decode_lossless(&bytes);
            assert_eq!(encoding.encode_lossless(&decoded.text, encoding).bytes, bytes);
        }
        send.send(()).unwrap();
    }).unwrap();
    receive.recv_timeout(std::time::Duration::from_secs(15)).unwrap();
    worker.join().unwrap();
}

#[test]
fn binary_detection() {
    assert!(!looks_binary(b"plain text\r\nsecond line\twith tab"));
    assert!(looks_binary(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D]));
    assert!(!looks_binary(&Encoding::Utf16Le.encode("text in utf-16").bytes));
    assert!(!looks_binary(b""));
    assert!(looks_binary(&[1, 2, 3, 4, 5, 6, 7, 8, b'a', b'b']));
}
