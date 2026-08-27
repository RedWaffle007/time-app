import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_timezone/flutter_timezone.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../notifications/application/messaging_service.dart';
import '../../social/application/social_providers.dart';
import '../../social/data/username_repository.dart';
import '../../social/domain/username.dart';
import '../application/auth_providers.dart';
import 'timezone_picker.dart';

/// Shown after first sign-in when the user has no profile yet. Captures name
/// and the REQUIRED home timezone before the app can be used.
class CompleteProfileScreen extends ConsumerStatefulWidget {
  const CompleteProfileScreen({super.key});

  @override
  ConsumerState<CompleteProfileScreen> createState() =>
      _CompleteProfileScreenState();
}

class _CompleteProfileScreenState extends ConsumerState<CompleteProfileScreen> {
  final _nameController = TextEditingController();
  final _usernameController = TextEditingController();
  String? _timezone; // null until detected/picked
  bool _saving = false;
  String? _error;

  /// The live format problem with the typed handle, or null when it is empty or
  /// valid. Availability (uniqueness) is not checked here — [claim] decides that
  /// atomically on Save, and surfaces a "taken" message if it loses the race.
  String? get _usernameProblem {
    final raw = _usernameController.text;
    if (raw.trim().isEmpty) return null; // Emptiness is handled by _canSave.
    final problem = validateUsername(canonicalUsername(raw));
    return problem == UsernameProblem.none
        ? null
        : describeUsernameProblem(problem);
  }

  @override
  void initState() {
    super.initState();
    _prefill();
  }

  Future<void> _prefill() async {
    // Prefill the name from the Google account.
    final user = ref.read(authRepositoryProvider).currentUser;
    _nameController.text = user?.displayName ?? '';

    // Default the timezone to the device's current zone (the user can change it,
    // e.g. if they're travelling and want their real home zone).
    try {
      final info = await FlutterTimezone.getLocalTimezone();
      if (mounted) setState(() => _timezone = info.identifier);
    } catch (_) {
      // Leave null — the user must then pick one manually.
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _usernameController.dispose();
    super.dispose();
  }

  Future<void> _pickTimezone() async {
    final chosen = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const TimezonePicker()),
    );
    if (chosen != null) setState(() => _timezone = chosen);
  }

  bool get _canSave =>
      _nameController.text.trim().isNotEmpty &&
      (_timezone?.isNotEmpty ?? false) &&
      _usernameController.text.trim().isNotEmpty &&
      _usernameProblem == null;

  Future<void> _save() async {
    final user = ref.read(authRepositoryProvider).currentUser;
    if (user == null) return; // shouldn't happen — router guards this.

    final handle = canonicalUsername(_usernameController.text);
    final problem = validateUsername(handle);
    if (problem != UsernameProblem.none) {
      setState(() => _error = describeUsernameProblem(problem));
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(profileRepositoryProvider).createProfile(
            uid: user.uid,
            name: _nameController.text,
            homeTimezone: _timezone!,
            avatarUrl: user.photoURL,
          );
      // The username is a SECOND write (reservation + mirror), and it can fail
      // where the profile did not — the handle may have been taken between the
      // last keystroke and Save. Claiming AFTER createProfile means a taken
      // handle leaves a name+tz profile that is still `!isComplete` (no
      // username), so the gate keeps us here to pick another — rather than
      // stranding a half-account. See DECISIONS.md "Mandatory username".
      await ref.read(usernameRepositoryProvider).claim(
            uid: user.uid,
            rawHandle: handle,
          );
      // profileProvider will emit the now-complete profile and the gate moves on.
    } on UsernameUnavailable catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save profile: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Complete your profile'),
        actions: [
          TextButton(
            onPressed: () => signOutWithTokenCleanup(ref),
            child: const Text('Sign out'),
          ),
        ],
      ),
      body: Padding(
        padding: Space.screenFormSafe(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _nameController,
              // Border, fill and radius come from InputDecorationTheme.
              decoration: const InputDecoration(labelText: 'Your name'),
              onChanged: (_) => setState(() {}), // refresh _canSave
            ),
            const SizedBox(height: Space.xl),
            // Required username — the handle people search for. Without one the
            // account is invisible to search (see UserProfile.isComplete).
            TextField(
              controller: _usernameController,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Username',
                prefixIcon: const Icon(AppIcons.username),
                errorText: _usernameProblem,
              ),
              onChanged: (_) => setState(() {}), // refresh _canSave + error
            ),
            const SizedBox(height: Space.sm),
            Text(
              'This is how friends find you, so it has to be unique. Use '
              '$kUsernameMinLength–$kUsernameMaxLength characters: lowercase '
              'letters, numbers and underscores, starting with a letter.',
              style: context.text.bodySmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
            const SizedBox(height: Space.xl),
            // Required home timezone.
            Text('Home timezone (required)', style: context.text.labelLarge),
            const SizedBox(height: Space.sm),
            OutlinedButton.icon(
              onPressed: _pickTimezone,
              icon: const Icon(AppIcons.timezone),
              label: Text(_timezone ?? 'Detecting… tap to choose'),
            ),
            const SizedBox(height: Space.sm),
            Text(
              "This is the timezone friends plan against. It's required because "
              'the whole app runs on your local time.',
              style: context.text.bodySmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
            const SizedBox(height: Space.xxl),
            FilledButton(
              onPressed: (_canSave && !_saving) ? _save : null,
              child: _saving
                  ? const SizedBox(
                      height: Sizes.buttonSpinner,
                      width: Sizes.buttonSpinner,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save and continue'),
            ),
            if (_error != null) ...[
              const SizedBox(height: Space.lg),
              Text(
                _error!,
                style: context.text.bodyMedium
                    ?.copyWith(color: context.colors.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
