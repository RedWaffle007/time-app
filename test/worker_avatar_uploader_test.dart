import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/social/data/worker_avatar_uploader.dart';

void main() {
  group('avatar Worker failure messages', () {
    test(
      'separates storage/backend failures from auth and image validation',
      () {
        expect(
          describeAvatarUploadFailure(
            502,
            '{"error":"store-failed","reason":"storage-authorization-failed"}',
          ),
          'Avatar storage rejected the upload. Your picture was not changed.',
        );
        expect(
          describeAvatarUploadFailure(
            500,
            '{"error":"storage-not-configured"}',
          ),
          'Avatar storage is not configured on the server yet.',
        );
        expect(
          describeAvatarUploadFailure(401, '{}'),
          'Your session expired. Sign in again and retry.',
        );
        expect(
          describeAvatarUploadFailure(415, '{}'),
          'That file type is not supported. Use JPEG, PNG, GIF or WebP.',
        );
      },
    );

    test('never displays a non-JSON gateway or provider response body', () {
      const secretDetail = '<html>upstream service details</html>';
      final message = describeAvatarUploadFailure(502, secretDetail);

      expect(message, 'The avatar storage service is unavailable. Try again.');
      expect(message, isNot(contains('upstream')));
    });
  });
}
