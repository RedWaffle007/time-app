import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../applock/application/app_lock_providers.dart';
import '../../auth/application/auth_providers.dart';
import '../application/celebration_providers.dart';
import '../application/celebration_queue.dart';
import '../domain/completion_celebration.dart';
import 'completion_confetti.dart';

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
  late CompletionConfettiBurst _burst;
  bool _playing = false;
  bool _paused = false;
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
    )..addStatusListener(_animationStatusChanged);
    _burst = CompletionConfettiBurst.seeded(0);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    if (_resumed) {
      _resumeCurrent();
    } else {
      _pauseCurrent();
    }
  }

  @override
  void didUpdateWidget(CompletionCelebrationHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled && !oldWidget.enabled) {
      _resumeCurrent();
    }
    if (!widget.enabled && oldWidget.enabled) {
      _pauseCurrent();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _animation.dispose();
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
    _paused = false;
    _burst = CompletionConfettiBurst.seeded(
      CompletionConfettiBurst.seedForEvent(event.id),
    );
    _animation.forward(from: 0);
    setState(() {});
  }

  void _pauseCurrent({bool notify = true}) {
    if (!_playing || _paused) {
      return;
    }
    _animation.stop(canceled: false);
    _paused = true;
    if (notify && mounted) {
      setState(() {});
    }
  }

  void _resumeCurrent() {
    final lock = ref.read(appLockControllerProvider);
    if (!widget.enabled || !_resumed || lock.isLocked) return;
    if (!_playing || !_paused) {
      _scheduleStart();
      return;
    }
    final event = _queue.current;
    if (event == null) return;
    _paused = false;
    _animation.forward();
  }

  void _animationStatusChanged(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    final event = _queue.current;
    if (event != null) _finish(event);
  }

  void _finish(CompletionCelebration event) {
    if (!mounted || !_playing || _queue.current?.id != event.id) return;
    _playing = false;
    _paused = false;
    _animation.reset();
    _queue.complete(event.id);
    setState(() {});
    _scheduleStart();

    final uid = _sessionUid;
    if (uid != null) {
      // Delivery acknowledgement must not block the next queued visual.
      unawaited(
        ref
            .read(completionCelebrationRepositoryProvider)
            .acknowledge(event, uid)
            .catchError((_) {}),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = ref.watch(currentUidProvider);
    if (_sessionUid != uid) {
      _sessionUid = uid;
      _queue.clear();
      _playing = false;
      _paused = false;
      _animation.reset();
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
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _resumeCurrent();
          });
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            widget.child,
            if (_playing)
              Positioned.fill(
                key: ValueKey('completion-celebration-${_queue.current?.id}'),
                child: IgnorePointer(
                  child: AnimatedBuilder(
                    animation: _animation,
                    builder: (_, _) => CompletionConfetti(
                      progress: _animation.value,
                      burst: _burst,
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
