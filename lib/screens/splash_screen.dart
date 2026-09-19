import 'package:flutter/material.dart';
import '../services/ads_service.dart';
import '../services/intent_service.dart';
import '../utils/format_utils.dart';
import 'home_screen.dart';
import 'pdf_viewer_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;
  String _statusText = 'Your PDF Toolkit';

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
      ),
    );

    _scaleAnimation = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.6, curve: Curves.elasticOut),
      ),
    );

    _controller.forward();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    // Ads initialize in parallel with the splash animation so they never add
    // to perceived startup time. Firebase is already up (see main()).
    final initFuture = AdsService.instance.initialize();

    // Wait for animation to start
    await Future.delayed(const Duration(milliseconds: 800));

    if (mounted) {
      setState(() => _statusText = 'Ready to go!');
    }

    // Make sure init completes before navigating, but cap the wait so we
    // never block the user on a slow network. The services are no-ops if
    // they haven't finished by the time they're called later.
    await initFuture.timeout(const Duration(seconds: 3), onTimeout: () {});

    // Small delay before navigation
    await Future.delayed(const Duration(milliseconds: 500));

    _navigateToHome();
  }

  void _navigateToHome() async {
    if (!mounted) return;
    String? pdfPath;
    try {
      pdfPath = await IntentService.getOpenedPdfPath();
    } catch (e) {
      debugPrint('[SplashScreen] getOpenedPdfPath error: $e');
    }
    if (!mounted) return;

    debugPrint('[SplashScreen] _navigateToHome: pdfPath=$pdfPath');

    if (pdfPath == null) {
      debugPrint('[SplashScreen] No intent, navigating to HomeScreen default');
      _goToHome();
      return;
    }

    // Launched on a document: go straight to reading it. Every other tool is
    // one tap away from the viewer's own menu.
    debugPrint('[SplashScreen] Navigating to PdfViewerScreen path=$pdfPath');
    final path = pdfPath;
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            PdfViewerScreen(pdfPath: path, title: getPdfDisplayTitle(path)),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
        transitionDuration: const Duration(milliseconds: 500),
      ),
    );
  }

  void _goToHome() {
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            const HomeScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
        transitionDuration: const Duration(milliseconds: 500),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1A1A2E), Color(0xFF16213E), Color(0xFF0F3460)],
          ),
        ),
        child: Center(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              return FadeTransition(
                opacity: _fadeAnimation,
                child: ScaleTransition(
                  scale: _scaleAnimation,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 120,
                        height: 120,
                        decoration: BoxDecoration(
                          color: const Color(0xFFE94560),
                          borderRadius: BorderRadius.circular(30),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(
                                0xFFE94560,
                              ).withValues(alpha: 0.4),
                              blurRadius: 30,
                              spreadRadius: 5,
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.picture_as_pdf_rounded,
                          size: 60,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 30),
                      const Text(
                        'PDF Helper',
                        style: TextStyle(
                          fontSize: 36,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          letterSpacing: 2,
                        ),
                      ),
                      const SizedBox(height: 10),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        child: Text(
                          _statusText,
                          key: ValueKey(_statusText),
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w300,
                            color: Colors.white.withValues(alpha: 0.7),
                            letterSpacing: 2,
                          ),
                        ),
                      ),
                      const SizedBox(height: 60),
                      Semantics(
                        label: 'Loading PDF Helper',
                        child: SizedBox(
                          width: 40,
                          height: 40,
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              const Color(0xFFE94560).withValues(alpha: 0.8),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
