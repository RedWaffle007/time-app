import 'dart:typed_data';

import '../domain/avatar.dart';

/// **The upload seam.** One method, one throwable, and — the rule that matters
/// — **no storage vocabulary crosses it.**
///
/// Same discipline as `ChatbotService` in the chatbot feature, and for the same
/// reason: the storage backend is expected to change. No bucket name, no
/// endpoint URL, no signed-URL mechanics, no provider SDK type appears in this
/// interface or in anything that calls it. The UI hands over bytes and a MIME
/// type and receives a [ProfileAvatar].
///
/// **Why a seam here is not speculative.** Firebase Storage — the obvious
/// choice — requires the Blaze plan, and this project deliberately has no
/// payment card attached (`DECISIONS.md`, "Completion→planner push"). The
/// current implementation therefore uploads through the existing Cloudflare
/// Worker into Supabase Storage. On card-day, or if Supabase's free tier ever
/// stops suiting, a second implementation lands behind this interface and
/// `avatarUploaderProvider` changes by one line — exactly the swap the chatbot's
/// `HttpChatbotService` → `OnDeviceChatbotService` move turned out to be.
abstract class AvatarUploader {
  /// Upload [bytes] as the signed-in user's profile picture.
  ///
  /// Returns the stored picture's metadata, ready to write onto the profile.
  /// Throws [AvatarUploadFailure] with a message already written for the user.
  ///
  /// [previousKey] names the object this one replaces, so the backend can
  /// delete it. Passing null keeps the old object — which is a leak, not a
  /// safety measure, so callers should pass it whenever they have it.
  Future<ProfileAvatar> upload({
    required Uint8List bytes,
    required String mime,
    String? previousKey,
  });

  /// Remove the picture entirely, returning the profile to its fallback.
  Future<void> remove({required String storageKey});

  /// Upload a group picture. The backend verifies the caller owns [groupId].
  Future<ProfileAvatar> uploadGroup({
    required String groupId,
    required Uint8List bytes,
    required String mime,
    String? previousKey,
  });

  /// Remove a group picture with the same server-side ownership check.
  Future<void> removeGroup({
    required String groupId,
    required String storageKey,
  });
}

/// An upload that did not happen, carrying copy the UI can show verbatim.
class AvatarUploadFailure implements Exception {
  const AvatarUploadFailure(this.message);
  final String message;
  @override
  String toString() => message;
}
