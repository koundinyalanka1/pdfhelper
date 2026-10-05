import 'dart:io';

/// A real PDF with a distinct text layer on each page, or a shape for empty text.
File writeTextPdfFixture(Directory root, List<String> pages) {
  final fontId = 3 + pages.length;
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [${List.generate(pages.length, (i) => '${3 + i} 0 R').join(' ')}] /Count ${pages.length} >>',
    for (var i = 0; i < pages.length; i++)
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] '
          '/Resources << /Font << /F1 $fontId 0 R >> >> '
          '/Contents ${fontId + 1 + i} 0 R >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Courier '
        '/FirstChar 32 /LastChar 126 /Widths [${List.filled(95, '600').join(' ')}] >>',
  ];
  for (final text in pages) {
    final escaped = text
        .replaceAll(r'\', r'\\')
        .replaceAll('(', r'\(')
        .replaceAll(')', r'\)');
    final content = text.isEmpty
        ? '0.8 g 40 240 200 100 re f'
        : 'BT /F1 20 Tf 1 0 0 1 40 310 Tm ($escaped) Tj ET';
    objects.add('<< /Length ${content.length} >>\nstream\n$content\nendstream');
  }
  final output = StringBuffer('%PDF-1.7\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(output.length);
    output.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = output.length;
  output.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final offset in offsets) {
    output.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  output.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n'
    'startxref\n$xref\n%%EOF\n',
  );
  return File('${root.path}/Text.pdf')..writeAsStringSync(output.toString());
}
