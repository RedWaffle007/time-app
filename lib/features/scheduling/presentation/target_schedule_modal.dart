import 'dart:ui';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format/datetime_format.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/theme/status_style.dart';
import '../../../core/widgets/async_view.dart';
import '../../auth/application/auth_providers.dart';
import '../application/slot_availability.dart';
import '../application/target_schedule_providers.dart';
import '../domain/schedule_item.dart';

/// What the planner chose: the instant, plus the slot it belongs to.
class SlotChoice {
  const SlotChoice({required this.startUtc, required this.slotIndex});
  final DateTime startUtc;
  final int slotIndex;
}

/// **The "view B's schedule" modal** (UI-RULES.md §6.11).
///
/// Opens over the schedule builder so a planner can see what the target already
/// has planned before choosing a time. Existing items are context, not blockers:
/// schedule items are point alarms and have no duration.
///
/// **A function, not a route** — like every other dialog and sheet here. It is
/// transient state inside a form, not a location: a shared link or a rotation
/// should not restore someone into a modal over a builder with no target
/// selected. (DECISIONS.md → "View B's schedule modal + slot conflicts".)
///
/// Returns the chosen slot, or null if dismissed.
Future<SlotChoice?> showTargetScheduleModal(
  BuildContext context, {
  required String targetUid,
  required String targetName,
  required String targetTimezone,
  required DateTime initialLocalDay,
}) {
  return showGeneralDialog<SlotChoice>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    // Blur PLUS a scrim, never blur alone: blurring lowers contrast without
    // raising it anywhere, so on its own the §7 floor would depend on whatever
    // happened to be behind the modal (UI-RULES.md §6.11).
    barrierColor: context.colors.scrim.withValues(alpha: 0.4),
    transitionDuration: Motion.normal,
    pageBuilder: (context, _, _) => const SizedBox.shrink(),
    transitionBuilder: (context, animation, _, _) {
      final t = Curves.easeOutCubic.transform(animation.value);
      return BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: Blurs.modalBackdrop * t,
          sigmaY: Blurs.modalBackdrop * t,
        ),
        child: Opacity(
          opacity: t,
          child: _TargetScheduleModal(
            targetUid: targetUid,
            targetName: targetName,
            targetTimezone: targetTimezone,
            initialLocalDay: initialLocalDay,
          ),
        ),
      );
    },
  );
}

class _TargetScheduleModal extends ConsumerStatefulWidget {
  const _TargetScheduleModal({
    required this.targetUid,
    required this.targetName,
    required this.targetTimezone,
    required this.initialLocalDay,
  });

  final String targetUid;
  final String targetName;
  final String targetTimezone;
  final DateTime initialLocalDay;

  @override
  ConsumerState<_TargetScheduleModal> createState() =>
      _TargetScheduleModalState();
}

class _TargetScheduleModalState extends ConsumerState<_TargetScheduleModal> {
  late DateTime _day;

  @override
  void initState() {
    super.initState();
    _day = widget.initialLocalDay;
  }

  void _shiftDay(int days) =>
      setState(() => _day = _day.add(Duration(days: days)));

  @override
  Widget build(BuildContext context) {
    final itemsAsync = ref.watch(targetScheduleProvider(widget.targetUid));
    final media = MediaQuery.of(context);

    return Center(
      child: Padding(
        padding: Space.screenList,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: Sizes.modalMaxWidth,
            maxHeight: media.size.height * Sizes.modalMaxHeightFraction,
          ),
          child: Material(
            color: context.colors.surface,
            borderRadius: Radii.lg,
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _header(context),
                Divider(
                  height: Sizes.hairline,
                  color: context.colors.outlineVariant,
                ),
                Flexible(
                  // A `permission-denied` here is not a fault to retry — it is
                  // the expected two-device state: the target has a live grant
                  // but has never opened the app online since, so their
                  // `plannerAccess/{me}_{target}` mirror row does not exist yet
                  // and the rules deny the read. Show a plain, actionable
                  // message instead of the raw exception + Retry, which would
                  // never succeed until THEY act. Every other error still falls
                  // through to AsyncView. (DECISIONS.md → "View B's schedule
                  // modal + slot conflicts", plannerAccess mirror.)
                  child: _isAccessNotReady(itemsAsync.error)
                      ? _accessPending(context)
                      : AsyncView<List<ScheduleItem>>(
                          value: itemsAsync,
                          onRetry: () => ref.invalidate(
                            targetScheduleProvider(widget.targetUid),
                          ),
                          builder: (context, items) =>
                              _slotList(context, items),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Space.lg,
        Space.md,
        Space.sm,
        Space.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  "${widget.targetName}'s schedule",
                  style: context.text.titleMedium,
                ),
              ),
              IconButton(
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                icon: const Icon(AppIcons.rejected),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: Space.xs),
          Row(
            children: [
              IconButton(
                tooltip: 'Previous day',
                icon: const Icon(AppIcons.previousPeriod),
                onPressed: () => _shiftDay(-1),
              ),
              Expanded(
                child: Text(
                  formatDayHeadingShort(context, _day),
                  textAlign: TextAlign.center,
                  style: context.text.bodyMedium,
                ),
              ),
              IconButton(
                tooltip: 'Next day',
                icon: const Icon(AppIcons.nextPeriod),
                onPressed: () => _shiftDay(1),
              ),
            ],
          ),
          // Whose clock this is. Never omitted — "4pm" without a zone is the
          // exact confusion this modal exists to prevent (UI-RULES.md §6.11).
          Row(
            children: [
              Icon(
                AppIcons.timezone,
                size: Sizes.inlineIcon,
                color: context.colors.onSurfaceVariant,
              ),
              const SizedBox(width: Space.sm),
              Expanded(
                child: Text(
                  'Times below are ${widget.targetName}\'s local time '
                  '(${widget.targetTimezone}).',
                  style: context.text.bodySmall?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// True when the schedule read failed *only* because the target has not yet
  /// published their `plannerAccess` mirror row (the two-device sync gap), not
  /// for any other reason.
  bool _isAccessNotReady(Object? error) =>
      error is FirebaseException && error.code == 'permission-denied';

  /// The friendly stand-in for a raw permission error: the grant is real, the
  /// mirror just has not synced. Matches the §6.5 empty-state recipe.
  Widget _accessPending(BuildContext context) {
    return Center(
      child: Padding(
        padding: Space.screenForm,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              AppIcons.pending,
              size: Sizes.emptyStateIcon,
              color: context.colors.onSurfaceVariant,
            ),
            const SizedBox(height: Space.md),
            Text(
              "Can't load their schedule yet",
              style: context.text.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Space.sm),
            Text(
              'Ask ${widget.targetName} to open the app once so their '
              'schedule can sync, then reopen this.',
              textAlign: TextAlign.center,
              style: context.text.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _slotList(BuildContext context, List<ScheduleItem> items) {
    final slots = slotsForLocalDay(
      localDay: _day,
      timezone: widget.targetTimezone,
      items: items,
      now: DateTime.now().toUtc(),
    );
    final hint = nextFreeSlot(slots);

    return ListView(
      padding: const EdgeInsets.only(bottom: Space.lg),
      children: [
        if (hint != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, 0),
            child: Text(
              'Next available: '
              '${formatInstantTime(context, hint.startUtc, widget.targetTimezone)}',
              style: context.text.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
          ),
        for (final slot in slots)
          _SlotRow(
            slot: slot,
            timezone: widget.targetTimezone,
            onTap: slot.isSelectable
                ? () => Navigator.of(context).pop(
                    SlotChoice(startUtc: slot.startUtc, slotIndex: slot.index),
                  )
                : null,
          ),
      ],
    );
  }
}

/// One half-hour.
///
/// Existing items remain visible, but only elapsed time disables a row.
class _SlotRow extends ConsumerWidget {
  const _SlotRow({
    required this.slot,
    required this.timezone,
    required this.onTap,
  });

  final TargetSlot slot;
  final String timezone;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final occupant = slot.occupants.isEmpty ? null : slot.occupants.first;

    // The planner's own equivalent, only when the two zones actually differ —
    // repeating the same clock twice would be noise.
    final myZone = ref.watch(profileProvider).value?.homeTimezone;
    final showMine = myZone != null && myZone != timezone;

    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: Sizes.slotRowHeight),
        padding: const EdgeInsets.symmetric(
          horizontal: Space.lg,
          vertical: Space.sm,
        ),
        child: Row(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  formatInstantTime(context, slot.startUtc, timezone),
                  style: context.text.bodyMedium?.copyWith(
                    color: slot.isSelectable
                        ? context.colors.onSurface
                        : context.colors.onSurfaceVariant,
                  ),
                ),
                if (showMine)
                  Text(
                    '${formatInstantTime(context, slot.startUtc, myZone)} yours',
                    style: context.text.labelSmall?.copyWith(
                      color: context.colors.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            const SizedBox(width: Space.lg),
            Expanded(
              child: occupant != null
                  // A real item owns this half-hour, so it is drawn with the ONE
                  // status mapping — the planner can see what it is, which is
                  // what the grant entitles them to.
                  ? Text(
                      slot.occupants.length == 1
                          ? occupant.title
                          : '${occupant.title} +${slot.occupants.length - 1} more',
                      style: context.text.bodyMedium,
                      overflow: TextOverflow.ellipsis,
                    )
                  // Merely unselectable (already begun) is line work and
                  // onSurfaceVariant, never a status colour — nothing is waiting
                  // on anyone here (UI-RULES.md §6.11).
                  : Text(
                      slot.isPast ? 'Past' : 'Free',
                      style: context.text.bodySmall?.copyWith(
                        color: context.colors.onSurfaceVariant,
                      ),
                    ),
            ),
            if (occupant != null) ...[
              const SizedBox(width: Space.sm),
              StatusBadge.status(occupant.status, context),
            ],
          ],
        ),
      ),
    );
  }
}
