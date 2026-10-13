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
    DocKind.slides => true,
    _ => false,
  };

  /// Extensions of kinds DocHelper opens only in some formats (legacy
  /// binaries such as `.xls` arrive later).
  static const Set<String> _openableSheetExtensions = {
    'xlsx', 'xlsm', 'xltx', 'xltm', 'ods', 'ots', 'csv', 'tsv',
  };

  static const Set<String> _openableWordExtensions = {
    'docx', 'docm', 'dotx', 'dotm', 'odt', 'ott', 'rtf',
  };

  static const Set<String> _openableSlideExtensions = {
    'pptx', 'pptm', 'ppsx', 'ppsm', 'potx', 'potm', 'odp', 'otp',
  };

  /// Whether DocHelper can open this particular file.
  static bool canOpenPath(String path) {
    final kind = ofPath(path);
    if (!kind.canOpen) return false;
    return switch (kind) {
      DocKind.sheet => _openableSheetExtensions.contains(extensionOf(path)),
      DocKind.word => _openableWordExtensions.contains(extensionOf(path)),
      DocKind.slides => _openableSlideExtensions.contains(extensionOf(path)),
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
    // Archives.
    'zip': DocKind.archive, '7z': DocKind.archive, 'rar': DocKind.archive,
    'tar': DocKind.archive, 'gz': DocKind.archive,
  };

  /// Text extensions worth listing in the Files tab. Source code and data
  /// files are left out: a phone holds thousands of them inside app folders,
  /// and they would bury the documents.
  static const Set<String> _listedTextExtensions = {'txt', 'md', 'markdown'};

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
  static DocKind? sniff(List<int> head, {String? name}) {
    bool startsWith(List<int> magic) =>
        head.length >= magic.length &&
        List.generate(magic.length, (i) => head[i] == magic[i]).every((b) => b);
    final byName = name == null ? null : ofPath(name);
    if (_containsPdfHeader(head)) return DocKind.pdf;
    if (startsWith([0x50, 0x4B, 0x03, 0x04]) ||
        startsWith([0x50, 0x4B, 0x05, 0x06])) {
      // OOXML, ODF and plain ZIP all start this way.
      return switch (byName) {
        DocKind.word || DocKind.sheet || DocKind.slides => byName,
        _ => DocKind.archive,
      };
    }
    if (startsWith([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])) {
      // OLE2: legacy Word, Excel, PowerPoint and WPS files.
      return switch (byName) {
        DocKind.word || DocKind.sheet || DocKind.slides => byName,
        _ => null,
      };
    }
    if (startsWith('{\\rtf'.codeUnits)) return DocKind.word;
    if (startsWith([0xFF, 0xD8, 0xFF]) ||
        startsWith([0x89, 0x50, 0x4E, 0x47]) ||
        startsWith('GIF8'.codeUnits)) {
      return DocKind.image;
    }
    return null;
  }

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
      'doc': 'application/msword',
      'odt': 'application/vnd.oasis.opendocument.text',
      'rtf': 'application/rtf',
      'xlsx':
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'xls': 'application/vnd.ms-excel',
      'ods': 'application/vnd.oasis.opendocument.spreadsheet',
      'csv': 'text/csv',
      'tsv': 'text/tab-separated-values',
      'pptx':
          'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'ppt': 'application/vnd.ms-powerpoint',
      'odp': 'application/vnd.oasis.opendocument.presentation',
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
      'zip': 'application/zip',
    };
    final extension = extensionOf(path);
    return types[extension] ??
        (ofPath(path) == DocKind.text
            ? 'text/plain'
            : 'application/octet-stream');
  }
}
