//! Try flat OpenDocument files.
//!
//! ```text
//! cargo run --example odfcli -- unflatten FILE.fodt OUT.odt
//! cargo run --example odfcli -- flatten FILE.odt OUT.fodt
//! ```

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (Some(cmd), Some(input), Some(out)) = (args.first(), args.get(1), args.get(2)) else {
        eprintln!("commands: unflatten FILE OUT, flatten FILE OUT");
        return;
    };
    let bytes = std::fs::read(input).unwrap_or_else(|e| panic!("{input}: {e}"));
    let started = std::time::Instant::now();
    let result = match cmd.as_str() {
        "unflatten" => {
            println!("mimetype: {:?}", doc_odf::flat_mimetype(&bytes));
            doc_odf::unflatten(&bytes)
        }
        "flatten" => doc_odf::flatten(&bytes),
        _ => {
            eprintln!("commands: unflatten FILE OUT, flatten FILE OUT");
            return;
        }
    };
    let bytes = result.unwrap_or_else(|e| panic!("{input}: {e}"));
    std::fs::write(out, &bytes).unwrap();
    println!("wrote {out} ({} bytes) in {:?}", bytes.len(), started.elapsed());
}
