/// Switches for work that is built but not yet shipped.
///
/// A flag here hides the ways *into* a feature, not the feature itself. The
/// screens and services behind it stay in the tree, keep compiling and keep
/// their tests running, so turning the flag back on is the whole of the work
/// needed to ship it.
class Features {
  Features._();

  /// The on-device AI tools: "Ask AI" (summarise and question a document) and
  /// the local model manager.
  ///
  /// **Hidden for now — planned for a future update.** Everything behind it
  /// is complete: [AiService], the extractive model, the document index and
  /// both screens. What is not settled is the shipping side of it — which
  /// models to offer, their download size, and how the first-run experience
  /// should read — so the entry points are hidden until that is decided
  /// rather than shipping a half-answered feature.
  ///
  /// Set to `true` to restore it. The entry points are in
  /// `tools_screen.dart`, `library_screen.dart` and `pdf_viewer_screen.dart`;
  /// each is guarded by this flag and nothing else.
  static const bool ai = false;
}
