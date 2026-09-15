import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/notifications/application/fcm_failure_banner_policy.dart';
import 'package:time_app/features/notifications/application/messaging_service.dart';

void main() {
  FcmFailureBannerMode decide({
    required FcmRegistrationStatus status,
    bool onboardingCompleted = true,
    bool permissionFlowInProgress = false,
    bool dismissed = false,
    bool retryRequested = false,
  }) => fcmFailureBannerMode(
    registrationStatus: status,
    onboardingCompleted: onboardingCompleted,
    permissionFlowInProgress: permissionFlowInProgress,
    failureDismissed: dismissed,
    retryRequested: retryRequested,
  );

  test('a real FCM failure is deferred during incomplete onboarding', () {
    expect(
      decide(status: FcmRegistrationStatus.failed, onboardingCompleted: false),
      FcmFailureBannerMode.hidden,
    );
    // The unchanged failure becomes visible once onboarding has actually ended.
    expect(
      decide(status: FcmRegistrationStatus.failed),
      FcmFailureBannerMode.failed,
    );
  });

  test('permission/settings flow suppresses registration presentation', () {
    expect(
      decide(
        status: FcmRegistrationStatus.failed,
        permissionFlowInProgress: true,
      ),
      FcmFailureBannerMode.hidden,
    );
  });

  test('retry has a visible registering state and success clears warning', () {
    expect(
      decide(status: FcmRegistrationStatus.registering, retryRequested: true),
      FcmFailureBannerMode.retrying,
    );
    expect(
      decide(status: FcmRegistrationStatus.registered),
      FcmFailureBannerMode.hidden,
    );
  });

  test('a dismissed unchanged failure does not immediately reappear', () {
    expect(
      decide(status: FcmRegistrationStatus.failed, dismissed: true),
      FcmFailureBannerMode.hidden,
    );
  });

  testWidgets(
    'Retry invokes the registration callback and busy state disables it',
    (tester) async {
      var retried = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FcmRegistrationBanner(
              mode: FcmFailureBannerMode.failed,
              onDismiss: () {},
              onRetry: () => retried = true,
            ),
          ),
        ),
      );
      await tester.tap(find.text('Retry'));
      expect(retried, isTrue);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FcmRegistrationBanner(
              mode: FcmFailureBannerMode.retrying,
              onDismiss: _noop,
              onRetry: _noop,
            ),
          ),
        ),
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Retrying…'))
            .onPressed,
        isNull,
      );
    },
  );
}

void _noop() {}
