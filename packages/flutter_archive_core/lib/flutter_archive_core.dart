/// flutter_archive_core: DocHelper's archive engine, built from scratch in
/// Rust.
///
/// Browses, extracts and creates ZIP files, and browses and extracts `.tar`,
/// `.gz` and `.tar.gz` files. Extraction is safe with archives from
/// anywhere: names cannot reach outside the target folder, links are never
/// written, existing files are never replaced, and zip bombs are refused
/// before anything is written ([ArchiveCore.extractAll]).
library;

export 'src/archive_core_api.dart'
    show
        ArchiveCore,
        ArchiveCoreException,
        ArchiveEntry,
        ArchiveEntryKind,
        ArchiveExtraction,
        ArchiveFormat,
        ArchiveListing,
        ArchiveSkipped,
        ArchiveSource;
