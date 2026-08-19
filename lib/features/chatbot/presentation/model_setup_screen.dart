import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/warning_panel.dart';
import '../application/model_setup_controller.dart';
import '../data/model_manifest.dart';
import '../domain/model_setup_state.dart';
import 'chat_gate.dart';

/// Getting the language model onto this phone.
///
/// **The manual door to the same machinery the chat gate uses.** The chat is
/// now gated on the model being present ([ChatGate]), so most people never come
/// here — this is where you go to watch a download you left running, or to
/// retry one that failed, without opening the chat.
///
/// The state lives in `modelSetupControllerProvider`, which is not
/// `autoDispose`: leaving this screen mid-download does not cancel it, and
/// coming back — from here or from the gate — re-attaches to the run already in
/// progress. That shared, screen-independent state is what lets both entry
/// points show the same download rather than starting two.
class ModelSetupScreen extends StatelessWidget {
  const ModelSetupScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Offline model')),
      body: const SafeArea(child: ModelSetupBody()),
    );
  }
}

/// The setup UI without a Scaffold, so the chat gate and this screen render the
/// **same** states from the same code.
///
/// Two copies of this would drift the moment one of them grew a state, and the
/// one that drifts is the gate — the screen a first-time user actually meets.
class ModelSetupBody extends ConsumerWidget {
  const ModelSetupBody({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(modelSetupControllerProvider);

    return Padding(
      padding: Space.screenForm,
      child: switch (state) {
        ModelChecking() => const _Working(
            icon: AppIcons.offlineModel,
            headline: 'Checking',
            detail: 'Looking for the model files already on this phone.',
          ),
        ModelNeeded(:final totalBytes) => _Needed(totalBytes: totalBytes),
        ModelDownloading() => _Downloading(state),
        ModelVerifying(:final file) => _Working(
            icon: AppIcons.offlineModel,
            headline: 'Checking the download',
            detail: 'Making sure ${file.description.toLowerCase()} arrived '
                'intact. This takes a moment for a large file.',
          ),
        ModelReady() => const _Ready(),
        ModelFailed(:final message) => _Failed(message: message),
      },
    );
  }
}

/// The first thing a new user sees, and the reason the download is a button and
/// not a side effect.
///
/// It states the size before asking, because 143MB on mobile data is a real
/// cost to someone and "Download" with no number is a request to trust the app
/// about it.
class _Needed extends ConsumerWidget {
  const _Needed({required this.totalBytes});

  final int? totalBytes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(
          AppIcons.modelDownload,
          size: Sizes.emptyStateIcon,
          color: context.colors.primary,
        ),
        const SizedBox(height: Space.md),
        Text(
          'Practise offline',
          textAlign: TextAlign.center,
          style: context.text.titleMedium,
        ),
        const SizedBox(height: Space.sm),
        Text(
          'The language model runs entirely on this phone — once it is here, '
          'practice works with no internet at all.',
          textAlign: TextAlign.center,
          style: context.text.bodySmall
              ?.copyWith(color: context.colors.onSurfaceVariant),
        ),
        const SizedBox(height: Space.xl),
        FilledButton.icon(
          onPressed: () =>
              ref.read(modelSetupControllerProvider.notifier).start(),
          icon: const Icon(AppIcons.modelDownload, size: Sizes.inlineIcon),
          label: const Text('Download to start practising'),
        ),
        const SizedBox(height: Space.sm),
        Text(
          totalBytes == null
              ? 'Best done on Wi-Fi. You can leave this screen while it runs.'
              : '${_formatBytes(totalBytes!)} — best done on Wi-Fi. You can '
                  'leave this screen while it runs.',
          textAlign: TextAlign.center,
          style: context.text.labelSmall
              ?.copyWith(color: context.colors.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// Determinate progress (UI-RULES.md §6.7), degrading to indeterminate when the
/// server declared no length — never a faked total.
class _Downloading extends StatelessWidget {
  const _Downloading(this.state);

  final ModelDownloading state;

  @override
  Widget build(BuildContext context) {
    final fraction = state.fraction;
    final total = state.total;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          AppIcons.modelDownload,
          size: Sizes.emptyStateIcon,
          color: context.colors.primary,
        ),
        const SizedBox(height: Space.md),
        Text(
          'Downloading the model',
          textAlign: TextAlign.center,
          style: context.text.titleMedium,
        ),
        const SizedBox(height: Space.xl),
        // Naming the segment is what stops the bar looking like it went
        // backwards when the next file starts from zero (§6.7).
        Text(
          'File ${state.fileNumber} of ${state.fileCount} · '
          '${state.file.description}',
          style: context.text.bodySmall
              ?.copyWith(color: context.colors.onSurfaceVariant),
        ),
        const SizedBox(height: Space.sm),
        LinearProgressIndicator(
          value: fraction,
          minHeight: Sizes.progressBar,
          borderRadius: Radii.pill,
        ),
        const SizedBox(height: Space.sm),
        // The bar says something is happening; this line is what tells someone
        // whether it is worth waiting for.
        Text(
          total == null
              ? _formatBytes(state.received)
              : '${_formatBytes(state.received)} of ${_formatBytes(total)}',
          style: context.text.bodySmall
              ?.copyWith(color: context.colors.onSurfaceVariant),
        ),
        const SizedBox(height: Space.xl),
        Text(
          '${kModelTotalBytes == null ? 'This' : _formatBytes(kModelTotalBytes!)} '
          'in total, so this is best done on Wi-Fi. You can leave this screen — '
          'the download keeps going, and an interrupted one picks up where it '
          'stopped.',
          textAlign: TextAlign.center,
          style: context.text.bodySmall
              ?.copyWith(color: context.colors.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// An indeterminate wait with something to read (UI-RULES.md §6.7 — no faked
/// total, so no bar).
class _Working extends StatelessWidget {
  const _Working({
    required this.icon,
    required this.headline,
    required this.detail,
  });

  final IconData icon;
  final String headline;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: Sizes.emptyStateIcon, color: context.colors.primary),
        const SizedBox(height: Space.md),
        Text(headline, style: context.text.titleMedium),
        const SizedBox(height: Space.sm),
        Text(
          detail,
          textAlign: TextAlign.center,
          style: context.text.bodySmall
              ?.copyWith(color: context.colors.onSurfaceVariant),
        ),
        const SizedBox(height: Space.xl),
        const SizedBox(
          width: Sizes.buttonSpinner,
          height: Sizes.buttonSpinner,
          child: CircularProgressIndicator(strokeWidth: Sizes.ruleWidth - 1),
        ),
      ],
    );
  }
}

/// **The Part 1 finish line.** Deliberately says only that the files are here —
/// the engine that uses them is the next session's work, and a screen that
/// promised anything more would be lying.
class _Ready extends StatelessWidget {
  const _Ready();

  @override
  Widget build(BuildContext context) {
    // Named on screen rather than buried in a decision doc: while the manifest
    // carries no digests, "verified" means "the whole declared length arrived",
    // which is not the same promise.
    final unverifiable = kModelFiles.where((f) => f.isPlaceholder).isNotEmpty;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          AppIcons.modelReady,
          size: Sizes.emptyStateIcon,
          color: context.colors.primary,
        ),
        const SizedBox(height: Space.md),
        Text('Model ready', style: context.text.titleMedium),
        const SizedBox(height: Space.sm),
        Text(
          'All the model files are on this phone and check out. Practice runs '
          'offline — you can turn the internet off entirely.',
          textAlign: TextAlign.center,
          style: context.text.bodySmall
              ?.copyWith(color: context.colors.onSurfaceVariant),
        ),
        if (unverifiable) ...[
          const SizedBox(height: Space.lg),
          Text(
            'Checked by size only — this build has no checksums for the model '
            'files yet.',
            textAlign: TextAlign.center,
            style: context.text.labelSmall
                ?.copyWith(color: context.colors.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}

/// Setup stopped. The message comes from the layer that knew why and is
/// rendered verbatim; every failure is retryable, because each path either kept
/// the partial download or cleared it.
class _Failed extends ConsumerWidget {
  const _Failed({required this.message});

  final String message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Orange belongs here and not on the progress bar (§2.7, §6.7).
        WarningPanel(message),
        const SizedBox(height: Space.xl),
        FilledButton.icon(
          onPressed: () =>
              ref.read(modelSetupControllerProvider.notifier).start(),
          icon: const Icon(AppIcons.retry, size: Sizes.inlineIcon),
          label: const Text('Try again'),
        ),
      ],
    );
  }
}

/// Byte counts a person can read, in their locale's number format.
///
/// MB and GB in the decimal sense (1 MB = 1,000,000 bytes), which is how a
/// download size is quoted everywhere the user will have seen this file
/// mentioned. One decimal place: a 130MB download moving in 0.1MB steps looks
/// alive, and moving in 1MB steps looks stuck.
String _formatBytes(int bytes) {
  const kb = 1000;
  const mb = kb * 1000;
  const gb = mb * 1000;

  final (double value, String unit) = switch (bytes) {
    >= gb => (bytes / gb, 'GB'),
    >= mb => (bytes / mb, 'MB'),
    >= kb => (bytes / kb, 'kB'),
    _ => (bytes.toDouble(), 'B'),
  };

  // Locale-aware separators, for the same reason dates go through one helper:
  // a build that renders "1.5 MB" to someone whose locale writes "1,5" is
  // rendering an English number, not a number.
  final digits = unit == 'B' ? 0 : 1;
  final format = NumberFormat.decimalPatternDigits(decimalDigits: digits);
  return '${format.format(value)} $unit';
}
