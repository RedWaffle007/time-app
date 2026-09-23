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

  @override
  Future<String> current() async => value;
}
