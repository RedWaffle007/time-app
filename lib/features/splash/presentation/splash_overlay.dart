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

  /// Total intro duration — a true 3-second, 3-beat sequence. The hammer hits
  /// land at 0.00 / 1.00 / 2.00s (fired natively); the wordmark blooms up AFTER
  /// hit #1 (around hit #2) and holds through hits #2 and #3 to 3.00s, matching
  /// how the logo does not pop on the first beat. Phased by the `Interval`s in
  /// `_RevealPainter`.
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
    final auth = watch ? ref.watch(authStateProvider) : ref.read(authStateProvider);
    if (auth.isLoading) return false;
    if (auth.value == null) return true; // headed to /auth: nothing async to await
    final profile =
        watch ? ref.watch(profileProvider) : ref.read(profileProvider);
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
            child: AnimatedBuilder(
              animation: Listenable.merge([_intro, _outro]),
              builder: (context, _) => _RevealPainter(
                intro: _intro.value,
                outro: _outro.value,
                showWaiting: showWaiting,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The visual, given the two normalized progresses. Kept separate so all the
/// curve/interval maths lives in one place.
class _RevealPainter extends StatelessWidget {
  const _RevealPainter({
    required this.intro,
    required this.outro,
    required this.showWaiting,
  });

  /// 0→1 across [_SplashOverlayState._introDuration].
  final double intro;

  /// 0→1 across [_SplashOverlayState._outroDuration]; 0 until the outro starts.
  final double outro;

  /// Whether to show the quiet "Preparing your app…" note near the bottom.
  final bool showWaiting;

  // --- intro phases (fractions of the 3.00s intro timeline) ---
  // The pendulum strike rings at 0.00 (black); the wordmark begins to emerge at
  // ~0.55s and resolves by ~1.55s, then holds to 3.00s. One smooth easeOut fade
  // + a subtle scale — no per-frame blur (the glow is baked into the text
  // shadows), which is what keeps it buttery like the Supercell reveal.
  static const _fadeIn = Interval(0.18, 0.52, curve: Curves.easeOutCubic);
  static const _scaleUp = Interval(0.18, 0.60, curve: Curves.easeOutCubic);

  @override
  Widget build(BuildContext context) {
    // Wordmark opacity: eases up out of black, held at full through the hold
    // phase; the whole layer's fade to the app is applied by `layerOpacity`.
    final wordOpacity = _fadeIn.transform(intro);

    // Subtle scale-up as it resolves (0.94 → 1.0), then a whisper of forward
    // drift during the outro so it recedes INTO the app — the Supercell
    // "settles forward" feel. Kept small so it never reads as a zoom.
    final scale = 0.94 + 0.06 * _scaleUp.transform(intro) + 0.012 * outro;

    // The entire reveal fades out into the app during the outro.
    final layerOpacity = 1.0 - Curves.easeInOut.transform(outro);

    return Opacity(
      opacity: layerOpacity.clamp(0.0, 1.0),
      child: ColoredBox(
        color: SplashTokens.background,
        child: Stack(
          children: [
            Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Padding(
                  // Keeps the wordmark off the very edges when scaled to fit a
                  // narrow screen.
                  padding: const EdgeInsets.symmetric(horizontal: Space.xl),
                  child: Transform.scale(
                    scale: scale,
                    // IntrinsicWidth + stretch makes the two bars span exactly
                    // the wordmark's width.
                    child: IntrinsicWidth(
                      child: Opacity(
                        // One opacity on the whole lockup = one cheap compositor
                        // op per frame. The glow rides along as baked shadows.
                        opacity: wordOpacity.clamp(0.0, 1.0),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: const [
                            // Wordmark, both bars and the tagline share the ONE
                            // outer Opacity above, so they emerge together.
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
                  ),
                ),
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

/// One underline bar. Opacity/scale come from the shared reveal lockup above, so
/// it emerges together with the wordmark.
class _Bar extends StatelessWidget {
  const _Bar({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: SplashTokens.lineThickness,
      color: color,
    );
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
