import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_pdf_core/flutter_pdf_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfhelper/utils/error_logger.dart';

/// Handled errors reach crash reporting outside debug builds, as their tag
/// and kind only: messages can contain document names and paths.
void main() {
  tearDown(() => handledErrorReporter = null);

  test('an error is described by its type and stable code, not its message', () {
    expect(
      describeErrorKind(PdfException('ENCRYPTED', 'Invoice.pdf is locked')),
      'PdfException(ENCRYPTED)',
    );
    expect(
      describeErrorKind(
        PlatformException(code: 'PUBLIC_SAVE_FAILED', message: '/sdcard/x.pdf'),
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
    final generic = describeErrorKind(Exception('/storage/emulated/0/Tax.pdf'));
    expect(generic, isNot(contains('Tax')));
    expect(describeErrorKind(StateError('Medical.pdf')), 'StateError');
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
