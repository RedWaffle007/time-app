import 'package:shared_preferences/shared_preferences.dart';

/// Where the practice service lives out of the box: the Tailscale address of
/// the laptop running it.
///
/// A default, **not** a constant the app depends on. The address changes
/// whenever the service moves, which is why it is editable at all — this value
/// only decides what the field is pre-filled with on a fresh install.
const kDefaultChatbotBaseUrl = 'http://100.116.97.26:5000';

/// The base URL of the HTTP practice service, on this device.
///
/// **This whole file belongs to [HttpChatbotService] and dies with it.** When
/// the on-device engine lands there is no address to configure, so the setting,
/// its screen and this store are deleted together. Nothing outside the chatbot
/// feature reads it, and the seam (`ChatbotService`) does not mention it — that
/// is what makes deleting it a local change rather than a migration.
///
/// `shared_preferences`, for the same reason the app-lock flag uses it: this is
/// a property of *this phone* pointed at *this laptop*, not of the account.
/// Putting it on the Firestore profile would sync a LAN address to devices that
/// cannot reach it.
abstract interface class ChatbotEndpointStore {
  /// The configured address, or [kDefaultChatbotBaseUrl] if none was ever set.
  /// Never returns an unnormalised or empty string.
  Future<String> baseUrl();

  /// Persist [value]. Normalised on the way in, so a stored address is always
  /// something [Uri.parse] can use directly.
  Future<void> setBaseUrl(String value);
}

class SharedPrefsChatbotEndpointStore implements ChatbotEndpointStore {
  const SharedPrefsChatbotEndpointStore();

  static const _key = 'chatbot_base_url';

  @override
  Future<String> baseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_key);
    if (stored == null) return kDefaultChatbotBaseUrl;
    // Re-normalise on read as well as write: a value stored by an older build
    // (or hand-edited) must not be able to produce a broken Uri here, where
    // there is no user in front of the failure to explain it to.
    return normalizeBaseUrl(stored) ?? kDefaultChatbotBaseUrl;
  }

  @override
  Future<void> setBaseUrl(String value) async {
    final normalized = normalizeBaseUrl(value);
    if (normalized == null) {
      throw ArgumentError.value(value, 'value', 'not a usable base URL');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, normalized);
  }
}

/// Clean up what a person types into a form field, or return null if it cannot
/// be made into an address.
///
/// Shared by the settings screen (to validate *before* saving, so the user sees
/// the refusal) and by the store (so nothing invalid can be persisted by any
/// other route). One function, so the two can never disagree about what counts
/// as valid.
///
/// Typing a bare `host:port` is the common case on a phone keyboard, so a
/// missing scheme is filled in as `http://` rather than rejected. A trailing
/// slash is dropped so paths can be appended with a plain `'$base/chat'`.
String? normalizeBaseUrl(String input) {
  var text = input.trim();
  if (text.isEmpty) return null;
  if (!text.contains('://')) text = 'http://$text';

  final uri = Uri.tryParse(text);
  if (uri == null) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  if (uri.host.isEmpty) return null;

  // Keep only what a base URL is allowed to carry. A query or fragment pasted
  // in by accident would otherwise end up glued in front of `/chat`.
  final path = uri.path.replaceAll(RegExp(r'/+$'), '');
  return Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null, path: path)
      .toString();
}
