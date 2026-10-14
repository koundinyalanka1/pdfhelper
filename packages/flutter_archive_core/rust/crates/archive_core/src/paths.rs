//! Turning the names stored in an archive into safe relative paths.
//!
//! A name in an archive is only a suggestion. A hostile or careless one can
//! be absolute (`/etc/passwd`, `C:\Windows`), climb out of the folder being
//! extracted into (`../../x`, the "zip slip"), use `\` as a separator, or
//! hold characters that memory cards cannot store. [`safe_components`]
//! reduces any name to plain folder and file names that can only land
//! inside the target folder.

/// Longest file or folder name written, in bytes. File systems allow 255;
/// the rest leaves room for a " (99)" suffix.
const MAX_COMPONENT_BYTES: usize = 240;

/// Longest extension kept whole when a long name is shortened.
const MAX_EXTENSION_BYTES: usize = 16;

/// Why a stored name cannot be used at all.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BadName {
    /// The name holds a NUL character, which no file name can.
    Nul,
}

/// The folder and file names to write for `stored`, outermost first.
///
/// `\` counts as a separator; a leading `/` or drive letter, `.` and `..`
/// components and empty components are dropped; characters that FAT memory
/// cards and Windows reject (`<>:"|?*` and control characters) become `_`;
/// trailing dots and spaces are trimmed, and over-long names shortened. An
/// empty result means the name was only the archive's root (`./`, `/`).
pub fn safe_components(stored: &str) -> Result<Vec<String>, BadName> {
    if stored.contains('\0') {
        return Err(BadName::Nul);
    }
    let unified = stored.replace('\\', "/");
    let mut rest = unified.as_str();
    let bytes = rest.as_bytes();
    if bytes.len() >= 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' {
        rest = &rest[2..];
    }
    Ok(rest.split('/').filter(|part| !part.is_empty() && *part != "." && *part != "..").map(clean_component).collect())
}

/// [`safe_components`] joined with `/`, or `None` when nothing usable is left.
pub fn safe_path(stored: &str) -> Option<String> {
    let parts = safe_components(stored).ok()?;
    (!parts.is_empty()).then(|| parts.join("/"))
}

fn clean_component(part: &str) -> String {
    let replaced: String = part
        .chars()
        .map(|c| match c {
            '<' | '>' | ':' | '"' | '|' | '?' | '*' => '_',
            c if c.is_control() => '_',
            c => c,
        })
        .collect();
    let trimmed = replaced.trim_end_matches(['.', ' ']);
    if trimmed.is_empty() {
        return "_".to_owned();
    }
    shorten(trimmed, MAX_COMPONENT_BYTES)
}

/// Split `name` before its extension; a leading dot (`.profile`) does not
/// start one.
fn split_extension(name: &str) -> (&str, &str) {
    match name.rfind('.') {
        Some(dot) if dot > 0 && name.len() - dot <= MAX_EXTENSION_BYTES => name.split_at(dot),
        _ => (name, ""),
    }
}

fn floor_char_boundary(text: &str, max: usize) -> usize {
    let mut end = max.min(text.len());
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    end
}

/// Cut `name` to at most `max` bytes, keeping its extension.
fn shorten(name: &str, max: usize) -> String {
    if name.len() <= max {
        return name.to_owned();
    }
    let (stem, extension) = split_extension(name);
    let keep = floor_char_boundary(stem, max.saturating_sub(extension.len()));
    format!("{}{}", &stem[..keep], extension)
}

/// The `n`th name to try when `name` is taken: `photo (2).jpg`. Folders keep
/// dots as part of their name (`v1.2 (2)`).
pub fn numbered(name: &str, n: usize, is_dir: bool) -> String {
    let (stem, extension) = if is_dir { (name, "") } else { split_extension(name) };
    format!("{stem} ({n}){extension}")
}

/// The last part of a stored name, for showing in a list: `docs/a.txt` is
/// `a.txt`, and the folder `docs/` is `docs`.
pub fn display_name(stored: &str) -> String {
    let unified = stored.replace('\\', "/");
    let trimmed = unified.trim_end_matches('/');
    match trimmed.rsplit('/').next() {
        Some(last) if !last.is_empty() => last.to_owned(),
        _ => stored.to_owned(),
    }
}
