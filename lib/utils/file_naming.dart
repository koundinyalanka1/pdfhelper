import 'dart:io';

/// Naming for the files this app writes.
///
/// Every tool used to name its output `<verb>_<epoch millis>.pdf` — never
/// ambiguous, never readable either: a Files tab full of
/// `images_to_pdf_1758...`. Output names now come from the user, so a typed
/// title has to survive a write to disk, Android's MediaStore and a share
/// sheet. That is what the sanitiser below stands between.

/// Characters no mainstream filesystem accepts, plus control codes.
final RegExp _illegalChars = RegExp(r'[<>:"/\\|?*\x00-\x1F]');
final RegExp _collapseSpaces = RegExp(r'\s+');

/// Windows silently drops trailing dots and spaces; Android's MediaStore
/// refuses the name outright.
final RegExp _trailingJunk = RegExp(r'[. ]+$');

/// Longest base name we will write. Comfortably under the 255-byte limit
/// every filesystem in play enforces, leaving room for a ` (2)` suffix and
/// the extension.
const int maxBaseNameLength = 80;

/// Turn user input into something writable, without quietly losing the name.
///
/// Illegal characters become spaces rather than being deleted, so
/// `Invoice 12/05` reads as `Invoice 12 05` instead of `Invoice 1205`.
String sanitizeFileName(String input, {String fallback = 'Document'}) {
  var name = input.replaceAll(_illegalChars, ' ');
  name = name.replaceAll(_collapseSpaces, ' ').trim();
  name = name.replaceAll(_trailingJunk, '');
  // A leading dot hides the file on every Unix-derived platform — including
  // from the Files tab's own sweep, which skips dot-files.
  while (name.startsWith('.')) {
    name = name.substring(1).trim();
  }
  if (name.length > maxBaseNameLength) {
    name = name.substring(0, maxBaseNameLength).replaceAll(_trailingJunk, '');
  }
  return name.isEmpty ? fallback : name;
}

/// The name without its `.pdf` extension, for pre-filling a rename field.
String stripPdfExtension(String fileName) {
  if (fileName.toLowerCase().endsWith('.pdf')) {
    return fileName.substring(0, fileName.length - 4);
  }
  return fileName;
}

String withPdfExtension(String baseName) =>
    baseName.toLowerCase().endsWith('.pdf') ? baseName : '$baseName.pdf';

/// `<directory>/<fileName>`, with ` (2)`, ` (3)`… appended until it is free.
///
/// Named files collide in a way timestamped ones never did — saving "Invoice"
/// twice is a completely ordinary thing to do, and must not overwrite the
/// first one.
Future<String> uniqueFilePath(String directory, String fileName) async {
  final dot = fileName.lastIndexOf('.');
  final base = dot > 0 ? fileName.substring(0, dot) : fileName;
  final ext = dot > 0 ? fileName.substring(dot) : '';

  var candidate = '$directory/$fileName';
  for (var counter = 2; counter <= 999; counter++) {
    if (!await File(candidate).exists()) return candidate;
    candidate = '$directory/$base ($counter)$ext';
  }
  // A thousand files of the same name is not a real case; fall back to the
  // scheme that cannot collide rather than looping forever.
  return '$directory/$base ${DateTime.now().millisecondsSinceEpoch}$ext';
}

/// The title offered when the user has not typed one — the verb plus a
/// sortable, filename-safe timestamp: `Scan 2026-09-19 14.32`.
String defaultPdfName(String label, {DateTime? now}) {
  final t = now ?? DateTime.now();
  String two(int value) => value.toString().padLeft(2, '0');
  return '$label ${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}.${two(t.minute)}';
}
