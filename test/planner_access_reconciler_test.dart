import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/groups/application/planner_access_reconciler.dart';
import 'package:time_app/features/groups/domain/planner_grant.dart';

/// The planner-side hint rule (`desiredAccess`) in isolation — no Firestore.
/// One hint row per target the caller holds a LIVE GROUP grant over.
void main() {
  PlannerGrant grant(
    String planner,
    String target,
    String group, {
    bool granted = true,
  }) =>
      PlannerGrant(
        plannerUid: planner,
        targetUid: target,
        groupId: group,
        granted: granted,
      );

  group('desiredAccess', () {
    test('a live group grant yields one hint naming that group', () {
      final d = PlannerAccessReconciler.desiredAccess(
        plannerUid: 'me',
        grants: [grant('me', 'b', 'g1')],
      );
      expect(d, {'b': 'g1'});
    });

    test('a revoked grant yields nothing', () {
      final d = PlannerAccessReconciler.desiredAccess(
        plannerUid: 'me',
        grants: [grant('me', 'b', 'g1', granted: false)],
      );
      expect(d, isEmpty);
    });

    test('a self grant is skipped (target reads their own schedule)', () {
      final d = PlannerAccessReconciler.desiredAccess(
        plannerUid: 'me',
        grants: [grant('me', 'me', 'g1')],
      );
      expect(d, isEmpty);
    });

    test('an empty-group grant is skipped — friendship grants need no hint', () {
      final d = PlannerAccessReconciler.desiredAccess(
        plannerUid: 'me',
        grants: [grant('me', 'b', '')],
      );
      expect(d, isEmpty);
    });

    test('a grant the caller does not hold is skipped', () {
      final d = PlannerAccessReconciler.desiredAccess(
        plannerUid: 'me',
        grants: [grant('someone', 'b', 'g1')],
      );
      expect(d, isEmpty);
    });

    test('two live grants over one target collapse to one hint', () {
      final d = PlannerAccessReconciler.desiredAccess(
        plannerUid: 'me',
        grants: [grant('me', 'b', 'g1'), grant('me', 'b', 'g2')],
      );
      expect(d.keys, ['b']);
      expect(d['b'], anyOf('g1', 'g2'));
    });
  });
}
