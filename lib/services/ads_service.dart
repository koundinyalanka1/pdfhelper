import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

/// Centralized AdMob coordinator.
///
/// Uses Google's published test ad-unit IDs everywhere — replace with your
/// real unit IDs before publishing.
///
/// **Interstitial UX policy:**
/// We deliberately do NOT show an interstitial after every operation, because
/// users typically perform several operations in a row (merge several batches,
/// split a few files, scan multiple docs) and back-to-back fullscreen ads are
/// the #1 reason users uninstall PDF tools.
///
/// Rules enforced by [maybeShowInterstitial]:
/// 1. The very first completion of every app session is ad-free (let the user
///    succeed and see the result).
/// 2. After that, an ad is shown only every Nth completion ([_completionsBetweenAds]).
/// 3. A hard minimum gap ([_minGapBetweenAds]) between any two interstitials,
///    regardless of completion count.
class AdsService {
  AdsService._();
  static final AdsService instance = AdsService._();

  // ---------- Throttling tunables ----------
  static const int _completionsBetweenAds = 3;
  static const Duration _minGapBetweenAds = Duration(seconds: 90);

  // ---------- State ----------
  bool _initialized = false;
  bool get isInitialized => _initialized;

  InterstitialAd? _interstitial;
  bool _isLoadingInterstitial = false;

  int _completionCount = 0;
  DateTime? _lastInterstitialShownAt;

  // ---------- Test ad-unit IDs (Google's official, safe to ship in dev) ----------
  static String get bannerAdUnitId {
    if (Platform.isAndroid) return 'ca-app-pub-3940256099942544/6300978111';
    if (Platform.isIOS) return 'ca-app-pub-3940256099942544/2934735716';
    return '';
  }

  static String get interstitialAdUnitId {
    if (Platform.isAndroid) return 'ca-app-pub-3940256099942544/1033173712';
    if (Platform.isIOS) return 'ca-app-pub-3940256099942544/4411468910';
    return '';
  }

  /// Initialize the Mobile Ads SDK and start preloading an interstitial.
  /// Safe to call multiple times.
  Future<void> initialize() async {
    if (_initialized) return;
    try {
      await MobileAds.instance.initialize();
      _initialized = true;
      _loadInterstitial();
      debugPrint('[AdsService] initialized');
    } catch (e) {
      debugPrint('[AdsService] initialization failed: $e');
    }
  }

  void _loadInterstitial() {
    if (!_initialized) return;
    if (_interstitial != null || _isLoadingInterstitial) return;
    _isLoadingInterstitial = true;
    InterstitialAd.load(
      adUnitId: interstitialAdUnitId,
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) {
          _isLoadingInterstitial = false;
          _interstitial = ad;
          ad.fullScreenContentCallback = FullScreenContentCallback(
            onAdDismissedFullScreenContent: (a) {
              a.dispose();
              _interstitial = null;
              _loadInterstitial();
            },
            onAdFailedToShowFullScreenContent: (a, _) {
              a.dispose();
              _interstitial = null;
              _loadInterstitial();
            },
          );
        },
        onAdFailedToLoad: (err) {
          _isLoadingInterstitial = false;
          _interstitial = null;
          debugPrint('[AdsService] interstitial load failed: $err');
        },
      ),
    );
  }

  /// Call this after a user-visible operation completes (merge / split /
  /// convert). The service decides whether to actually show the ad based on
  /// the throttling policy described in the class doc.
  ///
  /// [trigger] is purely for logging.
  Future<void> maybeShowInterstitial({String trigger = 'unknown'}) async {
    _completionCount++;

    // Rule 1: first completion of the session is ad-free.
    if (_completionCount == 1) {
      _loadInterstitial(); // make sure one is queued for next time
      debugPrint(
        '[AdsService] skipping interstitial: first completion ($trigger)',
      );
      return;
    }

    // Rule 2: only every Nth completion.
    if (_completionCount % _completionsBetweenAds != 0) {
      debugPrint(
        '[AdsService] skipping interstitial: count=$_completionCount ($trigger)',
      );
      return;
    }

    // Rule 3: hard min-gap between ads.
    final last = _lastInterstitialShownAt;
    if (last != null && DateTime.now().difference(last) < _minGapBetweenAds) {
      debugPrint('[AdsService] skipping interstitial: too soon ($trigger)');
      return;
    }

    final ad = _interstitial;
    if (ad == null) {
      // Not loaded yet — kick off a load so it's ready next time.
      _loadInterstitial();
      debugPrint('[AdsService] interstitial not ready ($trigger)');
      return;
    }

    _interstitial = null; // consumed
    _lastInterstitialShownAt = DateTime.now();
    debugPrint('[AdsService] showing interstitial ($trigger)');
    await ad.show();
  }

  void dispose() {
    _interstitial?.dispose();
    _interstitial = null;
  }
}
