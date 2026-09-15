import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_tokens.dart';
import '../../../core/theme/splash_tokens.dart';
import '../../auth/application/auth_providers.dart';
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
/// triggers it.
///
/// It is guarded two ways so it can never replay WITHIN a process either:
///   1. [_revealPlayed] — a process-scoped static, `false` on every fresh
///      isolate, set `true` only once the reveal fully completes. A killed
///      process resets it (a genuine cold start); a live one keeps it.
///   2. This State's own `_done` flag survives parent rebuilds (auth changes,
///      etc.), so a mid-session rebuild of `MaterialApp.builder` can't replay it.
///
/// **Hold-until-ready.** The final fade-out waits until the app is actually ready
/// (auth settled, and — when signed in — the profile stream resolved), so the
/// user never sees a boot flicker under the reveal. A [_maxHold] cap bounds that
/// wait: if the profile read stalls, the reveal fades anyway and HomeGate's own
/// loading/Retry UI takes over beneath, rather than the black holding forever.
class SplashOverlay extends ConsumerStatefulWidget {
  const SplashOverlay({super.key, required this.child});

  /// The whole app (the app-lock gate + router) rendered beneath the reveal.
  final Widget child;

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

  @override
  ConsumerState<SplashOverlay> createState() => _SplashOverlayState();
}

class _SplashOverlayState extends ConsumerState<SplashOverlay>
    with TickerProviderStateMixin {
  /// The emerge / bloom / settle-to-full timeline. Everything up to the steady
  /// hold on the full-opacity wordmark.
  late final AnimationController _intro;

  /// The fade of the entire reveal into the app. Started only once [_intro] has
  /// finished AND the app is ready (or [_maxHold] has elapsed).
  late final AnimationController _outro;

  /// The reveal is finished and this widget is a pass-through to [widget.child].
  bool _done = false;

  bool _introDone = false;
  bool _outroStarted = false;

  /// Set when [_maxHold] fires — forces the outro even if the app isn't ready,
  /// so a stalled profile read can't trap the user behind the black.
  bool _holdExpired = false;

  Timer? _holdTimer;

  /// Total intro duration. The pendulum strike rings at 0.00s (fired natively as
  /// the black reveal mounts) and the wordmark blooms in WITH it — glowing up
  /// over the first ~360ms, synchronised to the ting rather than lagging a beat
  /// behind it — then holds at full to 3.00s. Phased by the `Interval`s in
  /// `_RevealLayer`.
  static const _introDuration = Duration(milliseconds: 3000);
  static const _outroDuration = Duration(milliseconds: 550);

  /// The longest the reveal will hold (chimes ducked + loading note) waiting for
  /// the app to become ready before fading out regardless. Under HomeGate's 12s
  /// profile timeout, so its Retry surface is reachable if the read is stuck.
  static const _maxHold = Duration(seconds: 10);

  @override
  void initState() {
    super.initState();

    if (SplashOverlay._revealPlayed) {
      // Warm path within a live process (or a rebuild): the reveal has already
      // played, so this is a pass-through from the first frame.
      _done = true;
      // Late finals must still be initialised — disposed immediately below is
      // avoided by only creating them on the cold path.
      _intro = AnimationController(vsync: this, duration: _introDuration);
      _outro = AnimationController(vsync: this, duration: _outroDuration);
      return;
    }

    _intro = AnimationController(vsync: this, duration: _introDuration)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          _introDone = true;
          if (_readyNow()) {
            _maybeStartOutro(true);
          } else {
            // Still loading at the end of the reveal: hold the logo + show the
            // "App is loading…" note. A safety cap bounds the wait so a truly
            // stuck read hands off to HomeGate's own loading/Retry surface.
            _holdTimer = Timer(_maxHold, () {
              _holdExpired = true;
              if (mounted) setState(() {}); // re-evaluate the outro gate
            });
          }
        }
      });

    _outro = AnimationController(vsync: this, duration: _outroDuration)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          SplashOverlay._revealPlayed = true;
          if (mounted) setState(() => _done = true);
        }
      });

    // Ring the pendulum strike once as the black reveal mounts — before the logo.
    // Native owns the one-shot + the mute check; fire-and-forget.
    SplashSound.instance.play();

    _intro.forward();
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _intro.dispose();
    _outro.dispose();
    super.dispose();
  }

  /// True once the app has something real to show beneath the reveal: auth has
  /// settled, and if signed in, the profile stream has resolved (data OR error —
  /// an error hands off to HomeGate's Retry surface rather than holding here).
  ///
  /// WATCH version — call only from `build`, so a readiness change rebuilds the
  /// widget and re-evaluates the gate.
  bool _appReady() => _computeReady(watch: true);

  /// READ version — safe to call from listeners/callbacks outside `build`.
  bool _readyNow() => _computeReady(watch: false);

  bool _computeReady({required bool watch}) {
    final auth = watch
        ? ref.watch(authStateProvider)
        : ref.read(authStateProvider);
    if (auth.isLoading) return false;
    if (auth.value == null) {
      return true; // headed to /auth: nothing async to await
    }
    final profile = watch
        ? ref.watch(profileProvider)
        : ref.read(profileProvider);
    return !profile.isLoading;
  }

  void _maybeStartOutro(bool ready) {
    if (_outroStarted || !_introDone) return;
    if (!_holdExpired && !ready) return;
    _outroStarted = true;
    _holdTimer?.cancel();
    // Kick off after the current build/frame — this can be reached from build().
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _outro.forward();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return widget.child;

    // Re-evaluate the outro gate on every rebuild (auth/profile emissions rebuild
    // this via the ref.watch inside _appReady).
    final ready = _appReady();
    _maybeStartOutro(ready);

    // The quiet loading note appears only when the 3s reveal has finished but the
    // readiness gate is still holding (and the outro hasn't begun). The chimes
    // are already ducked to a background bed at that point.
    final showWaiting = _introDone && !_outroStarted && !ready;

    return Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: _RevealLayer(
              intro: _intro,
              outro: _outro,
              showWaiting: showWaiting,
            ),
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
  const _RevealLayer({
    required this.intro,
    required this.outro,
    required this.showWaiting,
  });

  final Animation<double> intro;

  final Animation<double> outro;

  /// Whether to show the quiet "Preparing your app…" note near the bottom.
  final bool showWaiting;

  // --- intro phases (fractions of the 3.00s intro timeline) ---
  // The pendulum strike rings at 0.00 (black) and the wordmark glows in WITH it:
  // the reveal starts at 0.00 and resolves by ~0.36s, then holds to 3.00s. It
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
            // The quiet holding note, only while the readiness gate holds past
            // the intro. AnimatedOpacity so it fades rather than pops.
            Positioned(
              left: 0,
              right: 0,
              bottom: Space.xxxl,
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: showWaiting ? 1.0 : 0.0,
                  duration: Motion.normal,
                  child: const Text(
                    'App is loading…',
                    textAlign: TextAlign.center,
                    style: SplashTokens.waitingStyle,
                  ),
                ),
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
