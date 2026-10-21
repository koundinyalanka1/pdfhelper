//! Draw metafiles as PNGs: `metapng in.wmf out.png [max px]`.

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let bytes = std::fs::read(&args[0]).expect("a metafile");
    let max = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(800);
    let mut book = doc_font::FontBook::new();
    for dir in ["/usr/share/fonts", "/system/fonts", "/System/Library/Fonts", "/Library/Fonts"] {
        book.add_dir(std::path::Path::new(dir));
    }
    let t = std::time::Instant::now();
    match doc_metafile::to_png(&bytes, max, Some(&mut book)) {
        Some(png) => {
            std::fs::write(&args[1], png).unwrap();
            println!("{:?} {:?} in {:?}", doc_metafile::kind(&bytes), doc_metafile::size(&bytes), t.elapsed());
        }
        None => println!("nothing drawn ({:?})", doc_metafile::kind(&bytes)),
    }
}
