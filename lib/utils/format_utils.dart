import '../models/doc_kind.dart';

String formatFileSize(int? bytes) {
  if (bytes == null || bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  int i = 0;
  double size = bytes.toDouble();
  while (size >= 1024 && i < units.length - 1) {
    size /= 1024;
    i++;
  }
  return '${size.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
}

/// A whole number with thousands separators: 12480 → "12,480".
String formatCount(int value) {
  final digits = value.abs().toString();
  final grouped = digits.replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );
  return value < 0 ? '-$grouped' : grouped;
}

/// The name to show for a document, without the `intent_<n>_` prefix that
/// copies handed over by "Open with" carry. Falls back to a description of
/// the kind when the provider gave no name.
String documentDisplayName(String path) {
  final name = path.split(RegExp(r'[/\\]')).last;
  final stripped = name.replaceFirst(RegExp(r'^intent_\d+_'), '');
  final kind = DocKind.ofPath(name);
  final fallback = switch (kind) {
    DocKind.pdf => 'View PDF',
    DocKind.other => 'Document',
    _ => '${kind.label} file',
  };
  if (stripped.isEmpty) return fallback;
  if (stripped == name && name.startsWith('intent_')) return fallback;
  if (RegExp(r'^opened\.[a-z0-9]+$').hasMatch(stripped)) return fallback;
  return stripped;
}

/// Gets a display title for a PDF path. Strips intent temp file prefix (intent_TIMESTAMP_)
/// and falls back to 'View PDF' if the name looks like a temp file.
String getPdfDisplayTitle(String path) {
  final name = path.split(RegExp(r'[/\\]')).last;
  final stripped = name.replaceFirst(RegExp(r'^intent_\d+_'), '');
  if (stripped.isEmpty) return 'View PDF';
  if (stripped == name && name.startsWith('intent_')) return 'View PDF';
  if (stripped == 'opened.pdf') return 'View PDF';
  return stripped;
}

const List<String> _monthAbbreviations = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// Date label for the Files library.
///
/// Short form drops the year for dates in [now]'s year, the way a file
/// listing does — "Sep 12" this year, "Mar 2024" for anything older. [now] is
/// injectable so the rollover is testable rather than dependent on the clock.
String formatLibraryDate(DateTime date, {bool long = false, DateTime? now}) {
  final month = _monthAbbreviations[date.month - 1];
  if (long) {
    final hour = date.hour.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');
    return '$month ${date.day}, ${date.year} at $hour:$minute';
  }
  final reference = now ?? DateTime.now();
  if (date.year == reference.year) return '$month ${date.day}';
  return '$month ${date.year}';
}
