import 'package:flutter/material.dart';

/// The kinds of file DocHelper knows about, each served by its own engine
/// library (see PLAN.md).
///
/// A file's kind comes from its extension. For files arriving through "Open
/// with", [DocKind.sniff] checks the content too, because providers often
/// hand over names without one.
enum DocKind {
  pdf,
  word,
  sheet,
  slides,
  text,
  image,
  archive,
  other;

  /// What to call one file of this kind.
  String get label => switch (this) {
    DocKind.pdf => 'PDF',
    DocKind.word => 'Word',
    DocKind.sheet => 'Excel',
    DocKind.slides => 'PowerPoint',
    DocKind.text => 'Text',
    DocKind.image => 'Image',
    DocKind.archive => 'Archive',
    DocKind.other => 'File',
  };

  /// What to call several, for filters and empty states.
  String get pluralLabel => switch (this) {
    DocKind.pdf => 'PDFs',
    DocKind.word => 'documents',
    DocKind.sheet => 'spreadsheets',
    DocKind.slides => 'presentations',
    DocKind.text => 'text files',
    DocKind.image => 'images',
    DocKind.archive => 'archives',
    DocKind.other => 'files',
  };

  IconData get icon => switch (this) {
    DocKind.pdf => Icons.picture_as_pdf_rounded,
    DocKind.word => Icons.description_rounded,
    DocKind.sheet => Icons.table_chart_rounded,
    DocKind.slides => Icons.slideshow_rounded,
    DocKind.text => Icons.notes_rounded,
    DocKind.image => Icons.image_rounded,
    DocKind.archive => Icons.folder_zip_rounded,
    DocKind.other => Icons.insert_drive_file_rounded,
  };

  /// The colour people associate with the kind (Word blue, Excel green...).
  Color get color => switch (this) {
    DocKind.pdf => const Color(0xFFE94560),
    DocKind.word => const Color(0xFF2B79D8),
    DocKind.sheet => const Color(0xFF21A366),
    DocKind.slides => const Color(0xFFE8622A),
    DocKind.text => const Color(0xFF78909C),
    DocKind.image => const Color(0xFF9C6ADE),
    DocKind.archive => const Color(0xFFB58A5A),
    DocKind.other => const Color(0xFF90A4AE),
  };

  /// Whether DocHelper has a screen for this kind yet. Kinds without one are
  /// still listed, and offer "Open with another app".
  bool get canOpen => switch (this) {
    DocKind.pdf ||
    DocKind.text ||
    DocKind.sheet ||
    DocKind.word ||
    DocKind.slides ||
    DocKind.image ||
    DocKind.archive => true,
    DocKind.other => false,
  };

  /// Extensions of kinds DocHelper opens only in some formats.
  static const Set<String> _openableSheetExtensions = {
    'xlsx', 'xlsm', 'xltx', 'xltm', 'ods', 'ots', 'fods', 'csv', 'tsv', 'xls',
    'xlt', 'et', 'ett',
  };

  static const Set<String> _openableWordExtensions = {
    'docx', 'docm', 'dotx', 'dotm', 'odt', 'ott', 'fodt', 'rtf', 'doc', 'dot',
    'wps', 'wpt',
  };

  static const Set<String> _openableSlideExtensions = {
    'pptx', 'pptm', 'ppsx', 'ppsm', 'potx', 'potm', 'odp', 'otp', 'fodp', 'ppt',
    'pps', 'pot', 'dps', 'dpt',
  };

  static const Set<String> _openableImageExtensions = {
    'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp', 'heic', 'heif',
  };

  /// 7-Zip and RAR are archives DocHelper cannot unpack: those offer
  /// another app.
  static const Set<String> _openableArchiveExtensions = {
    'zip', 'tar', 'gz', 'tgz',
  };

  /// Whether DocHelper can open this particular file.
  static bool canOpenPath(String path) {
    final kind = ofPath(path);
    if (!kind.canOpen) return false;
    final extension = extensionOf(path);
    return switch (kind) {
      DocKind.sheet => _openableSheetExtensions.contains(extension),
      DocKind.word => _openableWordExtensions.contains(extension),
      DocKind.slides => _openableSlideExtensions.contains(extension),
      DocKind.image => _openableImageExtensions.contains(extension),
      DocKind.archive => _openableArchiveExtensions.contains(extension),
      _ => true,
    };
  }

  /// The kinds the Files tab can filter by, in chip order.
  static const List<DocKind> filterable = [
    DocKind.pdf,
    DocKind.word,
    DocKind.sheet,
    DocKind.slides,
    DocKind.text,
    DocKind.archive,
  ];

  static const Map<String, DocKind> _byExtension = {
    'pdf': DocKind.pdf,
    // Word processing: Microsoft, LibreOffice/OpenDocument, RTF, WPS Writer.
    'docx': DocKind.word, 'docm': DocKind.word, 'dotx': DocKind.word,
    'dotm': DocKind.word, 'doc': DocKind.word, 'dot': DocKind.word,
    'odt': DocKind.word, 'ott': DocKind.word, 'fodt': DocKind.word,
    'rtf': DocKind.word, 'wps': DocKind.word, 'wpt': DocKind.word,
    // Spreadsheets: Excel, OpenDocument, CSV, WPS Spreadsheets.
    'xlsx': DocKind.sheet, 'xlsm': DocKind.sheet, 'xltx': DocKind.sheet,
    'xltm': DocKind.sheet, 'xls': DocKind.sheet, 'xlt': DocKind.sheet,
    'ods': DocKind.sheet, 'ots': DocKind.sheet, 'fods': DocKind.sheet,
    'csv': DocKind.sheet, 'tsv': DocKind.sheet, 'et': DocKind.sheet,
    'ett': DocKind.sheet,
    // Presentations: PowerPoint, OpenDocument, WPS Presentation.
    'pptx': DocKind.slides, 'pptm': DocKind.slides, 'ppsx': DocKind.slides,
    'ppsm': DocKind.slides, 'potx': DocKind.slides, 'potm': DocKind.slides,
    'ppt': DocKind.slides, 'pps': DocKind.slides, 'pot': DocKind.slides,
    'odp': DocKind.slides, 'otp': DocKind.slides, 'fodp': DocKind.slides,
    'dps': DocKind.slides, 'dpt': DocKind.slides,
    // Plain text, markup, data and source code.
    'txt': DocKind.text, 'text': DocKind.text, 'log': DocKind.text,
    'md': DocKind.text, 'markdown': DocKind.text, 'json': DocKind.text,
    'xml': DocKind.text, 'html': DocKind.text, 'htm': DocKind.text,
    'css': DocKind.text, 'js': DocKind.text, 'ts': DocKind.text,
    'ini': DocKind.text, 'cfg': DocKind.text, 'conf': DocKind.text,
    'yaml': DocKind.text, 'yml': DocKind.text, 'toml': DocKind.text,
    'properties': DocKind.text, 'srt': DocKind.text, 'vtt': DocKind.text,
    'sh': DocKind.text, 'bat': DocKind.text, 'py': DocKind.text,
    'dart': DocKind.text, 'java': DocKind.text, 'kt': DocKind.text,
    'c': DocKind.text, 'h': DocKind.text, 'cpp': DocKind.text,
    'cs': DocKind.text, 'go': DocKind.text, 'rs': DocKind.text,
    'swift': DocKind.text, 'sql': DocKind.text, 'tex': DocKind.text,
    'nfo': DocKind.text, 'vcf': DocKind.text, 'ics': DocKind.text,
    // Images.
    'jpg': DocKind.image, 'jpeg': DocKind.image, 'png': DocKind.image,
    'webp': DocKind.image, 'gif': DocKind.image, 'bmp': DocKind.image,
    'heic': DocKind.image, 'heif': DocKind.image,
    // Archives. A name ending `.tar.gz` has the extension `gz`.
    'zip': DocKind.archive, '7z': DocKind.archive, 'rar': DocKind.archive,
    'tar': DocKind.archive, 'gz': DocKind.archive, 'tgz': DocKind.archive,
  };

  /// Text extensions worth listing in the Files tab. Source code and data
  /// files are left out: a phone holds thousands of them inside app folders,
  /// and they would bury the documents.
  static const Set<String> _listedTextExtensions = {'txt', 'md', 'markdown'};

  /// Archives worth listing: ZIP files, which people send and receive.
  /// TAR and gzip files are mostly backups and app data, and photos are left
  /// out because a phone holds thousands.
  static const Set<String> _listedArchiveExtensions = {'zip'};

  /// The lower-case extension of [path] without the dot, or `''`.
  static String extensionOf(String path) {
    final name = path.split(RegExp(r'[/\\]')).last;
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }

  /// The kind a file name or path suggests.
  static DocKind ofPath(String path) =>
      _byExtension[extensionOf(path)] ?? DocKind.other;

  /// Whether the Files tab should list a file with this name.
  static bool isListed(String name) {
    final extension = extensionOf(name);
    final kind = _byExtension[extension];
    if (kind == null) return false;
    return switch (kind) {
      DocKind.pdf || DocKind.word || DocKind.sheet || DocKind.slides => true,
      DocKind.text => _listedTextExtensions.contains(extension),
      DocKind.archive => _listedArchiveExtensions.contains(extension),
      _ => false,
    };
  }

  /// Extensions the import picker offers: everything DocHelper lists.
  static List<String> get importExtensions => [
    for (final entry in _byExtension.entries)
      if (isListed('x.${entry.key}')) entry.key,
  ];

  /// The name without its extension, when the extension names a known kind.
  static String titleOf(String name) {
    final extension = extensionOf(name);
    if (extension.isEmpty || !_byExtension.containsKey(extension)) return name;
    return name.substring(0, name.length - extension.length - 1);
  }

  /// The kind the first bytes of a file reveal, or null when they do not
  /// settle it. ZIP and OLE2 containers hold several kinds, so the extension
  /// decides between those.
  ///
  /// A kilobyte settles most files. Flat OpenDocument files need more:
  /// office suites write the root's mimetype after its namespace
  /// declarations, about 2 KB in, and a head that stops before it falls back
  /// on the name.
  static DocKind? sniff(List<int> head, {String? name}) {
    bool startsWith(List<int> magic) => _at(head, 0, magic);
    final byName = name == null ? null : ofPath(name);
    // A TAR file's first entry may itself be a PDF, inside the kilobyte
    // the PDF header is looked for in.
    if (startsWith(const [0x1F, 0x8B]) || _at(head, 257, 'ustar'.codeUnits)) {
      return DocKind.archive;
    }
    if (_containsPdfHeader(head)) return DocKind.pdf;
    if (startsWith(const [0x50, 0x4B, 0x03, 0x04]) ||
        startsWith(const [0x50, 0x4B, 0x05, 0x06])) {
      // OOXML, ODF and plain ZIP all start this way.
      return switch (byName) {
        DocKind.word || DocKind.sheet || DocKind.slides => byName,
        _ => DocKind.archive,
      };
    }
    if (startsWith(const [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])) {
      // OLE2: legacy Word, Excel, PowerPoint and WPS files.
      return switch (byName) {
        DocKind.word || DocKind.sheet || DocKind.slides => byName,
        _ => null,
      };
    }
    if (startsWith('{\\rtf'.codeUnits)) return DocKind.word;
    if (startsWith(const [0xFF, 0xD8, 0xFF]) ||
        startsWith(const [0x89, 0x50, 0x4E, 0x47]) ||
        startsWith('GIF8'.codeUnits) ||
        (startsWith('RIFF'.codeUnits) && _at(head, 8, 'WEBP'.codeUnits)) ||
        _looksLikeBmp(head)) {
      return DocKind.image;
    }
    return _sniffFlatOpenDocument(head, byName);
  }

  /// Whether [head] holds [magic] at [offset].
  static bool _at(List<int> head, int offset, List<int> magic) {
    if (head.length < offset + magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (head[offset + i] != magic[i]) return false;
    }
    return true;
  }

  /// A BMP starts `BM`, but so does plenty of text: its header must also
  /// give a known size for the bitmap header that follows, with the pixels
  /// after both.
  static bool _looksLikeBmp(List<int> head) {
    if (head.length < 18 || !_at(head, 0, 'BM'.codeUnits)) return false;
    int u32(int at) =>
        head[at] | head[at + 1] << 8 | head[at + 2] << 16 | head[at + 3] << 24;
    final infoSize = u32(14);
    return const {12, 16, 40, 52, 56, 64, 108, 124}.contains(infoSize) &&
        u32(10) >= 14 + infoSize;
  }

  /// How far into a head a flat OpenDocument file's root is looked for.
  static const int _flatHead = 64 * 1024;

  /// The kind a flat OpenDocument file (`.fodt`, `.fods`, `.fodp`: one XML
  /// file) names in its root, `<office:document ...
  /// office:mimetype="application/vnd.oasis.opendocument.text">`. Other XML
  /// (SVG, XHTML, a package's own parts) is null, as is a root whose
  /// mimetype is not a document DocHelper opens. When the head stops before
  /// the root's start tag ends, a flat root is taken for the kind its name
  /// says.
  static DocKind? _sniffFlatOpenDocument(List<int> head, DocKind? byName) {
    final limit = head.length < _flatHead ? head.length : _flatHead;
    bool isSpace(int c) => c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;
    // Past the end of [close] after [from], or -1.
    int skipPast(int from, List<int> close) {
      for (var i = from; i + close.length <= limit; i++) {
        if (_at(head, i, close)) return i + close.length;
      }
      return -1;
    }

    // The prolog: whitespace, the XML declaration and comments.
    var i = _at(head, 0, const [0xEF, 0xBB, 0xBF]) ? 3 : 0;
    while (i >= 0) {
      while (i < limit && isSpace(head[i])) {
        i++;
      }
      if (_at(head, i, '<?'.codeUnits)) {
        i = skipPast(i + 2, '?>'.codeUnits);
      } else if (_at(head, i, '<!--'.codeUnits)) {
        i = skipPast(i + 4, '-->'.codeUnits);
      } else {
        break;
      }
    }
    const root = '<office:document';
    if (i < 0 || !_at(head, i, root.codeUnits)) return null;
    final fromName = switch (byName) {
      DocKind.word || DocKind.sheet || DocKind.slides => byName,
      _ => null,
    };
    const quotes = [0x22, 0x27]; // " and '
    const tagEnd = 0x3E; // >
    const emptyTagEnd = 0x2F; // /
    // `<office:document-content` and the like are parts of a package.
    final attributes = i + root.length;
    if (attributes >= limit) return fromName;
    final next = head[attributes];
    if (!isSpace(next) && next != tagEnd && next != emptyTagEnd) return null;
    // The start tag ends at the first `>` outside an attribute's quotes.
    var end = -1;
    int? quote;
    for (var j = attributes; j < limit; j++) {
      final c = head[j];
      if (quote != null) {
        if (c == quote) quote = null;
      } else if (quotes.contains(c)) {
        quote = c;
      } else if (c == tagEnd) {
        end = j;
        break;
      }
    }
    final tag = String.fromCharCodes(head, attributes, end < 0 ? limit : end);
    final mimetype = _flatMimetype.firstMatch(tag);
    if (mimetype == null) return end < 0 ? fromName : null;
    // Templates (`text-template`) are read as their documents.
    return switch (mimetype[1]) {
      'text' => DocKind.word,
      'spreadsheet' => DocKind.sheet,
      _ => DocKind.slides,
    };
  }

  static final RegExp _flatMimetype = RegExp(
    r'''\soffice:mimetype\s*=\s*["']\s*application/vnd\.oasis\.opendocument\.(text|spreadsheet|presentation)''',
  );

  static bool _containsPdfHeader(List<int> head) {
    // The header may follow up to 1 KB of junk, as viewers allow.
    const magic = [0x25, 0x50, 0x44, 0x46, 0x2D]; // %PDF-
    final limit = head.length < 1024 ? head.length : 1024;
    for (var i = 0; i + magic.length <= limit; i++) {
      var match = true;
      for (var j = 0; j < magic.length; j++) {
        if (head[i + j] != magic[j]) {
          match = false;
          break;
        }
      }
      if (match) return true;
    }
    return false;
  }

  /// The MIME type to share a file of this name with.
  static String mimeTypeOf(String path) {
    const types = {
      'pdf': 'application/pdf',
      'docx':
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'docm': 'application/vnd.ms-word.document.macroEnabled.12',
      'dotx':
          'application/vnd.openxmlformats-officedocument.wordprocessingml.template',
      'dotm': 'application/vnd.ms-word.template.macroEnabled.12',
      'doc': 'application/msword',
      'dot': 'application/msword',
      'odt': 'application/vnd.oasis.opendocument.text',
      'ott': 'application/vnd.oasis.opendocument.text-template',
      'fodt': 'application/vnd.oasis.opendocument.text-flat-xml',
      'rtf': 'application/rtf',
      'xlsx':
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'xlsm': 'application/vnd.ms-excel.sheet.macroEnabled.12',
      'xltx':
          'application/vnd.openxmlformats-officedocument.spreadsheetml.template',
      'xltm': 'application/vnd.ms-excel.template.macroEnabled.12',
      'xls': 'application/vnd.ms-excel',
      'xlt': 'application/vnd.ms-excel',
      'ods': 'application/vnd.oasis.opendocument.spreadsheet',
      'ots': 'application/vnd.oasis.opendocument.spreadsheet-template',
      'fods': 'application/vnd.oasis.opendocument.spreadsheet-flat-xml',
      'csv': 'text/csv',
      'tsv': 'text/tab-separated-values',
      'pptx':
          'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'pptm': 'application/vnd.ms-powerpoint.presentation.macroEnabled.12',
      'ppsx':
          'application/vnd.openxmlformats-officedocument.presentationml.slideshow',
      'ppsm': 'application/vnd.ms-powerpoint.slideshow.macroEnabled.12',
      'potx':
          'application/vnd.openxmlformats-officedocument.presentationml.template',
      'potm': 'application/vnd.ms-powerpoint.template.macroEnabled.12',
      'ppt': 'application/vnd.ms-powerpoint',
      'pps': 'application/vnd.ms-powerpoint',
      'pot': 'application/vnd.ms-powerpoint',
      'odp': 'application/vnd.oasis.opendocument.presentation',
      'otp': 'application/vnd.oasis.opendocument.presentation-template',
      'fodp': 'application/vnd.oasis.opendocument.presentation-flat-xml',
      'txt': 'text/plain',
      'md': 'text/markdown',
      'json': 'application/json',
      'xml': 'text/xml',
      'html': 'text/html',
      'htm': 'text/html',
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'png': 'image/png',
      'webp': 'image/webp',
      'gif': 'image/gif',
      'bmp': 'image/bmp',
      'heic': 'image/heic',
      'heif': 'image/heif',
      'zip': 'application/zip',
      'tar': 'application/x-tar',
      'gz': 'application/gzip',
      'tgz': 'application/gzip',
      '7z': 'application/x-7z-compressed',
      'rar': 'application/vnd.rar',
    };
    final extension = extensionOf(path);
    return types[extension] ??
        (ofPath(path) == DocKind.text
            ? 'text/plain'
            : 'application/octet-stream');
  }
}
