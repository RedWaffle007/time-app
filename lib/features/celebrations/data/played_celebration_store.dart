import 'package:shared_preferences/shared_preferences.dart';

/// Which celebrations have already played their confetti on THIS device, per
/// account (device report 2026-09-28: the planner saw the confetti twice).
///
/// The Firestore queue stays the delivery path and is still acknowledged as
/// before; this only guarantees one burst per event per phone, whatever
/// replays it (a restart before the acknowledgement landed, a failed offline
/// acknowledgement, a rebuilt host). The planner's pop-up is not affected.
abstract interface class PlayedCelebrationStore {
  Future<Set<String>> load(String uid);
  Future<void> markPlayed(String uid, String eventId);
}

/// One per app (a provider), so a rebuilt host keeps what this process has
/// played even before the stored list is read back; an unreadable store falls
/// back to that memory.
class PlayedCelebrations {
  PlayedCelebrations(this._store);

  final PlayedCelebrationStore _store;
  final _byUid = <String, Set<String>>{};

  Set<String> _memory(String uid) => _byUid.putIfAbsent(uid, () => {});

  Future<void> load(String uid) async {
    try {
      _memory(uid).addAll(await _store.load(uid));
    } catch (_) {}
  }

  bool hasPlayed(String uid, String eventId) => _memory(uid).contains(eventId);

  void markPlayed(String uid, String eventId) {
    _memory(uid).add(eventId);
    _store.markPlayed(uid, eventId).catchError((_) {});
  }
}

class SharedPrefsPlayedCelebrationStore implements PlayedCelebrationStore {
  const SharedPrefsPlayedCelebrationStore();

  static String _key(String uid) => 'celebrations_played_v1_$uid';

  /// Newest ids kept; an event is acknowledged long before this many more.
  static const _keep = 100;

  @override
  Future<Set<String>> load(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_key(uid)) ?? const []).toSet();
  }

  @override
  Future<void> markPlayed(String uid, String eventId) async {
    final prefs = await SharedPreferences.getInstance();
    final ids = [
      for (final id in prefs.getStringList(_key(uid)) ?? const <String>[])
        if (id != eventId) id,
      eventId,
    ];
    await prefs.setStringList(
      _key(uid),
      ids.length > _keep ? ids.sublist(ids.length - _keep) : ids,
    );
  }
}
