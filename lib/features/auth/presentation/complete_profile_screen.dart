import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_timezone/flutter_timezone.dart';

import '../../notifications/application/messaging_service.dart';
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
  String? _timezone; // null until detected/picked
  bool _saving = false;
  String? _error;

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
      (_timezone?.isNotEmpty ?? false);

  Future<void> _save() async {
    final user = ref.read(authRepositoryProvider).currentUser;
    if (user == null) return; // shouldn't happen — router guards this.

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
      // profileProvider will emit the new profile and the gate moves us on.
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
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Your name',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}), // refresh _canSave
            ),
            const SizedBox(height: 20),
            // Required home timezone.
            Text(
              'Home timezone (required)',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _pickTimezone,
              icon: const Icon(Icons.public),
              label: Text(_timezone ?? 'Detecting… tap to choose'),
            ),
            const SizedBox(height: 8),
            const Text(
              "This is the timezone friends plan against. It's required because "
              'the whole app runs on your local time.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 32),
            FilledButton(
              onPressed: (_canSave && !_saving) ? _save : null,
              child: _saving
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save and continue'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
