import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../applock/application/app_lock_providers.dart';
import '../../auth/application/auth_providers.dart';
import '../application/celebration_providers.dart';
import '../application/celebration_queue.dart';
import '../data/celebration_sound.dart';
import '../domain/completion_celebration.dart';

const completionCelebrationDuration = Duration(milliseconds: 1500);

final celebrationSoundProvider = Provider<CelebrationSound>((ref) {
  return const PlatformCelebrationSound();
});

/// App-wide overlay host. Firestore is the delivery queue, so it covers the
/// target immediately, an online planner live, and an offline planner on their
/// next unlocked foreground session with the same code path.
class CompletionCelebrationHost extends ConsumerStatefulWidget {
  const CompletionCelebrationHost({
    super.key,
    required this.child,
    this.enabled = true,
  });

  final Widget child;
  final bool enabled;

  @override
  ConsumerState<CompletionCelebrationHost> createState() =>
      _CompletionCelebrationHostState();
}

class _CompletionCelebrationHostState
    extends ConsumerState<CompletionCelebrationHost>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _queue = CompletionCelebrationQueue();
  late final AnimationController _animation;
  Timer? _finishTimer;
  bool _playing = false;
  bool _resumed = true;
  String? _sessionUid;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _resumed =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _animation = AnimationController(
      vsync: this,
      duration: completionCelebrationDuration,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    if (_resumed) {
      _scheduleStart();
    } else {
      _pauseCurrent();
    }
  }

  @override
  void didUpdateWidget(CompletionCelebrationHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled && !oldWidget.enabled) {
      _scheduleStart();
    }
    if (!widget.enabled && oldWidget.enabled) {
      _pauseCurrent();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _finishTimer?.cancel();
    _animation.dispose();
    unawaited(ref.read(celebrationSoundProvider).stop());
    super.dispose();
  }

  void _eventsChanged(List<CompletionCelebration> events) {
    _queue.addAll(events);
    _scheduleStart();
  }

  void _scheduleStart() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _startIfPossible();
      }
    });
  }

  void _startIfPossible() {
    final lock = ref.read(appLockControllerProvider);
    if (_playing ||
        !widget.enabled ||
        !_resumed ||
        lock.isLocked ||
        _sessionUid == null) {
      return;
    }
    final event = _queue.takeNext();
    if (event == null) {
      return;
    }
    _playing = true;
    _animation.forward(from: 0);
    unawaited(ref.read(celebrationSoundProvider).play());
    setState(() {});
    _finishTimer = Timer(completionCelebrationDuration, () async {
      if (!mounted || !_playing) {
        return;
      }
      _playing = false;
      _animation.reset();
      unawaited(ref.read(celebrationSoundProvider).stop());
      setState(() {});
      final uid = _sessionUid;
      if (uid != null) {
        try {
          await ref
              .read(completionCelebrationRepositoryProvider)
              .acknowledge(event, uid);
        } catch (_) {
          // Leave the event unseen so the next app session retries it.
        }
      }
      _queue.complete(event.id);
      _scheduleStart();
    });
  }

  void _pauseCurrent({bool notify = true}) {
    if (!_playing) {
      return;
    }
    _finishTimer?.cancel();
    _playing = false;
    _animation.reset();
    unawaited(ref.read(celebrationSoundProvider).stop());
    if (notify && mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = ref.watch(currentUidProvider);
    if (_sessionUid != uid) {
      _sessionUid = uid;
      _queue.clear();
      _finishTimer?.cancel();
      _playing = false;
      _animation.reset();
      unawaited(ref.read(celebrationSoundProvider).stop());
    }
    ref.listen(unseenCompletionCelebrationsProvider, (_, next) {
      final events = next.value;
      if (events != null) {
        _eventsChanged(events);
      }
    });
    final lock = ref.watch(appLockControllerProvider);
    return ListenableBuilder(
      listenable: lock,
      builder: (context, _) {
        if (lock.isLocked) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _pauseCurrent();
          });
        } else {
          _scheduleStart();
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            widget.child,
            if (_playing)
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedBuilder(
                    animation: _animation,
                    builder: (_, _) => CustomPaint(
                      painter: _ColoredPaperPainter(_animation.value),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ColoredPaperPainter extends CustomPainter {
  const _ColoredPaperPainter(this.progress);

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final origin = Offset(size.width / 2, size.height * 0.38);
    for (var i = 0; i < 72; i++) {
      final delay = (i % 9) * 0.018;
      final p = ((progress - delay) / (1 - delay)).clamp(0.0, 1.0);
      if (p <= 0) {
        continue;
      }
      final seed = (i * 37 % 101) / 101;
      final angle = -math.pi * (0.08 + seed * 0.84);
      final speed = 0.35 + ((i * 19 % 47) / 47) * 0.55;
      final x = origin.dx + math.cos(angle) * speed * size.width * p;
      final y =
          origin.dy +
          math.sin(angle) * speed * size.height * 0.62 * p +
          size.height * 0.72 * p * p;
      final opacity = ((1 - p) / 0.22).clamp(0.0, 1.0);
      final paint = Paint()
        ..color = AppColors
            .completionCelebrationPaper[i %
                AppColors.completionCelebrationPaper.length]
            .withValues(alpha: opacity);
      final width = 5.0 + (i % 4) * 1.8;
      final height = 10.0 + (i % 5) * 2.2;
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(p * math.pi * (2 + i % 4) + seed * math.pi);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: width, height: height),
          const Radius.circular(1.5),
        ),
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ColoredPaperPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
