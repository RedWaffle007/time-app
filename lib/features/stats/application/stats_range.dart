import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'my_stats.dart';

/// Remembers this phone's choice of chart range (2026-09-28). Best-effort: a
/// failed read or write only means the chart opens on Last 8 weeks.
abstract interface class StatsRangeStore {
  Future<StatsRange?> read();
  Future<void> write(StatsRange range);
}

class SharedPrefsStatsRangeStore implements StatsRangeStore {
  const SharedPrefsStatsRangeStore();

  static const _key = 'stats_range_v1';

  @override
  Future<StatsRange?> read() async {
    try {
      final name = (await SharedPreferences.getInstance()).getString(_key);
      for (final range in StatsRange.values) {
        if (range.name == name) return range;
      }
    } catch (_) {}
    return null;
  }

  @override
  Future<void> write(StatsRange range) async {
    try {
      await (await SharedPreferences.getInstance()).setString(_key, range.name);
    } catch (_) {}
  }
}

final statsRangeStoreProvider = Provider<StatsRangeStore>(
  (ref) => const SharedPrefsStatsRangeStore(),
);

final statsRangeProvider = NotifierProvider<StatsRangeNotifier, StatsRange>(
  StatsRangeNotifier.new,
);

class StatsRangeNotifier extends Notifier<StatsRange> {
  var _chosenBeforeRestore = false;

  @override
  StatsRange build() {
    _restore();
    return StatsRange.weeks;
  }

  Future<void> _restore() async {
    final saved = await ref.read(statsRangeStoreProvider).read();
    if (saved != null && !_chosenBeforeRestore) state = saved;
  }

  Future<void> choose(StatsRange range) async {
    _chosenBeforeRestore = true;
    state = range;
    await ref.read(statsRangeStoreProvider).write(range);
  }
}
