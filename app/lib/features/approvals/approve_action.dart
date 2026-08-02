import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/bridge/bridge_client.dart';
import '../../data/bridge/bridge_providers.dart';
import '../../data/bridge/models/snapshot.dart';

/// One-tap approval for a blocked agent (D7/D8), shared by every surface that
/// exposes it — the inbox row, the overview card, and the terminal app bar.
///
/// POSTs `/approve {agent: pane_id, seq: state_change_seq}` through the active
/// [BridgeClient], then reflects the outcome:
/// - `applied:true`  → a subtle confirmation, and a snapshot refresh so the row
///   leaves the blocked state.
/// - `applied:false` → a toast carrying the bridge's `reason` (stale seq, no
///   longer blocked, …). No keystroke is ever sent from the app; the bridge
///   picks the agent's confirm key.
Future<void> approveAgent(
  BuildContext context,
  WidgetRef ref,
  Agent agent,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final client = ref.read(bridgeClientProvider);
  if (client == null) {
    messenger.showSnackBar(
      const SnackBar(content: Text('No bridge connection.')),
    );
    return;
  }

  // seq is the idempotency token; the bridge no-ops on a stale one anyway, so a
  // missing seq just means "let the bridge decide" (it'll report why).
  final seq = agent.stateChangeSeq ?? 0;

  try {
    final result = await client.approve(agent.paneId, seq);
    if (!context.mounted) return;
    if (result.applied) {
      messenger.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
          content: Row(
            children: [
              const Icon(Icons.check_circle_outline, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text('Approved ${agent.displayTitle}')),
            ],
          ),
        ),
      );
      // No manual refresh: the live event stream (WS /events → snapshotController)
      // reflects the agent leaving `blocked` on its own.
    } else {
      messenger.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(result.reason ?? 'Nothing to approve.'),
        ),
      );
    }
  } on BridgeException catch (e) {
    if (!context.mounted) return;
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
  }
}
