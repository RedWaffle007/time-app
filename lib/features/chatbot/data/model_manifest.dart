import 'package:flutter/foundation.dart';

/// **The one line that moves when the release moves.**
///
/// The on-device model is ~143MB across four files. Bundling that in the APK
/// would quadruple the download for every user of the *delegation* app — who is
/// the actual user, and who does not want a German practice bot — so the files
/// live on a GitHub Release and are fetched on first use.
///
/// Same shape and same reasoning as `kNotifyEndpoint`: an address that is going
/// to change should be one named constant, not a string spread across a data
/// layer. Not a secret either — these are public release assets.
///
/// **Live as of 2026-08-19** — release tag `model-v1`. The four assets below
/// are attached to it under exactly these filenames; a rename on the release
/// side is a 404 here, so the tag is treated as immutable and a new set of
/// files gets a new tag rather than an edit to this one.
const String kModelReleaseBaseUrl =
    'https://github.com/RedWaffle007/German-Subtitle-Chatbot/releases/download/model-v1';

/// One file the on-device engine needs, and what "intact" means for it.
///
/// [sha256] and [sizeBytes] are nullable because they were unknowable before the
/// release existed: null means "verify what is knowable" — the bytes received
/// must match the length the server declared. **Every entry below now carries
/// both**, so the strict path is what runs, and it turned on with no code
/// change because `ModelStore.verify` already read them.
///
/// The nullable state is kept rather than tightened to non-null: the next model
/// revision goes through the same before-upload window, and [isPlaceholder]
/// plus the setup screen's "checked by size only" line are what stop that
/// window from silently implying a guarantee it cannot make.
@immutable
class ModelFile {
  const ModelFile({
    required this.name,
    required this.description,
    this.sha256,
    this.sizeBytes,
  });

  /// The release asset's filename, which is also its name on the device. No
  /// path separators — [ModelStore] places it, and a name that could climb out
  /// of the model directory is rejected by [isSafeName].
  final String name;

  /// What this file is, for the progress line. The person watching a 130MB
  /// download deserves better than four opaque filenames.
  final String description;

  /// Lowercase hex sha256 of the finished file, or null while unknown.
  final String? sha256;

  /// Exact byte length of the finished file, or null while unknown.
  final int? sizeBytes;

  String get url => '$kModelReleaseBaseUrl/$name';

  /// True while this entry cannot be strongly verified.
  bool get isPlaceholder => sha256 == null || sizeBytes == null;

  /// A filename is only ever appended to the model directory, so it must not be
  /// able to escape it. Enforced in a test rather than trusted.
  bool get isSafeName =>
      name.isNotEmpty &&
      !name.contains('/') &&
      !name.contains(r'\') &&
      name != '.' &&
      name != '..';
}

/// The engine loads these by name, so the names are constants rather than
/// literals repeated in a second file. A rename on the release side is then one
/// edit, not two that can drift apart.
const String kOnnxModelFile = 'minilm-multilingual.int8.onnx';
const String kTokenizerFile = 'tokenizer.json';
const String kEmbeddingsFile = 'subs_embeddings_int8.npz';
const String kMetaFile = 'subs_meta.json';
const String kEnglishFile = 'subs_en.json';

/// Every file the on-device engine needs, downloaded in this order.
///
/// The big one leads deliberately: if the connection is going to fail, it fails
/// on the file most likely to fail, and the small ones do not create a false
/// sense of progress first.
///
/// Each [name] is the release asset's filename **exactly**; the URL is nothing
/// but the base plus this string, so a typo here is a 404 the user reads as
/// "the app needs an update".
const List<ModelFile> kModelFiles = [
  ModelFile(
    name: kOnnxModelFile,
    description: 'Language model',
    sha256: '05bfc027d05122a83bc4c9fe5fab0f6aa8c114c5d59c0621cb549bff98bd1c19',
    sizeBytes: 118107460,
  ),
  ModelFile(
    name: kTokenizerFile,
    description: 'Tokenizer',
    sha256: 'cad551d5600a84242d0973327029452a1e3672ba6313c2a3c3d69c4310e12719',
    sizeBytes: 17082987,
  ),
  ModelFile(
    name: kEmbeddingsFile,
    description: 'Phrase index',
    sha256: 'ed4a6674d63a8be30a2b4a855e28a36a195024ab15f97cdf0f02e3b5fce3ae72',
    sizeBytes: 7506612,
  ),
  ModelFile(
    name: kMetaFile,
    description: 'Phrase metadata',
    sha256: '3819cfc375c9abcac9c7b0c83bc0ef694d37c3b1c1b0b25c249070b4a9f716fb',
    sizeBytes: 543554,
  ),
  ModelFile(
    name: kEnglishFile,
    description: 'English translations',
    sha256: 'a5fa0007f331866867aaf44b9892ad64696db3bcfdeaeea66f9774d9528299bd',
    sizeBytes: 209871,
  ),
];

/// Total download size, or null while any file's size is unknown.
///
/// Null is what makes the UI show per-file progress instead of inventing an
/// overall percentage it cannot compute (UI-RULES.md §6.7 — never fake a total).
int? get kModelTotalBytes {
  var total = 0;
  for (final file in kModelFiles) {
    final size = file.sizeBytes;
    if (size == null) return null;
    total += size;
  }
  return total;
}
