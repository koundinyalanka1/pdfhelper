import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'operation_ad_policy.dart';

export 'operation_ad_policy.dart' show PdfOperation;

/// Centralized AdMob coordinator.
///
/// Uses test units in development and requests ads only when UMP permits it.
///
/// A ready interstitial may appear after every fourth successful document
/// operation. Viewing never counts, and navigation waits for ad dismissal.
class AdsService {
  AdsService._();
  static final AdsService instance = AdsService._();

  // ---------- State ----------
  bool _initialized = false;
  bool get isInitialized => _initialized && adsAllowed.value;
  final ValueNotifier<bool> adsAllowed = ValueNotifier(false);
  final ValueNotifier<bool> privacyOptionsRequired = ValueNotifier(false);
  Future<void>? _initializing;
  int _adGeneration = 0;

  InterstitialAd? _interstitial;
  bool _isLoadingInterstitial = false;

  late final _operationPolicy = OperationAdPolicy(
    showInterstitial: _showLoadedInterstitial,
  );

  @visibleForTesting
  int get completedOperationCount => _operationPolicy.completedOperations;

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

  // ---------- Consent preview (debug and profile builds only) ----------
  //
  // UMP only asks for consent where a regulation applies, so outside the EEA
  // the GDPR message never appears on its own. To preview it:
  //
  //   flutter run --dart-define=UMP_DEBUG_GEOGRAPHY=eea \
  //     --dart-define=UMP_TEST_DEVICE_IDS=<hashed id>[,<hashed id>]
  //
  // `us` previews a regulated US state instead. The UMP SDK logs the device's
  // hashed ID (logcat / Xcode console) on the first request. Stored consent
  // is reset on each such launch so the form shows every time.
  static const _debugGeography = String.fromEnvironment('UMP_DEBUG_GEOGRAPHY');
  static const _testDeviceIds = String.fromEnvironment('UMP_TEST_DEVICE_IDS');

  static ConsentDebugSettings? get _consentDebugSettings {
    if (kReleaseMode) return null;
    final geography = switch (_debugGeography) {
      'eea' => DebugGeography.debugGeographyEea,
      'us' => DebugGeography.debugGeographyRegulatedUsState,
      _ => null,
    };
    if (geography == null) return null;
    return ConsentDebugSettings(
      debugGeography: geography,
      testIdentifiers: [
        for (final id in _testDeviceIds.split(','))
          if (id.trim().isNotEmpty) id.trim(),
      ],
    );
  }

  /// Initialize the Mobile Ads SDK and start preloading an interstitial.
  /// Safe to call multiple times.
  Future<void> initialize() => _initializing ??= _gatherConsent();

  Future<void> _gatherConsent() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    try {
      final debugSettings = _consentDebugSettings;
      if (debugSettings != null) {
        debugPrint('[AdsService] consent preview: $_debugGeography');
        await ConsentInformation.instance.reset();
      }
      final updated = Completer<bool>();
      ConsentInformation.instance.requestConsentInfoUpdate(
        ConsentRequestParameters(consentDebugSettings: debugSettings),
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

  /// Call exactly once when document processing succeeds, before opening its
  /// preview/result. Awaiting this also waits for any fullscreen ad to close.
  Future<void> operationCompleted(
    PdfOperation operation, {
    bool allowPresentation = true,
    bool Function()? canPresent,
  }) async {
    final foreground = allowPresentation &&
        (canPresent?.call() ?? true) &&
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    // Tools can be entered directly from an external document without ever
    // visiting Home. Initialize here, and finish consent before navigation
    // can open the operation's result in the ad-free viewer.
    if (foreground) await initialize();
    await _operationPolicy.completed(
      operation,
      allowPresentation: foreground &&
          (canPresent?.call() ?? true) &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
    );
  }

  Future<void> _showLoadedInterstitial(PdfOperation operation) async {
    if (!isInitialized) return;
    final ad = _interstitial;
    if (ad == null) {
      _loadInterstitial();
      debugPrint('[AdsService] interstitial not ready (${operation.name})');
      return;
    }
    _interstitial = null;
    final dismissed = Completer<void>();
    void finish() {
      if (dismissed.isCompleted) return;
      unawaited(ad.dispose());
      dismissed.complete();
      _loadInterstitial();
    }

    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (_) => finish(),
      onAdFailedToShowFullScreenContent: (_, error) {
        debugPrint('[AdsService] could not show ad: $error');
        finish();
      },
    );
    try {
      // show() resolves when the native SDK accepts the request, not when
      // the ad closes. Only the fullscreen callbacks release navigation.
      await ad.show();
      await dismissed.future;
    } catch (e) {
      finish();
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
