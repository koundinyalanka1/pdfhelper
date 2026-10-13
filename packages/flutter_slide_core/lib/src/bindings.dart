// Raw dart:ffi bindings for the Rust slide_ffi library.
//
// Strings are UTF-8 and NUL-terminated. Strings the library returns are
// freed with [SlideBindings.freeString]; `slide_last_error` and
// `slide_core_version` return borrowed pointers that must not be freed.
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
typedef _HandleIntStrC = Pointer<Utf8> Function(Int64, Int64);
typedef _HandleIntStrDart = Pointer<Utf8> Function(int, int);
typedef _HandleArgC = Pointer<Utf8> Function(Int64, Pointer<Utf8>);
typedef _HandleArgDart = Pointer<Utf8> Function(int, Pointer<Utf8>);
typedef _HandleArg2C =
    Pointer<Utf8> Function(Int64, Pointer<Utf8>, Pointer<Utf8>);
typedef _HandleArg2Dart =
    Pointer<Utf8> Function(int, Pointer<Utf8>, Pointer<Utf8>);
typedef _PartC = Int64 Function(Int64, Pointer<Utf8>, Pointer<Utf8>);
typedef _PartDart = int Function(int, Pointer<Utf8>, Pointer<Utf8>);

/// The slide library, resolved once per isolate.
class SlideBindings {
  SlideBindings._(DynamicLibrary lib)
    : lastError = lib.lookupFunction<_StrC, _StrC>('slide_last_error'),
      freeString = lib.lookupFunction<_FreeStringC, _FreeStringDart>(
        'slide_free_string',
      ),
      version = lib.lookupFunction<_StrC, _StrC>('slide_core_version'),
      open = lib.lookupFunction<_OpenC, _OpenDart>('slide_open'),
      create = lib.lookupFunction<_NewC, _NewDart>('slide_new'),
      close = lib.lookupFunction<_HandleC, _HandleDart>('slide_close'),
      infoJson = lib.lookupFunction<_HandleStrC, _HandleStrDart>(
        'slide_info_json',
      ),
      sceneJson = lib.lookupFunction<_HandleIntStrC, _HandleIntStrDart>(
        'slide_scene_json',
      ),
      notes = lib.lookupFunction<_HandleIntStrC, _HandleIntStrDart>(
        'slide_notes',
      ),
      apply = lib.lookupFunction<_HandleArgC, _HandleArgDart>('slide_apply'),
      undo = lib.lookupFunction<_HandleC, _HandleDart>('slide_undo'),
      redo = lib.lookupFunction<_HandleC, _HandleDart>('slide_redo'),
      partSave = lib.lookupFunction<_PartC, _PartDart>('slide_part_save'),
      text = lib.lookupFunction<_HandleStrC, _HandleStrDart>('slide_text'),
      save = lib.lookupFunction<_HandleArgC, _HandleArgDart>('slide_save'),
      writeCopy = lib.lookupFunction<_HandleArg2C, _HandleArg2Dart>(
        'slide_write_copy',
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
  final _HandleIntStrDart sceneJson;
  final _HandleIntStrDart notes;
  final _HandleArgDart apply;
  final _HandleDart undo;
  final _HandleDart redo;
  final _PartDart partSave;
  final _HandleStrDart text;
  final _HandleArgDart save;
  final _HandleArg2Dart writeCopy;

  static SlideBindings? _instance;

  /// The bindings for this isolate. Throws [ArgumentError] when the native
  /// library cannot be loaded.
  ///
  /// `SLIDE_CORE_LIB_PATH` overrides the library location (host tests).
  static SlideBindings get instance => _instance ??= SlideBindings._(_open());

  static DynamicLibrary _open() {
    final override = Platform.environment['SLIDE_CORE_LIB_PATH'];
    if (override != null && override.isNotEmpty) {
      return DynamicLibrary.open(override);
    }
    if (Platform.isAndroid || Platform.isLinux) {
      return DynamicLibrary.open('libslide_ffi.so');
    }
    if (Platform.isMacOS || Platform.isIOS) {
      // CocoaPods links the vendored library into the app.
      final process = DynamicLibrary.process();
      if (process.providesSymbol('slide_last_error')) return process;
      return DynamicLibrary.open('libslide_ffi.dylib');
    }
    if (Platform.isWindows) {
      return DynamicLibrary.open('slide_ffi.dll');
    }
    return DynamicLibrary.process();
  }
}
