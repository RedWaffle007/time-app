/// **How long an alarm keeps trying** (2026-10-04, user-directed: mirror a
/// phone's own alarm). It rings for 5 minutes, goes quiet for 5, and does that
/// three times: rings start at 0, 10 and 20 minutes, and the alarm gives up
/// at 25 — only then is the person "unavailable" and the missed pop-up shown.
///
/// Native `RingCyclePolicy` (AlarmDeliveryPolicy.kt) applies the same numbers
/// at ring time; `test/ring_cycle_test.dart` keeps the two in step. Pure: no
/// clock, no plugins.
library;

const kRingLength = Duration(minutes: 5);
const kRingGap = Duration(minutes: 5);
const kRingCount = 3;

/// From the alarm's time until it gives up: 25 minutes.
const kRingCycleTotal = Duration(minutes: 25);

/// Where an alarm is at [nowUtc]: ringing (which ring, until when), quiet
/// (which ring next, when), or over.
sealed class RingPhase {
  const RingPhase();
}

class Ringing extends RingPhase {
  const Ringing(this.ring, this.endsAtUtc);

  /// 1, 2 or 3.
  final int ring;
  final DateTime endsAtUtc;
}

class Quiet extends RingPhase {
  const Quiet(this.nextRing, this.nextRingAtUtc);

  /// 2 or 3.
  final int nextRing;
  final DateTime nextRingAtUtc;
}

class RingOver extends RingPhase {
  const RingOver();
}

/// When ring [ring] (1-based) starts for an alarm at [scheduledUtc].
DateTime ringStartUtc(DateTime scheduledUtc, int ring) =>
    scheduledUtc.add((kRingLength + kRingGap) * (ring - 1));

/// The phase of an alarm scheduled at [scheduledUtc], at [nowUtc]. Before its
/// time it counts as the first ring (it is about to start).
RingPhase ringPhaseAt(DateTime scheduledUtc, DateTime nowUtc) {
  final elapsed = nowUtc.difference(scheduledUtc);
  if (elapsed >= kRingCycleTotal) return const RingOver();
  if (elapsed.isNegative) {
    return Ringing(1, scheduledUtc.add(kRingLength));
  }
  final period = kRingLength + kRingGap;
  final index = elapsed.inMicroseconds ~/ period.inMicroseconds;
  final within = elapsed - period * index;
  if (within < kRingLength) {
    return Ringing(
      index + 1,
      ringStartUtc(scheduledUtc, index + 1).add(kRingLength),
    );
  }
  return Quiet(index + 2, ringStartUtc(scheduledUtc, index + 2));
}
