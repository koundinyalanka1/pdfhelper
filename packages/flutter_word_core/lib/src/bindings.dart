// Raw dart:ffi bindings for the Rust word_ffi library.
//
// Strings are UTF-8 and NUL-terminated. Strings the library returns are
// freed with [WordBindings.freeString]; `word_last_error` and
// `word_core_version` return borrowed pointers that must not be freed.
//
// This file is internal to the package (not exported), so its fields may use
// the private native signature typedefs.
// ignore_for_file: library_private_types_in_public_api

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _StrC = Pointer<Utf8> Function();
typedef _FreeStringC = Void Function(Pointer<Utf8>);
typedef _FreeStringDart = void Function(Pointer<Utf8>);
typedef _OpenC = Int64 Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _OpenDart = int Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _NewC = Int64 Function();
typedef _NewDart = int Function();
typedef _HandleC = Int64 Function(Int64);
typedef _HandleDart = int Function(int);
typedef _HandleStrC = Pointer<Utf8> Function(Int64);
typedef _HandleStrDart = Pointer<Utf8> Function(int);
typedef _HandleIntIntStrC = Pointer<Utf8> Function(Int64, Int64, Int64);
typedef _HandleIntIntStrDart = Pointer<Utf8> Function(int, int, int);
typedef _HandleIntStrC = Pointer<Utf8> Function(Int64, Int64);
typedef _HandleIntStrDart = Pointer<Utf8> Function(int, int);
typedef _HandleIntC = Int64 Function(Int64, Int64);
typedef _HandleIntDart = int Function(int, int);
typedef _HandleArgC = Pointer<Utf8> Function(Int64, Pointer<Utf8>);
typedef _HandleArgDart = Pointer<Utf8> Function(int, Pointer<Utf8>);
typedef _HandleArg2C =
    Pointer<Utf8> Function(Int64, Pointer<Utf8>, Pointer<Utf8>);
typedef _HandleArg2Dart =
    Pointer<Utf8> Function(int, Pointer<Utf8>, Pointer<Utf8>);
typedef _ImageC = Pointer<Utf8> Function(Int64, Int64, Pointer<Utf8>);
typedef _ImageDart = Pointer<Utf8> Function(int, int, Pointer<Utf8>);

/// The word library, resolved once per isolate.
class WordBindings {
  WordBindings._(DynamicLibrary lib)
    : lastError = lib.lookupFunction<_StrC, _StrC>('word_last_error'),
      freeString = lib.lookupFunction<_FreeStringC, _FreeStringDart>(
        'word_free_string',
      ),
      version = lib.lookupFunction<_StrC, _StrC>('word_core_version'),
      open = lib.lookupFunction<_OpenC, _OpenDart>('word_open'),
      create = lib.lookupFunction<_NewC, _NewDart>('word_new'),
      close = lib.lookupFunction<_HandleC, _HandleDart>('word_close'),
      infoJson = lib.lookupFunction<_HandleStrC, _HandleStrDart>(
        'word_info_json',
      ),
      blocksJson = lib.lookupFunction<_HandleIntIntStrC, _HandleIntIntStrDart>(
        'word_blocks_json',
      ),
      paragraphJson = lib.lookupFunction<_HandleIntStrC, _HandleIntStrDart>(
        'word_paragraph_json',
      ),
      blockIndex = lib.lookupFunction<_HandleIntC, _HandleIntDart>(
        'word_block_index',
      ),
      apply = lib.lookupFunction<_HandleArgC, _HandleArgDart>('word_apply'),
      undo = lib.lookupFunction<_HandleC, _HandleDart>('word_undo'),
      redo = lib.lookupFunction<_HandleC, _HandleDart>('word_redo'),
      findJson = lib.lookupFunction<_HandleArg2C, _HandleArg2Dart>(
        'word_find_json',
      ),
      outlineJson = lib.lookupFunction<_HandleStrC, _HandleStrDart>(
        'word_outline_json',
      ),
      countsJson = lib.lookupFunction<_HandleStrC, _HandleStrDart>(
        'word_counts_json',
      ),
      text = lib.lookupFunction<_HandleStrC, _HandleStrDart>('word_text'),
      imageSave = lib.lookupFunction<_ImageC, _ImageDart>('word_image_save'),
      save = lib.lookupFunction<_HandleArgC, _HandleArgDart>('word_save'),
      writeCopy = lib.lookupFunction<_HandleArg2C, _HandleArg2Dart>(
        'word_write_copy',
      );

  /// The thread's last error; borrowed, do not free.
  final _StrC lastError;

  /// Frees a string returned by this library.
  final _FreeStringDart freeString;

  /// Static library version; borrowed, do not free.
  final _StrC version;
  final _OpenDart open;
  final _NewDart create;
  final _HandleDart close;
  final _HandleStrDart infoJson;
  final _HandleIntIntStrDart blocksJson;
  final _HandleIntStrDart paragraphJson;
  final _HandleIntDart blockIndex;
  final _HandleArgDart apply;
  final _HandleDart undo;
  final _HandleDart redo;
  final _HandleArg2Dart findJson;
  final _HandleStrDart outlineJson;
  final _HandleStrDart countsJson;
  final _HandleStrDart text;
  final _ImageDart imageSave;
  final _HandleArgDart save;
  final _HandleArg2Dart writeCopy;

  static WordBindings? _instance;

  /// The bindings for this isolate. Throws [ArgumentError] when the native
  /// library cannot be loaded.
  ///
  /// `WORD_CORE_LIB_PATH` overrides the library location (host tests).
  static WordBindings get instance => _instance ??= WordBindings._(_open());

  static DynamicLibrary _open() {
    final override = Platform.environment['WORD_CORE_LIB_PATH'];
    if (override != null && override.isNotEmpty) {
      return DynamicLibrary.open(override);
    }
    if (Platform.isAndroid || Platform.isLinux) {
      return DynamicLibrary.open('libword_ffi.so');
    }
    if (Platform.isMacOS || Platform.isIOS) {
      // CocoaPods links the vendored library into the app.
      final process = DynamicLibrary.process();
      if (process.providesSymbol('word_last_error')) return process;
      return DynamicLibrary.open('libword_ffi.dylib');
    }
    if (Platform.isWindows) {
      return DynamicLibrary.open('word_ffi.dll');
    }
    return DynamicLibrary.process();
  }
}
