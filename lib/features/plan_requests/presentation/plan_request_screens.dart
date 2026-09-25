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
import '../../groups/application/group_providers.dart';
import '../../notifications/application/friend_notifier.dart';
import '../../notifications/application/outcome_notifier.dart';
import '../../social/application/social_providers.dart';
import '../../social/presentation/avatar_image.dart';
import '../application/plan_request_providers.dart';
import '../domain/plan_request.dart';

class CreatePlanRequestScreen extends ConsumerStatefulWidget {
  const CreatePlanRequestScreen({super.key});

  @override
  ConsumerState<CreatePlanRequestScreen> createState() =>
      _CreatePlanRequestScreenState();
}

class _CreatePlanRequestScreenState
    extends ConsumerState<CreatePlanRequestScreen> {
  final _selected = <String>{};
  final _title = TextEditingController();
  final _message = TextEditingController();
  PlanRequestMode _mode = PlanRequestMode.onePlan;
  DateTime? _startDate;
  DateTime? _endDate;
  TimeOfDay? _startTime;
  TimeOfDay? _endTime;
  int _duration = 30;
  bool _saving = false;

  @override
  void dispose() {
    _title.dispose();
    _message.dispose();
    super.dispose();
  }

  Future<void> _pickDate(bool start) async {
    final now = DateTime.now();
    final value = await showDatePicker(
      context: context,
      initialDate: (start ? _startDate : _endDate) ?? now,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (value != null) {
      setState(() {
        if (start) {
          _startDate = value;
          _endDate ??= value;
        } else {
          _endDate = value;
        }
      });
    }
  }

  Future<void> _pickTime(bool start) async {
    final value = await showTimePicker(
      context: context,
      initialTime: (start ? _startTime : _endTime) ?? TimeOfDay.now(),
    );
    if (value != null) {
      setState(() {
        if (start) {
          _startTime = value;
        } else {
          _endTime = value;
        }
      });
    }
  }

  DateTime _wall(DateTime date, TimeOfDay time) =>
      DateTime.utc(date.year, date.month, date.day, time.hour, time.minute);

  Future<void> _submit(String uid, String timezone) async {
    if (_selected.isEmpty ||
        _startDate == null ||
        _endDate == null ||
        _startTime == null ||
        _endTime == null ||
        _saving) {
      return;
    }
    final start = resolveWallTimeToUtc(
      _wall(_startDate!, _startTime!),
      timezone,
    );
    final end = resolveWallTimeToUtc(_wall(_endDate!, _endTime!), timezone);
    final now = DateTime.now().toUtc();
    if (!start.isAfter(now) || !end.isAfter(start)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Choose a future window with a later end.'),
        ),
      );
      return;
    }

    setState(() => _saving = true);
    final batchId = '$uid-${DateTime.now().microsecondsSinceEpoch}';
    final planners = _selected.toList();
    try {
      await ref
          .read(planRequestRepositoryProvider)
          .createBatch(
            batchId: batchId,
            requesterUid: uid,
            plannerUids: planners,
            mode: _mode,
            timezone: timezone,
            windowStartUtc: start,
            windowEndUtc: end,
            durationMinutes: _duration,
            title: _title.text,
            message: _message.text,
          );
      final notifier = ref.read(friendEventNotifierProvider);
      for (final plannerUid in planners) {
        unawaited(
          notifier.notify(
            event: FriendNotifyEvent.planRequested,
            fromUid: uid,
            toUid: plannerUid,
            planRequestId: PlanRequest.requestId(batchId, plannerUid),
          ),
        );
      }
      if (mounted) context.pop();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not send the request. $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = ref.watch(currentUidProvider);
    final profile = ref.watch(profileProvider).value;
    final grants = ref.watch(grantsOverMeProvider);
    final friends = ref.watch(myFriendUidsProvider).value?.toSet() ?? const {};

    return Scaffold(
      appBar: AppBar(title: const Text('Request a plan')),
      body: AsyncView(
        value: grants,
        onRetry: () => ref.invalidate(grantsOverMeProvider),
        builder: (context, values) {
          final eligible = values
              .where(
                (grant) =>
                    grant.granted &&
                    grant.groupId.isEmpty &&
                    friends.contains(grant.plannerUid),
              )
              .toList();
          if (uid == null || profile == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return ListView(
            padding: Space.screenListSafe(context),
            children: [
              const SectionHeader('Ask'),
              if (eligible.isEmpty)
                Text(
                  'First let a friend plan for you from their profile.',
                  style: context.text.bodyMedium?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                )
              else
                for (final grant in eligible)
                  _PlannerChoice(
                    uid: grant.plannerUid,
                    selected: _selected.contains(grant.plannerUid),
                    onChanged: (value) => setState(() {
                      value
                          ? _selected.add(grant.plannerUid)
                          : _selected.remove(grant.plannerUid);
                    }),
                  ),
              const SectionHeader('Request'),
              SegmentedButton<PlanRequestMode>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: PlanRequestMode.onePlan,
                    label: Text('One plan'),
                  ),
                  ButtonSegment(
                    value: PlanRequestMode.flexibleWindow,
                    label: Text('Flexible window'),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: (value) =>
                    setState(() => _mode = value.first),
              ),
              const SizedBox(height: Space.lg),
              TextField(
                controller: _title,
                maxLength: 200,
                decoration: InputDecoration(
                  labelText: _mode == PlanRequestMode.onePlan
                      ? 'What should they plan? (optional)'
                      : 'Theme or goal (optional)',
                ),
              ),
              const SizedBox(height: Space.md),
              TextField(
                controller: _message,
                maxLength: 500,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Message (optional)',
                ),
              ),
              const SectionHeader('Window in your local time'),
              _DateTimeChoice(
                label: 'Starts',
                date: _startDate,
                time: _startTime,
                onDate: () => _pickDate(true),
                onTime: () => _pickTime(true),
              ),
              const SizedBox(height: Space.md),
              _DateTimeChoice(
                label: 'Ends',
                date: _endDate,
                time: _endTime,
                onDate: () => _pickDate(false),
                onTime: () => _pickTime(false),
              ),
              const SizedBox(height: Space.lg),
              DropdownButtonFormField<int>(
                initialValue: _duration,
                decoration: InputDecoration(
                  labelText: _mode == PlanRequestMode.onePlan
                      ? 'Plan duration'
                      : 'Default item duration',
                ),
                items: [15, 30, 45, 60, 90, 120]
                    .map(
                      (minutes) => DropdownMenuItem(
                        value: minutes,
                        child: Text(formatDurationMinutes(context, minutes)),
                      ),
                    )
                    .toList(),
                onChanged: (value) => setState(() => _duration = value ?? 30),
              ),
              const SizedBox(height: Space.xl),
              FilledButton.icon(
                onPressed: _selected.isNotEmpty && !_saving
                    ? () => _submit(uid, profile.homeTimezone)
                    : null,
                icon: const Icon(AppIcons.send),
                label: Text(_saving ? 'Sending…' : 'Send request'),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _PlannerChoice extends ConsumerWidget {
  const _PlannerChoice({
    required this.uid,
    required this.selected,
    required this.onChanged,
  });

  final String uid;
  final bool selected;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileByUidProvider(uid)).value;
    return Card(
      child: CheckboxListTile(
        value: selected,
        onChanged: (value) => onChanged(value ?? false),
        secondary: AvatarImage(profile: profile, size: Sizes.avatarRow),
        title: Text(profile?.name ?? 'Friend'),
      ),
    );
  }
}

class _DateTimeChoice extends StatelessWidget {
  const _DateTimeChoice({
    required this.label,
    required this.date,
    required this.time,
    required this.onDate,
    required this.onTime,
  });

  final String label;
  final DateTime? date;
  final TimeOfDay? time;
  final VoidCallback onDate;
  final VoidCallback onTime;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: Sizes.avatarRow, child: Text(label)),
        const SizedBox(width: Space.sm),
        Expanded(
          child: OutlinedButton(
            onPressed: onDate,
            child: Text(date == null ? 'Date' : formatWallDate(context, date!)),
          ),
        ),
        const SizedBox(width: Space.sm),
        Expanded(
          child: OutlinedButton(
            onPressed: onTime,
            child: Text(
              time == null ? 'Time' : formatTimeOfDay(context, time!),
            ),
          ),
        ),
      ],
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
        heroTag: 'requestPlanFab',
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
              '${formatInstant(context, request.windowStartUtc, request.timezone)} '
              '– ${formatInstant(context, request.windowEndUtc, request.timezone)}',
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
                      child: const Text('Plan'),
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

class FulfillPlanRequestScreen extends ConsumerStatefulWidget {
  const FulfillPlanRequestScreen({required this.requestId, super.key});

  final String requestId;

  @override
  ConsumerState<FulfillPlanRequestScreen> createState() =>
      _FulfillPlanRequestScreenState();
}

class _FulfillPlanRequestScreenState
    extends ConsumerState<FulfillPlanRequestScreen> {
  final _title = TextEditingController();
  final _note = TextEditingController();
  DateTime? _date;
  TimeOfDay? _time;
  int? _duration;
  bool _finish = false;
  bool _saving = false;
  bool _seeded = false;

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final value = await showDatePicker(
      context: context,
      initialDate: _date ?? now,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (value != null) setState(() => _date = value);
  }

  Future<void> _pickTime() async {
    final value = await showTimePicker(
      context: context,
      initialTime: _time ?? TimeOfDay.now(),
    );
    if (value != null) setState(() => _time = value);
  }

  Future<void> _save(PlanRequest request) async {
    final uid = ref.read(currentUidProvider);
    if (uid == null || _date == null || _time == null || _saving) return;
    final wall = DateTime.utc(
      _date!.year,
      _date!.month,
      _date!.day,
      _time!.hour,
      _time!.minute,
    );
    setState(() => _saving = true);
    try {
      final itemId = await ref
          .read(planRequestRepositoryProvider)
          .fulfill(
            request: request,
            plannerUid: uid,
            title: _title.text,
            note: _note.text,
            wall: wall,
            durationMinutes: _duration ?? request.durationMinutes,
            finishFlexibleRequest: _finish,
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
      if (!mounted) return;
      if (request.isOnePlan || _finish) {
        context.pop();
      } else {
        setState(() {
          _title.clear();
          _note.clear();
          _date = null;
          _time = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Item added. You can add another.')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not add the plan. $error')),
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
      appBar: AppBar(title: const Text('Fulfill request')),
      body: AsyncView<PlanRequest?>(
        value: value,
        onRetry: () => ref.invalidate(planRequestProvider(widget.requestId)),
        isEmpty: (request) => request == null,
        emptyMessage: 'This request is no longer available.',
        builder: (context, request) {
          final live = request!;
          if (!_seeded) {
            _seeded = true;
            _title.text = live.title ?? '';
            _duration = live.durationMinutes;
            final local = tz.TZDateTime.from(
              live.windowStartUtc,
              tz.getLocation(live.timezone),
            );
            _date = DateTime(local.year, local.month, local.day);
            _time = TimeOfDay(hour: local.hour, minute: local.minute);
          }
          return ListView(
            padding: Space.screenListSafe(context),
            children: [
              Text(
                'Use ${live.timezone}. The item must stay inside '
                '${formatInstant(context, live.windowStartUtc, live.timezone)} '
                '– ${formatInstant(context, live.windowEndUtc, live.timezone)}.',
                style: context.text.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: Space.lg),
              TextField(
                controller: _title,
                decoration: const InputDecoration(labelText: 'Title'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: Space.lg),
              _DateTimeChoice(
                label: 'Starts',
                date: _date,
                time: _time,
                onDate: _pickDate,
                onTime: _pickTime,
              ),
              const SizedBox(height: Space.lg),
              DropdownButtonFormField<int>(
                initialValue: _duration,
                decoration: const InputDecoration(labelText: 'Duration'),
                items: [15, 30, 45, 60, 90, 120]
                    .map(
                      (minutes) => DropdownMenuItem(
                        value: minutes,
                        child: Text(formatDurationMinutes(context, minutes)),
                      ),
                    )
                    .toList(),
                onChanged: live.isOnePlan
                    ? null
                    : (value) => setState(() => _duration = value),
              ),
              const SizedBox(height: Space.lg),
              TextField(
                controller: _note,
                decoration: const InputDecoration(labelText: 'Note (optional)'),
              ),
              if (!live.isOnePlan) ...[
                const SizedBox(height: Space.sm),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Finish request after this item'),
                  value: _finish,
                  onChanged: (value) => setState(() => _finish = value),
                ),
                if (live.fulfilledSpans.isNotEmpty)
                  TextButton(
                    onPressed: () async {
                      await ref
                          .read(planRequestRepositoryProvider)
                          .completeFlexible(live);
                      if (context.mounted) context.pop();
                    },
                    child: const Text('Finish without another item'),
                  ),
              ],
              const SizedBox(height: Space.xl),
              FilledButton(
                onPressed: _title.text.trim().isNotEmpty && !_saving
                    ? () => _save(live)
                    : null,
                child: Text(_saving ? 'Adding…' : 'Add plan'),
              ),
            ],
          );
        },
      ),
    );
  }
}
