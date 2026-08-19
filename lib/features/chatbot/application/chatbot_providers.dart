import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/chatbot_endpoint_store.dart';
import '../data/chatbot_service.dart';
import '../data/http_chatbot_service.dart';
import '../data/on_device_chatbot_service.dart';
import 'model_setup_controller.dart';

/// Plain providers, no families or code-gen — same shape as the rest of the
/// app's Riverpod use.

/// **The swap point, and it has been swapped.** One line decides which
/// implementation of the seam the whole feature talks to, and it now names the
/// on-device engine: no laptop, no Tailscale, no internet.
///
/// The chat screen did not change to make this happen. That was the whole point
/// of keeping [ChatbotService] to one method with no transport in its signature
/// (DECISIONS.md, 2026-08-18) — the promise was that the engine could be
/// replaced at one line, and this is the line.
///
/// [HttpChatbotService] is kept, not deleted. It is the reference implementation
/// the on-device pipeline is checked against: when a reply looks wrong, running
/// the same message past the laptop is how you find out which side is lying.
/// Restoring it is this one line and nothing else.
final chatbotServiceProvider = Provider<ChatbotService>((ref) {
  // Typed as the implementation, not the interface, so `dispose` is reachable.
  // Registering the teardown here is what keeps `dispose` off the seam.
  final service = OnDeviceChatbotService(ref.watch(chatbotModelStoreProvider));
  ref.onDispose(service.dispose);
  return service;
});

/// HTTP-implementation-scoped (see [ChatbotEndpointStore]). Still wired so the
/// settings screen keeps working as a comparison tool; nothing reads it while
/// the on-device engine is the one selected above.
final chatbotEndpointStoreProvider =
    Provider<ChatbotEndpointStore>((ref) => const SharedPrefsChatbotEndpointStore());

/// The address as currently stored, for the settings field to show.
///
/// The service does **not** read this — it reads the store directly on each
/// send, so a saved edit applies immediately whether or not anything watching
/// this provider is still mounted. This exists purely so the form can be
/// pre-filled; invalidate it after a save.
final chatbotBaseUrlProvider =
    FutureProvider<String>((ref) => ref.watch(chatbotEndpointStoreProvider).baseUrl());
