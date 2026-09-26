import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../../core/format/datetime_format.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/timezone/tz_resolver.dart';
import '../../../core/widgets/async_view.dart';
import '../../../core/widgets/section_header.dart';
import '../../../routing/app_router.dart';
import '../../auth/application/auth_providers.dart';
import '../../notifications/application/friend_notifier.dart';
import '../../notifications/application/outcome_notifier.dart';
import '../../scheduling/application/schedule_clash.dart';
import '../../scheduling/application/schedule_providers.dart';
import '../../social/application/social_providers.dart';
import '../../social/presentation/avatar_image.dart';
import '../application/plan_request_providers.dart';
import '../domain/plan_request.dart';

/// **Request Plan** (Batch G item 5, DECISIONS.md "Request Plan redesign"):
/// ask ONE friend to plan a reminder for something you might forget — when you
/// need it (your own zone), what it is, and an optional note. The friend is
/// pushed at once and reminded until they actually set it.
class CreatePlanRequestScreen extends ConsumerStatefulWidget {
  const CreatePlanRequestScreen({super.key});

  @override
  ConsumerState<CreatePlanRequestScreen> createState() =>
      _CreatePlanRequestScreenState();
}

class _CreatePlanRequestScreenState
    extends ConsumerState<CreatePlanRequestScreen> {
  final _task = TextEditingController();
  final _note = TextEditingController();
  String? _friendUid;
  DateTime? _date;
  TimeOfDay? _time;
  bool _taskError = false;
  bool _saving = false;

  /// Item 4: your own minute must be free — the friend's plan could not land.
  String? _clashKey;
  bool _clashBlocked = false;

  @override
  void dispose() {
    _task.dispose();
    _note.dispose();
    super.dispose();
  }

  DateTime _nowIn(String? zone) {
    if (zone != null && zone.isNotEmpty) return wallNowIn(zone);
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day, now.hour, now.minute);
  }

  Future<void> _pickDate(String? zone) async {
    final now = _nowIn(zone);
    final today = DateTime(now.year, now.month, now.day);
    final value = await showDatePicker(
      context: context,
      initialDate: _date ?? today,
      currentDate: today,
      firstDate: today,
      lastDate: today.add(const Duration(days: 365)),
    );
    if (value != null) setState(() => _date = value);
  }

  Future<void> _pickTime(String? zone) async {
    final now = _nowIn(zone);
    final value = await showTimePicker(
      context: context,
      initialTime: _time ?? TimeOfDay(hour: now.hour, minute: now.minute),
    );
    if (value != null) setState(() => _time = value);
  }

  DateTime _wall() => DateTime.utc(
    _date!.year,
    _date!.month,
    _date!.day,
    _time!.hour,
    _time!.minute,
  );

  bool get _canSend =>
      _friendUid != null &&
      _date != null &&
      _time != null &&
      !_saving &&
      !_clashBlocked;

  Future<void> _checkClash(String key, String uid, DateTime instantUtc) async {
    final result = await ref
        .read(scheduleClashCheckerProvider)
        .check(targetUid: uid, instantUtc: instantUtc);
    if (mounted && _clashKey == key) {
      setState(() => _clashBlocked = result == ClashResult.clash);
    }
  }

  Future<void> _send(String uid, String timezone) async {
    final task = _task.text.trim();
    setState(() => _taskError = task.isEmpty);
    if (task.isEmpty || !_canSend) return;
    final instant = resolveWallTimeToUtc(_wall(), timezone);
    if (!instant.isAfter(DateTime.now().toUtc())) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('That time has already passed. Pick a later time.'),
        ),
      );
      return;
    }
    final friendUid = _friendUid!;
    final friendName =
        ref.read(profileByUidProvider(friendUid)).value?.name ?? 'your friend';
    final notifier = ref.read(friendEventNotifierProvider);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      final requestId = await ref
          .read(planRequestRepositoryProvider)
          .createRequest(
            requesterUid: uid,
            plannerUid: friendUid,
            timezone: timezone,
            instantUtc: instant,
            task: task,
            note: _note.text,
          );
      // The instant push; reminders follow from the Worker until they plan it.
      unawaited(
        notifier.notify(
          event: FriendNotifyEvent.planRequested,
          fromUid: uid,
          toUid: friendUid,
          planRequestId: requestId,
        ),
      );
      messenger.showSnackBar(
        SnackBar(content: Text('Request sent to $friendName.')),
      );
      if (mounted) context.pop();
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not send the request. $error')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = ref.watch(currentUidProvider);
    final profile = ref.watch(profileProvider).value;
    final zone = profile?.homeTimezone;
    final friendsAsync = ref.watch(myFriendUidsProvider);

    if (uid != null &&
        zone != null &&
        zone.isNotEmpty &&
        _date != null &&
        _time != null) {
      final instant = resolveWallTimeToUtc(_wall(), zone);
      final key = '$uid|${instant.millisecondsSinceEpoch}';
      if (key != _clashKey) {
        _clashKey = key;
        _clashBlocked = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _checkClash(key, uid, instant);
        });
      }
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Request a plan')),
      body: AsyncView(
        value: friendsAsync,
        onRetry: () => ref.invalidate(myFriendshipsProvider),
        builder: (context, friends) {
          if (uid == null || profile == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return ListView(
            padding: Space.screenListSafe(context),
            children: [
              const SectionHeader('Ask one friend'),
              if (friends.isEmpty)
                Text(
                  'Add a friend first — any friend can plan for you.',
                  style: context.text.bodyMedium?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                )
              else
                RadioGroup<String>(
                  groupValue: _friendUid,
                  onChanged: (value) => setState(() => _friendUid = value),
                  child: Column(
                    children: [
                      for (final friendUid in friends)
                        _FriendChoice(uid: friendUid),
                    ],
                  ),
                ),
              const SectionHeader('When do you need the reminder?'),
              Text(
                'In your local time — $zone.',
                style: context.text.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: Space.sm),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const ValueKey('request-date'),
                      onPressed: () => _pickDate(zone),
                      icon: const Icon(AppIcons.date),
                      label: Text(
                        _date == null
                            ? 'Pick date'
                            : formatWallDate(context, _date!),
                      ),
                    ),
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const ValueKey('request-time'),
                      onPressed: () => _pickTime(zone),
                      icon: const Icon(AppIcons.time),
                      label: Text(
                        _time == null
                            ? 'Pick time'
                            : formatTimeOfDay(context, _time!),
                      ),
                    ),
                  ),
                ],
              ),
              if (_clashBlocked)
                _RequestError(
                  'You already have a plan scheduled for this time. '
                  'Please select a different time.',
                ),
              const SizedBox(height: Space.xl),
              TextField(
                key: const ValueKey('request-task'),
                controller: _task,
                maxLength: 200,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Task for which you need a reminder',
                ),
                onChanged: (_) {
                  if (_taskError) setState(() => _taskError = false);
                },
              ),
              if (_taskError)
                const _RequestError('Please write the task. It is mandatory.'),
              const SizedBox(height: Space.md),
              TextField(
                key: const ValueKey('request-note'),
                controller: _note,
                maxLength: 500,
                maxLines: 3,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Note (optional)'),
              ),
              const SizedBox(height: Space.xl),
              FilledButton.icon(
                key: const ValueKey('request-send'),
                onPressed: _canSend && zone != null && zone.isNotEmpty
                    ? () => _send(uid, zone)
                    : null,
                icon: const Icon(AppIcons.send),
                label: Text(_saving ? 'Sending…' : 'Send'),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _RequestError extends StatelessWidget {
  const _RequestError(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: Space.sm),
    child: Text(
      message,
      key: ValueKey('error-$message'),
      style: context.text.bodySmall?.copyWith(color: context.colors.error),
    ),
  );
}

class _FriendChoice extends ConsumerWidget {
  const _FriendChoice({required this.uid});

  final String uid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileByUidProvider(uid)).value;
    return Card(
      child: RadioListTile<String>(
        key: ValueKey('request-friend-$uid'),
        value: uid,
        secondary: AvatarImage(profile: profile, size: Sizes.avatarRow),
        title: Text(profile?.name ?? 'Loading…'),
      ),
    );
  }
}

class PlanRequestsScreen extends ConsumerWidget {
  const PlanRequestsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final incoming = ref.watch(incomingPlanRequestsProvider);
    final outgoing = ref.watch(outgoingPlanRequestsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Plan requests')),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'planRequestsListFab',
        onPressed: () => context.push(Routes.newPlanRequest),
        icon: const Icon(AppIcons.add),
        label: const Text('Request'),
      ),
      body: AsyncView<List<PlanRequest>>(
        value: incoming,
        onRetry: () => ref.invalidate(incomingPlanRequestsProvider),
        builder: (context, received) {
          final sent = outgoing.value ?? const <PlanRequest>[];
          if (received.isEmpty && sent.isEmpty) {
            return const Center(child: Text('No plan requests yet.'));
          }
          return ListView(
            padding: Space.screenListSafe(context),
            children: [
              if (received.isNotEmpty) ...[
                const SectionHeader('Waiting on you', attention: true),
                for (final request in received)
                  _PlanRequestCard(request: request, incoming: true),
              ],
              if (sent.isNotEmpty) ...[
                const SectionHeader('Sent'),
                for (final request in sent)
                  _PlanRequestCard(request: request, incoming: false),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _PlanRequestCard extends ConsumerWidget {
  const _PlanRequestCard({required this.request, required this.incoming});

  final PlanRequest request;
  final bool incoming;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final otherUid = incoming ? request.requesterUid : request.plannerUid;
    final profile = ref.watch(profileByUidProvider(otherUid)).value;
    final title = request.title?.trim();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title?.isNotEmpty == true ? title! : 'Plan request',
              style: context.text.titleMedium,
            ),
            const SizedBox(height: Space.xs),
            Text(
              '${incoming ? 'From' : 'To'} ${profile?.name ?? 'friend'} · '
              '${formatInstant(context, request.windowStartUtc, request.timezone)}'
              '${request.durationMinutes <= 1 ? '' : ' – ${formatInstant(context, request.windowEndUtc, request.timezone)}'}',
              style: context.text.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
            if (request.message?.isNotEmpty ?? false) ...[
              const SizedBox(height: Space.sm),
              Text(request.message!),
            ],
            const SizedBox(height: Space.md),
            if (incoming)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => ref
                          .read(planRequestRepositoryProvider)
                          .decline(request),
                      child: const Text('Decline'),
                    ),
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => context.push(
                        Routes.fulfillPlanRequestFor(request.id),
                      ),
                      child: const Text('View'),
                    ),
                  ),
                ],
              )
            else if (request.isOpen)
              OutlinedButton(
                onPressed: () =>
                    ref.read(planRequestRepositoryProvider).cancel(request),
                child: const Text('Cancel request'),
              )
            else
              Text(request.status.name, style: context.text.labelMedium),
          ],
        ),
      ),
    );
  }
}

/// A friend's request, seen by the friend asked (Batch G item 5): who, what,
/// when (in THEIR zone), the note, and one action — **Set the alarm** — which
/// creates the plan at exactly that minute and completes the request. Opening
/// this screen does not stop the reminders; setting the alarm does.
class FulfillPlanRequestScreen extends ConsumerStatefulWidget {
  const FulfillPlanRequestScreen({required this.requestId, super.key});

  final String requestId;

  @override
  ConsumerState<FulfillPlanRequestScreen> createState() =>
      _FulfillPlanRequestScreenState();
}

class _FulfillPlanRequestScreenState
    extends ConsumerState<FulfillPlanRequestScreen> {
  bool _saving = false;
  String? _error;

  Future<void> _setAlarm(PlanRequest request, String requesterName) async {
    final uid = ref.read(currentUidProvider);
    if (uid == null || _saving) return;
    final local = tz.TZDateTime.from(
      request.windowStartUtc,
      tz.getLocation(request.timezone),
    );
    final wall = DateTime.utc(
      local.year,
      local.month,
      local.day,
      local.hour,
      local.minute,
    );
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final itemId = await ref
          .read(planRequestRepositoryProvider)
          .fulfill(
            request: request,
            plannerUid: uid,
            title: (request.title ?? '').trim().isEmpty
                ? 'Reminder'
                : request.title!,
            note: request.message,
            wall: wall,
            durationMinutes: request.durationMinutes,
            finishFlexibleRequest: true,
          );
      unawaited(
        ref
            .read(notificationEventNotifierProvider)
            .notifyConfirmed(
              event: NotifyEvent.created,
              targetUid: request.requesterUid,
              itemId: itemId,
            ),
      );
      messenger.showSnackBar(
        SnackBar(content: Text('Alarm set for $requesterName.')),
      );
      if (mounted) context.pop();
    } catch (error) {
      // Refused? Most likely they already have a plan at that minute (item 4).
      String? holder;
      try {
        holder = await ref
            .read(scheduleRepositoryProvider)
            .minuteLockHolder(request.requesterUid, request.windowStartUtc);
      } catch (_) {}
      if (mounted) {
        setState(
          () => _error = holder != null
              ? '$requesterName already has a plan scheduled for this time, '
                    'so this alarm can’t be set.'
              : 'Could not set the alarm. $error',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final value = ref.watch(planRequestProvider(widget.requestId));
    return Scaffold(
      appBar: AppBar(title: const Text('Plan request')),
      body: AsyncView<PlanRequest?>(
        value: value,
        onRetry: () => ref.invalidate(planRequestProvider(widget.requestId)),
        isEmpty: (request) => request == null,
        emptyMessage: 'This request is no longer available.',
        builder: (context, request) {
          final live = request!;
          final requester = ref
              .watch(profileByUidProvider(live.requesterUid))
              .value;
          final name = requester?.name ?? 'Your friend';
          final task = (live.title ?? '').trim();
          final note = (live.message ?? '').trim();
          return ListView(
            padding: Space.screenListSafe(context),
            children: [
              Text(
                '$name has requested you to plan for them.',
                style: context.text.titleMedium,
              ),
              const SizedBox(height: Space.lg),
              _Detail(label: 'Task', value: task.isEmpty ? '—' : task),
              _Detail(
                label: 'When',
                value:
                    '${formatInstant(context, live.windowStartUtc, live.timezone)}'
                    ' (${live.timezone})',
              ),
              if (note.isNotEmpty) _Detail(label: 'Note', value: note),
              const SizedBox(height: Space.xl),
              if (_error != null) ...[
                _RequestError(_error!),
                const SizedBox(height: Space.md),
              ],
              if (live.isOpen) ...[
                FilledButton.icon(
                  key: const ValueKey('request-set-alarm'),
                  onPressed: _saving ? null : () => _setAlarm(live, name),
                  icon: const Icon(AppIcons.navPlan),
                  label: Text(_saving ? 'Setting…' : 'Set the alarm'),
                ),
                const SizedBox(height: Space.sm),
                OutlinedButton(
                  key: const ValueKey('request-decline'),
                  onPressed: _saving
                      ? null
                      : () async {
                          await ref
                              .read(planRequestRepositoryProvider)
                              .decline(live);
                          if (context.mounted) context.pop();
                        },
                  child: const Text('Decline'),
                ),
              ] else
                Text(switch (live.status) {
                  PlanRequestStatus.fulfilled => 'The alarm is set.',
                  PlanRequestStatus.declined => 'You declined this request.',
                  PlanRequestStatus.cancelled => 'They cancelled this request.',
                  _ => '',
                }, style: context.text.bodyMedium),
            ],
          );
        },
      ),
    );
  }
}

class _Detail extends StatelessWidget {
  const _Detail({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: Space.md),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: context.text.labelMedium?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: Space.xs),
        Text(value, style: context.text.bodyLarge),
      ],
    ),
  );
}
