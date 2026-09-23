import 'dart:typed_data';

import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';

import '../domain/avatar.dart';

class AvatarSelection {
  const AvatarSelection({required this.bytes, required this.mime});

  final Uint8List bytes;
  final String mime;
}

/// Picks an avatar without flattening animated GIF/WebP files.
Future<AvatarSelection?> pickAvatarSelection() async {
  final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
  if (picked == null) return null;

  final pickedMime = avatarMimeFor(picked);
  if (!isAllowedAvatarMime(pickedMime)) {
    // Return the unsupported declaration to the shared pre-flight validator so
    // callers show the precise supported-format message. Do not hand unknown
    // bytes to the cropper and accidentally turn an unlisted format into JPEG.
    return AvatarSelection(bytes: await picked.readAsBytes(), mime: pickedMime);
  }
  if (kAnimatedCapableMimes.contains(pickedMime)) {
    return AvatarSelection(bytes: await picked.readAsBytes(), mime: pickedMime);
  }

  final cropped = await ImageCropper().cropImage(
    sourcePath: picked.path,
    maxWidth: 1024,
    maxHeight: 1024,
    compressQuality: 85,
    compressFormat: ImageCompressFormat.jpg,
    aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1),
    uiSettings: [
      AndroidUiSettings(toolbarTitle: 'Crop photo', lockAspectRatio: true),
      IOSUiSettings(title: 'Crop photo', aspectRatioLockEnabled: true),
    ],
  );
  if (cropped == null) return null;
  return AvatarSelection(
    bytes: await cropped.readAsBytes(),
    mime: 'image/jpeg',
  );
}

/// Picker MIME with an extension fallback for Android gallery results.
String avatarMimeFor(XFile file) {
  final declared = file.mimeType;
  if (declared != null && isAllowedAvatarMime(declared)) return declared;
  final name = file.name.toLowerCase();
  final dot = name.lastIndexOf('.');
  final ext = dot == -1 ? '' : name.substring(dot + 1);
  return kAvatarMimeByExtension[ext] ?? '';
}
