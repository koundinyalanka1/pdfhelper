//! Try the engine on real decks.
//!
//! ```text
//! cargo run --example slidecli -- dump FILE
//! cargo run --example slidecli -- demo FILE OUT
//! ```

use slide_core::scene::{Fill, Item};
use slide_core::{Edit, TextPatch};

fn describe(it: &Item) -> String {
    let fill = match &it.fill {
        Fill::None => "none".to_owned(),
        Fill::Solid(c) => format!("#{c:08X}"),
        Fill::Gradient { stops, .. } => format!("gradient {} stops", stops.len()),
        Fill::Image { part } => format!("image {part}"),
    };
    let text = it.text.as_ref().map(|t| {
        let first = t.paras.iter().flat_map(|p| p.runs.first()).next();
        format!(
            " text={:?}{} {}",
            t.text(),
            first.map(|r| format!(" ({}pt {} {} b={})", r.size, r.font, format_args!("#{:08X}", r.color), r.bold)).unwrap_or_default(),
            t.paras.iter().filter_map(|p| p.bullet.as_ref()).map(|b| b.text.clone()).collect::<Vec<_>>().join(",")
        )
    });
    format!(
        "#{} {:?} {:?} [{:.0},{:.0} {:.0}x{:.0}] fill={} line={} paths={}{}{}{}",
        it.id,
        it.kind,
        it.name,
        it.x,
        it.y,
        it.w,
        it.h,
        fill,
        it.line.as_ref().map_or("none".into(), |l| format!("{:.1}pt #{:08X}", l.width, l.color)),
        it.paths.len(),
        it.placeholder.as_ref().map(|p| format!(" ph={p}")).unwrap_or_default(),
        text.unwrap_or_default(),
        it.image.as_ref().map(|(p, _)| format!(" image={p}")).unwrap_or_default(),
    )
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let path = args.get(1).expect("a file");
    if args[0] == "blank" {
        let mut d = slide_core::blank().unwrap();
        std::fs::write(path, d.save().unwrap()).unwrap();
        return;
    }
    let mut d = slide_core::open(std::fs::read(path).unwrap(), path).expect("opens");
    match args[0].as_str() {
        "dump" => {
            println!("{} slides, {:?} points; layouts {:?}", d.slide_count(), d.size(), d.layouts().iter().map(|l| &l.1).collect::<Vec<_>>());
            for i in 0..d.slide_count() {
                let s = d.scene(i).unwrap();
                println!("slide {} hidden={} bg={:?}", i + 1, s.hidden, s.background);
                for it in &s.items {
                    println!("  {}", describe(it));
                    if let Some(t) = &it.table {
                        for r in &t.rows {
                            println!("    row {:?}", r.cells.iter().map(|c| c.text.text()).collect::<Vec<_>>());
                        }
                    }
                }
                let n = d.notes(i).unwrap();
                if !n.is_empty() {
                    println!("  notes: {n:?}");
                }
            }
        }
        "demo" => {
            let out = args.get(2).expect("an output file");
            let s = d.scene(0).unwrap();
            let title = s.items.iter().find(|i| i.editable && i.text.is_some()).map(|i| i.id).unwrap();
            let mut text = s.items.iter().find(|i| i.id == title).unwrap().text.as_ref().unwrap().text();
            text.push_str(" (edited)");
            d.apply(&Edit::SetText { slide: 0, shape: title, cell: None, paras: vec![text] }).unwrap();
            d.apply(&Edit::FormatText {
                slide: 0,
                shape: title,
                cell: None,
                patch: TextPatch { color: Some(0xC00000), ..TextPatch::default() },
            })
            .unwrap();
            d.apply(&Edit::AddSlide { after: Some(0), layout: None }).unwrap();
            d.apply(&Edit::AddTextBox { slide: 1, x: 72.0, y: 200.0, w: 400.0, h: 50.0, text: "Added by DocHelper".into() }).unwrap();
            d.apply(&Edit::AddShape { slide: 1, preset: "ellipse".into(), x: 500.0, y: 300.0, w: 100.0, h: 100.0 }).unwrap();
            d.apply(&Edit::SetNotes { slide: 0, text: "First slide notes".into() }).unwrap();
            d.apply(&Edit::DuplicateSlide { slide: 0 }).unwrap();
            d.apply(&Edit::HideSlide { slide: 2, hidden: true }).unwrap();
            let last = d.slide_count() - 1;
            d.apply(&Edit::MoveSlide { from: last, to: 1 }).unwrap();
            std::fs::write(out, d.save().unwrap()).unwrap();
            println!("saved {} slides", d.slide_count());
        }
        _ => eprintln!("commands: dump, demo"),
    }
}
