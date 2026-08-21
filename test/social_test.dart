import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/social/domain/avatar.dart';
import 'package:time_app/features/social/domain/profile_visibility.dart';
import 'package:time_app/features/social/domain/social_ids.dart';
import 'package:time_app/features/social/domain/username.dart';

/// Covers the pure half of the social layer — the half where the logic that can
/// actually be wrong lives.
///
/// Same discipline as `reminder_scheduling_test.dart`: the repositories are thin
/// Firestore wrappers with nothing to decide, so the value is in testing the
/// id derivation, the validation and the visibility matrix, none of which need
/// a device, a network or a Firebase project.
void main() {
  group('username validation', () {
    test('canonical form is trimmed and lowercased', () {
      expect(canonicalUsername('  Ana_B  '), 'ana_b');
    });

    test('lowercasing is locale-INDEPENDENT', () {
      // The Turkish dotted/dotless I is the classic break. If canonicalisation
      // were locale-sensitive, the same handle typed on a Turkish phone and an
      // English one would produce two different reservation keys — a uniqueness
      // guarantee that silently depended on the typist's device.
      expect(canonicalUsername('ANIL'), 'anil');
      expect(canonicalUsername('Iris'), 'iris');
    });

    test('accepts a plain handle', () {
      expect(validateUsername('ana_b12'), UsernameProblem.none);
      expect(isValidUsername('ana'), isTrue);
    });

    test('enforces both length bounds', () {
      expect(validateUsername('ab'), UsernameProblem.tooShort);
      expect(validateUsername('a' * 21), UsernameProblem.tooLong);
      expect(validateUsername('a' * 20), UsernameProblem.none);
    });

    test('rejects anything outside [a-z0-9_]', () {
      for (final bad in ['ana.b', 'ana-b', 'ana b', 'Ana', 'anaé', 'ana!']) {
        expect(
          validateUsername(bad),
          UsernameProblem.badCharacters,
          reason: '"$bad" should be refused',
        );
      }
    });

    test('must start with a letter', () {
      expect(validateUsername('1ana'), UsernameProblem.mustStartWithLetter);
      expect(validateUsername('_ana'), UsernameProblem.mustStartWithLetter);
    });

    test('reserved handles are refused, case-insensitively', () {
      expect(validateUsername('admin'), UsernameProblem.reserved);
      expect(validateUsername(canonicalUsername('Admin')),
          UsernameProblem.reserved);
      expect(validateUsername('support'), UsernameProblem.reserved);
    });

    test('every route segment the router owns is reserved', () {
      // A handle colliding with a route would make a future vanity URL
      // ambiguous, and migrating someone's handle later is far worse than
      // reserving the word now.
      for (final route in ['friends', 'profile', 'groups', 'outcome', 'user']) {
        expect(kReservedUsernames, contains(route));
      }
    });
  });

  group('relationship document ids', () {
    const a = 'AAAAuid';
    const b = 'ZZZZuid';

    test('a friendship id is SYMMETRIC — both parties compute the same one', () {
      // The property the whole privacy model rests on. If the two sides could
      // derive different addresses, one friendship would be two documents, the
      // rules would have to check both, and unfriending would remove half an
      // edge.
      expect(friendshipId(a, b), friendshipId(b, a));
      expect(friendshipId(a, b), 'AAAAuid_ZZZZuid');
    });

    test('a friend-request id is DIRECTED — the two directions differ', () {
      // Crossing requests must be two documents. Sorting this id would make the
      // second one overwrite the first.
      expect(
        friendRequestId(fromUid: a, toUid: b),
        isNot(friendRequestId(fromUid: b, toUid: a)),
      );
      expect(friendRequestId(fromUid: a, toUid: b), 'AAAAuid_ZZZZuid');
      expect(friendRequestId(fromUid: b, toUid: a), 'ZZZZuid_AAAAuid');
    });

    test('a block id is DIRECTED — A blocking B is not B blocking A', () {
      expect(
        blockId(blockerUid: a, blockedUid: b),
        isNot(blockId(blockerUid: b, blockedUid: a)),
      );
    });
  });

  group('profile visibility', () {
    const me = 'me';
    const them = 'them';

    ProfileRelation relation({
      bool isFriend = false,
      bool iBlocked = false,
      bool theyBlocked = false,
      bool outgoing = false,
      bool incoming = false,
    }) {
      return relationBetween(
        viewerUid: me,
        profileUid: them,
        isFriend: isFriend,
        viewerBlockedThem: iBlocked,
        theyBlockedViewer: theyBlocked,
        outgoingRequestPending: outgoing,
        incomingRequestPending: incoming,
      );
    }

    test('own profile is self', () {
      expect(
        relationBetween(
          viewerUid: me,
          profileUid: me,
          isFriend: false,
          viewerBlockedThem: false,
          theyBlockedViewer: false,
          outgoingRequestPending: false,
          incomingRequestPending: false,
        ),
        ProfileRelation.self,
      );
    });

    test('a block OUTRANKS a stale friendship or request, both directions', () {
      // Blocking cleans up across several documents and is not atomic, so a
      // leftover friendship row can genuinely coexist with a fresh block. The
      // block has to win, or the cleanup order becomes security-critical.
      expect(
        relation(isFriend: true, iBlocked: true),
        ProfileRelation.blocking,
      );
      expect(
        relation(isFriend: true, theyBlocked: true),
        ProfileRelation.blockedBy,
      );
      expect(
        relation(outgoing: true, theyBlocked: true),
        ProfileRelation.blockedBy,
      );
    });

    test('friendship outranks a leftover request row', () {
      expect(relation(isFriend: true, outgoing: true), ProfileRelation.friend);
    });

    test('request direction is distinguished', () {
      expect(relation(outgoing: true), ProfileRelation.requestSent);
      expect(relation(incoming: true), ProfileRelation.requestReceived);
      expect(relation(), ProfileRelation.none);
    });

    test('a PRIVATE profile hides stats from a stranger', () {
      final v = visibilityFor(relation: ProfileRelation.none, isPublic: false);
      expect(v.canSeeStats, isFalse);
      expect(v.canSendRequest, isTrue);
    });

    test('a PUBLIC profile shows stats to a stranger — the leaderboard case', () {
      final v = visibilityFor(relation: ProfileRelation.none, isPublic: true);
      expect(v.canSeeStats, isTrue);
    });

    test('a friend sees stats even when the profile is private', () {
      final v = visibilityFor(relation: ProfileRelation.friend, isPublic: false);
      expect(v.canSeeStats, isTrue);
    });

    test('a PENDING request grants nothing', () {
      // If it did, a private profile would be readable by anyone willing to tap
      // Add friend and never follow up.
      for (final r in [
        ProfileRelation.requestSent,
        ProfileRelation.requestReceived,
      ]) {
        expect(
          visibilityFor(relation: r, isPublic: false).canSeeStats,
          isFalse,
          reason: '$r must not unlock a private profile',
        );
      }
    });

    test('a block hides stats even on a PUBLIC profile', () {
      for (final r in [ProfileRelation.blocking, ProfileRelation.blockedBy]) {
        final v = visibilityFor(relation: r, isPublic: true);
        expect(v.canSeeStats, isFalse, reason: '$r must override isPublic');
        expect(v.canSendRequest, isFalse);
        expect(v.isUnreachable, isTrue);
      }
    });

    test('someone who has been blocked can still block back', () {
      // Removing the control would announce the block by its absence.
      expect(
        visibilityFor(relation: ProfileRelation.blockedBy, isPublic: false)
            .canBlock,
        isTrue,
      );
      expect(
        visibilityFor(relation: ProfileRelation.blocking, isPublic: false)
            .canBlock,
        isFalse,
      );
    });

    test('you cannot friend-request or block yourself', () {
      final v = visibilityFor(relation: ProfileRelation.self, isPublic: true);
      expect(v.canSendRequest, isFalse);
      expect(v.canBlock, isFalse);
      expect(v.canSeeStats, isTrue);
    });
  });

  group('avatar limits', () {
    test('animated-capable formats get the larger cap', () {
      expect(avatarMaxBytesFor('image/gif'), kAvatarMaxBytesAnimated);
      expect(avatarMaxBytesFor('image/webp'), kAvatarMaxBytesAnimated);
      expect(avatarMaxBytesFor('image/png'), kAvatarMaxBytesStatic);
      expect(avatarMaxBytesFor('image/jpeg'), kAvatarMaxBytesStatic);
    });

    test('an unknown type gets the STRICTER cap', () {
      // An unrecognised format must never buy a larger allowance.
      expect(avatarMaxBytesFor('image/svg+xml'), kAvatarMaxBytesStatic);
      expect(avatarMaxBytesFor(''), kAvatarMaxBytesStatic);
    });

    test('accepts the four supported formats and nothing else', () {
      for (final mime in [
        'image/jpeg',
        'image/png',
        'image/gif',
        'image/webp',
      ]) {
        expect(isAllowedAvatarMime(mime), isTrue, reason: mime);
      }
      // SVG in particular: served from a trusted origin it is a scripting
      // primitive, not a picture.
      for (final mime in ['image/svg+xml', 'text/html', 'image/bmp', '']) {
        expect(isAllowedAvatarMime(mime), isFalse, reason: mime);
      }
    });

    test('pre-flight refuses empty, oversized and unsupported files', () {
      expect(
        checkAvatarUpload(mime: 'image/png', bytes: 0),
        AvatarRejection.empty,
      );
      expect(
        checkAvatarUpload(mime: 'image/svg+xml', bytes: 100),
        AvatarRejection.unsupportedFormat,
      );
      expect(
        checkAvatarUpload(mime: 'image/png', bytes: kAvatarMaxBytesStatic + 1),
        AvatarRejection.tooLarge,
      );
      // The same byte count is fine as an animated format.
      expect(
        checkAvatarUpload(mime: 'image/gif', bytes: kAvatarMaxBytesStatic + 1),
        AvatarRejection.none,
      );
    });

    test('a rejected or pending picture is not displayable', () {
      ProfileAvatar withState(AvatarModeration m) => ProfileAvatar(
            url: 'https://example.test/a.gif',
            storageKey: 'avatars/u/a.gif',
            mime: 'image/gif',
            sizeBytes: 10,
            moderation: m,
          );

      expect(withState(AvatarModeration.approved).isDisplayable, isTrue);
      // Flagged stays visible: a report is an accusation, not a finding, and
      // hiding on accusation alone is a griefing tool.
      expect(withState(AvatarModeration.flagged).isDisplayable, isTrue);
      expect(withState(AvatarModeration.pending).isDisplayable, isFalse);
      expect(withState(AvatarModeration.rejected).isDisplayable, isFalse);
    });

    test('an unreadable moderation state fails CLOSED', () {
      final avatar = ProfileAvatar.fromMap({
        'url': 'https://example.test/a.png',
        'storageKey': 'avatars/u/a.png',
        'mime': 'image/png',
        'sizeBytes': 10,
        'moderation': 'something-new-from-the-future',
      });
      expect(avatar!.moderation, AvatarModeration.pending);
      expect(avatar.isDisplayable, isFalse);
    });
  });
}
