// Raw dart:ffi bindings for the Rust archive_ffi library.
//
// Strings are UTF-8 and NUL-terminated. Strings the library returns are
// freed with [ArchiveBindings.freeString]; `archive_last_error` and
// `archive_core_version` return borrowed pointers that must not be freed.
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
typedef _ListC = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _ExtractC = Int64 Function(Pointer<Utf8>, Int64, Pointer<Utf8>);
typedef _ExtractDart = int Function(Pointer<Utf8>, int, Pointer<Utf8>);
typedef _ExtractAllC = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _CreateC = Int64 Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _CreateDart = int Function(Pointer<Utf8>, Pointer<Utf8>);

/// The archive library, resolved once per isolate.
class ArchiveBindings {
  ArchiveBindings._(DynamicLibrary lib)
    : lastError = lib.lookupFunction<_StrC, _StrC>('archive_last_error'),
      freeString = lib.lookupFunction<_FreeStringC, _FreeStringDart>(
        'archive_free_string',
      ),
      version = lib.lookupFunction<_StrC, _StrC>('archive_core_version'),
      listJson = lib.lookupFunction<_ListC, _ListC>('archive_list_json'),
      extract = lib.lookupFunction<_ExtractC, _ExtractDart>('archive_extract'),
      extractAllJson = lib.lookupFunction<_ExtractAllC, _ExtractAllC>(
        'archive_extract_all_json',
      ),
      create = lib.lookupFunction<_CreateC, _CreateDart>('archive_create');

  final _StrC lastError;
  final _FreeStringDart freeString;
  final _StrC version;
  final _ListC listJson;
  final _ExtractDart extract;
  final _ExtractAllC extractAllJson;
  final _CreateDart create;

  static ArchiveBindings? _instance;

  /// The bindings for this isolate. Throws [ArgumentError] when the native
  /// library cannot be loaded.
  ///
  /// `ARCHIVE_CORE_LIB_PATH` overrides the library location (host tests).
  static ArchiveBindings get instance =>
      _instance ??= ArchiveBindings._(_open());

  static DynamicLibrary _open() {
    final override = Platform.environment['ARCHIVE_CORE_LIB_PATH'];
    if (override != null && override.isNotEmpty) {
      return DynamicLibrary.open(override);
    }
    if (Platform.isAndroid || Platform.isLinux) {
      return DynamicLibrary.open('libarchive_ffi.so');
    }
    if (Platform.isMacOS || Platform.isIOS) {
      // CocoaPods links the vendored library into the app.
      final process = DynamicLibrary.process();
      if (process.providesSymbol('archive_last_error')) return process;
      return DynamicLibrary.open('libarchive_ffi.dylib');
    }
    if (Platform.isWindows) {
      return DynamicLibrary.open('archive_ffi.dll');
    }
    return DynamicLibrary.process();
  }
}
