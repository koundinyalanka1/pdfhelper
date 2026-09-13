import 'dart:typed_data';

class SelectedPdfFile {
  SelectedPdfFile({
    required this.path,
    required this.name,
    required this.fileSize,
    this.isLoading = false,
    this.thumbnail,
    this.pageCount = 0,
    this.aspectRatio,
  });

  final String path;
  final String name;
  final int? fileSize;
  bool isLoading;

  /// First-page preview, PNG bytes from the native rasterizer.
  Uint8List? thumbnail;
  int pageCount;
  /// First page width/height for responsive thumbnail sizing
  double? aspectRatio;
}
