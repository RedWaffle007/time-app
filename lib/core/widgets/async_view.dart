import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Renders an [AsyncValue] so a stuck listener can never present as an infinite
/// spinner. A Firestore listener can sit in `loading` forever (a query that
/// never emits data OR an error), and a bare `.when(...)` would spin silently —
/// making every backend problem look identical to "the app is broken."
///
/// Guarantees:
///  - loading shows a spinner, but after [timeout] with still no data/error it
///    flips to an actionable message + Retry;
///  - an error shows the message + Retry;
///  - an empty collection (per [isEmpty]) shows [emptyMessage] instead of a
///    blank list.
class AsyncView<T> extends StatefulWidget {
  const AsyncView({
    super.key,
    required this.value,
    required this.onRetry,
    required this.builder,
    this.isEmpty,
    this.emptyMessage = 'Nothing here yet.',
    this.timeout = const Duration(seconds: 12),
  });

  final AsyncValue<T> value;

  /// Called by the Retry button — typically `() => ref.invalidate(provider)`.
  final VoidCallback onRetry;
  final Widget Function(BuildContext context, T data) builder;

  /// Optional emptiness check for collection-shaped data.
  final bool Function(T data)? isEmpty;
  final String emptyMessage;
  final Duration timeout;

  @override
  State<AsyncView<T>> createState() => _AsyncViewState<T>();
}

class _AsyncViewState<T> extends State<AsyncView<T>> {
  Timer? _timer;
  bool _timedOut = false;

  /// Genuine first-load: loading with no prior data and no prior error.
  bool get _initialLoading =>
      widget.value.isLoading &&
      !widget.value.hasValue &&
      !widget.value.hasError;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant AsyncView<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  /// Keep the timeout timer in step with the current loading state so a healthy
  /// idle stream (which emits once, then goes quiet) never trips a false timeout.
  void _sync() {
    if (_initialLoading) {
      _timer ??= Timer(widget.timeout, () {
        if (mounted) setState(() => _timedOut = true);
      });
    } else {
      _timer?.cancel();
      _timer = null;
      _timedOut = false;
    }
  }

  void _retry() {
    _timer?.cancel();
    _timer = null;
    setState(() => _timedOut = false);
    widget.onRetry();
    _sync();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_timedOut && _initialLoading) {
      return _Retryable(
        icon: Icons.hourglass_empty,
        title: 'Taking longer than expected',
        detail:
            'Still no response. Check your connection and try again — if it '
            'keeps happening, the data may not be loading.',
        onRetry: _retry,
      );
    }
    return widget.value.when(
      skipLoadingOnReload: true,
      skipLoadingOnRefresh: true,
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _Retryable(
        icon: Icons.error_outline,
        title: 'Something went wrong',
        detail: '$e',
        onRetry: _retry,
      ),
      data: (data) {
        if (widget.isEmpty?.call(data) ?? false) {
          return _Centered(child: _Message(text: widget.emptyMessage));
        }
        return widget.builder(context, data);
      },
    );
  }
}

class _Centered extends StatelessWidget {
  const _Centered({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(padding: const EdgeInsets.all(24), child: child),
      );
}

class _Message extends StatelessWidget {
  const _Message({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) =>
      Text(text, textAlign: TextAlign.center);
}

class _Retryable extends StatelessWidget {
  const _Retryable({
    required this.icon,
    required this.title,
    required this.detail,
    required this.onRetry,
  });

  final IconData icon;
  final String title;
  final String detail;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return _Centered(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text(title,
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(detail,
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.outline)),
          const SizedBox(height: 16),
          FilledButton.tonalIcon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}
