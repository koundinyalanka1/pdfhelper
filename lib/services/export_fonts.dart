import 'dart:io';

/// Folders whose fonts PDF exports may use: the system's fonts on each
/// platform. The engines index them once per process.
List<String> exportFontDirs() {
  final home = Platform.environment['HOME'] ?? '';
  if (Platform.isAndroid) {
    return const ['/system/fonts', '/product/fonts', '/system/product/fonts'];
  }
  if (Platform.isMacOS || Platform.isIOS) {
    return [
      '/System/Library/Fonts',
      '/Library/Fonts',
      if (home.isNotEmpty) '$home/Library/Fonts',
    ];
  }
  if (Platform.isWindows) {
    final windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    return ['$windir\\Fonts'];
  }
  return [
    '/usr/share/fonts',
    '/usr/local/share/fonts',
    if (home.isNotEmpty) '$home/.fonts',
    if (home.isNotEmpty) '$home/.local/share/fonts',
  ];
}
