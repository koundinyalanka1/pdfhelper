import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Small, valid PDFs authored independently of the engine under test.
///
/// Sparse xref subsections are intentional: the last fixture uses object
/// 1,000,000 but contains only four objects. Each stream length and xref offset
/// is computed from encoded bytes, so parser recovery is never needed.
({File dashed, File layered, File sparse}) writePdfFidelityFixtures(
  Directory root,
) {
  File page(
    String name,
    String content, {
    bool layer = false,
    bool sparse = false,
  }) {
    final streamId = sparse ? 1000000 : 4;
    final objects = <int, String>{
      1:
          '<< /Type /Catalog /Pages 2 0 R '
          '${layer ? '/OCProperties << /OCGs [5 0 R] /D << /OFF [5 0 R] >> >>' : ''} >>',
      2: '<< /Type /Pages /Count 1 /Kids [3 0 R] >>',
      3:
          '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 120 80] '
          '/Contents $streamId 0 R /Resources '
          '${layer ? '<< /Properties << /Hidden 5 0 R >> >>' : '<<>>'} >>',
      streamId:
          '<< /Length ${ascii.encode(content).length} >>\n'
          'stream\n$content\nendstream',
      if (layer) 5: '<< /Type /OCG /Name (Hidden) >>',
    };
    final bytes = BytesBuilder(copy: false);
    void write(String value) => bytes.add(ascii.encode(value));
    write('%PDF-1.7\n');
    final offsets = <int, int>{};
    final ids = objects.keys.toList()..sort();
    for (final id in ids) {
      offsets[id] = bytes.length;
      write('$id 0 obj\n${objects[id]}\nendobj\n');
    }
    final xref = bytes.length;
    write('xref\n0 1\n0000000000 65535 f \n');
    for (final id in ids) {
      write('$id 1\n${offsets[id].toString().padLeft(10, '0')} 00000 n \n');
    }
    write(
      'trailer\n<< /Size ${ids.last + 1} /Root 1 0 R >>\n'
      'startxref\n$xref\n%%EOF\n',
    );
    return File('${root.path}/$name')..writeAsBytesSync(bytes.takeBytes());
  }

  return (
    dashed: page('dashed.pdf', '4 w [10 10] 0 d 10 40 m 110 40 l S'),
    layered: page(
      'layered.pdf',
      '/OC /Hidden BDC 1 0 0 rg 0 0 120 80 re f EMC '
          '0 0 1 rg 10 10 10 10 re f',
      layer: true,
    ),
    sparse: page('sparse.pdf', '0 0 1 rg 10 10 30 30 re f', sparse: true),
  );
}

/// Standard graphics and the indirect font-width structure from the reported
/// receipt. These fixtures contain synthetic text only.
Map<String, File> writeRendererCompletionFixtures(Directory root) {
  String stream(String dictionary, String content) =>
      '<< $dictionary /Length ${ascii.encode(content).length} >>\n'
      'stream\n$content\nendstream';
  File write(
    String name,
    String content,
    String resources,
    List<String> extra,
  ) {
    final objects = [
      '<< /Type /Catalog /Pages 2 0 R >>',
      '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 120 80] '
          '/Resources $resources /Contents 4 0 R >>',
      stream('', content),
      ...extra,
    ];
    final bytes = BytesBuilder(copy: false);
    void put(String s) => bytes.add(ascii.encode(s));
    put('%PDF-1.7\n');
    final offsets = <int>[];
    for (var i = 0; i < objects.length; i++) {
      offsets.add(bytes.length);
      put('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
    }
    final xref = bytes.length;
    put('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
    for (final offset in offsets) {
      put('${offset.toString().padLeft(10, '0')} 00000 n \n');
    }
    put(
      'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n'
      'startxref\n$xref\n%%EOF\n',
    );
    return File('${root.path}/$name.pdf')..writeAsBytesSync(bytes.takeBytes());
  }

  File font(bool indirect) => write(
    indirect ? 'font-indirect' : 'font-direct',
    'BT /F 20 Tf 10 30 Td <000100020003> Tj ET '
        'BT /F 20 Tf 44 30 Td <0003> Tj ET',
    '<< /Font << /F 5 0 R >> >>',
    [
      '<< /Subtype /Type0 /BaseFont /Synthetic-Regular /Encoding /Identity-H '
          '/ToUnicode 6 0 R /DescendantFonts [<< /Subtype /CIDFontType2 '
          '/DW 1000 /W [1 ${indirect ? '7 0 R' : '[550 280 720]'}] >>] >>',
      stream(
        '',
        '3 beginbfchar <0001> <0046> <0002> <0049> <0003> <0044> endbfchar',
      ),
      '[550 280 720]',
    ],
  );

  return {
    'fontDirect': font(false),
    'fontIndirect': font(true),
    'group': write(
      'group',
      '/H gs /G Do',
      '<< /ExtGState << /H << /ca 0.5 >> >> /XObject << /G 5 0 R >> >>',
      [
        stream(
          '/Subtype /Form /BBox [0 0 120 80] '
              '/Group << /S /Transparency /I true /CS /DeviceRGB >>',
          '1 0 0 rg 0 0 80 80 re f 0 0 1 rg 40 0 80 80 re f',
        ),
      ],
    ),
    'softMask': write(
      'soft-mask',
      '/M gs 0 g 0 0 120 80 re f',
      '<< /ExtGState << /M << /SMask << /S /Luminosity /G 5 0 R >> >> >> >>',
      [
        stream(
          '/Subtype /Form /BBox [0 0 120 80] '
              '/Group << /S /Transparency /I true /CS /DeviceRGB >>',
          '0.5 g 0 0 60 80 re f 1 g 60 0 60 80 re f',
        ),
      ],
    ),
    'function': write(
      'function',
      '/S sh',
      '<< /Shading << /S << /ShadingType 1 /ColorSpace /DeviceRGB '
          '/Domain [0 1 0 1] /Matrix [120 0 0 80 0 0] /Function 5 0 R >> >> >>',
      [
        stream(
          '/FunctionType 4 /Domain [0 1 0 1] /Range [0 1 0 1 0 1]',
          '{ pop dup 0 exch 1 exch sub }',
        ),
      ],
    ),
  };
}
