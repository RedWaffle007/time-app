import '../../../core/config/notify_config.dart';
import '../../social/domain/username.dart';

/// A tap-to-open invite link (item 17, 2026-09-26), served by the Worker:
///
///   `https://{worker}/i/u/{username}` — add a friend
///   `https://{worker}/i/g/{joinCode}` — ask to join a group
///
/// It carries only an existing username or join code; the Worker's
/// `invite.js` validates the same two shapes and must stay in step.
enum InviteKind { user, group }

class InviteLink {
  const InviteLink(this.kind, this.value);

  final InviteKind kind;

  /// Canonical: a lowercase username, or an uppercase join code.
  final String value;

  static final _joinCode = RegExp(r'^[A-HJ-NP-Z2-9]{6}$');

  /// The invite a path (`/i/u/ana`, as go_router sees an App Link) names, or
  /// null for anything else — including a malformed or hostile value.
  static InviteLink? parsePath(String path) {
    final match = RegExp(r'^/i/([ug])/([^/]+)/?$').firstMatch(path);
    if (match == null) return null;
    String value;
    try {
      value = Uri.decodeComponent(match.group(2)!).trim();
    } on ArgumentError {
      return null;
    }
    if (match.group(1) == 'u') {
      final handle = canonicalUsername(value);
      return isValidUsername(handle)
          ? InviteLink(InviteKind.user, handle)
          : null;
    }
    final code = value.toUpperCase();
    return _joinCode.hasMatch(code) ? InviteLink(InviteKind.group, code) : null;
  }

  /// The shareable https link for this invite.
  Uri toUri() => Uri.parse(
    kNotifyEndpoint,
  ).replace(path: '/i/${kind == InviteKind.user ? 'u' : 'g'}/$value');

  @override
  bool operator ==(Object other) =>
      other is InviteLink && other.kind == kind && other.value == value;

  @override
  int get hashCode => Object.hash(kind, value);

  @override
  String toString() => 'InviteLink($kind, $value)';
}

/// "Add me on Checkmate" — share text for a friend invite.
String friendInviteShareText(String username) =>
    'Add me on Checkmate: ${InviteLink(InviteKind.user, canonicalUsername(username)).toUri()}';

/// "Join my group" — share text for a group invite. Keeps the code visible
/// for anyone who prefers to type it.
String groupInviteShareText(String groupName, String joinCode) =>
    'Join my group "$groupName" on Checkmate: '
    '${InviteLink(InviteKind.group, joinCode.toUpperCase()).toUri()}\n'
    'Or enter the code $joinCode in the app.';
