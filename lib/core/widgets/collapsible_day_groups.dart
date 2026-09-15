import 'package:flutter/material.dart';

import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
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

  /// The localized date label shown in the header (e.g. "Mon, 12 Aug 2026").
  final String label;

  /// The rows under this day. The shared scroller invokes this only for visible
  /// rows in an expanded group; handing it prebuilt children here used to mount
  /// an entire history on the first scroll frame.
  final int itemCount;
  final Widget Function(BuildContext context, int index) itemBuilder;

  int get count => itemCount;
}

/// **The one** collapsible date-grouped list, shared by My Schedule, Activity
/// and Track so the pattern is identical across all three (a tap on the header —
/// or its chevron — expands/collapses just that day, smoothly and independently).
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

  @override
  void didUpdateWidget(CollapsibleDayGroups oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A newly-arrived forced day (deep-linked highlight) must be opened so the
    // card mounts and the screen can scroll to it. Only ADD — never re-collapse
    // what the user chose.
    final force = widget.forceExpandKey;
    if (force != null && force != oldWidget.forceExpandKey) {
      _expanded.add(force);
    }
  }

  void _toggle(String key) {
    setState(() {
      if (!_expanded.remove(key)) _expanded.add(key);
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
    // Tracks the section of the previous group so a header is emitted only when
    // the section changes (groups sharing a section sit under one header).
    String? lastSection;
    for (final group in widget.groups) {
      if (group.section != null && group.section != lastSection) {
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
            child: _DayHeader(
              label: group.label,
              count: group.count,
              expanded: expanded,
              onTap: () => _toggle(group.key),
            ),
          ),
        ),
      );
      // Collapsed groups contribute no child sliver at all. Expanded groups use
      // a builder delegate, keeping long histories lazy while retaining the
      // same independent per-day expansion state.
      if (expanded) {
        slivers.add(
          SliverPadding(
            padding: horizontal,
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                group.itemBuilder,
                childCount: group.count,
                addAutomaticKeepAlives: false,
              ),
            ),
          ),
        );
      }
    }
    if (padding.bottom > 0) {
      slivers.add(SliverToBoxAdapter(child: SizedBox(height: padding.bottom)));
    }
    return CustomScrollView(controller: widget.controller, slivers: slivers);
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({
    required this.label,
    required this.count,
    required this.expanded,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final unit = count == 1 ? 'item' : 'items';
    return InkWell(
      onTap: onTap,
      borderRadius: Radii.sm,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          vertical: Space.md,
          horizontal: Space.xs,
        ),
        child: Row(
          children: [
            // The green structure rule, echoing SectionHeader so a day header
            // reads as the same kind of thing (STRUCTURE, never a fill).
            Container(
              width: Sizes.sectionRuleWidth,
              height: Sizes.ruleWidth,
              color: context.colors.primary,
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: Text(
                '$label · $count $unit',
                style: context.text.titleMedium,
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
    );
  }
}
