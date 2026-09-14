import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../application/auth_providers.dart';

/// Sign-in screen. Google is the only provider in v1.
class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authRepositoryProvider).signInWithGoogle();
      // On success, auth state changes and the router redirects us away —
      // nothing else to do here.
    } catch (_) {
      if (mounted) setState(() => _error = 'Sign-in failed. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: Space.screenFormSafe(context),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // The only use of displaySmall in the app.
              Text('Checkmate', style: context.text.displaySmall),
              const SizedBox(height: Space.sm),
              const Text(
                'Let a trusted friend help plan your time.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: Space.xxxl),
              if (_busy)
                const CircularProgressIndicator()
              else
                FilledButton.icon(
                  onPressed: _signIn,
                  icon: const Icon(AppIcons.signIn),
                  label: const Text('Continue with Google'),
                ),
              if (_error != null) ...[
                const SizedBox(height: Space.xl),
                Text(
                  _error!,
                  // An auth failure is a real error — one of the rationed uses
                  // of red (UI-RULES.md §2.5).
                  style: context.text.bodyMedium
                      ?.copyWith(color: context.colors.error),
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
