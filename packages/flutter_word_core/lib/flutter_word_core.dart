/// flutter_word_core: DocHelper's word-processing engine, built from scratch
/// in Rust.
///
/// The engine reads Word documents (DOCX, DOCM, DOTX) and OpenDocument
/// text (ODT, OTT), shows their paragraphs as styled text, tables and
/// objects, and writes edits back into the original file, keeping
/// everything it does not show. RTF, plain text and Markdown are imported
/// and saved as Word documents.
library;

export 'src/word_core_api.dart';
