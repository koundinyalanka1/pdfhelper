import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/utils/format_utils.dart';

void main() {
  group('formatFileSize', () {
    test('formats bytes', () {
      expect(formatFileSize(0), contains('B'));
      expect(formatFileSize(512), contains('B'));
    });

    test('formats kilobytes', () {
      expect(formatFileSize(1024), contains('KB'));
      expect(formatFileSize(2048), contains('KB'));
    });

    test('formats megabytes', () {
      expect(formatFileSize(1024 * 1024), contains('MB'));
      expect(formatFileSize(5 * 1024 * 1024), contains('MB'));
    });
  });

  group('getPdfDisplayTitle', () {
    test('returns last path segment', () {
      expect(getPdfDisplayTitle('/path/to/Report.pdf'), 'Report.pdf');
    });

    test('handles backslash paths', () {
      expect(getPdfDisplayTitle(r'C:\docs\My File.pdf'), 'My File.pdf');
    });

    test('strips intent_TIMESTAMP_ prefix', () {
      expect(
        getPdfDisplayTitle('/tmp/intent_1234567_resume.pdf'),
        'resume.pdf',
      );
    });

    test('falls back to View PDF for opened.pdf', () {
      expect(getPdfDisplayTitle('/tmp/opened.pdf'), 'View PDF');
    });

    test('returns name unchanged when no path', () {
      expect(getPdfDisplayTitle('Untitled.pdf'), 'Untitled.pdf');
    });
  });
}
