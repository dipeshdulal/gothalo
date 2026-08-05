import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/connection/connection.dart';
import '../../data/bridge/bridge_client.dart';
import '../../data/db/database.dart';
import 'push_payload.dart';

/// Action ids on a blocked notification. They are matched against
/// `NotificationResponse.actionId`, so they must stay stable.
const kActionApprove = 'gothalo.approve';
const kActionReject = 'gothalo.reject';

/// Secure-storage key holding a server's bearer, mirroring
/// `connection_providers.dart`. Duplicated deliberately: this code runs in the
/// notification isolate, which has no Riverpod container to read the repository
/// from.
String _bearerKey(String id) => 'gothalo.bearer.$id';

/// Resolve the bridge a push came from into a usable client.
///
/// The lookup is by the *bridge's* `server_id` rather than the app's active
/// server, because acting on a notification must hit the machine that sent it —
/// which may not be the one the UI is showing, and there may be no UI at all.
Future<BridgeClient?> _clientFor(String serverId, AppDatabase db) async {
  final profile = await db.profileByServerId(serverId);
  if (profile == null) return null;
  final bearer = await const FlutterSecureStorage().read(
    key: _bearerKey(profile.id),
  );
  if (bearer == null || bearer.isEmpty) return null;
  return BridgeClient(
    Connection(
      id: profile.id,
      name: profile.name,
      baseUrl: profile.baseUrl,
      bearer: bearer,
      deviceId: profile.deviceId,
    ),
  );
}

/// Outcome of a tray action, for logging and for deciding whether to leave the
/// notification on screen.
enum ActionOutcome { applied, stale, unroutable, failed }

/// Run an Approve/Reject tapped on a notification.
///
/// Approve goes through `POST /approve {agent, seq}`, which is idempotent: the
/// bridge no-ops if the agent has moved past that `seq`. That is what makes it
/// safe to act on a notification that has been sitting on the lock screen — the
/// worst case is a no-op, never a keystroke sent into an unrelated prompt.
///
/// Reject has no dedicated endpoint by design: declining is agent-specific UI,
/// so it is expressed as the prompt's own decline choice — the `esc` keystroke
/// the parser found, or the non-default numbered option.
Future<ActionOutcome> runNotificationAction({
  required String actionId,
  required DeepLinkTarget target,
  required List<PushOption> options,
}) async {
  final db = AppDatabase();
  try {
    final client = await _clientFor(target.serverId, db);
    if (client == null) {
      debugPrint('gothalo: no saved server for ${target.serverId}');
      return ActionOutcome.unroutable;
    }

    if (actionId == kActionApprove) {
      final seq = target.seq;
      if (seq == null) return ActionOutcome.unroutable;
      final res = await client.approve(target.pane, seq);
      if (!res.applied) {
        debugPrint('gothalo: approve no-op (${res.reason})');
        return ActionOutcome.stale;
      }
    } else {
      final decline = _declineFrom(options);
      if (decline == null) return ActionOutcome.unroutable;
      if (decline.key.isNotEmpty) {
        await client.sendKey(target.pane, decline.key);
      } else {
        await client.sendText(target.pane, '${decline.index}\n');
      }
    }

    return ActionOutcome.applied;
  } catch (e) {
    debugPrint('gothalo: notification action failed: $e');
    return ActionOutcome.failed;
  } finally {
    await db.close();
  }
}

/// The decline choice, mirroring [PushPayload.declineOption] for a bare option
/// list.
PushOption? _declineFrom(List<PushOption> options) {
  for (final o in options) {
    if (o.key.isNotEmpty) return o;
  }
  for (final o in options) {
    if (!o.selected && o.index > 0) return o;
  }
  return null;
}
