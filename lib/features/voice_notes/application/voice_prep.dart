// Named public collaborators keep call sites legible; private initializing
// formals would expose unusable `_client:`-style parameter names.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../scheduling/domain/schedule_item.dart';
import '../data/voice_note_client.dart';
import 'group_voice_attacher.dart';

/// One recipient's voice note, already on the server under [itemId]: the plan
/// for that person is created with exactly this id and metadata.
typedef PreparedVoice = ({String itemId, VoiceNoteMeta meta});

enum VoicePrepPhase { idle, working, ready, failed }

/// **Sends the voice note while the planner finishes the plan** (2026-10-04,
/// user-directed). The upload starts the moment a recording stops (or a
/// library note is picked), so Send usually only writes the plan.
///
/// For several recipients it reuses [GroupVoiceAttacher]: one upload, then a
/// server-side copy per further person. A connection problem is retried here
/// quietly; only a refusal (no permission, bad audio) or a connection that
/// stays down through every attempt ends a run as [VoicePrepPhase.failed].
///
/// Every [start] mints FRESH plan ids. Reusing an id across a re-record would
/// let the older upload finish last and leave the server's audio and its
/// record disagreeing with the metadata the plan carries; unused uploads are
/// deleted by the Worker's orphan sweep.
class VoicePrep extends ChangeNotifier {
  VoicePrep({
    required VoiceNoteClient client,
    required String Function(String targetUid) mintItemId,
    this.retryDelays = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
    ],
  }) : _client = client,
       _mintItemId = mintItemId;

  final VoiceNoteClient _client;
  final String Function(String targetUid) _mintItemId;

  /// The pauses between attempts after a connection problem; one attempt
  /// more than there are delays.
  final List<Duration> retryDelays;

  VoicePrepPhase _phase = VoicePrepPhase.idle;
  VoicePrepPhase get phase => _phase;

  /// The words for a failed run.
  String? _error;
  String? get error => _error;

  final Map<String, PreparedVoice> _done = {};

  /// Recipients refused for good (the Worker's own words); they get no plan.
  final Map<String, String> _refused = {};
  Map<String, String> get refused => Map.unmodifiable(_refused);

  int _gen = 0;
  Completer<void>? _run;
  Uint8List? _recording;
  String? _libraryNoteId;
  String _groupId = '';
  List<String> _targets = const [];

  /// Whether a run has been started for anything at all.
  bool get hasSource => _recording != null || _libraryNoteId != null;

  /// Starts (or restarts) preparing [recording] or [libraryNoteId] for each
  /// of [targetUids], in order. Any earlier run's result is dropped.
  void start({
    Uint8List? recording,
    String? libraryNoteId,
    required List<String> targetUids,
    String groupId = '',
  }) {
    assert((recording == null) != (libraryNoteId == null));
    _recording = recording;
    _libraryNoteId = libraryNoteId;
    _groupId = groupId;
    _targets = List.unmodifiable(targetUids);
    _done.clear();
    _refused.clear();
    _launch();
  }

  /// The same source, for a new set of recipients (the planner changed who
  /// the plan is for after recording).
  void retarget(List<String> targetUids, {String groupId = ''}) {
    if (!hasSource) return;
    start(
      recording: _recording,
      libraryNoteId: _libraryNoteId,
      targetUids: targetUids,
      groupId: groupId,
    );
  }

  /// Forget everything: the note was discarded or the kind no longer takes
  /// one. A run in flight finishes into nothing.
  void clear() {
    _gen++;
    _recording = null;
    _libraryNoteId = null;
    _targets = const [];
    _done.clear();
    _refused.clear();
    _finish(_run);
    _run = null;
    _set(VoicePrepPhase.idle, null);
  }

  /// Waits for the current run. When it had failed on a connection problem,
  /// the missing recipients are tried once more first (Send's own attempt).
  /// Then: each recipient's prepared note, or null for one refused or still
  /// missing. Check [phase] for the outcome.
  Future<Map<String, PreparedVoice?>> ready() async {
    if (_phase == VoicePrepPhase.failed && _refused.length < _targets.length) {
      _launch(onlyMissing: true);
    }
    await _run?.future;
    return {for (final uid in _targets) uid: _done[uid]};
  }

  void _launch({bool onlyMissing = false}) {
    final gen = ++_gen;
    final previous = _run;
    final run = Completer<void>();
    _run = run;
    // A superseded waiter must not hang: it resolves with the new run.
    if (previous != null && !previous.isCompleted) {
      unawaited(run.future.then((_) => _finish(previous)));
    }
    _set(VoicePrepPhase.working, null);
    unawaited(_work(gen, run, onlyMissing: onlyMissing));
  }

  Future<void> _work(
    int gen,
    Completer<void> run, {
    required bool onlyMissing,
  }) async {
    final attacher = GroupVoiceAttacher(
      client: _client,
      groupId: _groupId,
      recording: _recording,
      libraryNoteId: _recording == null ? _libraryNoteId : null,
    );
    String? connectionError;
    // A copy needs the source upload; on a resumed run, upload again for the
    // first missing recipient, then copy from that.
    for (final uid in _targets) {
      if (gen != _gen) return;
      if (_done.containsKey(uid) || _refused.containsKey(uid)) continue;
      try {
        final itemId = _mintItemId(uid);
        final meta = await _withRetries(
          gen,
          () => attacher(targetUid: uid, itemId: itemId),
        );
        if (gen != _gen) return;
        _done[uid] = (itemId: itemId, meta: meta);
      } on VoiceNoteFailure catch (e) {
        if (gen != _gen) return;
        if (e.retryable) {
          connectionError = e.message;
        } else {
          _refused[uid] = e.message;
        }
      } catch (_) {
        if (gen != _gen) return;
        connectionError = voiceNoteErrorMessage(null);
      }
    }
    if (gen != _gen) return;
    final missing = _targets.where(
      (uid) => !_done.containsKey(uid) && !_refused.containsKey(uid),
    );
    if (missing.isNotEmpty) {
      _set(VoicePrepPhase.failed, connectionError ?? kVoiceUploadFailed);
    } else if (_done.isEmpty) {
      _set(VoicePrepPhase.failed, _refused.values.first);
    } else {
      _set(VoicePrepPhase.ready, null);
    }
    _finish(run);
  }

  static void _finish(Completer<void>? run) {
    if (run != null && !run.isCompleted) run.complete();
  }

  /// Runs [attempt], retrying a connection problem after each delay.
  Future<VoiceNoteMeta> _withRetries(
    int gen,
    Future<VoiceNoteMeta> Function() attempt,
  ) async {
    for (var i = 0; ; i++) {
      try {
        return await attempt();
      } on VoiceNoteFailure catch (e) {
        if (!e.retryable || i >= retryDelays.length || gen != _gen) rethrow;
      } catch (_) {
        if (i >= retryDelays.length || gen != _gen) rethrow;
      }
      await Future<void>.delayed(retryDelays[i]);
    }
  }

  void _set(VoicePrepPhase phase, String? error) {
    _phase = phase;
    _error = error;
    notifyListeners();
  }

  @override
  void dispose() {
    _gen++;
    _finish(_run);
    super.dispose();
  }
}

/// Shown, with Retry, when a voice note genuinely could not be sent.
const kVoiceUploadFailed =
    "Upload failed. Check your connection, then tap Retry.";
