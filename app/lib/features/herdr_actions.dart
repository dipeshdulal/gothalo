import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/bridge/bridge_client.dart';
import '../data/bridge/bridge_providers.dart';

/// Herdr-CLI-parity actions over the allowlisted `POST /herdr` proxy — create
/// and close worktrees, tabs and panes from the app. Destructive ops (close /
/// remove) confirm first. The live `/events` stream reflects the change, so
/// these never refresh state by hand.
///
/// See `docs/CONTRACT-herdr-proxy.md` for the method + params contract.

/// Run one proxy command, surfacing the outcome as a snackbar. Returns the
/// `result` object, or null on no-connection / error.
Future<Map<String, dynamic>?> _run(
  BuildContext context,
  WidgetRef ref,
  String method,
  Map<String, dynamic> params, {
  String? successMessage,
}) async {
  final client = ref.read(bridgeClientProvider);
  final messenger = ScaffoldMessenger.of(context);
  if (client == null) {
    messenger.showSnackBar(const SnackBar(content: Text('No bridge connection.')));
    return null;
  }
  try {
    final result = await client.herdrCommand(method, params);
    if (successMessage != null) {
      messenger.showSnackBar(
        SnackBar(content: Text(successMessage), duration: const Duration(seconds: 1)),
      );
    }
    return result;
  } on BridgeException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
    return null;
  }
}

/// Run one dedicated bridge endpoint (not the `/herdr` proxy), surfacing the
/// outcome as a snackbar. Returns whether it succeeded.
///
/// The agent-lifecycle endpoints are not proxy calls — starting an agent is a
/// multi-step operation with server-side validation, and stopping one has no
/// Herdr method at all — so they need their own runner alongside [_run]. The
/// snackbar/no-connection behaviour is kept identical so every action in this
/// file feels the same.
Future<bool> _bridge(
  BuildContext context,
  WidgetRef ref,
  Future<void> Function(BridgeClient client) call, {
  String? successMessage,
}) async {
  final client = ref.read(bridgeClientProvider);
  final messenger = ScaffoldMessenger.of(context);
  if (client == null) {
    messenger.showSnackBar(const SnackBar(content: Text('No bridge connection.')));
    return false;
  }
  try {
    await call(client);
    if (successMessage != null) {
      messenger.showSnackBar(
        SnackBar(content: Text(successMessage), duration: const Duration(seconds: 2)),
      );
    }
    return true;
  } on BridgeException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
    return false;
  }
}

/// A yes/no confirm for a destructive action; the confirm button is error-tinted.
Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final scheme = Theme.of(ctx).colorScheme;
      return AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
  return ok ?? false;
}

/// Split [paneId] to add a pane beside it (the app's "new pane").
Future<void> splitPane(
  BuildContext context,
  WidgetRef ref,
  String paneId, {
  String direction = 'down',
}) =>
    _run(
      context,
      ref,
      'pane.split',
      {'target_pane_id': paneId, 'direction': direction},
      successMessage: 'Pane added',
    );

/// Close [paneId] (closing a tab's last pane closes the tab too).
Future<void> closePane(BuildContext context, WidgetRef ref, String paneId) async {
  if (!await _confirm(
    context,
    title: 'Close pane?',
    message: 'This closes $paneId on the host. Anything running in it stops.',
    confirmLabel: 'Close',
  )) {
    return;
  }
  if (!context.mounted) return;
  await _run(context, ref, 'pane.close', {'pane_id': paneId},
      successMessage: 'Pane closed');
}

/// Close a whole tab and its panes.
Future<void> closeTab(BuildContext context, WidgetRef ref, String tabId) async {
  if (!await _confirm(
    context,
    title: 'Close tab?',
    message: 'This closes tab $tabId and every pane in it on the host.',
    confirmLabel: 'Close',
  )) {
    return;
  }
  if (!context.mounted) return;
  await _run(context, ref, 'tab.close', {'tab_id': tabId},
      successMessage: 'Tab closed');
}

/// Add a new tab (with its root shell) to [workspaceId].
Future<void> newTab(BuildContext context, WidgetRef ref, String workspaceId) =>
    _run(context, ref, 'tab.create', {'workspace_id': workspaceId},
        successMessage: 'Tab created');

/// Remove a git worktree workspace (deletes its checkout on the host).
Future<void> removeWorktree(
  BuildContext context,
  WidgetRef ref,
  String workspaceId,
  String label,
) async {
  if (!await _confirm(
    context,
    title: 'Remove worktree?',
    message:
        'This removes the "$label" worktree checkout on the host. Uncommitted '
        'changes there are lost.',
    confirmLabel: 'Remove',
  )) {
    return;
  }
  if (!context.mounted) return;
  await _run(context, ref, 'worktree.remove', {'workspace_id': workspaceId},
      successMessage: 'Worktree removed');
}

/// Stop the agent running in [paneId], leaving the pane open at a shell prompt.
///
/// Confirmed first, and worded so the cost is unambiguous: this is not a pause
/// or a disconnect, it quits a process that may be mid-edit. [kind] names the
/// agent in the prompt ("Stop claude?") so the dialog says what is being killed.
Future<bool> stopAgent(
  BuildContext context,
  WidgetRef ref,
  String paneId, {
  String kind = 'agent',
}) async {
  if (!await _confirm(
    context,
    title: 'Stop $kind?',
    message: 'This quits the $kind running in $paneId on the host. Whatever '
        'it is doing right now is interrupted and lost. The pane stays open.',
    confirmLabel: 'Stop',
  )) {
    return false;
  }
  if (!context.mounted) return false;
  return _bridge(context, ref, (c) => c.stopAgent(paneId),
      successMessage: '$kind stopped');
}

/// Stop the agent in [paneId] and start the same kind again in the same pane
/// and directory.
///
/// Confirmed first. The message leads with the part that surprises people: the
/// replacement is a NEW agent session, so nothing that was discussed carries
/// over. "Restart" reads like a refresh, and it isn't one.
Future<bool> restartAgent(
  BuildContext context,
  WidgetRef ref,
  String paneId, {
  String kind = 'agent',
}) async {
  if (!await _confirm(
    context,
    title: 'Restart $kind?',
    message: 'This quits the $kind in $paneId and starts a fresh one in the '
        'same directory. The conversation is NOT carried over — the new agent '
        'has no memory of this one — and the current turn is lost.',
    confirmLabel: 'Restart',
  )) {
    return false;
  }
  if (!context.mounted) return false;
  return _bridge(context, ref, (c) => c.restartAgent(paneId),
      successMessage: '$kind restarted');
}

// Creating a worktree lives in `worktrees/new_worktree_sheet.dart` rather than
// here. It stopped being a one-call action the day it could also launch an
// agent into the checkout it just made: two calls, a partial-failure state
// between them, and progress to show while the second one runs — none of which
// fits [_run]'s one-call/one-snackbar shape.
