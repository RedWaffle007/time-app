import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../routing/app_router.dart';
import '../../auth/application/auth_providers.dart';
import '../application/social_providers.dart';
import '../data/username_repository.dart';
import '../domain/username.dart';
import 'user_row.dart';

/// Find someone by their exact username.
///
/// **Exact match only, and that is a security property rather than a missing
/// feature.** `users` has `allow list: if false` — applied deliberately,
/// because an unfiltered list over that collection leaked every user's name,
/// home timezone and quiet-hours window, i.e. when each person sleeps. Prefix
/// or fuzzy search needs `list` on *something* keyed by name, and adding it
/// here would reopen that hole through a different door.
///
/// So the search primitive is a `get` on `usernames/{handle}`: you can resolve
/// a handle you were given, and you cannot enumerate. The screen says so in
/// plain words rather than leaving the user to conclude the search is broken.
///
/// The trade-off, named: people have to exchange handles out-of-band. That is
/// the same shape as the group join code, which this app already relies on, and
/// it is the honest cost of not being enumerable.
class UserSearchScreen extends ConsumerStatefulWidget {
  const UserSearchScreen({super.key});

  @override
  ConsumerState<UserSearchScreen> createState() => _UserSearchScreenState();
}

class _UserSearchScreenState extends ConsumerState<UserSearchScreen> {
  final _controller = TextEditingController();

  /// What the last completed search found. Three distinct states, and they must
  /// stay distinct: null = nothing searched yet, empty string = searched and
  /// found nobody, a uid = found.
  String? _foundUid;
  bool _searched = false;
  bool _searching = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final raw = _controller.text;
    final handle = canonicalUsername(raw);

    final problem = validateUsername(handle);
    if (problem != UsernameProblem.none) {
      setState(() {
        _error = describeUsernameProblem(problem);
        _searched = false;
        _foundUid = null;
      });
      return;
    }

    setState(() {
      _searching = true;
      _error = null;
    });

    try {
      final uid = await ref.read(usernameRepositoryProvider).lookup(handle);
      if (!mounted) return;
      setState(() {
        _foundUid = uid;
        _searched = true;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Search failed. $e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(currentUidProvider);
    final muted = context.colors.onSurfaceVariant;

    return Scaffold(
      appBar: AppBar(title: const Text('Find people')),
      body: ListView(
        padding: Space.screenFormSafe(context),
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              labelText: 'Username',
              prefixIcon: const Icon(AppIcons.username),
              errorText: _error,
              suffixIcon: IconButton(
                tooltip: 'Search',
                icon: const Icon(AppIcons.search),
                onPressed: _searching ? null : _search,
              ),
            ),
            onChanged: (_) {
              // Clear a stale result the moment the query changes, so a "not
              // found" from the previous search cannot sit under a new query
              // and look like its answer.
              if (_searched || _error != null) {
                setState(() {
                  _searched = false;
                  _foundUid = null;
                  _error = null;
                });
              }
            },
            onSubmitted: (_) => _search(),
          ),
          const SizedBox(height: Space.md),
          Text(
            'Search matches a full username exactly — people are not '
            'listed or browsable, so ask for theirs the way you would a '
            'phone number.',
            style: context.text.bodySmall?.copyWith(color: muted),
          ),
          const SizedBox(height: Space.xl),
          if (_searching)
            const Center(child: CircularProgressIndicator())
          else if (_searched && _foundUid == null)
            _Message(
              icon: AppIcons.profileUnavailable,
              // Deliberately does not distinguish "no such handle" from
              // "that person blocked you" — the second must be indistinguishable
              // from the first, or a block announces itself.
              text: 'Nobody has that username.',
            )
          else if (_foundUid case final uid?)
            uid == me
                ? const _Message(
                    icon: AppIcons.viewProfile,
                    text: "That's you.",
                  )
                : _SearchResult(uid: uid),
        ],
      ),
    );
  }
}

/// A found user — unless a block sits between the two, in which case this
/// renders exactly what "no such username" renders.
///
/// **The indistinguishability is the point.** A search that said "found, but
/// unavailable" would tell someone they had been blocked, which is the one fact
/// a block exists to withhold — and it would do so on the cheapest possible
/// surface, since anyone can type a handle. The uid is already resolved at this
/// point (the reservation is readable by any signed-in user); what is withheld
/// is the acknowledgement.
class _SearchResult extends ConsumerWidget {
  const _SearchResult({required this.uid});

  final String uid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visibility = ref.watch(profileVisibilityProvider(uid));

    // While the relationship is still resolving, show nothing rather than the
    // row. Rendering it first and withdrawing it a frame later would flash the
    // name of someone who blocked the searcher.
    final v = visibility.value;
    if (v == null) return const Center(child: CircularProgressIndicator());

    if (v.isUnreachable) {
      return const _Message(
        icon: AppIcons.profileUnavailable,
        text: 'Nobody has that username.',
      );
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Space.sm),
        child: UserRow(
          uid: uid,
          onTap: () => context.push(Routes.userProfileFor(uid)),
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final muted = context.colors.onSurfaceVariant;
    return Column(
      children: [
        Icon(icon, size: Sizes.emptyStateIcon, color: muted),
        const SizedBox(height: Space.md),
        Text(
          text,
          textAlign: TextAlign.center,
          style: context.text.bodyMedium?.copyWith(color: muted),
        ),
      ],
    );
  }
}
