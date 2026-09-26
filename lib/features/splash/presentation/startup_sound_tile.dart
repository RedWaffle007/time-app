import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../application/startup_sound_providers.dart';

/// "This device" switch for the startup screen's clock strike. Alarms keep
/// their sound either way, and the subtitle says so.
class StartupSoundTile extends ConsumerWidget {
  const StartupSoundTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('Startup sound'),
      subtitle: const Text(
        'Play the clock strike when Checkmate opens. Alarms always ring.',
      ),
      secondary: const Icon(AppIcons.startupSound),
      value: ref.watch(startupSoundEnabledProvider),
      onChanged: (value) =>
          ref.read(startupSoundEnabledProvider.notifier).setEnabled(value),
    );
  }
}
