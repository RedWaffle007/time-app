import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/format/datetime_format.dart';
import '../../../core/widgets/section_header.dart';
import '../../applock/presentation/app_lock_tile.dart';
import '../../social/application/social_providers.dart';
import '../../social/data/username_repository.dart';
import '../../social/domain/username.dart';
import '../../social/presentation/profile_avatar_editor.dart';
import '../../social/presentation/social_profile_editor.dart';
import '../application/auth_providers.dart';
import 'timezone_picker.dart';

/// Edit an existing profile. Reachable once a profile exists (unlike
/// CompleteProfileScreen, which is the first-time create flow).
///
/// **One draft, one Save.** Name, home timezone, username, bio and the quiet-
/// hours window are all edited as a single draft committed by the one
/// "Save changes" button. This replaced two separate Save buttons (identity vs.
/// username/bio) that read as clutter on device. The three controls that are
/// deliberately NOT part of the draft stay instant, because a control that looks
/// like it needs saving but is really live is a safety trap: the profile
/// **picture** (an upload with its own progress), the **privacy** toggle (a
/// flip-and-walk-away safety switch — see [SocialProfileEditor]) and the
/// **app lock** (see AppLockTile). Section order is identity → public profile →
/// quiet hours → this device.
class ProfileEditScreen extends ConsumerStatefulWidget {
  const ProfileEditScreen({super.key});

  @override
  ConsumerState<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends ConsumerState<ProfileEditScreen> {
  final _nameController = TextEditingController();
  final _usernameController = TextEditingController();
  final _bioController = TextEditingController();
  String? _timezone;
  bool _initialised = false;
  bool _saving = false;
  String? _error;

  // Quiet hours (in the user's own timezone). Off until they set it; defaults
  // to a sensible overnight window when first enabled.
  bool _quietEnabled = false;
  TimeOfDay _quietStart = const TimeOfDay(hour: 22, minute: 0);
  TimeOfDay _quietEnd = const TimeOfDay(hour: 7, minute: 0);

  // What was loaded from the profile, kept so [_isDirty] can tell an actual
  // edit from a screen the user merely opened. Captured by the same one-shot
  // prefill that seeds the fields above.
  String _savedName = '';
  String? _savedTimezone;
  String? _savedUsername;
  String _savedBio = '';
  bool _savedQuietEnabled = false;
  TimeOfDay _savedQuietStart = const TimeOfDay(hour: 22, minute: 0);
  TimeOfDay _savedQuietEnd = const TimeOfDay(hour: 7, minute: 0);

  /// Bio length cap, mirrored in `firestore.rules`. 300 characters is a
  /// paragraph — enough to say who you are, short enough that a header stays a
  /// header. The rule enforces it; this keeps the counter honest.
  static const _maxBioLength = 300;

  /// Whether leaving now would lose something.
  ///
  /// The name and bio are compared **trimmed** (that is what a save writes), and
  /// the username is compared **canonicalised** (a claim lowercases it), so
  /// cosmetic-only typing is not treated as an edit. The quiet-hours times only
  /// count when the window is enabled — the pickers keep their defaults while
  /// the switch is off, and those defaults are not an edit.
  bool get _isDirty {
    if (_nameController.text.trim() != _savedName.trim()) return true;
    if (_timezone != _savedTimezone) return true;
    if (canonicalUsername(_usernameController.text) != (_savedUsername ?? '')) {
      return true;
    }
    if (_bioController.text.trim() != _savedBio.trim()) return true;
    if (_quietEnabled != _savedQuietEnabled) return true;
    if (!_quietEnabled) return false;
    return _quietStart != _savedQuietStart || _quietEnd != _savedQuietEnd;
  }

  /// The name is required, so an empty box needs to SAY so (a greyed Save with
  /// no stated reason was a dead end found on device 2026-08-15).
  String? get _nameError =>
      _nameController.text.trim().isEmpty ? 'Your name is required' : null;

  /// Username is required and must be well-formed — same validation as
  /// onboarding, so create and edit enforce identically.
  String? get _usernameError {
    final raw = _usernameController.text.trim();
    if (raw.isEmpty) return 'Username is required.';
    final problem = validateUsername(canonicalUsername(raw));
    return problem == UsernameProblem.none
        ? null
        : describeUsernameProblem(problem);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _usernameController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  Future<void> _pickTimezone() async {
    final chosen = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const TimezonePicker()));
    if (chosen != null) setState(() => _timezone = chosen);
  }

  Future<void> _pickQuietStart() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _quietStart,
    );
    if (picked != null) setState(() => _quietStart = picked);
  }

  Future<void> _pickQuietEnd() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _quietEnd,
    );
    if (picked != null) setState(() => _quietEnd = picked);
  }

  int _minutes(TimeOfDay t) => t.hour * 60 + t.minute;

  /// Back with unsaved edits asks before throwing them away.
  ///
  /// Deliberately a confirm, NOT a block: the user must always be able to leave,
  /// including out of an invalid state such as an empty name. Saving is
  /// unaffected — [_save] calls `Navigator.pop` directly, and a direct `pop()`
  /// does not consult [PopScope].
  Future<void> _confirmDiscard() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text("Your edits to this profile won't be saved."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) Navigator.of(context).pop();
  }

  bool get _canSave =>
      _nameError == null &&
      (_timezone?.isNotEmpty ?? false) &&
      _usernameError == null &&
      _bioController.text.length <= _maxBioLength &&
      !_saving;

  /// Commits the whole draft in one press.
  ///
  /// The username claim goes FIRST because it is the only write that can be
  /// refused (someone else took the handle). Doing it first means a rejected
  /// claim leaves nothing half-saved; the single Save button is where that error
  /// hangs. The identity and social writes are separate documents/fields, so
  /// merging the UX did not merge the writes.
  Future<void> _save() async {
    final user = ref.read(authRepositoryProvider).currentUser;
    final profile = ref.read(profileProvider).value;
    if (user == null || profile == null) return;

    final wanted = canonicalUsername(_usernameController.text);
    final problem = validateUsername(wanted);
    if (problem != UsernameProblem.none) {
      setState(
        () => _error = wanted.isEmpty
            ? 'Username is required.'
            : describeUsernameProblem(problem),
      );
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (wanted != (_savedUsername ?? '')) {
        await ref
            .read(usernameRepositoryProvider)
            .claim(
              uid: user.uid,
              rawHandle: wanted,
              previousHandle: _savedUsername,
            );
      }
      await ref
          .read(profileRepositoryProvider)
          .updateProfile(
            uid: user.uid,
            name: _nameController.text,
            homeTimezone: _timezone!,
            quietHoursStartMinutes: _quietEnabled
                ? _minutes(_quietStart)
                : null,
            quietHoursEndMinutes: _quietEnabled ? _minutes(_quietEnd) : null,
          );
      // Privacy is committed live by its own toggle; carry the current value
      // through so this write only touches the bio.
      await ref
          .read(profileRepositoryProvider)
          .updateSocialProfile(
            uid: user.uid,
            isPublic: profile.isPublic,
            bio: _bioController.text,
          );
      if (mounted) Navigator.of(context).pop();
    } on UsernameUnavailable catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Prefill once from the current profile.
    final profile = ref.watch(profileProvider).value;
    if (!_initialised && profile != null) {
      _nameController.text = profile.name;
      _usernameController.text = profile.username ?? '';
      _bioController.text = profile.bio ?? '';
      _timezone = profile.homeTimezone;
      if (profile.hasQuietHours) {
        _quietEnabled = true;
        _quietStart = TimeOfDay(
          hour: profile.quietHoursStartMinutes! ~/ 60,
          minute: profile.quietHoursStartMinutes! % 60,
        );
        _quietEnd = TimeOfDay(
          hour: profile.quietHoursEndMinutes! ~/ 60,
          minute: profile.quietHoursEndMinutes! % 60,
        );
      }
      // Snapshot what was loaded, in the same one-shot block, so the baseline
      // can never drift from the fields it is compared against.
      _savedName = _nameController.text;
      _savedUsername = profile.username;
      _savedBio = _bioController.text;
      _savedTimezone = _timezone;
      _savedQuietEnabled = _quietEnabled;
      _savedQuietStart = _quietStart;
      _savedQuietEnd = _quietEnd;
      _initialised = true;
    }

    return PopScope(
      canPop: !_isDirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmDiscard();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Edit profile')),
        body: SingleChildScrollView(
          padding: Space.screenFormSafe(context),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The picture is the page anchor: centred at the top, its own
              // widget, uploaded the instant it is picked (no Save gates it).
              const ProfileAvatarEditor(),

              // IDENTITY — name and home timezone. The two fields the schedule
              // and every screen depend on.
              const SectionHeader('Identity'),
              TextField(
                controller: _nameController,
                // Border, fill and radius come from InputDecorationTheme.
                decoration: InputDecoration(
                  labelText: 'Your name',
                  errorText: _nameError,
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: Space.lg),
              Text('Home timezone (required)', style: context.text.labelLarge),
              const SizedBox(height: Space.sm),
              OutlinedButton.icon(
                onPressed: _pickTimezone,
                icon: const Icon(AppIcons.timezone),
                label: Text(_timezone ?? 'Tap to choose'),
              ),

              // PUBLIC PROFILE — username and bio (part of the one draft) plus
              // the privacy toggle (instant, see SocialProfileEditor). Grouped
              // right after identity because it is the other "about me" half.
              const SectionHeader('Public profile'),
              TextField(
                controller: _usernameController,
                autocorrect: false,
                enableSuggestions: false,
                maxLength: kUsernameMaxLength,
                decoration: InputDecoration(
                  labelText: 'Username',
                  prefixIcon: const Icon(AppIcons.username),
                  helperText:
                      'How people find you — $kUsernameMinLength–'
                      '$kUsernameMaxLength chars, lowercase letters, numbers '
                      'and _, starting with a letter.',
                  // The rule is long; show it in full instead of clipping it to
                  // one ellipsised line.
                  helperMaxLines: 3,
                  errorText: _usernameError,
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: Space.lg),
              TextField(
                controller: _bioController,
                maxLines: 3,
                maxLength: _maxBioLength,
                decoration: const InputDecoration(
                  labelText: 'About you',
                  alignLabelWithHint: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: Space.sm),
              const SocialProfileEditor(),

              // QUIET HOURS — a window planners are warned about. Part of the
              // same draft as everything above, committed by the one Save below.
              const SectionHeader('Quiet hours'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Quiet hours'),
                subtitle: const Text(
                  'Planners are warned before scheduling in this window. '
                  '(11pm–6am is always flagged.)',
                ),
                value: _quietEnabled,
                onChanged: (v) => setState(() => _quietEnabled = v),
              ),
              if (_quietEnabled) ...[
                const SizedBox(height: Space.sm),
                Wrap(
                  spacing: Space.md,
                  runSpacing: Space.sm,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _pickQuietStart,
                      icon: const Icon(AppIcons.quietHoursStart),
                      label: Text(
                        'From ${formatTimeOfDay(context, _quietStart)}',
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: _pickQuietEnd,
                      icon: const Icon(AppIcons.quietHoursEnd),
                      label: Text('To ${formatTimeOfDay(context, _quietEnd)}'),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: Space.xl),

              // THE ONE SAVE — commits name, timezone, username, bio and quiet
              // hours together. Picture, privacy and app lock are instant and
              // sit outside this button by design.
              FilledButton(
                onPressed: _canSave ? _save : null,
                child: _saving
                    ? const SizedBox(
                        height: Sizes.buttonSpinner,
                        width: Sizes.buttonSpinner,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Save changes'),
              ),
              if (_error != null) ...[
                const SizedBox(height: Space.lg),
                Text(
                  _error!,
                  style: context.text.bodyMedium?.copyWith(
                    color: context.colors.error,
                  ),
                ),
              ],

              // THIS DEVICE — the app lock. No Save: it applies the instant it
              // is flipped. Named for the device because 'who can open this app'
              // is a different question from the privacy control above ('who can
              // see my stats').
              const SectionHeader('This device'),
              const AppLockTile(),
            ],
          ),
        ),
      ),
    );
  }
}
