import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../application/app_lock_providers.dart';

/// The cover shown while the app is locked.
///
/// **Fully opaque, edge to edge.** It is the only thing standing between a
/// passer-by and the schedule behind it, so it uses the scaffold background
/// rather than any scrim or translucency — a see-through lock screen would
/// defeat the entire feature while looking like it worked.
///
/// It carries no navigation, no app bar and no back affordance: there is
/// nowhere to go from here except through the prompt.
class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key});

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  @override
  void initState() {
    super.initState();
    // Prompt immediately. Making the user tap "Unlock" first would add a step
    // to every single app open for no security whatsoever.
    WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  void _unlock() => ref.read(appLockControllerProvider).unlock();

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(appLockControllerProvider);

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return Material(
          color: context.colors.surface,
          child: Center(
            child: Padding(
              padding: Space.screenForm,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Structure, not state — line work in `primary`, per §2.7.
                  Icon(AppIcons.appLock,
                      size: Sizes.emptyStateIcon, color: context.colors.primary),
                  const SizedBox(height: Space.md),
                  Text('Checkmate is locked',
                      style: context.text.titleMedium,
                      textAlign: TextAlign.center),
                  const SizedBox(height: Space.sm),
                  Text(
                    'Unlock with your fingerprint, face, or device PIN.',
                    textAlign: TextAlign.center,
                    style: context.text.bodySmall
                        ?.copyWith(color: context.colors.onSurfaceVariant),
                  ),
                  const SizedBox(height: Space.lg),
                  // Shown when the OS prompt was dismissed or failed. The
                  // prompt does not reappear on its own — retrying in a loop
                  // would trap the user in a dialog they just cancelled.
                  if (controller.isAuthenticating)
                    const SizedBox(
                      height: Sizes.buttonSpinner,
                      width: Sizes.buttonSpinner,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    FilledButton.icon(
                      onPressed: _unlock,
                      icon: const Icon(AppIcons.unlock),
                      label: const Text('Unlock'),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
