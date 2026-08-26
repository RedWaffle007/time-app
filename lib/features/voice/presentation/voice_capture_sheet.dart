import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../application/voice_providers.dart';

/// The result of a voice capture. Exactly one of the three states holds:
///  - a [transcript] the parser will read;
///  - [typeInstead] — the user chose the manual fallback (or the mic was
///    unavailable/denied);
///  - the sheet was DISMISSED — represented by a null return, not this object.
class VoiceCaptureOutcome {
  const VoiceCaptureOutcome._({this.transcript, this.typeInstead = false});

  const VoiceCaptureOutcome.transcript(String text)
      : this._(transcript: text);
  const VoiceCaptureOutcome.typeInstead() : this._(typeInstead: true);

  final String? transcript;
  final bool typeInstead;
}

/// Speak [promptText] aloud (and show it), then capture one spoken reply.
///
/// **Doctrine:** on first use the rationale is shown BEFORE the OS microphone
/// prompt — no raw prompt fires without an on-screen explanation. After the
/// grant, subsequent captures skip straight to listening. Denial is never
/// fatal: the sheet offers "Type instead", which every caller routes to the
/// identical manual flow.
///
/// Returns the [VoiceCaptureOutcome], or null if the sheet was dismissed.
Future<VoiceCaptureOutcome?> showVoiceCaptureSheet(
  BuildContext context,
  WidgetRef ref, {
  required String promptText,
  String? hintText,
}) {
  return showModalBottomSheet<VoiceCaptureOutcome>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    // Dismissing the sheet returns null (do-nothing); the buttons return the
    // explicit outcomes.
    builder: (_) =>
        _VoiceCaptureSheet(promptText: promptText, hintText: hintText),
  );
}

/// Persisted flag: the mic rationale has been accepted at least once, so the
/// intro step can be skipped on later captures. A DEVICE concern (like the app
/// lock flag) — deliberately not on the Firestore profile.
const _kRationaleAcceptedKey = 'voice_mic_rationale_accepted';

enum _Phase { intro, ready, preparing, listening, denied, empty }

class _VoiceCaptureSheet extends ConsumerStatefulWidget {
  const _VoiceCaptureSheet({required this.promptText, this.hintText});
  final String promptText;

  /// An always-visible example of what to say ("the audio answer template"), so
  /// the user does not have to remember the phrasing. Shown under the prompt in
  /// every phase. Null hides the line.
  final String? hintText;

  @override
  ConsumerState<_VoiceCaptureSheet> createState() => _VoiceCaptureSheetState();
}

class _VoiceCaptureSheetState extends ConsumerState<_VoiceCaptureSheet> {
  _Phase _phase = _Phase.intro;
  String _partial = '';
  bool _checkedFlag = false;

  /// Within [_Phase.ready]: whether the prompt has finished being spoken. The
  /// "Tap to speak" button is revealed only once this is true, so the button
  /// arrives AFTER the audio, not alongside it.
  bool _promptSpoken = false;

  @override
  void initState() {
    super.initState();
    // If the rationale was accepted before, skip it and go straight to the
    // spoken-prompt → Record button sequence (still never auto-listening).
    _maybeSkipIntro();
  }

  Future<void> _maybeSkipIntro() async {
    final prefs = await SharedPreferences.getInstance();
    final accepted = prefs.getBool(_kRationaleAcceptedKey) ?? false;
    if (!mounted) return;
    setState(() => _checkedFlag = true);
    if (accepted) _enterReady();
  }

  /// The tap-to-start entry: confirm the mic, **speak the prompt aloud**, and
  /// only then reveal the Record button. Listening never starts here — the user
  /// taps when ready, so the recognizer's silence timer never runs during their
  /// thinking time. Reused by the first-run "Start" tap and returning captures.
  Future<void> _enterReady() async {
    setState(() {
      _phase = _Phase.ready;
      _promptSpoken = false;
      _partial = '';
    });

    final service = ref.read(speechServiceProvider);
    // Idempotent: a returning user is already granted, so this fires no OS
    // prompt; a first-run user reaches here only after the rationale. It also
    // configures TTS await-completion, so `speak` below resolves when the audio
    // actually ends — which is what gates the button.
    final ready = await service.ensureReady();
    if (!mounted) return;
    if (!ready) {
      setState(() => _phase = _Phase.denied);
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kRationaleAcceptedKey, true);
    if (!mounted) return;

    await service.speak(widget.promptText);
    if (!mounted) return;
    setState(() => _promptSpoken = true);
  }

  /// Begin listening — invoked by the Record button (and "Try again"). The
  /// prompt was already spoken in [_enterReady], so this does not re-speak; it
  /// goes straight to the recognizer.
  Future<void> _listen() async {
    setState(() {
      _phase = _Phase.preparing;
      _partial = '';
    });

    final service = ref.read(speechServiceProvider);
    final ready = await service.ensureReady();
    if (!mounted) return;
    if (!ready) {
      setState(() => _phase = _Phase.denied);
      return;
    }

    setState(() => _phase = _Phase.listening);
    await service.listen(
      onResult: (transcript, isFinal) {
        if (!mounted) return;
        setState(() => _partial = transcript);
        if (isFinal) _finish(transcript);
      },
    );
  }

  void _finish(String transcript) {
    final text = transcript.trim();
    if (text.isEmpty) {
      setState(() => _phase = _Phase.empty);
      return;
    }
    Navigator.pop(context, VoiceCaptureOutcome.transcript(text));
  }

  Future<void> _stop() async {
    // Ask the recognizer to finalise; the final callback pops the sheet.
    await ref.read(speechServiceProvider).stop();
  }

  void _typeInstead() {
    ref.read(speechServiceProvider).cancel();
    Navigator.pop(context, const VoiceCaptureOutcome.typeInstead());
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          Space.xl, Space.sm, Space.xl, Space.xl + bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.promptText, style: context.text.titleLarge),
          if (widget.hintText != null) ...[
            const SizedBox(height: Space.sm),
            // The audio-answer template, always on screen so the user knows the
            // phrasing to use and does not fumble.
            Text(
              widget.hintText!,
              style: context.text.bodyMedium
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: Space.lg),
          if (!_checkedFlag)
            // The one-frame gap while the persisted flag is read.
            const Padding(
              padding: EdgeInsets.symmetric(vertical: Space.xl),
              child: Center(child: CircularProgressIndicator()),
            )
          else
            ..._body(),
        ],
      ),
    );
  }

  List<Widget> _body() {
    switch (_phase) {
      case _Phase.intro:
        return [
          Text(
            'Speak and it fills in the form for you to confirm — nothing is '
            'saved until you do. This uses the microphone.',
            style: context.text.bodyMedium
                ?.copyWith(color: context.colors.onSurfaceVariant),
          ),
          const SizedBox(height: Space.xl),
          FilledButton.icon(
            onPressed: _enterReady,
            icon: const Icon(AppIcons.voiceListening),
            label: const Text('Start listening'),
          ),
          const SizedBox(height: Space.sm),
          _typeInsteadButton(),
        ];

      case _Phase.ready:
        // The prompt is spoken aloud first; the Record button appears only once
        // it has finished (`_promptSpoken`), so the button follows the audio
        // rather than sitting next to it. Nothing listens until it is tapped.
        if (!_promptSpoken) {
          return [
            Row(
              children: [
                Icon(AppIcons.voice,
                    size: Sizes.inlineIcon,
                    color: context.colors.onSurfaceVariant),
                const SizedBox(width: Space.sm),
                Text(
                  'Playing the prompt…',
                  style: context.text.bodyMedium
                      ?.copyWith(color: context.colors.onSurfaceVariant),
                ),
              ],
            ),
            const SizedBox(height: Space.xl),
            _typeInsteadButton(),
          ];
        }
        return [
          Text(
            'Tap to speak, then pause when you\'re done — it stops on its own.',
            style: context.text.bodyMedium
                ?.copyWith(color: context.colors.onSurfaceVariant),
          ),
          const SizedBox(height: Space.xl),
          FilledButton.icon(
            autofocus: true,
            onPressed: _listen,
            icon: const Icon(AppIcons.voiceListening),
            label: const Text('Tap to speak'),
          ),
          const SizedBox(height: Space.sm),
          _typeInsteadButton(),
        ];

      case _Phase.preparing:
        return const [
          Padding(
            padding: EdgeInsets.symmetric(vertical: Space.xl),
            child: Center(child: CircularProgressIndicator()),
          ),
        ];

      case _Phase.listening:
        return [
          const Center(child: _PulsingMic()),
          const SizedBox(height: Space.lg),
          Text(
            _partial.isEmpty ? 'Listening…' : _partial,
            textAlign: TextAlign.center,
            style: context.text.bodyLarge?.copyWith(
              color: _partial.isEmpty ? context.colors.onSurfaceVariant : null,
            ),
          ),
          const SizedBox(height: Space.xl),
          FilledButton.icon(
            onPressed: _stop,
            icon: const Icon(AppIcons.voiceStop),
            label: const Text('Done'),
          ),
          const SizedBox(height: Space.sm),
          _typeInsteadButton(),
        ];

      case _Phase.denied:
        return [
          Text(
            "The microphone isn't available, so voice is off for now. You can "
            'still type it in — everything is doable by hand.',
            style: context.text.bodyMedium
                ?.copyWith(color: context.colors.onSurfaceVariant),
          ),
          const SizedBox(height: Space.xl),
          FilledButton.icon(
            onPressed: _typeInstead,
            icon: const Icon(AppIcons.typeInstead),
            label: const Text('Type it instead'),
          ),
        ];

      case _Phase.empty:
        return [
          Text(
            "Didn't catch that. Try again, or type it in.",
            style: context.text.bodyMedium
                ?.copyWith(color: context.colors.onSurfaceVariant),
          ),
          const SizedBox(height: Space.xl),
          FilledButton.icon(
            onPressed: _listen,
            icon: const Icon(AppIcons.voiceListening),
            label: const Text('Try again'),
          ),
          const SizedBox(height: Space.sm),
          _typeInsteadButton(),
        ];
    }
  }

  Widget _typeInsteadButton() => TextButton.icon(
        onPressed: _typeInstead,
        icon: const Icon(AppIcons.typeInstead),
        label: const Text('Type instead'),
      );
}

/// A gently pulsing filled mic disc — the "I'm listening" affordance.
class _PulsingMic extends StatefulWidget {
  const _PulsingMic();

  @override
  State<_PulsingMic> createState() => _PulsingMicState();
}

class _PulsingMicState extends State<_PulsingMic>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: Tween<double>(begin: 0.94, end: 1.06).animate(
        CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
      ),
      child: Container(
        width: Sizes.voicePulse,
        height: Sizes.voicePulse,
        decoration: BoxDecoration(
          color: context.colors.primaryContainer,
          shape: BoxShape.circle,
        ),
        child: Icon(
          AppIcons.voiceListening,
          size: Sizes.voicePulseIcon,
          color: context.colors.onPrimaryContainer,
        ),
      ),
    );
  }
}
