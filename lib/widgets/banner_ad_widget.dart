import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../services/ads_service.dart';

/// Self-contained adaptive banner ad. Hides itself entirely if the SDK isn't
/// initialized or the ad fails to load, so layout never reserves empty space.
class BannerAdWidget extends StatefulWidget {
  const BannerAdWidget({super.key});

  @override
  State<BannerAdWidget> createState() => _BannerAdWidgetState();
}

class _BannerAdWidgetState extends State<BannerAdWidget> {
  BannerAd? _ad;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    AdsService.instance.adsAllowed.addListener(_consentChanged);
    _consentChanged();
  }

  void _consentChanged() {
    if (!mounted) return;
    if (AdsService.instance.isInitialized) {
      if (_ad == null) _load();
    } else {
      _ad?.dispose();
      setState(() {
        _ad = null;
        _loaded = false;
      });
    }
  }

  void _load() {
    final ad = BannerAd(
      adUnitId: AdsService.bannerAdUnitId,
      size: AdSize.banner,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (ad) {
          if (!mounted || _ad != ad) return;
          setState(() => _loaded = true);
        },
        onAdFailedToLoad: (ad, err) {
          ad.dispose();
          if (_ad == ad) _ad = null;
          debugPrint('[BannerAd] failed: $err');
        },
      ),
    );
    _ad = ad;
    ad.load();
  }

  @override
  void dispose() {
    AdsService.instance.adsAllowed.removeListener(_consentChanged);
    _ad?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ad = _ad;
    if (!_loaded || ad == null) return const SizedBox.shrink();
    return SizedBox(
      width: ad.size.width.toDouble(),
      height: ad.size.height.toDouble(),
      child: AdWidget(ad: ad),
    );
  }
}
