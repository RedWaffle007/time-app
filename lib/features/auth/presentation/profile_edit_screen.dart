import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
      _initialised = true;
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Edit profile')),
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
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 20),
            Text(
              'Home timezone (required)',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _pickTimezone,
              icon: const Icon(Icons.public),
              label: Text(_timezone ?? 'Tap to choose'),
            ),
            const SizedBox(height: 32),
            FilledButton(
              onPressed: _canSave ? _save : null,
              child: _saving
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save changes'),
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
