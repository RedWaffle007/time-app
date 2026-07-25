import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';

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
    this.emptyIcon = Icons.inbox_outlined,
    this.timeout = const Duration(seconds: 12),
  });

  final AsyncValue<T> value;

  /// Called by the Retry button — typically `() => ref.invalidate(provider)`.
  final VoidCallback onRetry;
  final Widget Function(BuildContext context, T data) builder;

  /// Optional emptiness check for collection-shaped data.
  final bool Function(T data)? isEmpty;
  final String emptyMessage;

  /// Icon for the empty state (UI-RULES.md §6.5). Screens should pass one that
  /// fits what is missing; the default is a neutral inbox.
  final IconData emptyIcon;

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
          return _Centered(
            child: _Empty(icon: widget.emptyIcon, message: widget.emptyMessage),
          );
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
        child: Padding(padding: Space.screenForm, child: child),
      );
}

/// The empty-state recipe (UI-RULES.md §6.5).
///
/// Until 2026-07-25 the empty state was bare centred text — §6.5 was written
/// but never actually implemented for the empty case; the only icon in this
/// file lived in [_Retryable], which is the *error* state.
///
/// The icon is `primary`: an empty state is a resting state, not a failure, so
/// green is honest there. STRUCTURE, not state — it is line work, so the
/// firewall in §2.7 holds. [_Retryable] deliberately does **not** get this
/// treatment: green means action and affirmation, and a failure is neither.
class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon,
            size: Sizes.emptyStateIcon, color: context.colors.primary),
        const SizedBox(height: Space.md),
        Text(message,
            style: context.text.titleMedium, textAlign: TextAlign.center),
      ],
    );
  }
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
          // The empty-state recipe, UI-RULES.md §6.5. Both the icon and the
          // detail text use onSurfaceVariant: `outline` is a border role and
          // measures 3.65:1 (light) / 3.89:1 (dark) as text, under AA. This
          // widget was the audit's one live instance of that bug.
          Icon(icon,
              size: Sizes.emptyStateIcon,
              color: context.colors.onSurfaceVariant),
          const SizedBox(height: Space.md),
          Text(title, style: context.text.titleMedium, textAlign: TextAlign.center),
          const SizedBox(height: Space.sm),
          Text(detail,
              textAlign: TextAlign.center,
              style: context.text.bodySmall
                  ?.copyWith(color: context.colors.onSurfaceVariant)),
          const SizedBox(height: Space.lg),
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
