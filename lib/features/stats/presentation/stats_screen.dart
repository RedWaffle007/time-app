import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/section_header.dart';
import '../../social/application/stats_providers.dart';
import '../../social/application/stats_registry.dart';
import '../../social/domain/profile_stat.dart';
import '../../social/presentation/stats_section.dart';

/// **The Stats pillar — the signed-in user's own computed dashboard.**
class StatsScreen extends ConsumerWidget {
  const StatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final computed = ref.watch(myComputedStatsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Stats')),
      body: ListView(
        padding: Space.screenList,
        children: [
          const SectionHeader('Your numbers'),
          Text(
            'Your activity across planning, follow-through and tracked time.',
            style: context.text.bodySmall?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Space.md),
          computed.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) => Text(
              'Stats are unavailable right now.',
              style: context.text.bodySmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
            data: (values) => StatsGrid(
              stats: statsFromSnapshot(ProfileStatsSnapshot(values: values)),
            ),
          ),
        ],
      ),
    );
  }
}
