import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:time_app/features/social/presentation/avatar_selection.dart';

void main() {
  test('picker MIME keeps supported animated declarations', () {
    final gif = XFile.fromData(
      Uint8List(0),
      name: 'ignored.bin',
      mimeType: 'image/gif',
    );
    final webp = XFile.fromData(
      Uint8List(0),
      name: 'ignored.bin',
      mimeType: 'image/webp',
    );

    expect(avatarMimeFor(gif), 'image/gif');
    expect(avatarMimeFor(webp), 'image/webp');
  });

  test('picker MIME falls back to the file extension', () {
    // Native XFile.fromData deliberately ignores its `name` argument. Gallery
    // results are path-backed, so exercise the same filename source here.
    final gif = XFile('/tmp/animation.GIF');
    final webp = XFile('/tmp/animation.webp');
    final unsupported = XFile('/tmp/vector.svg');

    expect(avatarMimeFor(gif), 'image/gif');
    expect(avatarMimeFor(webp), 'image/webp');
    expect(avatarMimeFor(unsupported), isEmpty);
  });
}
