import 'package:flutter/material.dart';

import '../format/datetime_format.dart';
import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../theme/dataviz_tokens.dart';
import 'section_header.dart';

/// A `yyyy-MM-dd` key from a date, for [DayGroupData.key] and for the "today"
/// entry in [CollapsibleDayGroups.initiallyExpandedKeys]. Reads only the date
/// fields, so an item's own-timezone day (a UTC-kind carrier from
/// `calendarDayFor`) and a device-local `DateTime.now()` produce comparable keys.
String dayKeyOf(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

/// One day's worth of rows for [CollapsibleDayGroups].
class DayGroupData {
  const DayGroupData({
    required this.key,
    required this.date,
    required this.label,
    required this.itemCount,
    required this.itemBuilder,
    this.section,
  });

  /// Optional bucket label (e.g. "Today", "Future plans", "Past plans"). A
  /// [SectionHeader] is emitted above the FIRST group whose section differs from
  /// the previous one, so groups sharing a section sit under one header. Null on
  /// screens that don't bucket (Activity, Track).
  final String? section;

  /// Stable per-day identity for the expand/collapse state — a `yyyy-MM-dd`
  /// string. Must survive stream rebuilds so a day the user collapsed stays
  /// collapsed when the list refreshes.
  final String key;

  /// Calendar date represented by this group. Kept separate from [key] because
  /// My Schedule prefixes its stable state key with a time-section name. Long
  /// histories use this value to form localized month/year buckets without
  /// trying to parse presentation or storage strings.
  final DateTime date;

  /// The localized date label shown in the header (e.g. "Mon, 12 Aug 2026").
  final String label;

  /// The rows under this day. The shared scroller invokes this only for visible
  /// rows in an expanded group; handing it prebuilt children here used to mount
  /// an entire history on the first scroll frame.
  final int itemCount;
  final Widget Function(BuildContext context, int index) itemBuilder;

  int get count => itemCount;
}

/// **The one** collapsible date-grouped list, shared by My Schedule, Activity,
/// Track and Archived so the pattern is identical across item histories (a tap
/// on the header — or its chevron — expands/collapses that group).
///
/// It owns ONLY the expand/collapse UI + state. Each screen decides its own day
/// order (My Schedule upcoming-first; Activity/Track most-recent-first) and
/// builds its own rows, then hands them over as [groups]. Default expand state
/// is "today only" via [initiallyExpandedKeys]; a deep-link can force one more
/// day open via [forceExpandKey] (My Schedule's highlighted item).
class CollapsibleDayGroups extends StatefulWidget {
  const CollapsibleDayGroups({
    super.key,
    required this.groups,
    this.leading = const [],
    this.controller,
    this.padding,
    this.initiallyExpandedKeys = const {},
    this.forceExpandKey,
  });

  final List<DayGroupData> groups;

  /// Non-grouped widgets pinned above the first day header (e.g. My Schedule's
  /// hero band + reminder primer).
  final List<Widget> leading;

  final ScrollController? controller;
  final EdgeInsetsGeometry? padding;

  /// Days open on first build — "today only" in practice.
  final Set<String> initiallyExpandedKeys;

  /// A day key to force open when it changes (a deep-linked highlight lands in a
  /// day that would otherwise be collapsed). Null = nothing forced.
  final String? forceExpandKey;

  /// Test-only count of date-group controllers. Collapsed groups have no
  /// animation/ticker allocation; open or transitioning groups have one.
  @visibleForTesting
  static int debugAnimationControllerCount = 0;

  /// Below this many distinct day groups, another hierarchy level costs more
  /// taps than it saves. At this threshold a history is long enough that month
  /// landmarks materially reduce scanning.
  static const monthGroupingDayThreshold = 12;

  @override
  State<CollapsibleDayGroups> createState() => _CollapsibleDayGroupsState();
}

class _CollapsibleDayGroupsState extends State<CollapsibleDayGroups> {
  /// Keys currently expanded. Persists across rebuilds, so a stream refresh or a
  /// tab switch never re-opens a day the user closed (or vice-versa).
  late final Set<String> _expanded = {
    ...widget.initiallyExpandedKeys,
    if (widget.forceExpandKey != null) widget.forceExpandKey!,
  };

  late final Set<String> _expandedMonths = {
    for (final bucket in _monthBuckets())
      if (bucket.groups.any((group) => _expanded.contains(group.key)))
        bucket.key,
  };

  @override
  void didUpdateWidget(CollapsibleDayGroups oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A newly-arrived forced day (deep-linked highlight) must be opened so the
    // card mounts and the screen can scroll to it. Only ADD — never re-collapse
    // what the user chose.
    final force = widget.forceExpandKey;
    if (force != null) {
      _expanded.add(force);
      final bucket = _monthBucketForDay(force);
      if (bucket != null) _expandedMonths.add(bucket.key);
    }
  }

  void _toggle(String key) {
    setState(() {
      if (!_expanded.remove(key)) _expanded.add(key);
    });
  }

  void _toggleMonth(String key) {
    setState(() {
      if (!_expandedMonths.remove(key)) _expandedMonths.add(key);
    });
  }

  @override
  Widget build(BuildContext context) {
    final padding =
        widget.padding?.resolve(Directionality.of(context)) ?? EdgeInsets.zero;
    final horizontal = EdgeInsets.only(
      left: padding.left,
      right: padding.right,
    );
    final slivers = <Widget>[
      if (padding.top > 0)
        SliverToBoxAdapter(child: SizedBox(height: padding.top)),
      for (final leading in widget.leading)
        SliverPadding(
          padding: horizontal,
          sliver: SliverToBoxAdapter(child: leading),
        ),
    ];
    if (widget.groups.length < CollapsibleDayGroups.monthGroupingDayThreshold) {
      _addDayGroups(slivers, widget.groups, horizontal);
    } else {
      // Preserve the incoming day order exactly. A bucket is a consecutive run
      // of one section + calendar month; no sorting happens at this layer.
      String? lastSection;
      for (final bucket in _monthBuckets()) {
        if (bucket.section != null && bucket.section != lastSection) {
          slivers.add(
            SliverPadding(
              padding: horizontal,
              sliver: SliverToBoxAdapter(child: SectionHeader(bucket.section!)),
            ),
          );
          lastSection = bucket.section;
        }
        final expanded = _expandedMonths.contains(bucket.key);
        slivers.add(
          SliverPadding(
            padding: horizontal,
            sliver: SliverToBoxAdapter(
              child: _GroupHeader(
                label: formatMonthYear(context, bucket.date),
                count: bucket.itemCount,
                expanded: expanded,
                onTap: () => _toggleMonth(bucket.key),
                level: _GroupHeaderLevel.month,
              ),
            ),
          ),
        );
        if (expanded) {
          _addDayGroups(
            slivers,
            bucket.groups,
            horizontal.add(const EdgeInsetsDirectional.only(start: Space.lg)),
            showSections: false,
          );
        }
      }
    }
    if (padding.bottom > 0) {
      slivers.add(SliverToBoxAdapter(child: SizedBox(height: padding.bottom)));
    }
    return CustomScrollView(controller: widget.controller, slivers: slivers);
  }

  void _addDayGroups(
    List<Widget> slivers,
    List<DayGroupData> groups,
    EdgeInsetsGeometry horizontal, {
    bool showSections = true,
  }) {
    String? lastSection;
    for (final group in groups) {
      if (showSections &&
          group.section != null &&
          group.section != lastSection) {
        slivers.add(
          SliverPadding(
            padding: horizontal,
            sliver: SliverToBoxAdapter(child: SectionHeader(group.section!)),
          ),
        );
        lastSection = group.section;
      }
      final expanded = _expanded.contains(group.key);
      slivers.add(
        SliverPadding(
          padding: horizontal,
          sliver: SliverToBoxAdapter(
            child: _GroupHeader(
              label: group.label,
              count: group.count,
              expanded: expanded,
              onTap: () => _toggle(group.key),
              level: _GroupHeaderLevel.day,
            ),
          ),
        ),
      );
      // Collapsed groups contribute no child sliver at all. Expanded groups use
      // a builder delegate, keeping long histories lazy while retaining the
      // same independent per-day expansion state. `_AnimatedDayGroup` keeps
      // the sliver alive only until a close transition finishes; it never puts
      // all rows in a box just to animate their height.
      slivers.add(
        SliverPadding(
          padding: horizontal,
          sliver: _AnimatedDayGroup(
            key: ValueKey(group.key),
            expanded: expanded,
            itemCount: group.count,
            itemBuilder: group.itemBuilder,
          ),
        ),
      );
    }
  }

  List<_MonthBucket> _monthBuckets() {
    final buckets = <_MonthBucket>[];
    for (final group in widget.groups) {
      final month =
          '${group.date.year.toString().padLeft(4, '0')}-'
          '${group.date.month.toString().padLeft(2, '0')}';
      final key = '${group.section ?? ''}:$month';
      final previous = buckets.isEmpty ? null : buckets.last;
      if (previous == null || previous.key != key) {
        buckets.add(
          _MonthBucket(
            key: key,
            date: DateTime(group.date.year, group.date.month),
            section: group.section,
            groups: [group],
          ),
        );
      } else {
        previous.groups.add(group);
      }
    }
    return buckets;
  }

  _MonthBucket? _monthBucketForDay(String dayKey) {
    for (final bucket in _monthBuckets()) {
      if (bucket.groups.any((group) => group.key == dayKey)) return bucket;
    }
    return null;
  }
}

class _MonthBucket {
  const _MonthBucket({
    required this.key,
    required this.date,
    required this.section,
    required this.groups,
  });

  final String key;
  final DateTime date;
  final String? section;
  final List<DayGroupData> groups;
  int get itemCount => groups.fold(0, (sum, group) => sum + group.count);
}

enum _GroupHeaderLevel { month, day }

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.label,
    required this.count,
    required this.expanded,
    required this.onTap,
    required this.level,
  });

  final String label;
  final int count;
  final bool expanded;
  final VoidCallback onTap;
  final _GroupHeaderLevel level;

  @override
  Widget build(BuildContext context) {
    final unit = count == 1 ? 'item' : 'items';
    final text = '$label · $count $unit';
    return Semantics(
      container: true,
      header: true,
      button: true,
      expanded: expanded,
      label: text,
      hint: expanded ? 'Collapse group' : 'Expand group',
      onTap: onTap,
      child: ExcludeSemantics(
        child: InkWell(
          onTap: onTap,
          borderRadius: Radii.sm,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              vertical: Space.md,
              horizontal: Space.xs,
            ),
            child: Row(
              children: [
                // A compact, themed marker distinguishes adjacent dates without
                // competing with SectionHeader's horizontal structural rule.
                Icon(
                  level == _GroupHeaderLevel.month
                      ? AppIcons.calendar
                      : AppIcons.bullet,
                  size: level == _GroupHeaderLevel.month
                      ? Sizes.inlineIcon
                      : Sizes.bulletMarker,
                  color: context.colors.categoricalAccentFor(label),
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: Text(
                    text,
                    style: level == _GroupHeaderLevel.month
                        ? context.text.titleLarge
                        : context.text.titleMedium,
                  ),
                ),
                AnimatedRotation(
                  // Down (V) when collapsed → up when expanded.
                  turns: expanded ? 0.5 : 0.0,
                  duration: Motion.fast,
                  curve: Motion.curve,
                  child: Icon(
                    AppIcons.expandGroup,
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Animates one date group's visible rows without giving up `SliverList`'s
/// lazy child construction. The controller belongs only to this group, so
/// opening one date never animates or repaints unrelated dates.
class _AnimatedDayGroup extends StatefulWidget {
  const _AnimatedDayGroup({
    super.key,
    required this.expanded,
    required this.itemCount,
    required this.itemBuilder,
  });

  final bool expanded;
  final int itemCount;
  final Widget Function(BuildContext context, int index) itemBuilder;

  @override
  State<_AnimatedDayGroup> createState() => _AnimatedDayGroupState();
}

class _AnimatedDayGroupState extends State<_AnimatedDayGroup>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  Animation<double>? _animation;
  late bool _showRows = widget.expanded;

  @override
  void initState() {
    super.initState();
    if (widget.expanded) _createController(value: 1);
  }

  @override
  void didUpdateWidget(_AnimatedDayGroup oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded == oldWidget.expanded) return;
    if (widget.expanded) {
      // We are already in this widget's update/build pass, so this assignment
      // makes the lazy sliver available in the same frame without scheduling a
      // second rebuild solely to start the animation.
      _showRows = true;
      (_controller ?? _createController()).forward();
    } else {
      _controller?.reverse();
    }
  }

  AnimationController _createController({double? value}) {
    final controller = AnimationController(vsync: this, duration: Motion.fast);
    CollapsibleDayGroups.debugAnimationControllerCount++;
    _controller = controller;
    _animation = CurvedAnimation(parent: controller, curve: Motion.curve);
    controller.addStatusListener((status) {
      if (status == AnimationStatus.dismissed && mounted && _showRows) {
        _disposeController();
        setState(() => _showRows = false);
      }
    });
    if (value != null) controller.value = value;
    return controller;
  }

  void _disposeController() {
    final controller = _controller;
    if (controller == null) return;
    _controller = null;
    _animation = null;
    controller.dispose();
    CollapsibleDayGroups.debugAnimationControllerCount--;
  }

  @override
  void dispose() {
    _disposeController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_showRows) return const SliverToBoxAdapter(child: SizedBox.shrink());
    final animation = _animation!;
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) => SizeTransition(
          sizeFactor: animation,
          alignment: Alignment.topCenter,
          child: FadeTransition(
            opacity: animation,
            child: widget.itemBuilder(context, index),
          ),
        ),
        childCount: widget.itemCount,
        addAutomaticKeepAlives: false,
      ),
    );
  }
}
