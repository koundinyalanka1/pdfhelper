import 'dart:io';

import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Points every `path_provider` lookup at a real temp directory.
///
/// `flutter test` registers no plugins, so anything that asks for the
/// documents or support directory throws by default. Backing those with
/// directories that actually exist means the library sweep, the scan cache
/// and the recents store can all be tested against real file I/O rather than
/// against mocks of the file system.
class FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  FakePathProvider(this.root);

  final Directory root;

  Directory get documents => _ensure('documents');
  Directory get support => _ensure('support');
  Directory get temporary => _ensure('temporary');
  Directory get externalStorage => _ensure('external');

  Directory _ensure(String name) {
    final dir = Directory('${root.path}/$name');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// Installs this fake and returns it. Call [restore] in `tearDown`.
  static FakePathProvider install(Directory root) {
    _previous ??= PathProviderPlatform.instance;
    final fake = FakePathProvider(root);
    PathProviderPlatform.instance = fake;
    return fake;
  }

  static PathProviderPlatform? _previous;

  static void restore() {
    final previous = _previous;
    if (previous != null) PathProviderPlatform.instance = previous;
  }

  @override
  Future<String?> getApplicationDocumentsPath() async => documents.path;

  @override
  Future<String?> getApplicationSupportPath() async => support.path;

  @override
  Future<String?> getTemporaryPath() async => temporary.path;

  @override
  Future<String?> getExternalStoragePath() async => externalStorage.path;

  @override
  Future<List<String>?> getExternalStoragePaths({
    StorageDirectory? type,
  }) async => [externalStorage.path];

  @override
  Future<List<String>?> getExternalCachePaths() async => [_ensure('cache').path];

  @override
  Future<String?> getLibraryPath() async => support.path;

  @override
  Future<String?> getDownloadsPath() async => _ensure('downloads').path;
}
