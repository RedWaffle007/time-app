import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/format/datetime_format.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/timezone/tz_resolver.dart';
import '../../../core/widgets/async_view.dart';
import '../../../core/widgets/section_header.dart';
import '../../../core/widgets/tab_body_inset.dart';
import '../../../routing/app_router.dart';
import '../../auth/application/auth_providers.dart';
import '../../notifications/application/friend_notifier.dart';
import '../../scheduling/application/schedule_clash.dart';
import '../../scheduling/presentation/schedule_builder_screen.dart';
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
                  'Add a friend first. Any friend can plan for you.',
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
                'In your local time: $zone.',
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
      // The Request pillar's create action (item 8), bottom-LEFT like PLAN
      // (UI-RULES §6.12).
      floatingActionButtonLocation: FloatingActionButtonLocation.startFloat,
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('request-plan-fab'),
        heroTag: 'planRequestsListFab',
        tooltip: 'Ask a friend to plan a reminder',
        onPressed: () => context.push(Routes.newPlanRequest),
        label: const Text('REQUEST PLAN'),
      ),
      // A main-tab body since item 8: the shared tab gutter (UI-RULES §4).
      body: TabBodyInset(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _RequestsHeader(),
            Expanded(
              child: AsyncView<List<PlanRequest>>(
                value: incoming,
                onRetry: () => ref.invalidate(incomingPlanRequestsProvider),
                builder: (context, allReceived) {
                  // Only what can still be planned. A request whose time
                  // passed moves to History, even before the Worker marks it
                  // expired (2026-09-28).
                  final now = DateTime.now().toUtc();
                  final received = [
                    for (final request in allReceived)
                      if (request.isLiveAt(now)) request,
                  ];
                  final sent = [
                    for (final request in outgoing.value ?? const [])
                      if (request.isLiveAt(now)) request,
                  ];
                  if (received.isEmpty && sent.isEmpty) {
                    return const Center(child: Text('No open plan requests.'));
                  }
                  return ListView(
                    padding: Space.screenList,
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
            ),
          ],
        ),
      ),
    );
  }
}

/// The top of the Request tab: its HISTORY button, styled like the Plan
/// tab's (UI-RULES §6.12).
class _RequestsHeader extends StatelessWidget {
  const _RequestsHeader();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: Space.lg, bottom: Space.sm),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Open Requests',
              style: context.text.titleLarge,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          OutlinedButton(
            key: const ValueKey('request-history'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: Space.sm),
              textStyle: context.text.labelLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
              visualDensity: VisualDensity.compact,
              shape: const RoundedRectangleBorder(borderRadius: Radii.md),
            ),
            onPressed: () => context.push(Routes.planRequestHistory),
            child: const Text('HISTORY'),
          ),
        ],
      ),
    );
  }
}

/// What a finished request reads as, from the viewer's side.
String planRequestStatusLabel(
  PlanRequestStatus status, {
  required bool incoming,
}) => switch (status) {
  PlanRequestStatus.fulfilled => incoming ? 'You set the alarm' : 'Alarm set',
  PlanRequestStatus.declined => incoming ? 'You declined' : 'Declined',
  PlanRequestStatus.cancelled => incoming ? 'They cancelled' : 'You cancelled',
  PlanRequestStatus.expired =>
    incoming ? 'Missed: the time passed' : 'Not set: the time passed',
  PlanRequestStatus.pending || PlanRequestStatus.inProgress => 'Open',
};

/// **Request History** (2026-09-28): every finished request, sent and
/// received (set, declined, cancelled or expired), newest requested time
/// first under month + year headers, like the plan History.
class PlanRequestHistoryScreen extends ConsumerWidget {
  const PlanRequestHistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uid = ref.watch(currentUidProvider);
    final received = ref.watch(receivedPlanRequestsProvider);
    final sent = ref.watch(outgoingPlanRequestsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Request History')),
      body: AsyncView<List<PlanRequest>>(
        value: received,
        onRetry: () => ref.invalidate(receivedPlanRequestsProvider),
        builder: (context, receivedList) {
          final now = DateTime.now().toUtc();
          final finished = finishedPlanRequests([
            ...receivedList,
            ...sent.value ?? const <PlanRequest>[],
          ], now);
          if (finished.isEmpty) {
            return const Center(child: Text('No finished requests yet.'));
          }
          final children = <Widget>[];
          DateTime? month;
          for (final request in finished) {
            final local = request.windowStartUtc.toLocal();
            final start = DateTime(local.year, local.month);
            if (start != month) {
              month = start;
              children.add(SectionHeader(formatMonthYear(context, start)));
            }
            children.add(
              _PlanRequestCard(
                request: request,
                incoming: request.plannerUid == uid,
                history: true,
              ),
            );
          }
          return ListView(
            padding: Space.screenListSafe(context),
            children: children,
          );
        },
      ),
    );
  }
}

class _PlanRequestCard extends ConsumerWidget {
  const _PlanRequestCard({
    required this.request,
    required this.incoming,
    this.history = false,
  });

  final PlanRequest request;
  final bool incoming;

  /// In Request History: no actions, only how it ended.
  final bool history;

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
            if (history)
              Text(
                planRequestStatusLabel(
                  request.statusAt(DateTime.now().toUtc()),
                  incoming: incoming,
                ),
                key: ValueKey('request-status-${request.id}'),
                style: context.text.labelMedium,
              )
            else if (incoming)
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
            else
              OutlinedButton(
                onPressed: () =>
                    ref.read(planRequestRepositoryProvider).cancel(request),
                child: const Text('Cancel request'),
              ),
          ],
        ),
      ),
    );
  }
}

/// A friend's request, seen by the friend asked (Batch G item 5): who, what,
/// when (in THEIR zone), the note, and **Set the alarm**, which opens the
/// normal Plan screen pre-filled and locked to that minute (item 5b) — Default
/// Alarm or Voice Note. Opening either screen does not stop the reminders;
/// sending the plan does.
class FulfillPlanRequestScreen extends ConsumerStatefulWidget {
  const FulfillPlanRequestScreen({required this.requestId, super.key});

  final String requestId;

  @override
  ConsumerState<FulfillPlanRequestScreen> createState() =>
      _FulfillPlanRequestScreenState();
}

class _FulfillPlanRequestScreenState
    extends ConsumerState<FulfillPlanRequestScreen> {
  /// Item 5b: the normal Plan screen, pre-filled and locked to the requested
  /// minute — Default Alarm or Voice Note, exactly like any other plan.
  void _openPlan(PlanRequest request) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ScheduleBuilderScreen(planRequest: request),
      ),
    );
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
              _Detail(label: 'Task', value: task.isEmpty ? 'Not given' : task),
              _Detail(
                label: 'When',
                value:
                    '${formatInstant(context, live.windowStartUtc, live.timezone)}'
                    ' (${live.timezone})',
              ),
              if (note.isNotEmpty) _Detail(label: 'Note', value: note),
              const SizedBox(height: Space.xl),
              if (live.isLiveAt(DateTime.now().toUtc())) ...[
                FilledButton.icon(
                  key: const ValueKey('request-set-alarm'),
                  onPressed: () => _openPlan(live),
                  icon: const Icon(AppIcons.navPlan),
                  label: const Text('Set the alarm'),
                ),
                const SizedBox(height: Space.sm),
                OutlinedButton(
                  key: const ValueKey('request-decline'),
                  onPressed: () async {
                    await ref.read(planRequestRepositoryProvider).decline(live);
                    if (context.mounted) context.pop();
                  },
                  child: const Text('Decline'),
                ),
              ] else
                Text(switch (live.statusAt(DateTime.now().toUtc())) {
                  PlanRequestStatus.fulfilled => 'The alarm is set.',
                  PlanRequestStatus.declined => 'You declined this request.',
                  PlanRequestStatus.cancelled => 'They cancelled this request.',
                  PlanRequestStatus.expired =>
                    'The requested time has passed. This request is closed.',
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
