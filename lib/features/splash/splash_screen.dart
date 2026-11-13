import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/services/library_source.dart';
import '../../widgets/common_widgets.dart';
import '../home/home_screen.dart';
import '../setup/library_setup_screen.dart';

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with TickerProviderStateMixin {
  late AnimationController _bookController;
  late AnimationController _textController;
  late Animation<double> _bookAnimation;
  late Animation<double> _textFadeAnimation;
  late Animation<Offset> _textSlideAnimation;

  @override
  void initState() {
    super.initState();

    _bookController = AnimationController(
      duration: const Duration(milliseconds: 2500),
      vsync: this,
    );

    _bookAnimation = CurvedAnimation(
      parent: _bookController,
      curve: Curves.easeInOutCubic,
    );

    _textController = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    );

    _textFadeAnimation = CurvedAnimation(
      parent: _textController,
      curve: Curves.easeIn,
    );

    _textSlideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.3),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _textController,
      curve: Curves.easeOut,
    ));

    _bookController.forward();

    // Start text animation after book animation
    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted) _textController.forward();
    });

    // Navigate to home after animation — or to the import screen when this
    // build ships without the books and nothing has been imported yet.
    Future.delayed(const Duration(milliseconds: 3500), () async {
      if (!mounted) return;
      final hasLibrary = await LibrarySource.exists('library.json');
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (context, animation, secondaryAnimation) =>
              hasLibrary ? const HomeScreen() : const LibrarySetupScreen(),
          transitionsBuilder:
              (context, animation, secondaryAnimation, child) {
            return FadeTransition(
              opacity: animation,
              child: child,
            );
          },
          transitionDuration: const Duration(milliseconds: 800),
        ),
      );
    });
  }

  @override
  void dispose() {
    _bookController.dispose();
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const gold = Color(AppConstants.goldHex);
    const leather = Color(AppConstants.leatherBrownHex);
    const parchment = Color(AppConstants.parchmentHex);

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              parchment,
              Color(0xFFE8DBC0),
              parchment,
            ],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Animated book icon
              AnimatedBuilder(
                animation: _bookAnimation,
                builder: (context, child) {
                  return Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()
                      ..setEntry(3, 2, 0.002)
                      ..rotateY(_bookAnimation.value * 0.3)
                      // scale(double) deprecated → scaleByDouble
                      ..scaleByDouble(
                        0.8 + _bookAnimation.value * 0.2,
                        0.8 + _bookAnimation.value * 0.2,
                        0.8 + _bookAnimation.value * 0.2,
                        1,
                      ),
                    child: Opacity(
                      opacity: _bookAnimation.value,
                      child: child,
                    ),
                  );
                },
                child: Container(
                  width: 140,
                  height: 140,
                  decoration: BoxDecoration(
                    color: leather,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: gold, width: 3),
                    boxShadow: [
                      BoxShadow(
                        color: gold.withValues(alpha: 0.3),
                        blurRadius: 20,
                        spreadRadius: 5,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.menu_book,
                    size: 72,
                    color: gold,
                  ),
                ),
              ),

              const SizedBox(height: 40),

              // App name with fade-in + slide
              FadeTransition(
                opacity: _textFadeAnimation,
                child: SlideTransition(
                  position: _textSlideAnimation,
                  child: const Text(
                    AppConstants.appName,
                    style: TextStyle(
                      fontFamily: 'ReemKufi',
                      fontSize: 36,
                      fontWeight: FontWeight.bold,
                      color: leather,
                      height: 1.2,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),

              const SizedBox(height: 8),

              // Author name
              FadeTransition(
                opacity: _textFadeAnimation,
                child: Text(
                  AppConstants.author,
                  style: TextStyle(
                    fontFamily: 'Amiri',
                    fontSize: 18,
                    color: leather.withValues(alpha: 0.7),
                  ),
                ),
              ),

              const SizedBox(height: 32),

              // Ornamental divider
              FadeTransition(
                opacity: _textFadeAnimation,
                child: const OrnamentalDivider(height: 24),
              ),

              const SizedBox(height: 48),

              // Loading text with pulse
              AnimatedBuilder(
                animation: _bookController,
                builder: (context, _) {
                  final pulse = (sin(_bookController.value * 3.14) + 1) / 2;
                  return Opacity(
                    opacity: 0.3 + pulse * 0.4,
                    child: Text(
                      'جارٍ تحضير المكتبة...',
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 14,
                        color: leather.withValues(alpha: 0.5),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  double sin(double x) {
    // Simple sine approximation for pulsing effect
    return (x / 3.14159 * 3.14159).abs() > 3.14159
        ? -(x / 3.14159 * 3.14159 - 3.14159)
        : x / 3.14159 * 3.14159;
  }
}
