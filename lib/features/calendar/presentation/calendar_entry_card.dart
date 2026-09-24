import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format/datetime_format.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/theme/status_style.dart';
import '../../auth/application/auth_providers.dart';
import '../application/calendar_grouping.dart';

/// One item as a row in the agenda or the day rail.
///
/// Deliberately thinner than `_OutcomeCard` / `_ActivityCard`: those two are
/// where an item is *acted on*, and they carry the buttons to prove it. This one
/// is a row in a time axis — it says what and when, and a tap opens the sheet.
/// Putting Done and Skip here as well would be a second rendering of the same
/// controls to keep in step with the first.
class CalendarEntryCard extends ConsumerWidget {
  const CalendarEntryCard({
    super.key,
    required this.entry,
    required this.onTap,
  });

  final CalendarEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = entry.item;

    // Only looked up for the planner side — on your own items the name would be
    // your own, which the row does not need to tell you.
    final forName = entry.side == CalendarSide.planned
        ? ref.watch(profileByUidProvider(item.targetUid)).value?.name
        : null;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: Space.cardPadding,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // The time in the ITEM's own zone. `formatWallTimeOfDay` takes the
              // already-resolved wall carrier, so this cannot drift from the
              // cell the row is filed under — both come from `itemWallTime()`.
              Text(
                formatWallTimeOfDay(context, entry.wallTime),
                style: context.text.labelSmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: Space.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.title, style: context.text.titleMedium),
                    if (forName != null) ...[
                      const SizedBox(height: Space.xs),
                      // Prose, so `bodySmall` — UI-RULES.md §3's prose-wins
                      // tiebreaker, the same call the Activity card makes.
                      Text(
                        'for $forName · ${item.timezone}, their local time',
                        style: context.text.bodySmall?.copyWith(
                          color: context.colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: Space.sm),
              // ONE badge: the outcome replaces the status once there is one.
              if (item.outcome != null)
                StatusBadge.itemOutcome(item, context)
              else
                StatusBadge.status(item.status, context),
            ],
          ),
        ),
      ),
    );
  }
}
