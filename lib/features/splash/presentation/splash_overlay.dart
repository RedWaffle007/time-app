import 'package:flutter/widgets.dart';

import '../../../core/theme/app_tokens.dart';
import '../../../core/theme/splash_tokens.dart';
import '../data/splash_sound.dart';

/// The Supercell-style cold-start reveal, sitting ABOVE everything (including the
/// app lock) during app boot and fading out into the app beneath.
///
/// **Cold-start vs warm-resume — the mechanism.** A warm resume from the recents
/// tray does NOT re-run `main()` or rebuild this widget: the Dart isolate and the
/// whole widget tree stay alive, so the app simply resumes to the exact screen it
/// was on. Only a fresh PROCESS launch re-runs `main()` and constructs a new
/// isolate — which is precisely Android's cold-start / warm-resume distinction,
/// read the reliable way (isolate lifetime) rather than guessed from lifecycle
/// callbacks. So the reveal is intrinsically cold-start-only: resume never
/// triggers it. A notification cold start is the deliberate exception: the user
/// already chose a destination, so [skipReveal] exposes it immediately.
///
/// It is guarded two ways so it can never replay WITHIN a process either:
///   1. [_revealPlayed] — a process-scoped static, `false` on every fresh
///      isolate, set `true` once the reveal completes or a notification launch
///      bypasses it. A killed process resets it; a live one keeps it.
///   2. This State's own `_done` flag survives parent rebuilds (auth changes,
///      etc.), so a mid-session rebuild of `MaterialApp.builder` can't replay it.
///
/// **Fixed duration.** The reveal always hands off after 1.5 seconds. If startup
/// data is still resolving, HomeGate's own loading/Retry UI takes over beneath;
/// the brand surface never stretches into an indeterminate loading screen.
class SplashOverlay extends StatefulWidget {
  const SplashOverlay({
    super.key,
    required this.child,
    this.skipReveal = false,
    this.playSound = true,
    this.onRevealComplete,
  });

  /// The user's startup-sound setting (You → Edit profile → This device). Off
  /// means the reveal plays silently; it never affects alarm audio.
  final bool playSound;

  /// The whole app (the app-lock gate + router) rendered beneath the reveal.
  final Widget child;

  /// A notification tap is already an explicit destination request, so a cold
  /// start must reveal that destination immediately instead of holding it
  /// behind the normal launch animation and its readiness timeout.
  final bool skipReveal;

  /// Signals that content above the app may begin presenting. This differs
  /// from merely being mounted: during the 1.5-second cold reveal the app is
  /// intentionally covered and must not consume an unseen celebration.
  final VoidCallback? onRevealComplete;

  /// Process-scoped: has the reveal already played in THIS process? Reset only by
  /// a fresh isolate, i.e. a true cold start.
  static bool _revealPlayed = false;

  /// Test hook: forget that the reveal played, so a widget test can exercise the
  /// gate deterministically regardless of test ordering.
  @visibleForTesting
  static void resetForTest() => _revealPlayed = false;

  /// The glow-heavy wordmark is a retained raster layer. Tests use this key to
  /// guard the performance property: animation may transform or reveal this
  /// layer, but must not rebuild and repaint its text shadows every frame.
  @visibleForTesting
  static const lockupBoundaryKey = ValueKey<String>('splash-lockup-boundary');

  /// The black veil whose fade-out reveals the wordmark. Tests read its opacity
  /// to guard the timing contract: the name must be revealed WITH the ting, not
  /// a beat later. See [revealBudget].
  @visibleForTesting
  static const revealVeilKey = ValueKey<String>('splash-reveal-veil');

  /// The wordmark must be essentially revealed (the veil near-transparent) within
  /// this long of the ting — which fires as the overlay mounts (t=0). This
  /// encodes "the name glows in with the strike, not a second after it."
  @visibleForTesting
  static const revealBudget = Duration(milliseconds: 400);

  /// The complete cold-start surface lasts 1.5 seconds: a 1.15-second reveal
  /// followed by a 0.35-second fade into the app. Public test hooks keep the
  /// visual contract tied to the clock ting's native 1.5-second cutoff.
  @visibleForTesting
  static const introDuration = Duration(milliseconds: 1150);

  @visibleForTesting
  static const outroDuration = Duration(milliseconds: 350);

  @override
  State<SplashOverlay> createState() => _SplashOverlayState();
}

class _SplashOverlayState extends State<SplashOverlay>
    with TickerProviderStateMixin {
  /// The emerge / bloom / settle-to-full timeline. Everything up to the steady
  /// hold on the full-opacity wordmark.
  late final AnimationController _intro;

  /// The fade of the entire reveal into the app, started when [_intro] finishes.
  late final AnimationController _outro;

  /// The reveal is finished and this widget is a pass-through to [widget.child].
  bool _done = false;
  bool _reportedComplete = false;

  void _reportComplete() {
    if (_reportedComplete) {
      return;
    }
    _reportedComplete = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.onRevealComplete?.call();
      }
    });
  }

  @override
  void initState() {
    super.initState();

    if (SplashOverlay._revealPlayed || widget.skipReveal) {
      // Warm path within a live process (or a rebuild): the reveal has already
      // played, so this is a pass-through from the first frame. Notification
      // launches take the same immediate path even on a fresh process.
      if (widget.skipReveal) SplashOverlay._revealPlayed = true;
      _done = true;
      _reportComplete();
      // Late finals must still be initialised — disposed immediately below is
      // avoided by only creating them on the cold path.
      _intro = AnimationController(
        vsync: this,
        duration: SplashOverlay.introDuration,
      );
      _outro = AnimationController(
        vsync: this,
        duration: SplashOverlay.outroDuration,
      );
      return;
    }

    _intro =
        AnimationController(vsync: this, duration: SplashOverlay.introDuration)
          ..addStatusListener((status) {
            if (status == AnimationStatus.completed) {
              _outro.forward();
            }
          });

    _outro =
        AnimationController(vsync: this, duration: SplashOverlay.outroDuration)
          ..addStatusListener((status) {
            if (status == AnimationStatus.completed) {
              SplashOverlay._revealPlayed = true;
              if (mounted) {
                setState(() => _done = true);
                _reportComplete();
              }
            }
          });

    // Ring the pendulum strike once as the black reveal mounts — before the logo.
    // Native owns the one-shot + the mute check; fire-and-forget.
    if (widget.playSound) SplashSound.instance.play();

    _intro.forward();
  }

  @override
  void didUpdateWidget(SplashOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // `getInitialMessage()` completes asynchronously after the first frame. If
    // it identifies a notification launch while the reveal is already running,
    // tear the reveal down on this parent rebuild instead of waiting for its
    // 1.5-second reveal.
    if (widget.skipReveal && !oldWidget.skipReveal && !_done) {
      SplashOverlay._revealPlayed = true;
      _intro.stop();
      _outro.stop();
      _done = true;
      _reportComplete();
    }
  }

  @override
  void dispose() {
    _intro.dispose();
    _outro.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return widget.child;

    return Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: _RevealLayer(intro: _intro, outro: _outro),
          ),
        ),
      ],
    );
  }
}

/// The visual driven directly by the two controllers.
///
/// AnimatedBuilder used to rebuild the FittedBox, IntrinsicWidth, wordmark and
/// its large blurred shadows on every tick. The lockup is now painted once into
/// a RepaintBoundary; FadeTransition and ScaleTransition update compositor
/// properties around that retained layer. A black veil reveals it during the
/// intro, which also lets the expensive glyph layer warm up while fully hidden.
class _RevealLayer extends StatelessWidget {
  const _RevealLayer({required this.intro, required this.outro});

  final Animation<double> intro;

  final Animation<double> outro;

  // --- intro phases (fractions of the 1.15s intro timeline) ---
  // The pendulum strike rings at 0.00 (black) and the wordmark glows in WITH it:
  // the reveal starts at 0.00 and resolves by ~0.14s, then holds to 1.15s. It
  // must NOT be pushed later — the name is meant to appear as the ting lands, not
  // a beat after. One smooth easeOut fade + a subtle scale, no per-frame blur
  // (the glow is baked into the text shadows), which keeps it buttery. The timing
  // contract is guarded by test/splash_test.dart 'reveal blooms with the strike'.
  static const _fadeIn = Interval(0.0, 0.12, curve: Curves.easeOutCubic);
  static const _scaleUp = Interval(0.0, 0.18, curve: Curves.easeOutCubic);

  @override
  Widget build(BuildContext context) {
    final wordReveal = CurvedAnimation(parent: intro, curve: _fadeIn);
    final introScale = Tween<double>(
      begin: 0.94,
      end: 1,
    ).animate(CurvedAnimation(parent: intro, curve: _scaleUp));
    final outroScale = Tween<double>(begin: 1, end: 1.012).animate(outro);
    final layerOpacity = Tween<double>(
      begin: 1,
      end: 0,
    ).animate(CurvedAnimation(parent: outro, curve: Curves.easeInOut));

    return FadeTransition(
      opacity: layerOpacity,
      child: ColoredBox(
        color: SplashTokens.background,
        child: Stack(
          children: [
            Center(
              child: ScaleTransition(
                scale: outroScale,
                child: ScaleTransition(
                  scale: introScale,
                  child: const RepaintBoundary(
                    key: SplashOverlay.lockupBoundaryKey,
                    child: _SplashLockup(),
                  ),
                ),
              ),
            ),
            // The static lockup is already painted underneath. Fading this
            // cheap black veil from opaque to clear produces the same bloom as
            // fading the glyphs in, without repainting their blurred shadows.
            Positioned.fill(
              child: FadeTransition(
                key: SplashOverlay.revealVeilKey,
                opacity: ReverseAnimation(wordReveal),
                child: const ColoredBox(color: SplashTokens.background),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SplashLockup extends StatelessWidget {
  const _SplashLockup();

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Padding(
        // Keeps the wordmark off the very edges when scaled to fit a narrow
        // screen. IntrinsicWidth makes both bars match the wordmark width.
        padding: const EdgeInsets.symmetric(horizontal: Space.xl),
        child: IntrinsicWidth(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: const [
              _Wordmark(color: SplashTokens.wordmark),
              SizedBox(height: Space.sm),
              _Bar(color: SplashTokens.lineTop),
              SizedBox(height: Space.xs),
              _Bar(color: SplashTokens.lineBottom),
              SizedBox(height: Space.md),
              _Tagline(),
            ],
          ),
        ),
      ),
    );
  }
}

/// One underline bar. Opacity/scale come from the shared reveal lockup above, so
/// it emerges together with the wordmark.
class _Bar extends StatelessWidget {
  const _Bar({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(height: SplashTokens.lineThickness, color: color);
  }
}

class _Wordmark extends StatelessWidget {
  const _Wordmark({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Text(
      'CHECKMATE',
      maxLines: 1,
      textAlign: TextAlign.center,
      style: SplashTokens.wordmarkStyle.copyWith(color: color),
    );
  }
}

/// The tagline under the two brand bars. Centred so it reads as a caption to the
/// wordmark, not a stretched banner.
class _Tagline extends StatelessWidget {
  const _Tagline();

  @override
  Widget build(BuildContext context) {
    return const Text(
      'Mates Always Remember',
      maxLines: 1,
      textAlign: TextAlign.center,
      style: SplashTokens.taglineStyle,
    );
  }
}
