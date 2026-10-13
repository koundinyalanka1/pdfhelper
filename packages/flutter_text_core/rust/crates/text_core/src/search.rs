//! Find and replace over plain text.

/// How to match.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SearchOptions {
    pub case_sensitive: bool,
    /// Only match where the query is not part of a longer word.
    pub whole_word: bool,
}

/// A match, as byte offsets into the searched text.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Match {
    pub start: usize,
    pub end: usize,
}

fn fold(c: char) -> char {
    let mut lower = c.to_lowercase();
    match (lower.next(), lower.next()) {
        (Some(single), None) => single,
        _ => c,
    }
}

fn is_word_char(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

fn at_word_boundaries(text: &str, m: Match) -> bool {
    let before = text[..m.start].chars().next_back();
    let after = text[m.end..].chars().next();
    !before.is_some_and(is_word_char) && !after.is_some_and(is_word_char)
}

/// Every non-overlapping match, up to `limit`.
pub fn find_all(text: &str, query: &str, options: SearchOptions, limit: usize) -> Vec<Match> {
    let mut out = Vec::new();
    if query.is_empty() || limit == 0 {
        return out;
    }
    if options.case_sensitive {
        for (start, found) in text.match_indices(query) {
            let m = Match {
                start,
                end: start + found.len(),
            };
            if options.whole_word && !at_word_boundaries(text, m) {
                continue;
            }
            if out.last().is_some_and(|last: &Match| last.end > m.start) {
                continue;
            }
            out.push(m);
            if out.len() >= limit {
                break;
            }
        }
        return out;
    }
    let needle: Vec<char> = query.chars().map(fold).collect();
    let first = needle[0];
    let mut search_from = 0;
    let mut indices = text.char_indices();
    while let Some((start, c)) = indices.next() {
        if start < search_from || fold(c) != first {
            continue;
        }
        let mut rest = text[start..].char_indices();
        let mut end = start;
        let mut matched = true;
        for &want in &needle {
            match rest.next() {
                Some((offset, got)) if fold(got) == want => end = start + offset + got.len_utf8(),
                _ => {
                    matched = false;
                    break;
                }
            }
        }
        if !matched {
            continue;
        }
        let m = Match { start, end };
        if options.whole_word && !at_word_boundaries(text, m) {
            continue;
        }
        out.push(m);
        if out.len() >= limit {
            break;
        }
        search_from = end;
        // Skip the characters inside the match.
        while indices.clone().next().is_some_and(|(i, _)| i < end) {
            indices.next();
        }
    }
    out
}

/// Replace every match; returns the new text and the number of replacements.
pub fn replace_all(text: &str, query: &str, replacement: &str, options: SearchOptions) -> (String, usize) {
    let matches = find_all(text, query, options, usize::MAX);
    if matches.is_empty() {
        return (text.to_owned(), 0);
    }
    let mut out = String::with_capacity(text.len());
    let mut last = 0;
    for m in &matches {
        out.push_str(&text[last..m.start]);
        out.push_str(replacement);
        last = m.end;
    }
    out.push_str(&text[last..]);
    (out, matches.len())
}

/// Convert sorted byte offsets into UTF-16 offsets (what Dart strings use),
/// in one pass over the text.
pub fn utf16_offsets(text: &str, sorted_bytes: &[usize]) -> Vec<usize> {
    let mut out = Vec::with_capacity(sorted_bytes.len());
    let mut wanted = sorted_bytes.iter().peekable();
    let mut utf16 = 0;
    for (byte, c) in text.char_indices() {
        while let Some(&&target) = wanted.peek() {
            if target > byte {
                break;
            }
            out.push(utf16);
            wanted.next();
        }
        utf16 += c.len_utf16();
    }
    out.extend(wanted.map(|_| utf16));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spans(text: &str, query: &str, options: SearchOptions) -> Vec<&'static str> {
        find_all(text, query, options, 100)
            .into_iter()
            .map(|m| &*Box::leak(text[m.start..m.end].to_owned().into_boxed_str()))
            .collect()
    }

    #[test]
    fn case_insensitive_and_whole_word() {
        let text = "Total, total; TOTALS and subtotal. Ünïcode ÜNÏCODE";
        let any = SearchOptions::default();
        assert_eq!(spans(text, "total", any), ["Total", "total", "TOTAL", "total"]);
        let words = SearchOptions { whole_word: true, ..any };
        assert_eq!(spans(text, "total", words), ["Total", "total"]);
        let exact = SearchOptions { case_sensitive: true, ..any };
        assert_eq!(spans(text, "total", exact), ["total", "total"]);
        assert_eq!(spans(text, "ünïcode", any), ["Ünïcode", "ÜNÏCODE"]);
        assert!(find_all(text, "", any, 10).is_empty());
    }

    #[test]
    fn matches_do_not_overlap() {
        assert_eq!(find_all("aaaa", "aa", SearchOptions::default(), 10).len(), 2);
        let exact = SearchOptions { case_sensitive: true, ..Default::default() };
        assert_eq!(find_all("aaaa", "aa", exact, 10).len(), 2);
    }

    #[test]
    fn replaces_everything() {
        let (out, n) = replace_all("Rs. 10, rs. 20", "rs.", "₹", SearchOptions::default());
        assert_eq!((out.as_str(), n), ("₹ 10, ₹ 20", 2));
        let (out, n) = replace_all("cat catalog", "cat", "dog", SearchOptions { whole_word: true, ..Default::default() });
        assert_eq!((out.as_str(), n), ("dog catalog", 1));
    }

    #[test]
    fn converts_offsets_to_utf16() {
        let text = "a😀bఅc";
        // Byte offsets of 'a', 'b', 'అ', 'c' and the end.
        let bytes = [0, 5, 6, 9, 10];
        assert_eq!(utf16_offsets(text, &bytes), [0, 3, 4, 5, 6]);
    }
}
