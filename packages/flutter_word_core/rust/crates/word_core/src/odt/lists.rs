//! OpenDocument lists: `text:list` containers around paragraphs. Labels
//! are counted through the body; putting a paragraph in or out of a list
//! changes the tree.

use std::collections::HashMap;

use doc_xml::{ns, Element};

use super::styles::{ListStyle, OdfStyles};
use crate::docx::numbering::{format_number, roman};
use crate::tree::{BoxKind, BoxNode, Node};
use crate::view::{ListLabel, RunStyle};

/// An ODF number format as text.
fn format(n: i64, f: &str) -> String {
    match f {
        "" => String::new(),
        "a" => format_number(n, "lowerLetter"),
        "A" => format_number(n, "upperLetter"),
        "i" => roman(n).to_lowercase(),
        "I" => roman(n),
        _ => n.to_string(),
    }
}

struct Instance {
    style: String,
    counts: [i64; 10],
    started: [bool; 10],
}

/// Counts list items through the body.
pub struct Labeler<'a> {
    styles: &'a OdfStyles,
    instances: Vec<Instance>,
    /// `xml:id` of lists, for `text:continue-list`.
    by_id: HashMap<String, usize>,
    pub out: HashMap<u32, ListLabel>,
    base: &'a dyn Fn(&Element) -> RunStyle,
}

impl<'a> Labeler<'a> {
    pub fn new(styles: &'a OdfStyles, base: &'a dyn Fn(&Element) -> RunStyle) -> Labeler<'a> {
        Labeler {
            styles,
            instances: Vec::new(),
            by_id: HashMap::new(),
            out: HashMap::new(),
            base,
        }
    }

    pub fn walk(&mut self, items: &[Node]) {
        for n in items {
            if let Node::Box(b) = n {
                if b.kind == BoxKind::List {
                    self.list(b, None, 0);
                } else {
                    self.walk(&b.items);
                }
            }
        }
    }

    fn list(&mut self, list: &BoxNode, outer: Option<usize>, depth: usize) {
        let named = list.head.attr(ns::TEXT, "style-name").map(str::to_owned);
        let inst = match outer {
            Some(i) => i,
            None => {
                let continues = list.head.attr(ns::TEXT, "continue-numbering") == Some("true");
                let cont_id = list.head.attr(ns::TEXT, "continue-list");
                let style = named.clone().unwrap_or_default();
                let found = match cont_id {
                    Some(id) => self.by_id.get(id).copied(),
                    None if continues => self.instances.iter().rposition(|i| i.style == style),
                    None => None,
                };
                match found {
                    Some(i) => i,
                    None => {
                        self.instances.push(Instance {
                            style,
                            counts: [0; 10],
                            started: [false; 10],
                        });
                        self.instances.len() - 1
                    }
                }
            }
        };
        if let Some(id) = list.head.attr(ns::XML, "id") {
            self.by_id.insert(id.to_owned(), inst);
        }
        let style_name = self.instances[inst].style.clone();
        let list_style = self.styles.lists.get(&style_name).cloned().unwrap_or_else(|| ListStyle {
            levels: vec![
                super::styles::ListLevel {
                    bullet: true,
                    bullet_char: "\u{2022}".into(),
                    ..Default::default()
                };
                10
            ],
        });
        let level = depth.min(9);
        for item in &list.items {
            let Node::Box(item) = item else { continue };
            if item.kind != BoxKind::ListItem {
                continue;
            }
            let header = item.head.local() == "list-header";
            if !header {
                let st = &mut self.instances[inst];
                let lvl = &list_style.levels[level];
                if let Some(v) = item.head.attr(ns::TEXT, "start-value").and_then(|v| v.parse::<i64>().ok()) {
                    st.counts[level] = v;
                    st.started[level] = true;
                } else if st.started[level] {
                    st.counts[level] += 1;
                } else {
                    st.counts[level] = lvl.start;
                    st.started[level] = true;
                }
                for d in level + 1..10 {
                    st.started[d] = false;
                }
            }
            let mut first = !header;
            for child in &item.items {
                match child {
                    Node::Para(p) if first => {
                        first = false;
                        let st = &self.instances[inst];
                        let lvl = &list_style.levels[level];
                        let text = if lvl.bullet {
                            super::super::docx::numbering::map_symbol(lvl.bullet_char.chars().next().unwrap_or('\u{2022}')).to_string()
                        } else {
                            let shown = (lvl.display_levels.max(1) as usize).min(level + 1);
                            let parts: Vec<String> = (level + 1 - shown..=level)
                                .map(|l| format(st.counts[l].max(1), &list_style.levels[l].format))
                                .collect();
                            format!("{}{}{}", lvl.prefix, parts.join("."), lvl.suffix)
                        };
                        let mut style = (self.base)(&p.el);
                        style.underline = "none".into();
                        self.out.insert(
                            p.id,
                            ListLabel {
                                level: level as u8,
                                bullet: lvl.bullet,
                                text,
                                style,
                            },
                        );
                    }
                    Node::Box(b) if b.kind == BoxKind::List => self.list(b, Some(inst), depth + 1),
                    Node::Box(b) => self.walk(&b.items),
                    _ => {}
                }
            }
        }
    }
}
