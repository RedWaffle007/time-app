#!/usr/bin/env python3
"""Small, restore-safe mutation harness for time-app's pure scheduling logic.

The baseline is the repository's pre-existing focused tests. Only baseline
survivors are rerun with the new property/metamorphic and CIT files, yielding a
real before -> after score without changing pubspec.yaml.
"""

from __future__ import annotations

import atexit
import json
import signal
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent
FLUTTER = "/home/smbilal/flutter/bin/flutter"


@dataclass(frozen=True)
class Mutant:
    name: str
    path: str
    old: str
    new: str


def m(name: str, path: str, old: str, new: str) -> Mutant:
    return Mutant(name, path, old, new)


MUTANTS = [
    m("tz-day-window-23h", "lib/core/timezone/tz_resolver.dart",
      "const dayMs = Duration(hours: 24);", "const dayMs = Duration(hours: 23);"),
    m("tz-before-probe-direction", "lib/core/timezone/tz_resolver.dart",
      "wallAsUtcMs - dayMs.inMilliseconds", "wallAsUtcMs + dayMs.inMilliseconds"),
    m("tz-after-probe-direction", "lib/core/timezone/tz_resolver.dart",
      "wallAsUtcMs + dayMs.inMilliseconds", "wallAsUtcMs - dayMs.inMilliseconds"),
    m("tz-before-candidate-add", "lib/core/timezone/tz_resolver.dart",
      "final tBefore = wallAsUtcMs - offBefore;", "final tBefore = wallAsUtcMs + offBefore;"),
    m("tz-after-candidate-add", "lib/core/timezone/tz_resolver.dart",
      "final tAfter = wallAsUtcMs - offAfter;", "final tAfter = wallAsUtcMs + offAfter;"),
    m("tz-before-valid-invert", "lib/core/timezone/tz_resolver.dart",
      "final beforeValid = offsetAt(tBefore) == offBefore;", "final beforeValid = offsetAt(tBefore) != offBefore;"),
    m("tz-after-valid-invert", "lib/core/timezone/tz_resolver.dart",
      "final afterValid = offsetAt(tAfter) == offAfter;", "final afterValid = offsetAt(tAfter) != offAfter;"),
    m("tz-stable-offset-invert", "lib/core/timezone/tz_resolver.dart",
      "if (offBefore == offAfter)", "if (offBefore != offAfter)"),
    m("tz-overlap-and-to-or", "lib/core/timezone/tz_resolver.dart",
      "beforeValid && afterValid && tBefore != tAfter", "beforeValid || afterValid || tBefore == tAfter"),
    m("tz-overlap-pick-later", "lib/core/timezone/tz_resolver.dart",
      "tBefore < tAfter ? tBefore : tAfter", "tBefore > tAfter ? tBefore : tAfter"),
    m("tz-one-valid-equal", "lib/core/timezone/tz_resolver.dart",
      "if (beforeValid != afterValid)", "if (beforeValid == afterValid)"),
    m("tz-one-valid-wrong", "lib/core/timezone/tz_resolver.dart",
      "beforeValid ? tBefore : tAfter", "beforeValid ? tAfter : tBefore"),
    m("tz-gap-pick-earlier", "lib/core/timezone/tz_resolver.dart",
      "tBefore > tAfter ? tBefore : tAfter", "tBefore < tAfter ? tBefore : tAfter"),
    m("quiet-empty-matches", "lib/core/timezone/quiet_hours.dart",
      "if (start == end) return false;", "if (start == end) return true;"),
    m("quiet-nonwrap-boundary", "lib/core/timezone/quiet_hours.dart",
      "minuteOfDay >= start && minuteOfDay < end", "minuteOfDay > start && minuteOfDay <= end"),
    m("quiet-wrap-and", "lib/core/timezone/quiet_hours.dart",
      "minuteOfDay >= start || minuteOfDay < end", "minuteOfDay >= start && minuteOfDay < end"),
    m("quiet-null-and-to-or", "lib/core/timezone/quiet_hours.dart",
      "quietStartMinutes != null && quietEndMinutes != null", "quietStartMinutes != null || quietEndMinutes != null"),
    m("slot-size-15", "lib/features/scheduling/domain/slot.dart",
      "const int kSlotMinutes = 30;", "const int kSlotMinutes = 15;"),
    m("slot-floor-to-ceil", "lib/features/scheduling/domain/slot.dart",
      ").floor();", ").ceil();"),
    m("slot-start-next", "lib/features/scheduling/domain/slot.dart",
      "index * _msPerSlot", "(index + 1) * _msPerSlot"),
    m("slot-end-same", "lib/features/scheduling/domain/slot.dart",
      "slotStartUtc(index + 1)", "slotStartUtc(index)"),
    m("blocks-outcome-invert", "lib/features/scheduling/domain/slot.dart",
      "item.outcome == null", "item.outcome != null"),
    m("blocks-pending-remove", "lib/features/scheduling/domain/slot.dart",
      "item.status == ScheduleItemStatus.pending ||", "item.status == ScheduleItemStatus.rejected ||"),
    m("blocks-approved-remove", "lib/features/scheduling/domain/slot.dart",
      "item.status == ScheduleItemStatus.approved", "item.status == ScheduleItemStatus.withdrawn"),
    m("day-range-two-days", "lib/features/scheduling/domain/slot.dart",
      "start.add(const Duration(days: 1))", "start.add(const Duration(days: 2))"),
    m("availability-include-dead", "lib/features/scheduling/application/slot_availability.dart",
      "if (!blocksSlot(item)) continue;", "if (blocksSlot(item)) continue;"),
    m("availability-last-inclusive-next", "lib/features/scheduling/application/slot_availability.dart",
      "dayEnd.subtract(const Duration(milliseconds: 1))", "dayEnd.add(const Duration(milliseconds: 1))"),
    m("availability-drop-last", "lib/features/scheduling/application/slot_availability.dart",
      "i <= last", "i < last"),
    m("availability-past-invert", "lib/features/scheduling/application/slot_availability.dart",
      "!slotStartUtc(i).isAfter(nowUtc)", "slotStartUtc(i).isAfter(nowUtc)"),
    m("next-free-from-boundary", "lib/features/scheduling/application/slot_availability.dart",
      "slot.index < from", "slot.index <= from"),
    m("next-free-blocked", "lib/features/scheduling/application/slot_availability.dart",
      "if (slot.isSelectable) return slot;", "if (!slot.isSelectable) return slot;"),
    m("release-keep-dead", "lib/features/scheduling/application/slot_availability.dart",
      "if (blocksSlot(item) && slotStartUtc(index).isAfter(nowUtc))", "if (!blocksSlot(item) && slotStartUtc(index).isAfter(nowUtc))"),
    m("release-ignore-keep", "lib/features/scheduling/application/slot_availability.dart",
      "if (keep.contains(index)) continue;", "if (!keep.contains(index)) continue;"),
    m("bookable-now-inclusive", "lib/features/scheduling/application/slot_availability.dart",
      "if (!instantUtc.toUtc().isAfter(now.toUtc())) return false;", "if (instantUtc.toUtc().isBefore(now.toUtc())) return false;"),
    m("bookable-any-to-every", "lib/features/scheduling/application/slot_availability.dart",
      "return !items.any(", "return !items.every("),
    m("lapse-fallback-two-days", "lib/features/scheduling/application/item_lapse_policy.dart",
      ".add(const Duration(days: 1));", ".add(const Duration(days: 2));"),
    m("lapse-zone-two-days", "lib/features/scheduling/application/item_lapse_policy.dart",
      "local.day + 1", "local.day + 2"),
    m("lapse-boundary-strict", "lib/features/scheduling/application/item_lapse_policy.dart",
      "!nowUtc.toUtc().isBefore(endOfScheduledLocalDayUtc(item))", "nowUtc.toUtc().isAfter(endOfScheduledLocalDayUtc(item))"),
    m("lapse-pending-as-approved", "lib/features/scheduling/application/item_lapse_policy.dart",
      "item.status == ScheduleItemStatus.pending", "item.status == ScheduleItemStatus.approved"),
    m("lapse-approved-as-rejected", "lib/features/scheduling/application/item_lapse_policy.dart",
      "item.status == ScheduleItemStatus.approved &&", "item.status == ScheduleItemStatus.rejected &&"),
    m("calendar-signed-in-empty", "lib/features/calendar/application/calendar_grouping.dart",
      "if (viewerUid == null) return const [];", "if (viewerUid != null) return const [];"),
    m("calendar-target-first", "lib/features/calendar/application/calendar_grouping.dart",
      "for (final item in asPlanner) {", "for (final item in asTarget) {"),
    m("calendar-planner-second", "lib/features/calendar/application/calendar_grouping.dart",
      "for (final item in asTarget) {", "for (final item in asPlanner) {"),
    m("calendar-day-hour-not-dropped", "lib/features/calendar/application/calendar_grouping.dart",
      "DateTime.utc(wall.year, wall.month, wall.day);", "DateTime.utc(wall.year, wall.month, wall.day, wall.hour);"),
    m("calendar-day-key-hour", "lib/features/calendar/application/calendar_grouping.dart",
      "DateTime.utc(date.year, date.month, date.day);", "DateTime.utc(date.year, date.month, date.day, date.hour);"),
    m("calendar-instant-order-reverse", "lib/features/calendar/application/calendar_grouping.dart",
      "a.item.scheduledInstantUtc.compareTo(b.item.scheduledInstantUtc)", "b.item.scheduledInstantUtc.compareTo(a.item.scheduledInstantUtc)"),
    m("calendar-title-order-reverse", "lib/features/calendar/application/calendar_grouping.dart",
      "a.item.title.compareTo(b.item.title)", "b.item.title.compareTo(a.item.title)"),
]

BASELINE = [
    "test/tz_resolver_dst_test.dart",
    "test/slot_availability_test.dart",
    "test/item_lapse_test.dart",
    "test/calendar_grouping_test.dart",
]
ENHANCED = BASELINE + [
    "test/property_metamorphic_time_test.dart",
    "test/combinatorial_scheduling_test.dart",
    "test/mutation_gaps_test.dart",
]

EQUIVALENT = {
    # Under resolveWall's stated domain (at most one small offset transition in
    # a day), a 23h probe still either brackets the transition or uses the one
    # currently valid offset. Both paths return the same UTC/anomaly. Historical
    # date-line jumps are outside that documented DST resolver domain.
    "tz-day-window-23h",
}

originals: dict[Path, str] = {}


def restore() -> None:
    for path, source in originals.items():
        path.write_text(source)


def stop(signum: int, _frame: object) -> None:
    restore()
    raise SystemExit(128 + signum)


atexit.register(restore)
for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(sig, stop)


def run(mutant: Mutant, tests: list[str]) -> str:
    path = ROOT / mutant.path
    source = originals.setdefault(path, path.read_text())
    if source.count(mutant.old) != 1:
        return "invalid-target"
    path.write_text(source.replace(mutant.old, mutant.new, 1))
    try:
        result = subprocess.run(
            [FLUTTER, "test", "--no-pub", "--reporter=compact", *tests],
            cwd=ROOT,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=90,
        )
        return "survived" if result.returncode == 0 else "killed"
    except subprocess.TimeoutExpired:
        return "timeout"
    finally:
        path.write_text(source)


def score(results: dict[str, str]) -> tuple[int, int, float]:
    valid = {k: v for k, v in results.items() if v not in {"invalid-target"}}
    killed = sum(v == "killed" for v in valid.values())
    return killed, len(valid), 100 * killed / len(valid)


def main() -> int:
    close_only = "--close" in sys.argv
    report_path = ROOT / "mutation_results.json"
    if close_only:
        prior = json.loads(report_path.read_text())
        baseline = prior["baseline"]
    else:
        baseline = {}
    enhanced: dict[str, str] = {}
    if not close_only:
        for number, mutant in enumerate(MUTANTS, 1):
            state = run(mutant, BASELINE)
            baseline[mutant.name] = state
            print(f"[{number:02}/{len(MUTANTS)}] baseline {state:14} {mutant.name}", flush=True)
    survivors = [m for m in MUTANTS if baseline[m.name] == "survived"]
    for number, mutant in enumerate(survivors, 1):
        state = run(mutant, ENHANCED)
        enhanced[mutant.name] = state
        print(f"[{number:02}/{len(survivors)}] enhanced {state:14} {mutant.name}", flush=True)

    before = score(baseline)
    final_states = dict(baseline)
    final_states.update(enhanced)
    after = score(final_states)
    report = {
        "mutants": len(MUTANTS),
        "before": {"killed": before[0], "valid": before[1], "score": round(before[2], 2)},
        "after": {"killed": after[0], "valid": after[1], "score": round(after[2], 2)},
        "baseline": baseline,
        "enhanced_survivor_results": enhanced,
        "equivalent": sorted(EQUIVALENT & {k for k, v in final_states.items() if v == "survived"}),
    }
    effective_valid = after[1] - len(report["equivalent"])
    effective_killed = after[0]
    report["after_excluding_equivalent"] = {
        "killed": effective_killed,
        "valid_non_equivalent": effective_valid,
        "score": round(100 * effective_killed / effective_valid, 2),
    }
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report["before"]), "->", json.dumps(report["after"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
