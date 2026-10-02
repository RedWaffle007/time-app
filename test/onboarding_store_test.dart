import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_app/features/onboarding/data/onboarding_store.dart';

void main() {
  late _FakeInstallIdentity identity;
  late SharedPrefsOnboardingStore store;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    identity = _FakeInstallIdentity('install-a');
    store = SharedPrefsOnboardingStore.withInstallIdentity(identity);
  });

  test('a new installation has not completed permission onboarding', () async {
    expect(await store.isCompleted(), isFalse);
  });

  test(
    'completion remains valid across launches and in-place updates',
    () async {
      await store.markCompleted();

      expect(await store.isCompleted(), isTrue);
    },
  );

  test(
    'restored preferences cannot suppress onboarding after reinstall',
    () async {
      await store.markCompleted();
      identity.value = 'install-b';

      expect(await store.isCompleted(), isFalse);
    },
  );

  // 2026-10-02: the permissions are re-checked after every update.
  test('completing the flow also counts as this update\'s check', () async {
    expect(await store.isCheckedForThisUpdate(), isFalse);
    await store.markCompleted();
    expect(await store.isCheckedForThisUpdate(), isTrue);
  });

  test(
    'an update needs a fresh check, but onboarding stays completed',
    () async {
      await store.markCompleted();
      identity.updatedAt = 'update-2';
      expect(await store.isCompleted(), isTrue);
      expect(await store.isCheckedForThisUpdate(), isFalse);
      await store.markUpdateChecked();
      expect(await store.isCheckedForThisUpdate(), isTrue);
    },
  );

  test('a build that predates the check is treated as unchecked', () async {
    SharedPreferences.setMockInitialValues({
      'onboarding_permissions_completed_install_v2': 'install-a',
    });
    expect(await store.isCompleted(), isTrue);
    expect(await store.isCheckedForThisUpdate(), isFalse);
  });

  test('reset clears both', () async {
    await store.markCompleted();
    await store.reset();
    expect(await store.isCompleted(), isFalse);
    expect(await store.isCheckedForThisUpdate(), isFalse);
  });

  test('the legacy backup-restorable completion flag is ignored', () async {
    SharedPreferences.setMockInitialValues({
      'onboarding_permissions_completed_v1': true,
    });

    expect(await store.isCompleted(), isFalse);
  });
}

class _FakeInstallIdentity implements InstallIdentity {
  _FakeInstallIdentity(this.value);

  String value;
  String updatedAt = 'update-1';

  @override
  Future<String> current() async => value;

  @override
  Future<String> lastUpdate() async => updatedAt;
}
