//! Word list numbering (`word/numbering.xml`): list definitions, the labels
//! paragraphs get, and new bullet and numbered lists.

use std::collections::HashMap;

use doc_xml::{ns, Document, Element, Node};

use super::styles::{apply_rpr, wel, wval, ThemeFonts};
use crate::view::{ListLabel, RunStyle};

/// One level of a list definition.
#[derive(Clone, Debug, Default)]
pub struct Level {
    pub start: i64,
    /// `decimal`, `bullet`, `lowerLetter`...
    pub fmt: String,
    /// The label pattern (`%1.`, `%1.%2`, a bullet character).
    pub text: String,
    pub rpr: Option<Element>,
    /// Shows every level's number in decimal (`isLgl`).
    pub legal: bool,
    /// Restart after this level (1-based) appears; 0 never restarts.
    pub restart: Option<u8>,
}

#[derive(Clone, Debug, Default)]
pub struct AbstractNum {
    pub levels: Vec<Option<Level>>,
}

#[derive(Clone, Debug, Default)]
pub struct Num {
    pub abstract_id: String,
    /// Level overrides: a start value and/or a replacement level.
    pub overrides: HashMap<u8, (Option<i64>, Option<Level>)>,
}

#[derive(Clone, Debug, Default)]
pub struct Numbering {
    pub abstracts: HashMap<String, AbstractNum>,
    pub nums: HashMap<String, Num>,
    /// The part, for adding lists.
    pub doc: Option<Document>,
}

fn child<'e>(e: &'e Element, local: &str) -> Option<&'e Element> {
    e.elements().find(|c| c.ns == ns::W && c.local() == local)
}

fn read_level(l: &Element) -> Level {
    Level {
        start: child(l, "start")
            .and_then(wval)
            .and_then(|v| v.parse().ok())
            .unwrap_or(0),
        fmt: child(l, "numFmt")
            .and_then(wval)
            .unwrap_or("decimal")
            .to_owned(),
        text: child(l, "lvlText").and_then(wval).unwrap_or("").to_owned(),
        rpr: child(l, "rPr").cloned(),
        legal: child(l, "isLgl").is_some_and(|e| wval(e) != Some("0")),
        restart: child(l, "lvlRestart")
            .and_then(wval)
            .and_then(|v| v.parse().ok()),
    }
}

impl Numbering {
    pub fn read(doc: Document) -> Numbering {
        let mut n = Numbering::default();
        for e in doc.root.elements() {
            if e.ns != ns::W {
                continue;
            }
            match e.local() {
                "abstractNum" => {
                    let Some(id) = e.attr(ns::W, "abstractNumId") else {
                        continue;
                    };
                    let mut a = AbstractNum {
                        levels: vec![None; 9],
                    };
                    for l in e.elements().filter(|c| c.local() == "lvl") {
                        let i = l
                            .attr(ns::W, "ilvl")
                            .and_then(|v| v.parse::<usize>().ok())
                            .unwrap_or(0);
                        if i < 9 {
                            a.levels[i] = Some(read_level(l));
                        }
                    }
                    n.abstracts.insert(id.to_owned(), a);
                }
                "num" => {
                    let Some(id) = e.attr(ns::W, "numId") else {
                        continue;
                    };
                    let Some(abs) = child(e, "abstractNumId").and_then(wval) else {
                        continue;
                    };
                    let mut num = Num {
                        abstract_id: abs.to_owned(),
                        overrides: HashMap::new(),
                    };
                    for o in e.elements().filter(|c| c.local() == "lvlOverride") {
                        let i = o
                            .attr(ns::W, "ilvl")
                            .and_then(|v| v.parse::<u8>().ok())
                            .unwrap_or(0);
                        let start = child(o, "startOverride")
                            .and_then(wval)
                            .and_then(|v| v.parse().ok());
                        let level = child(o, "lvl").map(read_level);
                        num.overrides.insert(i, (start, level));
                    }
                    n.nums.insert(id.to_owned(), num);
                }
                _ => {}
            }
        }
        n.doc = Some(doc);
        n
    }

    /// The level definition a list paragraph uses.
    pub fn level(&self, num_id: &str, ilvl: u8) -> Option<&Level> {
        let num = self.nums.get(num_id)?;
        if let Some((_, Some(l))) = num.overrides.get(&ilvl) {
            return Some(l);
        }
        self.abstracts
            .get(&num.abstract_id)?
            .levels
            .get(ilvl as usize)?
            .as_ref()
    }

    pub fn is_bullet(&self, num_id: &str) -> bool {
        self.level(num_id, 0).is_some_and(|l| l.fmt == "bullet")
    }

    /// A list id whose first level is a bullet (`bullet` true) or a
    /// number, adding a list definition when there is none.
    pub fn list_for(&mut self, bullet: bool, w: &str) -> String {
        let mut ids: Vec<&String> = self.nums.keys().collect();
        ids.sort_by_key(|id| id.parse::<u64>().unwrap_or(u64::MAX));
        for id in ids {
            let Some(l) = self.level(id, 0) else { continue };
            let ok = if bullet {
                l.fmt == "bullet"
            } else {
                l.fmt == "decimal" && l.text.starts_with("%1")
            };
            if ok && self.nums[id].overrides.is_empty() {
                return id.clone();
            }
        }
        self.add_list(bullet, w)
    }

    /// Add a new list (a new abstract definition and a list using it).
    pub fn add_list(&mut self, bullet: bool, w: &str) -> String {
        let abs_id = (0..)
            .map(|i: u32| i.to_string())
            .find(|i| !self.abstracts.contains_key(i))
            .unwrap();
        let num_id = (1..)
            .map(|i: u32| i.to_string())
            .find(|i| !self.nums.contains_key(i))
            .unwrap();
        let q = |n: &str| {
            if w.is_empty() {
                n.to_owned()
            } else {
                format!("{w}:{n}")
            }
        };
        let mut abs = Element::new(q("abstractNum"), ns::W);
        abs.set_attr(&q("abstractNumId"), ns::W, abs_id.clone());
        abs.push(wel(w, "multiLevelType", Some("hybridMultilevel")));
        let bullets = ["\u{2022}", "\u{25E6}", "\u{25AA}"];
        let formats = ["decimal", "lowerLetter", "lowerRoman"];
        let mut def = AbstractNum {
            levels: vec![None; 9],
        };
        for i in 0..9u8 {
            let mut lvl = Element::new(q("lvl"), ns::W);
            lvl.set_attr(&q("ilvl"), ns::W, i.to_string());
            lvl.push(wel(w, "start", Some("1")));
            let (fmt, text) = if bullet {
                ("bullet", bullets[i as usize % 3].to_owned())
            } else {
                (formats[i as usize % 3], format!("%{}.", i + 1))
            };
            lvl.push(wel(w, "numFmt", Some(fmt)));
            lvl.push(wel(w, "lvlText", Some(&text)));
            lvl.push(wel(w, "lvlJc", Some("left")));
            let mut ppr = Element::new(q("pPr"), ns::W);
            let mut ind = Element::new(q("ind"), ns::W);
            ind.set_attr(&q("left"), ns::W, (720 * (i as u32 + 1)).to_string());
            ind.set_attr(&q("hanging"), ns::W, "360");
            ppr.push(ind);
            lvl.push(ppr);
            def.levels[i as usize] = Some(read_level(&lvl));
            abs.push(lvl);
        }
        let mut num = Element::new(q("num"), ns::W);
        num.set_attr(&q("numId"), ns::W, num_id.clone());
        num.push(wel(w, "abstractNumId", Some(&abs_id)));

        let doc = self.doc.get_or_insert_with(|| {
            let mut root = Element::new(q("numbering"), ns::W);
            let attr = if w.is_empty() {
                "xmlns".to_owned()
            } else {
                format!("xmlns:{w}")
            };
            root.set_attr(&attr, ns::XMLNS, ns::W.uri());
            Document::new(root)
        });
        // Every abstract definition comes before every list.
        let children = &mut doc.root.children;
        let first_num = children
            .iter()
            .position(|n| {
                n.as_element().is_some_and(|e| {
                    e.ns == ns::W && matches!(e.local(), "num" | "numIdMacAtCleanup")
                })
            })
            .unwrap_or(children.len());
        children.insert(first_num, Node::Element(abs));
        let after_nums = children
            .iter()
            .position(|n| {
                n.as_element()
                    .is_some_and(|e| e.ns == ns::W && e.local() == "numIdMacAtCleanup")
            })
            .unwrap_or(children.len());
        children.insert(after_nums, Node::Element(num));

        self.abstracts.insert(abs_id.clone(), def);
        self.nums.insert(
            num_id.clone(),
            Num {
                abstract_id: abs_id,
                overrides: HashMap::new(),
            },
        );
        num_id
    }
}

/// Counts list items through a document to give each its label.
#[derive(Default)]
pub struct Counters {
    /// Per abstract list: the counter of each level.
    counts: HashMap<String, [i64; 9]>,
    /// Per abstract list: which levels have started.
    started: HashMap<String, [bool; 9]>,
    /// Lists (num ids) seen, for start overrides.
    seen: HashMap<String, bool>,
}

impl Counters {
    /// The label of the next paragraph in list `num_id` at `ilvl`.
    pub fn next(
        &mut self,
        numbering: &Numbering,
        num_id: &str,
        ilvl: u8,
        mark: &RunStyle,
        theme: &ThemeFonts,
    ) -> Option<ListLabel> {
        let num = numbering.nums.get(num_id)?;
        let abs = num.abstract_id.clone();
        let level_of = |i: u8| numbering.level(num_id, i);
        let lvl = level_of(ilvl)?;
        let counts = self.counts.entry(abs.clone()).or_insert([0; 9]);
        let started = self.started.entry(abs.clone()).or_insert([false; 9]);
        // A list with start overrides restarts them the first time it is
        // used.
        if !self.seen.contains_key(num_id) {
            self.seen.insert(num_id.to_owned(), true);
            for (i, (start, level)) in &num.overrides {
                let i = *i as usize;
                if i < 9 && (start.is_some() || level.is_some()) {
                    started[i] = false;
                }
            }
        }
        let i = ilvl as usize;
        if started[i] {
            counts[i] += 1;
        } else {
            let start = num
                .overrides
                .get(&ilvl)
                .and_then(|(s, _)| *s)
                .unwrap_or(lvl.start);
            counts[i] = start;
            started[i] = true;
        }
        // Deeper levels restart.
        for d in i + 1..9 {
            let restart = level_of(d as u8).and_then(|l| l.restart);
            if restart != Some(0) && restart.is_none_or(|r| (r as usize) > i) {
                started[d] = false;
            }
        }
        let mut text = String::new();
        let pattern: Vec<char> = lvl.text.chars().collect();
        let mut k = 0;
        while k < pattern.len() {
            let c = pattern[k];
            if c == '%' && k + 1 < pattern.len() && pattern[k + 1].is_ascii_digit() {
                let n = pattern[k + 1].to_digit(10).unwrap() as usize;
                if (1..=9).contains(&n) {
                    let l = n - 1;
                    let value = if l <= i && (started[l] || l == i) {
                        counts[l]
                    } else {
                        level_of(l as u8).map_or(1, |x| x.start.max(1))
                    };
                    let fmt = if lvl.legal && l < i {
                        "decimal"
                    } else {
                        level_of(l as u8).map_or("decimal", |x| x.fmt.as_str())
                    };
                    text.push_str(&format_number(value, fmt));
                }
                k += 2;
                continue;
            }
            text.push(map_symbol(c));
            k += 1;
        }
        let bullet = lvl.fmt == "bullet";
        let mut style = mark.clone();
        style.underline = "none".into();
        if let Some(r) = &lvl.rpr {
            apply_rpr(&mut style, r, theme);
        }
        if bullet && is_symbol_font(&style.font) {
            style.font = mark.font.clone();
        }
        Some(ListLabel {
            level: ilvl,
            text,
            bullet,
            style,
        })
    }
}

fn is_symbol_font(font: &str) -> bool {
    let f = font.to_ascii_lowercase();
    f == "symbol" || f.starts_with("wingdings") || f.starts_with("webdings")
}

/// Symbol-font bullets live in the private use area; show their Unicode
/// look-alikes.
pub fn map_symbol(c: char) -> char {
    match c as u32 {
        0xF0B7 | 0xF09F => '\u{2022}',
        0xF0A7 | 0xF06E | 0xF0A8 => '\u{25AA}',
        0xF0D8 | 0xF0E8 => '\u{27A2}',
        0xF0FC => '\u{2713}',
        0xF076 => '\u{2756}',
        0xF0B2 => '\u{25C7}',
        0xF06F => '\u{25A1}',
        0xF0F0..=0xF0FF | 0xF000..=0xF0EF => '\u{2022}',
        _ => c,
    }
}

/// A list number in one of Word's formats.
pub fn format_number(n: i64, fmt: &str) -> String {
    match fmt {
        "none" | "bullet" => String::new(),
        "lowerLetter" => letters(n).to_lowercase(),
        "upperLetter" => letters(n),
        "lowerRoman" => roman(n).to_lowercase(),
        "upperRoman" => roman(n),
        "decimalZero" => format!("{n:02}"),
        "ordinal" => {
            let suffix = match (n % 100, n % 10) {
                (11..=13, _) => "th",
                (_, 1) => "st",
                (_, 2) => "nd",
                (_, 3) => "rd",
                _ => "th",
            };
            format!("{n}{suffix}")
        }
        "decimalEnclosedCircle" if (1..=20).contains(&n) => {
            char::from_u32(0x2460 + n as u32 - 1).unwrap().to_string()
        }
        "hindiNumbers" | "hindiCounting" | "hindiVowels" => devanagari(n),
        _ => n.to_string(),
    }
}

fn letters(n: i64) -> String {
    if n <= 0 {
        return n.to_string();
    }
    // Word repeats the letter: a..z, aa..zz, aaa...
    let letter = (b'A' + ((n - 1) % 26) as u8) as char;
    let times = ((n - 1) / 26 + 1) as usize;
    std::iter::repeat_n(letter, times).collect()
}

pub fn roman(mut n: i64) -> String {
    if !(1..4000).contains(&n) {
        return n.to_string();
    }
    let table = [
        (1000, "M"),
        (900, "CM"),
        (500, "D"),
        (400, "CD"),
        (100, "C"),
        (90, "XC"),
        (50, "L"),
        (40, "XL"),
        (10, "X"),
        (9, "IX"),
        (5, "V"),
        (4, "IV"),
        (1, "I"),
    ];
    let mut s = String::new();
    for (v, r) in table {
        while n >= v {
            s.push_str(r);
            n -= v;
        }
    }
    s
}

fn devanagari(n: i64) -> String {
    n.to_string()
        .chars()
        .map(|c| {
            c.to_digit(10)
                .map_or(c, |d| char::from_u32(0x0966 + d).unwrap())
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats() {
        assert_eq!(format_number(4, "lowerRoman"), "iv");
        assert_eq!(format_number(28, "upperLetter"), "BB");
        assert_eq!(format_number(3, "lowerLetter"), "c");
        assert_eq!(format_number(12, "ordinal"), "12th");
        assert_eq!(format_number(22, "ordinal"), "22nd");
        assert_eq!(roman(1994), "MCMXCIV");
    }
}
