//! Presentations: PowerPoint (`.pptx`) and OpenDocument (`.odp`) decks,
//! read into scenes the app draws, edited in place and written back.
//!
//! Each slide becomes a [`scene::Scene`]: its items in drawing order with
//! their outlines as paths (preset shapes and custom geometry resolved),
//! fills, lines, text with the list-style cascade resolved, pictures and
//! tables, all in points. Layout and master content is drawn behind the
//! slide's own. Edits change only the parts they touch.

pub mod color;
pub mod deck;
pub mod error;
pub mod geom;
pub mod pptx;
pub mod scene;
pub mod text;
pub mod theme;

#[cfg(test)]
mod tests;

use std::any::Any;

pub use deck::{Deck, Edit, EditResult, Format, TextPatch};
pub use error::SlideError;

impl deck::Backend for pptx::Pptx {
    fn format(&self) -> Format {
        self.format
    }

    fn size(&self) -> (f32, f32) {
        (self.width, self.height)
    }

    fn slide_count(&self) -> usize {
        self.state.slides.len()
    }

    fn scene(&mut self, i: usize) -> Result<scene::Scene, SlideError> {
        pptx::Pptx::scene(self, i)
    }

    fn notes(&mut self, i: usize) -> Result<String, SlideError> {
        pptx::Pptx::notes(self, i)
    }

    fn layouts(&mut self) -> Vec<(String, String)> {
        pptx::Pptx::layouts(self)
    }

    fn part(&self, name: &str) -> Option<Vec<u8>> {
        self.part_bytes(name)
    }

    fn apply(&mut self, edit: &Edit) -> Result<EditResult, SlideError> {
        pptx::Pptx::apply(self, edit)
    }

    fn snapshot(&self) -> Box<dyn Any + Send> {
        Box::new(self.state.clone())
    }

    fn restore(&mut self, state: Box<dyn Any + Send>) {
        if let Ok(s) = state.downcast::<pptx::State>() {
            self.state = *s;
        }
    }

    fn save(&self) -> Result<Vec<u8>, SlideError> {
        pptx::Pptx::save(self)
    }
}

/// Whether bytes are an Office file protected with a password.
fn is_encrypted_package(bytes: &[u8]) -> bool {
    if !bytes.starts_with(&[0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) {
        return false;
    }
    let needle: Vec<u8> = "EncryptedPackage".encode_utf16().flat_map(|u| u.to_le_bytes()).collect();
    bytes.windows(needle.len()).any(|w| w == needle.as_slice())
}

/// Open a deck from its bytes; `name` (the file name) helps tell formats
/// apart.
pub fn open(bytes: Vec<u8>, name: &str) -> Result<Deck, SlideError> {
    if is_encrypted_package(&bytes) {
        return Err(SlideError::Encrypted);
    }
    if bytes.starts_with(&[0xD0, 0xCF, 0x11, 0xE0]) {
        return Err(SlideError::Unsupported(
            "This is an older PowerPoint file (.ppt). Opening those is coming; for now, open it in another app.".into(),
        ));
    }
    if !bytes.starts_with(b"PK") {
        return Err(SlideError::Corrupt("This file is not a presentation this app can read.".into()));
    }
    let _ = name;
    let d = pptx::Pptx::open(bytes)?;
    Ok(Deck::new(Box::new(d)))
}

/// A new deck with one title slide.
pub fn blank() -> Result<Deck, SlideError> {
    let d = pptx::Pptx::open(pptx::template::bytes())?;
    Ok(Deck::new(Box::new(d)))
}
