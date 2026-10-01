import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../services/ads_service.dart';

/// The app's single, compact home banner. It never expands beyond 320 × 50,
/// and takes no space until an ad is available and the window can fit it.
class BannerAdWidget extends StatefulWidget {
  const BannerAdWidget({super.key});

  @override
  State<BannerAdWidget> createState() => _BannerAdWidgetState();
}

class _BannerAdWidgetState extends State<BannerAdWidget> {
  BannerAd? _ad;
  bool _loaded = false;
  bool _requested = false;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    AdsService.instance.adsAllowed.addListener(_consentChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? false)) return;
      unawaited(AdsService.instance.initialize());
    });
  }

  void _consentChanged() {
    if (!mounted) return;
    _request++;
    _ad?.dispose();
    setState(() {
      _ad = null;
      _loaded = false;
      _requested = false;
    });
  }

  Future<void> _load(int request) async {
    if (!mounted || request != _request || !AdsService.instance.isInitialized) {
      return;
    }
    final ad = BannerAd(
      adUnitId: AdsService.bannerAdUnitId,
      size: AdSize.banner,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (ad) {
          if (!mounted || request != _request || _ad != ad) return;
          setState(() => _loaded = true);
        },
        onAdFailedToLoad: (ad, error) {
          ad.dispose();
          if (!mounted || request != _request || _ad != ad) return;
          setState(() {
            _ad = null;
            _loaded = false;
          });
          debugPrint('[BannerAd] failed: $error');
        },
      ),
    );
    _ad = ad;
    try {
      await ad.load();
    } catch (error) {
      ad.dispose();
      if (!mounted || request != _request || _ad != ad) return;
      setState(() {
        _ad = null;
        _loaded = false;
      });
      debugPrint('[BannerAd] unavailable: $error');
    }
  }

  @override
  void dispose() {
    _request++;
    AdsService.instance.adsAllowed.removeListener(_consentChanged);
    _ad?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!AdsService.instance.isInitialized) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        if (width < AdSize.banner.width) return const SizedBox.shrink();
        if (!_requested) {
          _requested = true;
          final request = ++_request;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            unawaited(_load(request));
          });
        }
        final ad = _ad;
        if (!_loaded || ad == null) return const SizedBox.shrink();
        return Center(
          heightFactor: 1,
          child: SizedBox(
            width: AdSize.banner.width.toDouble(),
            height: AdSize.banner.height.toDouble(),
            child: AdWidget(ad: ad),
          ),
        );
      },
    );
  }
}
