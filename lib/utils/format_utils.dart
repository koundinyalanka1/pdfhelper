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
