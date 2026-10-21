use std::io::{Read, Write};
use std::path::Path;

use doc_opc::Package;
use doc_zip::ZipArchive;

fn unchanged(before: &ZipArchive, after: &ZipArchive, edited: Option<&str>) -> Result<(), String> {
    for (index, entry) in before.entries().iter().enumerate() {
        if edited == Some(entry.name.as_str()) || before.is_duplicate(index) { continue; }
        let saved = after.find(&entry.name).ok_or_else(|| format!("CONTENT_CHANGED: missing {}", entry.name))?;
        let result = &after.entries()[saved];
        if (entry.crc32, entry.method, entry.size) != (result.crc32, result.method, result.size) || before.raw_data(index) != after.raw_data(saved) {
            return Err(format!("CONTENT_CHANGED: untouched raw ZIP entry {}", entry.name));
        }
    }
    Ok(())
}

fn execute(args: Vec<String>) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let operation = args.get(1).ok_or("operation required: inspect, read, save or edit")?;
    let path = Path::new(args.get(2).ok_or("input file required")?);
    let mut bytes = Vec::new();
    std::fs::File::open(path)?.take((256 << 20) + 1).read_to_end(&mut bytes)?;
    if bytes.len() > 256 << 20 { return Err("TOO_LARGE: input exceeds 256 MiB".into()); }
    let mut package = Package::open(bytes.clone())?;
    match operation.as_str() {
        "inspect" => {
            let names = package.part_names();
            if names.is_empty() { return Err("EMPTY_CORPUS: empty ZIP package".into()); }
            for name in names {
                let hex: String = name.as_bytes().iter().map(|b| format!("{b:02x}")).collect();
                println!("part\t{hex}");
            }
            println!("duplicates\t{}", package.duplicate_parts().len());
        }
        "read" => {
            let name = args.get(3).ok_or("part name required")?;
            if name.ends_with(".xml") || name.ends_with(".rels") {
                let xml = package.read_xml(name)?;
                let _ = xml.root.text();
            } else { let _ = package.read(name)?; }
            println!("ok");
        }
        "save" | "edit" => {
            let output = Path::new(args.get(3).ok_or("new output file required")?);
            if output.exists() || path == output { return Err("INVALID_ARGUMENT: output must be a new file".into()); }
            let edited = if operation == "edit" {
                let part = package.main_part().unwrap_or_else(|_| "content.xml".into());
                let mut xml = package.read_xml(&part)?;
                xml.root.set_attr("dochelper-phase10", doc_xml::ns::NONE, "saved-content");
                package.set_xml(&part, &xml);
                Some(part)
            } else { None };
            let saved = package.save()?;
            let reopened = Package::open(saved.clone())?;
            unchanged(&package.archive, &reopened.archive, edited.as_deref())?;
            if let Some(part) = edited {
                if reopened.read_xml(&part)?.root.attr(doc_xml::ns::NONE, "dochelper-phase10") != Some("saved-content") {
                    return Err("CONTENT_CHANGED: saved XML edit is missing".into());
                }
            } else if saved != bytes {
                return Err("CONTENT_CHANGED: unedited package save is not byte-identical".into());
            }
            let mut file = std::fs::File::create_new(output)?;
            file.write_all(&saved)?;
            file.sync_all()?;
            println!("ok");
        }
        _ => return Err("INVALID_ARGUMENT: unknown operation".into()),
    }
    Ok(())
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let task = std::thread::Builder::new().stack_size(512 * 1024).spawn(move || execute(args));
    match task {
        Ok(task) => match task.join() {
            Ok(Ok(())) => {}
            Ok(Err(error)) => {
                eprintln!("{error}");
                std::process::exit(if error.to_string().contains("not supported") { 83 } else { 2 });
            }
            Err(_) => { eprintln!("PANIC: worker panicked"); std::process::exit(81); }
        }
        Err(error) => { eprintln!("UNSUPPORTED: {error}"); std::process::exit(83); }
    }
}
