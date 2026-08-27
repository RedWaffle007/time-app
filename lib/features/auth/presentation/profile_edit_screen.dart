import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/format/datetime_format.dart';
import '../../../core/widgets/section_header.dart';
import '../../applock/presentation/app_lock_tile.dart';
import '../../social/presentation/profile_avatar_editor.dart';
import '../../social/presentation/social_profile_editor.dart';
import '../application/auth_providers.dart';
import 'timezone_picker.dart';

/// Edit an existing profile — name and home timezone. Reachable once a profile
/// exists (unlike CompleteProfileScreen, which is the first-time create flow).
class ProfileEditScreen extends ConsumerStatefulWidget {
  const ProfileEditScreen({super.key});

  @override
  ConsumerState<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends ConsumerState<ProfileEditScreen> {
  final _nameController = TextEditingController();
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
  bool _savedQuietEnabled = false;
  TimeOfDay _savedQuietStart = const TimeOfDay(hour: 22, minute: 0);
  TimeOfDay _savedQuietEnd = const TimeOfDay(hour: 7, minute: 0);

  /// Whether leaving now would lose something.
  ///
  /// The name is compared **trimmed**, because that is what a save would write
  /// (`profile_repository.dart` trims): typing a trailing space changes nothing,
  /// so prompting about it would be a lie. The quiet-hours times only count when
  /// the window is enabled — the pickers keep their defaults while the switch is
  /// off, and those defaults are not an edit.
  bool get _isDirty {
    if (_nameController.text.trim() != _savedName.trim()) return true;
    if (_timezone != _savedTimezone) return true;
    if (_quietEnabled != _savedQuietEnabled) return true;
    if (!_quietEnabled) return false;
    return _quietStart != _savedQuietStart || _quietEnd != _savedQuietEnd;
  }

  /// The name is required, so an empty box needs to SAY so.
  ///
  /// Clearing it used to just grey out Save with no stated reason — a dead
  /// button and no explanation (found on device 2026-08-15). Null while the
  /// field is untouched-and-empty would be friendlier still, but this screen
  /// always opens on an existing profile, so empty here always means the user
  /// cleared it themselves.
  String? get _nameError =>
      _nameController.text.trim().isEmpty ? 'Your name is required' : null;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _pickTimezone() async {
    final chosen = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const TimezonePicker()),
    );
    if (chosen != null) setState(() => _timezone = chosen);
  }

  Future<void> _pickQuietStart() async {
    final picked =
        await showTimePicker(context: context, initialTime: _quietStart);
    if (picked != null) setState(() => _quietStart = picked);
  }

  Future<void> _pickQuietEnd() async {
    final picked =
        await showTimePicker(context: context, initialTime: _quietEnd);
    if (picked != null) setState(() => _quietEnd = picked);
  }

  int _minutes(TimeOfDay t) => t.hour * 60 + t.minute;

  /// Back with unsaved edits asks before throwing them away.
  ///
  /// Previously Back discarded silently — no confirmation, no trace, and the
  /// old values back on reopen. Deliberately a confirm, NOT a block: the user
  /// must always be able to leave, including out of an invalid state such as an
  /// empty name. Saving is unaffected — [_save] calls `Navigator.pop` directly,
  /// and a direct `pop()` does not consult [PopScope].
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
      _nameController.text.trim().isNotEmpty &&
      (_timezone?.isNotEmpty ?? false) &&
      !_saving;

  Future<void> _save() async {
    final user = ref.read(authRepositoryProvider).currentUser;
    if (user == null) return;

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(profileRepositoryProvider).updateProfile(
            uid: user.uid,
            name: _nameController.text,
            homeTimezone: _timezone!,
            quietHoursStartMinutes:
                _quietEnabled ? _minutes(_quietStart) : null,
            quietHoursEndMinutes: _quietEnabled ? _minutes(_quietEnd) : null,
          );
      if (mounted) Navigator.of(context).pop();
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
        // Scrollable now that Privacy is here: name + timezone + quiet hours +
        // two time buttons + Save + the lock tile overflow a short screen, and
        // an overflowing Column would clip the new section rather than reveal it.
        body: SingleChildScrollView(
          padding: Space.screenFormSafe(context),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The picture is the page anchor: centred at the top, its own
              // widget, uploaded the instant it is picked (no Save gates it).
              const ProfileAvatarEditor(),

              // IDENTITY — name and home timezone. The two fields the schedule
              // and every screen depend on, and the ones the Save below commits.
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

              // QUIET HOURS — a window planners are warned about. Its switch and
              // times are part of the same draft as Identity, so the one Save
              // below commits both.
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
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _pickQuietStart,
                        icon: const Icon(AppIcons.quietHoursStart),
                        label:
                            Text('From ${formatTimeOfDay(context, _quietStart)}'),
                      ),
                    ),
                    const SizedBox(width: Space.md),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _pickQuietEnd,
                        icon: const Icon(AppIcons.quietHoursEnd),
                        label: Text('To ${formatTimeOfDay(context, _quietEnd)}'),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: Space.xl),
              // The Save for Identity + Quiet hours, at the foot of ITS sections.
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
                  style: context.text.bodyMedium
                      ?.copyWith(color: context.colors.error),
                ),
              ],

              // PUBLIC PROFILE — username, bio and the public/private toggle.
              // Its own section with its OWN Save (see SocialProfileEditor):
              // identity above is one thing, presentation is another, and saving
              // them together would mean a privacy change also rewrote the user's
              // timezone. The picture that used to live here is the anchor above.
              const SectionHeader('Public profile'),
              const SocialProfileEditor(),

              // THIS DEVICE — the app lock. No Save: it applies the instant it is
              // flipped (a switch that looked like it needed saving would be a
              // lock people think is on when it is not). Named for the device
              // because the section above also holds a privacy control, and the
              // two answer different questions: 'who can see my stats' versus
              // 'who can open this app'.
              const SectionHeader('This device'),
              const AppLockTile(),
            ],
          ),
        ),
      ),
    );
  }
}
