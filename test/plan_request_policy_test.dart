import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/plan_requests/domain/plan_request.dart';

void main() {
  PlanRequest request({
    PlanRequestMode mode = PlanRequestMode.flexibleWindow,
    PlanRequestStatus status = PlanRequestStatus.pending,
    List<RequestedPlanSpan> spans = const [],
  }) {
    return PlanRequest(
      id: 'batch-planner',
      batchId: 'batch',
      requesterUid: 'target',
      plannerUid: 'planner',
      mode: mode,
      status: status,
      timezone: 'America/New_York',
      windowStartUtc: DateTime.utc(2026, 11, 1, 5),
      windowEndUtc: DateTime.utc(2026, 11, 1, 9),
      durationMinutes: 30,
      fulfilledSpans: spans,
    );
  }

  test(
    'request ids are stable per batch recipient and distinct across friends',
    () {
      expect(PlanRequest.requestId('batch', 'a'), 'batch_a');
      expect(
        PlanRequest.requestId('batch', 'a'),
        isNot(PlanRequest.requestId('batch', 'b')),
      );
    },
  );

  test('adjacent half-open spans fit while overlap does not', () {
    final live = request(
      spans: [
        RequestedPlanSpan(
          itemId: 'first',
          startUtc: DateTime.utc(2026, 11, 1, 6),
          durationMinutes: 30,
        ),
      ],
    );

    expect(
      spanFitsPlanRequest(
        live,
        startUtc: DateTime.utc(2026, 11, 1, 6, 30),
        durationMinutes: 30,
      ),
      isTrue,
    );
    expect(
      spanFitsPlanRequest(
        live,
        startUtc: DateTime.utc(2026, 11, 1, 6, 29),
        durationMinutes: 30,
      ),
      isFalse,
    );
  });

  test('bounds compare absolute instants across a DST overlap', () {
    final live = request();
    expect(
      spanFitsPlanRequest(
        live,
        startUtc: DateTime.utc(2026, 11, 1, 8, 30),
        durationMinutes: 30,
      ),
      isTrue,
    );
    expect(
      spanFitsPlanRequest(
        live,
        startUtc: DateTime.utc(2026, 11, 1, 8, 31),
        durationMinutes: 30,
      ),
      isFalse,
    );
  });

  test('one-plan request enforces its requested duration', () {
    final live = request(mode: PlanRequestMode.onePlan);
    expect(
      spanFitsPlanRequest(
        live,
        startUtc: DateTime.utc(2026, 11, 1, 6),
        durationMinutes: 30,
      ),
      isTrue,
    );
    expect(
      spanFitsPlanRequest(
        live,
        startUtc: DateTime.utc(2026, 11, 1, 6),
        durationMinutes: 45,
      ),
      isFalse,
    );
  });

  test('settled requests cannot accept replayed fulfillment', () {
    final settled = request(status: PlanRequestStatus.fulfilled);
    expect(
      spanFitsPlanRequest(
        settled,
        startUtc: DateTime.utc(2026, 11, 1, 6),
        durationMinutes: 30,
      ),
      isFalse,
    );
  });

  test('legacy point items conflict only at their instant', () {
    expect(
      planSpansOverlap(
        aStart: DateTime.utc(2026, 1, 1, 10),
        aMinutes: 0,
        bStart: DateTime.utc(2026, 1, 1, 10),
        bMinutes: 30,
      ),
      isTrue,
    );
    expect(
      planSpansOverlap(
        aStart: DateTime.utc(2026, 1, 1, 9, 59),
        aMinutes: 0,
        bStart: DateTime.utc(2026, 1, 1, 10),
        bMinutes: 30,
      ),
      isFalse,
    );
  });
}
