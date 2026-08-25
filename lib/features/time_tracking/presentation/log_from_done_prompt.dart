import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format/datetime_format.dart';
import '../../auth/application/auth_providers.dart';
import '../application/time_tracking_providers.dart';
import '../domain/tracked_entry.dart';

/// The Done→track hook's minimal confirm-and-duration UI.
///
/// Called right after a planned item is marked Done. It asks whether to log the
/// task to personal time-tracking and, if so, collects the DURATION — a plan has
/// no duration of its own, so it must be asked. On confirm it writes ONE
/// `trackedTime` entry carrying [sourceItemId] as the soft link back to the
/// plan, which is what a future "share of tracked time that came from plans"
/// stat reads. Manual/voice entries leave `sourceItemId` absent.
///
/// **Deliberately NOT a screen** and deliberately decoupled from the scheduling
/// domain — it takes only primitives ([taskName], [sourceItemId], [timezone]),
/// so `time_tracking` never depends on `scheduling`.
///
/// **The voice seam:** duration collection is a single, prefillable field. A
/// future "track time" voice flow parses the spoken minutes and passes them as
/// [initialMinutes]; the same dialog then just needs a confirming tap (or a
/// later version can auto-submit). Nothing about the write path changes.
///
/// Confirm + duration are one dialog on purpose: it is the smaller surface, it
/// keeps "log?" and "how long?" in a single decision, and the prefillable field
/// is exactly the seam voice needs. Splitting them later is trivial if wanted.
Future<void> promptLogFromDone(
  BuildContext context,
  WidgetRef ref, {
  required String taskName,
  required String sourceItemId,
  required String timezone,
  int? initialMinutes,
}) async {
  final minutes = await showDialog<int>(
    context: context,
    builder: (ctx) => _LogFromDoneDialog(
      taskName: taskName,
      initialMinutes: initialMinutes,
    ),
  );
  if (minutes == null) return; // "Not now"

  final uid = ref.read(currentUidProvider);
  if (uid == null) return;

  final entry = TrackedEntry(
    id: '',
    taskName: taskName,
    durationMinutes: minutes,
    // The task was completed now, so it belongs to today in the user's own zone.
    // One Done → one day → one entry; the multi-day split never applies here.
    logDate: logDateFor(DateTime.now().toUtc(), timezone),
    sourceItemId: sourceItemId,
  );
  await ref.read(trackedTimeRepositoryProvider).log(uid, entry);

  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        'Logged ${formatDurationMinutes(context, minutes)} to time tracking',
      ),
    ),
  );
}

class _LogFromDoneDialog extends StatefulWidget {
  const _LogFromDoneDialog({required this.taskName, this.initialMinutes});

  final String taskName;
  final int? initialMinutes;

  @override
  State<_LogFromDoneDialog> createState() => _LogFromDoneDialogState();
}

class _LogFromDoneDialogState extends State<_LogFromDoneDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialMinutes?.toString() ?? '',
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final parsed = int.tryParse(_controller.text.trim());
    if (parsed == null || parsed < 1 || parsed > kMaxEntryMinutes) {
      setState(() => _error = 'Enter minutes between 1 and $kMaxEntryMinutes.');
      return;
    }
    Navigator.pop(context, parsed);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Log this to time tracking?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.taskName),
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: 'Minutes spent',
              hintText: 'e.g. 30',
              errorText: _error,
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context), // null → not logged
          child: const Text('Not now'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Log')),
      ],
    );
  }
}
