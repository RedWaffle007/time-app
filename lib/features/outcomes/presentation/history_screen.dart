import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format/datetime_format.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/async_view.dart';
import '../../../core/widgets/collapsible_day_groups.dart';
import '../../../core/widgets/section_header.dart';
import '../../calendar/application/calendar_grouping.dart';
import '../../scheduling/application/schedule_item_order.dart';
import '../../scheduling/application/schedule_providers.dart';
import '../../scheduling/domain/schedule_item.dart';
import '../application/history_intent.dart';
import '../application/schedule_partition.dart';
import 'outcome_screen.dart';

/// Elapsed and completed target-side plans, separate from My Schedule.
class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({
    super.key,
    this.highlightItemId,
    this.highlightToken = 0,
  });

  final String? highlightItemId;
  final int highlightToken;

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen>
    with WidgetsBindingObserver {
  final _scrollController = ScrollController();
  final _highlightKey = GlobalKey();
  Timer? _clockTick;
  Timer? _boundaryTick;
  Timer? _fade;
  late DateTime _nowUtc;
  String? _highlighted;
  int? _highlightIndex;
  int _historyCount = 0;
  int _scrollRequest = 0;
  int _appliedIntentSeq = -1;

  static const _highlightDuration = Duration(seconds: 6);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _nowUtc = DateTime.now().toUtc();
    _clockTick = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() => _nowUtc = DateTime.now().toUtc());
    });
    final intent = ref.read(historyIntentProvider);
    if (widget.highlightItemId != null) {
      _applyHighlight(widget.highlightItemId);
    } else if (intent != null) {
      _appliedIntentSeq = intent.seq;
      _applyHighlight(intent.itemId);
    }
  }

  @override
  void didUpdateWidget(HistoryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.highlightItemId != oldWidget.highlightItemId ||
        widget.highlightToken != oldWidget.highlightToken) {
      _applyHighlight(widget.highlightItemId);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      setState(() => _nowUtc = DateTime.now().toUtc());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clockTick?.cancel();
    _boundaryTick?.cancel();
    _fade?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _applyHighlight(String? itemId) {
    _fade?.cancel();
    _highlighted = itemId;
    final request = ++_scrollRequest;
    if (itemId == null) return;
    _fade = Timer(_highlightDuration, () {
      if (mounted) setState(() => _highlighted = null);
    });
    _tryScroll(request, 0);
  }

  void _tryScroll(int request, int attempt) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _highlighted == null || request != _scrollRequest) return;
      final ctx = _highlightKey.currentContext;
      if (ctx != null) {
        if (_isVisible(ctx)) return;
        if (attempt < 60) {
          Scrollable.ensureVisible(
            ctx,
            duration: Motion.fast,
            curve: Motion.curve,
            alignment: 0.2,
          ).whenComplete(() => _tryScroll(request, attempt + 1));
        }
      } else {
        if (_scrollController.hasClients &&
            _highlightIndex != null &&
            _historyCount > 0) {
          final max = _scrollController.position.maxScrollExtent;
          final fraction = _historyCount <= 1
              ? 0.0
              : _highlightIndex! / (_historyCount - 1);
          _scrollController.jumpTo((fraction * max).clamp(0.0, max));
        }
        if (attempt < 60) _tryScroll(request, attempt + 1);
      }
    });
  }

  bool _isVisible(BuildContext context) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return false;
    final viewport = RenderAbstractViewport.maybeOf(box);
    final position = Scrollable.maybeOf(context)?.position;
    if (viewport == null ||
        position == null ||
        !position.hasPixels ||
        !position.hasViewportDimension) {
      return false;
    }
    final top = viewport.getOffsetToReveal(box, 0).offset;
    final bottom = top + box.size.height;
    return top < position.pixels + position.viewportDimension &&
        bottom > position.pixels;
  }

  void _scheduleBoundaryTick(List<ScheduleItem> items) {
    _boundaryTick?.cancel();
    final now = DateTime.now().toUtc();
    DateTime? next;
    for (final item in items) {
      if (item.status != ScheduleItemStatus.approved || item.outcome != null) {
        continue;
      }
      final due = item.scheduledInstantUtc;
      if (!due.isBefore(now) && (next == null || due.isBefore(next))) {
        next = due;
      }
    }
    if (next == null) return;
    _boundaryTick = Timer(
      next.difference(now) + const Duration(milliseconds: 1),
      () {
        if (mounted) setState(() => _nowUtc = DateTime.now().toUtc());
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<HistoryIntent?>(historyIntentProvider, (_, next) {
      if (next != null && next.seq != _appliedIntentSeq) {
        _appliedIntentSeq = next.seq;
        setState(() => _applyHighlight(next.itemId));
      }
    });

    final itemsAsync = ref.watch(myItemsAsTargetProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('History')),
      body: AsyncView<List<ScheduleItem>>(
        value: itemsAsync,
        onRetry: () => ref.invalidate(allItemsAsTargetProvider),
        builder: (context, items) {
          _scheduleBoundaryTick(items);
          final history =
              items.where((item) => isHistoryPlan(item, _nowUtc)).toList()
                ..sort(compareScheduleItemsLatestFirst);
          final byDay = <String, List<ScheduleItem>>{};
          final dateFor = <String, DateTime>{};
          for (final item in history) {
            final date = calendarDayFor(item);
            final key = dayKeyOf(date);
            dateFor[key] = date;
            byDay.putIfAbsent(key, () => []).add(item);
          }
          for (final dayItems in byDay.values) {
            dayItems.sort(compareScheduleItemsLatestFirst);
          }
          final orderedKeys = byDay.keys.toList()
            ..sort((a, b) => b.compareTo(a));

          _historyCount = history.length;
          _highlightIndex = null;
          var flattenedIndex = 0;
          for (final key in orderedKeys) {
            final index = byDay[key]!.indexWhere(
              (item) => item.id == _highlighted,
            );
            if (index >= 0) {
              _highlightIndex = flattenedIndex + index;
              break;
            }
            flattenedIndex += byDay[key]!.length;
          }

          String? forceKey;
          if (_highlighted != null) {
            for (final item in history) {
              if (item.id == _highlighted) {
                forceKey = dayKeyOf(calendarDayFor(item));
                break;
              }
            }
          }

          return CollapsibleDayGroups(
            controller: _scrollController,
            padding: Space.screenListSafe(context),
            forceExpandKey: forceKey,
            leading: [
              const SectionHeader('Past Plans'),
              if (history.isEmpty) const _NoPastPlans(),
            ],
            groups: [
              for (final key in orderedKeys)
                DayGroupData(
                  key: key,
                  date: dateFor[key]!,
                  label: formatWallDate(context, dateFor[key]!),
                  itemCount: byDay[key]!.length,
                  itemBuilder: (context, index) {
                    final item = byDay[key]![index];
                    return OutcomeCard(
                      item: item,
                      highlighted: item.id == _highlighted,
                      cardKey: item.id == _highlighted ? _highlightKey : null,
                    );
                  },
                ),
            ],
          );
        },
      ),
    );
  }
}

class _NoPastPlans extends StatelessWidget {
  const _NoPastPlans();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: Space.xxl),
    child: Center(
      child: Text(
        'No past plans yet.',
        style: context.text.titleMedium,
        textAlign: TextAlign.center,
      ),
    ),
  );
}
