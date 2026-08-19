import 'package:flutter/foundation.dart';

import '../data/model_manifest.dart';

/// Where the on-device model stands right now.
///
/// Sealed so the screen's renderer must handle every case: a state added later
/// is a compile error at the switch, not a screen that draws nothing.
///
/// **No transport vocabulary.** No status codes, no URLs, no `Range`. The
/// screen is told what is happening and how far along it is; *how* the bytes
/// arrive is [ModelDownloader]'s business, exactly as `ChatReply` keeps HTTP out
/// of the chat screen.
@immutable
sealed class ModelSetupState {
  const ModelSetupState();
}

/// Looking at what is already on disk. The first-launch answer comes from here,
/// and on a device that already has the files it lasts a few hundred
/// milliseconds — long enough that a blank screen would be wrong.
final class ModelChecking extends ModelSetupState {
  const ModelChecking();
}

/// The model is not on this phone, and nothing has been downloaded yet.
///
/// **The state that makes the download a choice.** 143MB is not something to
/// start on someone's behalf because they opened a chat screen — they may be on
/// mobile data, or just looking. So the check that runs on entry ends here, and
/// only a tap moves it on (DECISIONS.md, 2026-08-19).
///
/// [totalBytes] is null only if a manifest entry ever loses its size, in which
/// case the screen says "download" without a figure rather than inventing one.
final class ModelNeeded extends ModelSetupState {
  const ModelNeeded(this.totalBytes);

  final int? totalBytes;
}

/// Bytes are moving.
final class ModelDownloading extends ModelSetupState {
  const ModelDownloading({
    required this.file,
    required this.fileNumber,
    required this.fileCount,
    required this.received,
    required this.total,
  });

  final ModelFile file;

  /// 1-based, for "File 2 of 4". Naming the segment is what keeps a determinate
  /// bar from appearing to go backwards when the next file starts at zero
  /// (UI-RULES.md §6.7).
  final int fileNumber;
  final int fileCount;

  final int received;

  /// Null when the server declared no length. The UI must then show an
  /// indeterminate indicator rather than invent a fraction.
  final int? total;

  /// 0–1, or null when [total] is unknown or zero.
  double? get fraction {
    final total = this.total;
    if (total == null || total <= 0) return null;
    return (received / total).clamp(0.0, 1.0);
  }
}

/// Hashing a finished file. Its own state because a sha256 over 130MB takes
/// long enough on a phone that a frozen progress bar would read as a hang.
final class ModelVerifying extends ModelSetupState {
  const ModelVerifying(this.file);
  final ModelFile file;
}

/// Every file is present and verified.
final class ModelReady extends ModelSetupState {
  const ModelReady();
}

/// Setup stopped and needs the user. Always retryable — every failure path
/// either keeps the partial download for a resume or discards it for a clean
/// restart, so there is no dead end to represent.
final class ModelFailed extends ModelSetupState {
  const ModelFailed(this.message);

  /// Already written for a person, by the layer that knew why. Rendered
  /// verbatim.
  final String message;
}
