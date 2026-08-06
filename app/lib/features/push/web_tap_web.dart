import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'push_payload.dart';
import 'push_service.dart';

/// The string a service-worker notification tap sends to an already-open app
/// window. A contract with `web/firebase-messaging-sw.js`; the payload JSON
/// follows the prefix.
const _tapPrefix = 'gothalo:notification-tap:';

/// On web, notifications are drawn by the service worker, so a tap lands in
/// the worker — not the app. The worker forwards it two ways, and this wires
/// up both receiving ends:
///
/// - cold start: the worker opened `/?push=<payload>`, read here once from the
///   launch URL (then scrubbed, so a reload doesn't re-open the same agent);
/// - already running: the worker posts `gothalo:notification-tap:<payload>` to
///   the focused window, heard here via the service-worker message stream.
///
/// Either way the payload feeds [pendingDeepLink], the same routing the native
/// taps use.
void initWebNotificationTaps() {
  _consumeLaunchUrl();
  _listenForTaps();
}

void _consumeLaunchUrl() {
  final raw = Uri.base.queryParameters['push'];
  if (raw == null || raw.isEmpty) return;
  _queue(raw);
  final history = globalContext['history'] as JSObject?;
  history?.callMethod(
    'replaceState'.toJS,
    null,
    ''.toJS,
    Uri.base.path.toJS,
  );
}

void _listenForTaps() {
  final serviceWorker =
      (globalContext['navigator'] as JSObject?)?['serviceWorker'];
  if (serviceWorker == null || serviceWorker.isUndefinedOrNull) return;
  void onMessage(JSObject event) {
    final data = event['data'];
    if (data == null || !data.typeofEquals('string')) return;
    final message = (data as JSString).toDart;
    if (!message.startsWith(_tapPrefix)) return;
    _queue(message.substring(_tapPrefix.length));
  }

  (serviceWorker as JSObject).callMethod(
    'addEventListener'.toJS,
    'message'.toJS,
    onMessage.toJS,
  );
}

void _queue(String rawJson) {
  try {
    final decoded = jsonDecode(rawJson);
    if (decoded is! Map<String, dynamic>) return;
    final p = PushPayload.from(decoded);
    if (p.pane.isEmpty) return;
    pendingDeepLink.value = DeepLinkTarget(
      serverId: p.serverId,
      serverName: p.serverName,
      pane: p.pane,
      seq: p.seq,
      options: p.options,
    );
  } catch (_) {
    // A malformed tap payload routes nowhere; the app still opens normally.
  }
}
