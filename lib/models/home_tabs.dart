/// The app's top-level destinations.
///
/// Four, rather than one tab per feature. Every document operation now lives
/// behind [tools], which keeps the bar readable at a glance and frees the slot
/// [settings] needed — settings used to be the fourth icon in a crowded Files
/// app bar, which is the last place anyone thinks to look for it.
class HomeTabs {
  HomeTabs._();

  static const int files = 0;
  static const int tools = 1;
  static const int scan = 2;
  static const int settings = 3;
  static const int count = 4;
}

/// A document operation that opens *over* the tab scaffold instead of living
/// in it.
///
/// Merge and split used to be tabs. They are routes now: both are jobs you
/// finish and come back from, and a pushed route gets that for free — a back
/// button, and fresh state on every entry, where a tab needed a key-bumping
/// hack before it would notice it had been handed a second document.
enum DocHandoff { merge, split }
