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

/// The longest tab label the app will send.
///
/// Herdr imposes no limit of its own and happily accepts an empty string —
/// verified against the socket, where `tab.rename` with `""` blanks the label
/// and leaves a nameless tab behind. Both ends of the range are therefore the
/// app's to enforce: a blank tab is unrecoverable from the phone (there is
/// nothing left to long-press meaningfully), and a very long one just truncates
/// in the tab strip while pushing every other tab off screen.
const int maxTabLabelLength = 60;

/// The label to send for [raw], or null when it is not something worth sending.
///
/// Split out from the dialog so the rule is testable and so the confirm button
/// and the submit path cannot disagree about what counts as valid.
String? normalizeTabLabel(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty || trimmed.length > maxTabLabelLength) return null;
  return trimmed;
}

/// Prompt for a new label and rename [tabId].
///
/// Prefilled with the tab's current label and selected, so the common case
/// (replace it) is one keystroke and the rarer one (edit it) is still possible.
/// No manual refresh: Herdr emits `tab.renamed`, which reaches the app over
/// `/events` and re-snapshots like every other change.
Future<void> renameTabDialog(
  BuildContext context,
  WidgetRef ref,
  String tabId, {
  String currentLabel = '',
}) async {
  final label = await showDialog<String>(
    context: context,
    builder: (ctx) => _RenameTabDialog(initialLabel: currentLabel),
  );
  if (label == null || !context.mounted) return;
  // An unchanged name is a no-op, not a rename. Herdr would accept it, but the
  // round-trip and the "renamed" snackbar would both be lies.
  if (label == currentLabel.trim()) return;
  await _run(
    context,
    ref,
    'tab.rename',
    {'tab_id': tabId, 'label': label},
    successMessage: 'Tab renamed to "$label"',
  );
}

/// The rename prompt itself, pops with the normalized label or null.
///
/// A widget rather than an inline builder because it has to own its controller:
/// disposing one the moment `showDialog` returns tears it out from under the
/// field that is still animating away, and the confirm button listens to it too.
class _RenameTabDialog extends StatefulWidget {
  const _RenameTabDialog({required this.initialLabel});

  final String initialLabel;

  @override
  State<_RenameTabDialog> createState() => _RenameTabDialogState();
}

class _RenameTabDialogState extends State<_RenameTabDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialLabel,
  )..selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.initialLabel.length,
    );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final label = normalizeTabLabel(_controller.text);
    if (label != null) Navigator.pop(context, label);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename tab'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: maxTabLabelLength,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(
          labelText: 'Tab name',
          hintText: 'api server',
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        // Live-disabled rather than validated on submit: an empty or over-long
        // name is a state you can see, not an error to be told about after the
        // fact.
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _controller,
          builder: (_, value, _) => FilledButton(
            onPressed: normalizeTabLabel(value.text) == null ? null : _submit,
            child: const Text('Rename'),
          ),
        ),
      ],
    );
  }
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

/// Prompt for a branch name and create a new git worktree off [cwd]'s repo.
Future<void> newWorktreeDialog(
  BuildContext context,
  WidgetRef ref, {
  required String cwd,
  required String repoLabel,
}) async {
  final controller = TextEditingController();
  final branch = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('New worktree in $repoLabel'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Branch name',
          hintText: 'feat/my-change',
        ),
        onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text.trim()),
          child: const Text('Create'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (branch == null || branch.isEmpty || !context.mounted) return;
  await _run(
    context,
    ref,
    'worktree.create',
    {'cwd': cwd, 'branch': branch, 'label': branch},
    successMessage: 'Worktree "$branch" created',
  );
}
