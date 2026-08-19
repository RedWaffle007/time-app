import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/async_view.dart';
import '../application/chatbot_providers.dart';
import '../data/chatbot_endpoint_store.dart';

/// Where the practice service lives, as a field the user can edit.
///
/// **This screen belongs to the HTTP implementation and is deleted with it.**
/// It exists because the address genuinely moves — the service runs on a laptop
/// reached over Tailscale, and that address changes whenever the laptop does.
/// Hardcoding it in the UI would make every move a code change; keeping it here
/// means the seam above (`ChatbotService`) never learns what a URL is.
class ChatbotSettingsScreen extends ConsumerWidget {
  const ChatbotSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storedAsync = ref.watch(chatbotBaseUrlProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Service address')),
      // The stored value has to be read before the field can be built with it,
      // so the form waits on it rather than flashing the default and correcting
      // itself a frame later.
      body: AsyncView<String>(
        value: storedAsync,
        onRetry: () => ref.invalidate(chatbotBaseUrlProvider),
        builder: (context, stored) => _AddressForm(initialValue: stored),
      ),
    );
  }
}

class _AddressForm extends ConsumerStatefulWidget {
  const _AddressForm({required this.initialValue});

  final String initialValue;

  @override
  ConsumerState<_AddressForm> createState() => _AddressFormState();
}

class _AddressFormState extends ConsumerState<_AddressForm> {
  final _formKey = GlobalKey<FormState>();
  late final _controller = TextEditingController(text: widget.initialValue);
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _saving = true);
    try {
      await ref
          .read(chatbotEndpointStoreProvider)
          .setBaseUrl(_controller.text);
      // The service re-reads the store on every send, so there is nothing else
      // to notify. This invalidation is only so the field shows the NORMALISED
      // value if the user comes back.
      ref.invalidate(chatbotBaseUrlProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Address saved')));
      Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: ListView(
        padding: Space.screenForm,
        children: [
          TextFormField(
            controller: _controller,
            autocorrect: false,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: 'Base URL',
              prefixIcon: Icon(AppIcons.serviceAddress),
            ),
            // Validated with the same function that normalises on save, so the
            // form can never accept something the store would then reject.
            validator: (value) => normalizeBaseUrl(value ?? '') == null
                ? "That isn't an address the app can call. Example: "
                    '$kDefaultChatbotBaseUrl'
                : null,
            onFieldSubmitted: (_) => _save(),
          ),
          const SizedBox(height: Space.md),
          Text(
            'The chatbot runs as a service on your laptop and is reached over '
            'Tailscale, so this changes whenever the laptop does. A scheme is '
            'optional — "100.116.97.26:5000" becomes "http://…".\n\n'
            'This setting exists only while the bot is a server. When it runs '
            'on the phone itself there will be no address to set.',
            style: context.text.bodySmall
                ?.copyWith(color: context.colors.onSurfaceVariant),
          ),
          const SizedBox(height: Space.xl),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: Sizes.buttonSpinner,
                    height: Sizes.buttonSpinner,
                    child: CircularProgressIndicator(
                      strokeWidth: Sizes.ruleWidth - 1,
                    ),
                  )
                : const Text('Save'),
          ),
          const SizedBox(height: Space.sm),
          TextButton(
            onPressed: _saving
                ? null
                : () => _controller.text = kDefaultChatbotBaseUrl,
            child: const Text('Reset to default'),
          ),
        ],
      ),
    );
  }
}
