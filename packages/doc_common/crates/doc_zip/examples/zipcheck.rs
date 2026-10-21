//! Developer check: `zipcheck list <zip>` prints each entry with its CRC;
//! `zipcheck write <out.zip> [--zip64] <file>...` stores files under their
//! base names; `zipcheck copy <in.zip> <out.zip>` copies every entry raw.
use doc_zip::{Compression, ZipArchive, ZipWriter};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("list") => {
            let archive = ZipArchive::new(std::fs::read(&args[2]).unwrap()).unwrap();
            for (i, e) in archive.entries().iter().enumerate() {
                let data = archive.read(i).unwrap();
                println!("{}\t{}\t{:08x}\t{}", e.name, data.len(), doc_zip::crc32(&data), e.method);
            }
        }
        Some("write") => {
            let mut zip = ZipWriter::new();
            let mut files = &args[3..];
            if files.first().map(String::as_str) == Some("--zip64") {
                zip.force_zip64();
                files = &files[1..];
            }
            for path in files {
                let name = std::path::Path::new(path).file_name().unwrap().to_string_lossy();
                zip.add(&name, &std::fs::read(path).unwrap(), Compression::DEFAULT).unwrap();
            }
            std::fs::write(&args[2], zip.finish()).unwrap();
        }
        Some("copy") => {
            let archive = ZipArchive::new(std::fs::read(&args[2]).unwrap()).unwrap();
            let mut zip = ZipWriter::new();
            for i in 0..archive.len() {
                zip.copy_from(&archive, i).unwrap();
            }
            std::fs::write(&args[3], zip.finish()).unwrap();
        }
        _ => eprintln!("usage: zipcheck list|write|copy ..."),
    }
}
