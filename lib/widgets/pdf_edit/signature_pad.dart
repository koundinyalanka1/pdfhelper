import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'edit_items.dart';

/// A signature as drawn: strokes in a unit box, and that box's width over
/// its height.
class SavedSignature {
  const SavedSignature(this.strokes, this.aspect);

  factory SavedSignature.fromJson(Map<String, dynamic> json) => SavedSignature([
    for (final s in json['strokes'] as List)
      [
        for (final p in s as List)
          Offset(((p as List)[0] as num).toDouble(), (p[1] as num).toDouble()),
      ],
  ], (json['aspect'] as num).toDouble());

  final List<List<Offset>> strokes;
  final double aspect;

  Map<String, Object> toJson() => {
    'strokes': [
      for (final s in strokes)
        [
          for (final p in s) [_round(p.dx), _round(p.dy)],
        ],
    ],
    'aspect': aspect,
  };

  static double _round(double v) => (v * 10000).round() / 10000;

  /// Strokes drawn on a pad, fitted to their own bounds.
  static SavedSignature? fromDrawing(List<List<Offset>> strokes) {
    final all = strokes.expand((s) => s).toList();
    if (all.length < 2) return null;
    var left = all.first.dx, right = left, top = all.first.dy, bottom = top;
    for (final p in all) {
      if (p.dx < left) left = p.dx;
      if (p.dx > right) right = p.dx;
      if (p.dy < top) top = p.dy;
      if (p.dy > bottom) bottom = p.dy;
    }
    // A margin for the pen's width.
    const pad = 6.0;
    left -= pad;
    top -= pad;
    final width = right + pad - left;
    final height = bottom + pad - top;
    return SavedSignature([
      for (final s in strokes)
        [
          for (final p in s)
            Offset((p.dx - left) / width, (p.dy - top) / height),
        ],
    ], width / height);
  }
}

/// The signatures the user has drawn, kept for next time.
class SignatureStore {
  SignatureStore._();

  static const int maxKept = 6;

  /// Lets tests keep signatures somewhere of their own.
  static Directory? directoryOverride;

  static Future<File> _file() async {
    final dir = directoryOverride ?? await getApplicationSupportDirectory();
    return File('${dir.path}/signatures.json');
  }

  static Future<List<SavedSignature>> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return [];
      final list = jsonDecode(await file.readAsString()) as List;
      return [
        for (final s in list)
          SavedSignature.fromJson(s as Map<String, dynamic>),
      ];
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(List<SavedSignature> signatures) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final kept = signatures.take(maxKept).map((s) => s.toJson()).toList();
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(kept));
    await temp.rename(file.path);
  }

  static Future<void> add(SavedSignature signature) async =>
      save([signature, ...await load()]);
}

/// Draw a signature with a finger. Returns null when cancelled.
Future<SavedSignature?> drawSignature(
  BuildContext context, {
  Color ink = const Color(0xFF0D47A1),
}) => Navigator.of(context).push<SavedSignature>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => _SignaturePadScreen(ink: ink),
  ),
);

class _SignaturePadScreen extends StatefulWidget {
  const _SignaturePadScreen({required this.ink});

  final Color ink;

  @override
  State<_SignaturePadScreen> createState() => _SignaturePadScreenState();
}

class _SignaturePadScreenState extends State<_SignaturePadScreen> {
  final List<List<Offset>> _strokes = [];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Draw your signature'),
        actions: [
          TextButton(
            onPressed: _strokes.isEmpty ? null : () => setState(_strokes.clear),
            child: const Text('Clear'),
          ),
          TextButton(
            key: const ValueKey('signature-done'),
            onPressed: _strokes.isEmpty
                ? null
                : () => Navigator.pop(
                    context,
                    SavedSignature.fromDrawing(_strokes),
                  ),
            child: const Text('Done'),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.black26),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: GestureDetector(
                      key: const ValueKey('signature-pad'),
                      onPanStart: (d) =>
                          setState(() => _strokes.add([d.localPosition])),
                      onPanUpdate: (d) =>
                          setState(() => _strokes.last.add(d.localPosition)),
                      child: CustomPaint(
                        painter: _PadPainter(_strokes, widget.ink),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Sign inside the box. It is kept on this device for next time.',
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PadPainter extends CustomPainter {
  _PadPainter(this.strokes, this.ink);

  final List<List<Offset>> strokes;
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = Colors.black12
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(24, size.height * 0.7),
      Offset(size.width - 24, size.height * 0.7),
      line,
    );
    final pen = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (final s in strokes) {
      canvas.drawPath(smoothPath(s), pen);
    }
  }

  @override
  bool shouldRepaint(_PadPainter old) => true;
}

/// A saved signature, drawn to fit.
class SignaturePreview extends StatelessWidget {
  const SignaturePreview(
    this.signature, {
    super.key,
    this.color = const Color(0xFF0D47A1),
  });

  final SavedSignature signature;
  final Color color;

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: signature.aspect.clamp(0.5, 8.0),
    child: CustomPaint(painter: _PreviewPainter(signature, color)),
  );
}

class _PreviewPainter extends CustomPainter {
  _PreviewPainter(this.signature, this.color);

  final SavedSignature signature;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final pen = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (final s in signature.strokes) {
      canvas.drawPath(
        smoothPath([
          for (final p in s) Offset(p.dx * size.width, p.dy * size.height),
        ]),
        pen,
      );
    }
  }

  @override
  bool shouldRepaint(_PreviewPainter old) =>
      old.signature != signature || old.color != color;
}
