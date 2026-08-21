import 'package:flutter/material.dart';

import '../../../core/theme/app_text.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../auth/domain/user_profile.dart';

/// **The one profile-picture widget.** Every avatar in the app draws through
/// this — list rows, profile headers, the edit form.
///
/// Three things it guarantees, each of which was a bug waiting to happen if
/// left to call sites:
///
/// 1. **Animated GIF and WebP play.** Flutter's `Image.network` decodes and
///    animates both natively, so this needs no package and no special case —
///    but only if nobody wraps it in something that rasterises a single frame.
///    Do not add `cacheWidth`/`cacheHeight` here: they resize by re-decoding,
///    and on a multi-frame image that is how animation silently becomes a
///    still.
///
/// 2. **A failed load never shows a broken image.** A stored URL can 404 — the
///    object was deleted, the bucket moved, the network is down mid-scroll —
///    and `errorBuilder` falls back to the initial rather than to a grey box
///    with a torn-page glyph.
///
/// 3. **Moderation is honoured.** [UserProfile.displayAvatarUrl] returns null
///    for a withheld or rejected picture, so a moderated avatar renders as the
///    initial and there is no second code path that could forget to check.
///
/// The fallback is the display name's first letter on a `primaryContainer`
/// tint. Line work and a container tint, never an orange fill — orange is
/// rationed to state the user must act on (UI-RULES.md §2.7), and a person
/// without a photo is not a state.
class AvatarImage extends StatelessWidget {
  const AvatarImage({
    super.key,
    required this.profile,
    this.size = Sizes.avatarRow,
  });

  /// Null renders the neutral placeholder — used while a profile is still
  /// loading, so a row does not jump when the picture arrives.
  final UserProfile? profile;

  final double size;

  @override
  Widget build(BuildContext context) {
    final url = profile?.displayAvatarUrl;
    final cs = context.colors;

    return SizedBox(
      width: size,
      height: size,
      child: ClipOval(
        child: Container(
          color: cs.primaryContainer,
          alignment: Alignment.center,
          child: url == null
              ? _Initial(profile: profile, size: size)
              : Image.network(
                  url,
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                  // See point 1 in the class doc — no cacheWidth/cacheHeight.
                  errorBuilder: (context, error, stack) =>
                      _Initial(profile: profile, size: size),
                  // The initial stands in while bytes arrive, rather than a
                  // spinner. A 40pt spinner in a list row reads as breakage;
                  // the letter is what the row will fall back to anyway if the
                  // load fails, so nothing moves when it resolves.
                  loadingBuilder: (context, child, progress) => progress == null
                      ? child
                      : _Initial(profile: profile, size: size),
                ),
        ),
      ),
    );
  }
}

class _Initial extends StatelessWidget {
  const _Initial({required this.profile, required this.size});

  final UserProfile? profile;
  final double size;

  @override
  Widget build(BuildContext context) {
    final name = profile?.name.trim() ?? '';
    // `characters` semantics matter here: `name[0]` on an emoji or a
    // combining-mark name would slice a grapheme in half and render a
    // replacement glyph. Taking the first *character cluster* is correct in
    // every script the app supports.
    final initial = name.isEmpty ? '' : name.characters.first.toUpperCase();

    return Text(
      initial,
      // Scaled to the circle rather than a fixed token, because the same widget
      // draws at 40, 72 and 96. `titleMedium` at 40pt is right; the same style
      // at 96pt would be a letter floating in a large empty disc. A ratio keeps
      // the optical weight constant across all three.
      // Sized from the circle's diameter, not from the type scale — see
      // AppText.avatarInitial for why a letter-as-graphic is not a scale entry.
      style: AppText.avatarInitial(size)
          .copyWith(color: context.colors.onPrimaryContainer),
    );
  }
}
