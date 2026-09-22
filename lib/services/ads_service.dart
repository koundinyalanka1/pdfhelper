import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

/// Centralized AdMob coordinator.
///
/// Uses test units in development and requests ads only when UMP permits it.
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
  bool get isInitialized => _initialized && adsAllowed.value;
  final ValueNotifier<bool> adsAllowed = ValueNotifier(false);
  final ValueNotifier<bool> privacyOptionsRequired = ValueNotifier(false);
  Future<void>? _initializing;
  int _adGeneration = 0;

  InterstitialAd? _interstitial;
  bool _isLoadingInterstitial = false;

  int _completionCount = 0;
  DateTime? _lastInterstitialShownAt;

  // ---------- Test ad-unit IDs (Google's official, safe to ship in dev) ----------
  static String get bannerAdUnitId {
    if (Platform.isAndroid) {
      return kReleaseMode
          ? 'ca-app-pub-2596031675923197/8869279306'
          : 'ca-app-pub-3940256099942544/6300978111';
    }
    if (Platform.isIOS) return 'ca-app-pub-3940256099942544/2934735716';
    return '';
  }

  static String get interstitialAdUnitId {
    if (Platform.isAndroid) {
      return kReleaseMode
          ? 'ca-app-pub-2596031675923197/1158310245'
          : 'ca-app-pub-3940256099942544/1033173712';
    }
    if (Platform.isIOS) return 'ca-app-pub-3940256099942544/4411468910';
    return '';
  }

  /// Initialize the Mobile Ads SDK and start preloading an interstitial.
  /// Safe to call multiple times.
  Future<void> initialize() => _initializing ??= _gatherConsent();

  Future<void> _gatherConsent() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    try {
      final updated = Completer<bool>();
      ConsentInformation.instance.requestConsentInfoUpdate(
        ConsentRequestParameters(),
        () => updated.complete(true),
        (_) => updated.complete(false),
      );
      if (await updated.future) {
        final form = Completer<void>();
        ConsentForm.loadAndShowConsentFormIfRequired((_) => form.complete());
        await form.future;
      }
      await _refreshConsent();
    } catch (e) {
      debugPrint('[AdsService] consent unavailable: $e');
    }
  }

  Future<void> _refreshConsent() async {
    privacyOptionsRequired.value =
        await ConsentInformation.instance
            .getPrivacyOptionsRequirementStatus() ==
        PrivacyOptionsRequirementStatus.required;
    final allowed = await ConsentInformation.instance.canRequestAds();
    if (allowed && !_initialized) {
      await MobileAds.instance.initialize();
      _initialized = true;
    }
    adsAllowed.value = allowed;
    if (allowed) _loadInterstitial();
  }

  Future<void> showPrivacyOptions() async {
    adsAllowed.value = false;
    dispose();
    try {
      final dismissed = Completer<FormError?>();
      ConsentForm.showPrivacyOptionsForm(dismissed.complete);
      final error = await dismissed.future;
      await _refreshConsent();
      if (error != null) throw StateError(error.message);
    } catch (_) {
      // Keep ads disabled when the new consent status cannot be established.
      rethrow;
    }
  }

  void _loadInterstitial() {
    if (!isInitialized) return;
    if (_interstitial != null || _isLoadingInterstitial) return;
    _isLoadingInterstitial = true;
    final generation = _adGeneration;
    InterstitialAd.load(
      adUnitId: interstitialAdUnitId,
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) {
          if (generation != _adGeneration || !isInitialized) {
            ad.dispose();
            return;
          }
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
          if (generation != _adGeneration) return;
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
    if (!isInitialized) return;
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
    try {
      await ad.show();
    } catch (e) {
      ad.dispose();
      debugPrint('[AdsService] could not show ad: $e');
    }
  }

  void dispose() {
    _adGeneration++;
    _isLoadingInterstitial = false;
    _interstitial?.dispose();
    _interstitial = null;
  }
}
