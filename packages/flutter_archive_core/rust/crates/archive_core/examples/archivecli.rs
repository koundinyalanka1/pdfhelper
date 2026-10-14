//! Try the archive engine on real files.
//!
//! ```text
//! cargo run --release --example archivecli -- list backup.zip
//! cargo run --release --example archivecli -- extract backup.zip 3 out.pdf
//! cargo run --release --example archivecli -- extract-all backup.tar.gz out/
//! cargo run --release --example archivecli -- create new.zip notes.txt Photos/
//! ```

use std::path::Path;
use std::process::ExitCode;

use archive_core::{create_zip, Archive, ArchiveError, CreateOptions, Source};

fn run(args: &[String]) -> Result<(), ArchiveError> {
    let usage = || ArchiveError::Invalid("usage: archivecli list|extract|extract-all|create ...".to_owned());
    match args {
        [command, archive] if command == "list" => {
            let archive = Archive::open(archive)?;
            println!("{} archive, {} entries", archive.format().name(), archive.entries().len());
            if !archive.comment().is_empty() {
                println!("comment: {}", archive.comment());
            }
            for e in archive.entries() {
                println!(
                    "{:>5} {:<8} {:>12} {:>12} {:<9} {:<20} {}{}",
                    e.index,
                    e.kind.name(),
                    e.size,
                    e.compressed_size.map(|c| c.to_string()).unwrap_or_else(|| "-".to_owned()),
                    e.method.name(),
                    e.modified.as_deref().unwrap_or("-"),
                    e.path,
                    if e.encrypted { "  [password]" } else { "" },
                );
            }
        }
        [command, archive, index, out] if command == "extract" => {
            let index = index.parse().map_err(|_| usage())?;
            let written = Archive::open(archive)?.extract(index, Path::new(out))?;
            println!("wrote {written} bytes to {out}");
        }
        [command, archive, out] if command == "extract-all" => {
            let report = Archive::open(archive)?.extract_all(Path::new(out))?;
            for path in &report.written {
                println!("wrote   {}", path.display());
            }
            for skipped in &report.skipped {
                println!("skipped {}: {}", skipped.path, skipped.reason);
            }
        }
        [command, out, sources @ ..] if command == "create" && !sources.is_empty() => {
            let sources: Vec<Source> = sources.iter().map(Source::new).collect();
            let created = create_zip(&sources, Path::new(out), &CreateOptions::default())?;
            println!("wrote {out}: {} files, {} folders, {} bytes", created.files, created.folders, created.bytes);
        }
        _ => return Err(usage()),
    }
    Ok(())
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(&args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("{e}");
            ExitCode::FAILURE
        }
    }
}
