import 'package:flutter/material.dart';

import '../../../core/theme/app_icons.dart';
import 'messaging_service.dart';

/// Explicit presentation policy for the token-registration warning.
///
/// Registration itself is deliberately independent of notification permission:
/// a denied OS prompt does not mean the FCM token failed to reach Firestore.
/// This policy concerns only the latter, and gates presentation while the
/// first-run permission explanation or a system/settings permission surface is
/// active.
enum FcmFailureBannerMode { hidden, retrying, failed }

FcmFailureBannerMode fcmFailureBannerMode({
  required FcmRegistrationStatus registrationStatus,
  required bool onboardingCompleted,
  required bool permissionFlowInProgress,
  required bool failureDismissed,
  required bool retryRequested,
}) {
  if (!onboardingCompleted || permissionFlowInProgress) {
    return FcmFailureBannerMode.hidden;
  }
  if (registrationStatus == FcmRegistrationStatus.registering &&
      retryRequested) {
    return FcmFailureBannerMode.retrying;
  }
  if (registrationStatus == FcmRegistrationStatus.failed && !failureDismissed) {
    return FcmFailureBannerMode.failed;
  }
  return FcmFailureBannerMode.hidden;
}

/// Shared, testable content for the global registration banner. The app owns
/// the messenger lifetime; this widget owns only the mode-specific controls.
class FcmRegistrationBanner extends MaterialBanner {
  FcmRegistrationBanner({
    super.key,
    required this.mode,
    required this.onDismiss,
    required this.onRetry,
  }) : super(
         content: Text(
           mode == FcmFailureBannerMode.retrying
               ? 'Setting up notifications…'
               : "Couldn't set up notifications on this device — you may not be "
                     'notified when someone plans or completes an item.',
         ),
         leading: const Icon(AppIcons.notificationsOff),
         actions: [
           if (mode != FcmFailureBannerMode.retrying)
             TextButton(onPressed: onDismiss, child: const Text('Dismiss')),
           TextButton(
             onPressed: mode == FcmFailureBannerMode.retrying ? null : onRetry,
             child: Text(
               mode == FcmFailureBannerMode.retrying ? 'Retrying…' : 'Retry',
             ),
           ),
         ],
       );

  final FcmFailureBannerMode mode;
  final VoidCallback onDismiss;
  final VoidCallback onRetry;
}
