import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_archive_core/flutter_archive_core.dart';
import 'package:flutter_pdf_core/flutter_pdf_core.dart';
import 'package:flutter_sheet_core/flutter_sheet_core.dart';
import 'package:flutter_slide_core/flutter_slide_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_text_core/flutter_text_core.dart';
import 'package:flutter_word_core/flutter_word_core.dart';
import 'package:pdfhelper/utils/error_logger.dart';

/// Handled errors reach crash reporting outside debug builds, as their tag
/// and kind only: messages can contain document names and paths.
void main() {
  tearDown(() => handledErrorReporter = null);

  test(
    'an error is described by its type and stable code, not its message',
    () {
      expect(
        describeErrorKind(PdfException('ENCRYPTED', 'Invoice.pdf is locked')),
        'PdfException(ENCRYPTED)',
      );
      expect(
        describeErrorKind(
          PlatformException(
            code: 'PUBLIC_SAVE_FAILED',
            message: '/sdcard/x.pdf',
          ),
        ),
        'PlatformException(PUBLIC_SAVE_FAILED)',
      );
      expect(
        describeErrorKind(
          const FileSystemException(
            'Cannot open',
            '/data/user/0/app/files/Bank statement.pdf',
            OSError('No such file', 2),
          ),
        ),
        'FileSystemException(2)',
      );
      final generic = describeErrorKind(
        Exception('/storage/emulated/0/Tax.pdf'),
      );
      expect(generic, isNot(contains('Tax')));
      expect(describeErrorKind(StateError('Medical.pdf')), 'StateError');
    },
  );

  test('every engine error is named with its code, not its message', () {
    const secret = '/storage/emulated/0/Download/Divorce papers.docx';
    expect(
      describeErrorKind(TextCoreException('TOO_LARGE', secret)),
      'TextCoreException(TOO_LARGE)',
    );
    expect(
      describeErrorKind(SheetCoreException('CORRUPT', secret)),
      'SheetCoreException(CORRUPT)',
    );
    expect(
      describeErrorKind(WordCoreException('PANIC', secret)),
      'WordCoreException(PANIC)',
    );
    expect(
      describeErrorKind(SlideCoreException('ENCRYPTED', secret)),
      'SlideCoreException(ENCRYPTED)',
    );
    expect(
      describeErrorKind(ArchiveCoreException('UNSUPPORTED', secret)),
      'ArchiveCoreException(UNSUPPORTED)',
    );
    // Parsed from the engine's "CODE: message", as the bindings do.
    expect(
      describeErrorKind(WordCoreException.fromNative('IO: $secret: denied')),
      'WordCoreException(IO)',
    );
  });

  test('a code that is not a code is not reported', () {
    // A native message without a code splits at the path's own colon.
    final odd = SheetCoreException.fromNative(
      '/sdcard/Salaries 2026.xlsx: could not be read',
    );
    expect(odd.code, contains('Salaries'));
    expect(describeErrorKind(odd), 'SheetCoreException(?)');
    expect(
      describeErrorKind(PlatformException(code: 'Tax return.pdf missing')),
      'PlatformException(?)',
    );
    expect(
      describeErrorKind(PlatformException(code: 'camera_access_denied')),
      'PlatformException(camera_access_denied)',
    );
    expect(
      describeErrorKind(PlatformException(code: 'channel-error')),
      'PlatformException(channel-error)',
    );
  });

  test('a file name in a code\'s place is not reported', () {
    // Without a folder in front, the name alone looks almost like a code.
    final named = WordCoreException.fromNative('Will.docx: could not be read');
    expect(named.code, 'Will.docx');
    expect(describeErrorKind(named), 'WordCoreException(?)');
    expect(
      describeErrorKind(SheetCoreException('Salaries', 'from a message')),
      'SheetCoreException(?)',
    );
    expect(
      describeErrorKind(PlatformException(code: 'Will.docx')),
      'PlatformException(?)',
    );
    // Every code the engines raise still gets through.
    for (final code in [
      'IO',
      'INVALID_ARGUMENT',
      'BAD_HANDLE',
      'UNSUPPORTED',
      'ENCRYPTED',
      'WRONG_PASSWORD',
      'CORRUPT',
      'TOO_LARGE',
      'NOT_FOUND',
      'PANIC',
      'ERROR',
      'TIMEOUT',
    ]) {
      expect(
        describeErrorKind(TextCoreException(code, 'message')),
        'TextCoreException($code)',
      );
    }
  });

  group('describeDocument', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('error_logger'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('says the kind and a size bucket, never the name or folder', () {
      final file = File('${dir.path}/Bank statement March.xlsx')
        ..writeAsBytesSync(List.filled(3000, 0));
      final described = describeDocument(file.path);
      expect(described, 'sheet/xlsx, under 10 KB');
      expect(described, isNot(contains('Bank')));
      expect(described, isNot(contains(dir.path)));
    });

    test('a size the caller knows is used as given', () {
      expect(
        describeDocument('/x/Thesis.DOCX', sizeBytes: 5 * 1024 * 1024),
        'word/docx, 1-10 MB',
      );
      expect(
        describeDocument('/x/deck.ppt', sizeBytes: 0),
        'slides/ppt, empty',
      );
    });

    test('an extension DocHelper does not know is not repeated', () {
      final described = describeDocument(
        '/x/diary.mysecretproject',
        sizeBytes: 10,
      );
      expect(described, 'other, under 10 KB');
    });

    test('a file that cannot be read has an unknown size', () {
      expect(describeDocument('${dir.path}/gone.pdf'), 'pdf/pdf, unknown size');
    });
  });

  test('sizes fall into buckets ten times apart', () {
    const kb = 1024;
    const mb = 1024 * kb;
    expect(sizeBucket(null), 'unknown size');
    expect(sizeBucket(-1), 'unknown size');
    expect(sizeBucket(0), 'empty');
    expect(sizeBucket(1), 'under 10 KB');
    expect(sizeBucket(10 * kb - 1), 'under 10 KB');
    expect(sizeBucket(10 * kb), '10-100 KB');
    expect(sizeBucket(100 * kb), '100 KB-1 MB');
    expect(sizeBucket(mb), '1-10 MB');
    expect(sizeBucket(10 * mb), '10-100 MB');
    expect(sizeBucket(100 * mb), '100 MB-1 GB');
    expect(sizeBucket(1024 * mb - 1), '100 MB-1 GB');
    expect(sizeBucket(1024 * mb), '1 GB or more');
  });

  test('a document error reaches the reporter with its kind and size', () {
    final reported = <Object>[];
    handledErrorReporter = (error, stack) => reported.add(error);

    reportHandledError(
      'DocumentEditor.open',
      WordCoreException('PANIC', 'in /sdcard/Will.docx'),
      document: describeDocument('/sdcard/Will.docx', sizeBytes: 300 * 1024),
    );

    final error = reported.single as HandledError;
    expect(error.kind, 'WordCoreException(PANIC)');
    expect(error.document, 'word/docx, 100 KB-1 MB');
    expect(
      error.toString(),
      'DocumentEditor.open: WordCoreException(PANIC) [word/docx, 100 KB-1 MB]',
    );
    expect(error.toString(), isNot(contains('Will')));
  });

  test('logging a document error in debug builds reports nothing', () {
    final reported = <Object>[];
    handledErrorReporter = (error, stack) => reported.add(error);
    logDocumentError(
      'SheetEditor.save',
      SheetCoreException('IO', 'disk full'),
      path: '/sdcard/Budget.xlsx',
      sizeBytes: 1,
    );
    expect(reported, isEmpty);
  });

  test('handled errors reach the installed reporter without their message', () {
    final reported = <(Object, StackTrace)>[];
    handledErrorReporter = (error, stack) => reported.add((error, stack));

    reportHandledError(
      'PdfRaster.renderPage',
      PdfException('ERROR', 'failed to read /sdcard/Payslip.pdf'),
    );

    expect(reported, hasLength(1));
    final error = reported.single.$1;
    expect(error, isA<HandledError>());
    expect(error.toString(), 'PdfRaster.renderPage: PdfException(ERROR)');
    expect(error.toString(), isNot(contains('Payslip')));
    expect(reported.single.$2.toString(), isNotEmpty);
  });

  test('nothing is reported before crash reporting is set up', () {
    expect(handledErrorReporter, isNull);
    reportHandledError('Anywhere', StateError('ignored'));
  });
}
