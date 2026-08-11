import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/theme.dart';
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

/// Mark an agent as seen in Herdr when it is opened from the phone.
///
/// Herdr's `done` state means an idle agent finished unseen background work. The
/// `agent.focus` command is the supported way to acknowledge that work, and it
/// updates the desktop's state as well as the mobile snapshot. This is deliberately
/// best-effort: opening a chat must not fail because the host disappeared between
/// the snapshot and the focus request.
Future<void> markAgentSeen(WidgetRef ref, String paneId) async {
  if (paneId.isEmpty) return;
  final client = ref.read(bridgeClientProvider);
  if (client == null) return;
  try {
    await client.herdrCommand('agent.focus', {'target': paneId});
  } on BridgeException {
    // The screen is already open; a failed acknowledgement is not a navigation
    // error. The next snapshot will reflect whatever Herdr knows then.
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

/// Split [paneId] to open a second terminal beside it.
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
      successMessage: 'Terminal added',
    );

/// Close [paneId] (closing the last one sharing its split closes the split too).
///
/// [label] is what the user calls it — an agent's task or a terminal's name —
/// and [subject] is which of the two it is. The confirm names those rather than
/// the pane id: a dialog that says "this closes w1N:p3" is asking someone to
/// agree to something they cannot read, and the pane id is an address, not a
/// name.
Future<void> closePane(
  BuildContext context,
  WidgetRef ref,
  String paneId, {
  String? label,
  String subject = 'terminal',
}) async {
  final what = (label == null || label.trim().isEmpty)
      ? 'this $subject'
      : '"${label.trim()}"';
  if (!await _confirm(
    context,
    title: 'Close this $subject?',
    message: 'This closes $what on the host. Anything running in it stops.',
    confirmLabel: 'Close',
  )) {
    return;
  }
  if (!context.mounted) return;
  await _run(context, ref, 'pane.close', {'pane_id': paneId},
      successMessage: 'Closed');
}

/// Close a tab and everything in it.
///
/// [label] is the tab's own name when it has one, so the confirm can say which
/// tab rather than quoting `wN:t2` — the id is an address, not a name.
Future<void> closeTab(
  BuildContext context,
  WidgetRef ref,
  String tabId, {
  String? label,
}) async {
  final what = (label == null || label.trim().isEmpty)
      ? 'this tab'
      : 'the "${label.trim()}" tab';
  if (!await _confirm(
    context,
    title: 'Close this tab?',
    message: 'This closes $what and every terminal in it on the host. '
        'Anything running in them stops.',
    confirmLabel: 'Close tab',
  )) {
    return;
  }
  if (!context.mounted) return;
  await _run(context, ref, 'tab.close', {'tab_id': tabId},
      successMessage: 'Tab closed');
}

/// The longest tab name the app will send.
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

/// Prompt for a new name and rename [tabId].
///
/// Prefilled with the tab's current name and selected, so the common case
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
///
/// **"Tab" is kept, deliberately.** The rest of this rework replaces Herdr's
/// nouns — pane, workspace, space — because they are multiplexer vocabulary
/// that means nothing to someone who has not run one. A tab is not that: it is
/// a browser word, and a person who has never heard of tmux still knows what a
/// tab is and that things live in them. Renaming it would cost the user a
/// familiar word to save them an unfamiliar one, which is backwards. Tabs are a
/// real feature and stay a real feature: create here, rename via
/// [renameTabDialog], close via [closeTab], all reachable from a project.
Future<void> newTab(BuildContext context, WidgetRef ref, String workspaceId) =>
    _run(context, ref, 'tab.create', {'workspace_id': workspaceId},
        successMessage: 'Tab created');

/// Remove a git worktree workspace (deletes its checkout on the host), and
/// optionally the branch it was on.
///
/// Herdr removes the checkout and closes the workspace, and stops there — it
/// has no branch concept — so every removal used to leave a ref behind. The
/// branch delete is the bridge's own `POST /branch-delete`; see
/// `docs/CONTRACT-branch-delete.md`.
///
/// Three things this ordering is deliberate about:
///
///   - the preflight (`GET /branch-info`) runs BEFORE the dialog, so the
///     confirm can name the branch and say whether it is merged rather than
///     asking the user to opt into something unnamed;
///   - the branch delete runs only if `worktree.remove` succeeded — git cannot
///     delete a checked-out branch, and a failed removal must not be followed
///     by an attempt on the branch anyway;
///   - the result is reported as what actually happened. "Worktree gone, branch
///     kept" is a normal outcome (unmerged, refused, bridge too old) and says
///     so instead of a generic success.
Future<void> removeWorktree(
  BuildContext context,
  WidgetRef ref,
  String workspaceId,
  String label,
) async {
  final client = ref.read(bridgeClientProvider);
  final messenger = ScaffoldMessenger.of(context);
  if (client == null) {
    messenger.showSnackBar(const SnackBar(content: Text('No bridge connection.')));
    return;
  }

  // Null when the bridge is too old to answer or the space has no branch to
  // offer; the dialog then degrades to the plain confirm it always was.
  final branch = await client.branchInfo(workspaceId);
  if (!context.mounted) return;

  final deleteBranch = await showDialog<bool>(
    context: context,
    builder: (ctx) => _RemoveWorktreeDialog(label: label, branch: branch),
  );
  if (deleteBranch == null || !context.mounted) return;

  // No successMessage: the outcome line depends on what happens to the branch,
  // and two snackbars for one action would race each other.
  final removed = await _run(
    context,
    ref,
    'worktree.remove',
    {'workspace_id': workspaceId},
  );
  if (removed == null) return; // removal failed — _run reported it; stop here.

  if (!deleteBranch || branch == null) {
    messenger.showSnackBar(
      const SnackBar(content: Text('Work finished'), duration: Duration(seconds: 1)),
    );
    return;
  }

  try {
    final result = await client.deleteBranch(
      repoRoot: branch.repoRoot,
      branch: branch.branch,
      // Only ever true for a branch the user confirmed twice — the checkbox
      // cannot be ticked for an unmerged branch without the second dialog.
      force: !branch.merged,
    );
    messenger.showSnackBar(
      SnackBar(
        content: Text(removeWorktreeSummary(result)),
        duration: const Duration(seconds: 4),
      ),
    );
  } on BridgeException catch (e) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(branchKeptSummary(branch.branch, e.message)),
        duration: const Duration(seconds: 6),
      ),
    );
  }
}

/// The outcome line for a removal that also deleted the branch.
///
/// Split out and pure so the wording is testable, and so the three things it
/// must never conflate stay visible in one place: a forced delete says commits
/// were dropped (and leaves the sha, the only way back), a plain one does not,
/// and an upstream is reported as *kept* because nothing here pushes.
String removeWorktreeSummary(BranchDeleteResult r) {
  final parts = <String>['Work finished'];
  parts.add(r.forced
      ? 'unmerged branch ${r.branch} deleted (was ${r.sha})'
      : 'branch ${r.branch} deleted');
  if (r.upstream.isNotEmpty && !r.remoteDeleted) {
    parts.add('${r.upstream} left on the remote');
  }
  return parts.join(' · ');
}

/// The outcome line for a removal whose branch survived — the normal partial
/// result, not an error. [reason] is the bridge's own sentence.
String branchKeptSummary(String branch, String reason) =>
    'Work finished · branch $branch kept: $reason';

/// The "Finish this work?" confirm, with the opt-in branch delete.
///
/// The subject is the work, not the worktree: from a phone this is "I am done
/// with this branch, take it off the machine". Everything it actually does is
/// unchanged — `worktree.remove` on the host, then the optional
/// `POST /branch-delete` — and the parts that name git's own objects (the
/// branch, whether it is merged, the sha a forced delete leaves behind) keep
/// saying so, because those are the words that let someone get the work back.
///
/// Pops `null` (cancelled), `false` (remove the worktree only) or `true`
/// (remove it and delete the branch). Default is **off**: removing a worktree
/// is recoverable — the branch is still there and `worktree.open` brings it
/// back — while deleting a branch is much less so, and a phone is exactly where
/// a mis-tap is most likely.
class _RemoveWorktreeDialog extends StatefulWidget {
  const _RemoveWorktreeDialog({required this.label, required this.branch});

  final String label;

  /// The preflight, or null when there is nothing to offer.
  final BranchInfo? branch;

  @override
  State<_RemoveWorktreeDialog> createState() => _RemoveWorktreeDialogState();
}

class _RemoveWorktreeDialogState extends State<_RemoveWorktreeDialog> {
  bool _deleteBranch = false;

  /// Ticking the box for an **unmerged** branch is a different decision from
  /// ticking it for a merged one, so it is a different dialog rather than the
  /// same tap. Unticking is free and never asks.
  Future<void> _toggle(bool? on, BranchInfo info) async {
    if (on != true) {
      setState(() => _deleteBranch = false);
      return;
    }
    if (info.merged) {
      setState(() => _deleteBranch = true);
      return;
    }
    final n = info.unmergedCommits;
    final commits = n == 1 ? '1 commit' : '$n commits';
    final ok = await _confirm(
      context,
      title: 'Delete unmerged branch?',
      message:
          '"${info.branch}" is NOT merged into ${info.defaultBranch}. Deleting '
          'it drops $commits that exist nowhere else. This cannot be undone '
          'from the app.',
      confirmLabel: 'Delete anyway',
    );
    if (!mounted) return;
    setState(() => _deleteBranch = ok);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final info = widget.branch;
    final offerable = info != null && info.deletable && info.branch.isNotEmpty;

    return AlertDialog(
      title: const Text('Finish this work?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This removes the "${widget.label}" checkout on the host. '
              'Uncommitted changes there are lost.',
            ),
            if (offerable) ...[
              const SizedBox(height: 8),
              CheckboxListTile(
                value: _deleteBranch,
                onChanged: (v) => _toggle(v, info),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text.rich(
                  TextSpan(
                    children: [
                      const TextSpan(text: 'Also delete the branch '),
                      TextSpan(
                        text: info.branch,
                        style: const TextStyle(
                          fontFamily: AppTheme.monoFamily,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                subtitle: Text(
                  _branchStatusLine(info),
                  style: TextStyle(
                    color: info.merged ? null : scheme.error,
                    fontSize: 12,
                  ),
                ),
              ),
              // Stated whether or not the box is ticked: the remote branch is
              // the thing people assume went with it.
              if (info.hasUpstream)
                Text(
                  'The remote branch ${info.upstream} is never deleted from here.',
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
            ] else if (info != null &&
                info.branch.isNotEmpty &&
                info.blockedReason.isNotEmpty)
              // Not offerable, but there IS a branch — say which one survives
              // and why, rather than silently leaving it behind.
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'The branch ${info.branch} is kept: ${info.blockedReason}.',
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
          ),
          onPressed: () => Navigator.pop(context, _deleteBranch),
          child: Text(_deleteBranch ? 'Remove & delete branch' : 'Remove'),
        ),
      ],
    );
  }
}

/// The one-line verdict under the checkbox — the thing that has to be true
/// *before* the user confirms, not discovered afterwards.
String _branchStatusLine(BranchInfo info) {
  if (info.merged) {
    final into = info.mergedInto.isEmpty ? info.defaultBranch : info.mergedInto;
    return 'Merged into $into — deleting loses nothing.';
  }
  final n = info.unmergedCommits;
  final commits = n == 1 ? '1 commit' : '$n commits';
  return 'Not merged into ${info.defaultBranch} — $commits would be lost.';
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


/// Create a fresh terminal in [workspaceId] and open it.
///
/// `/pane/new` rather than the `tab.create` proxy call, because this one hands
/// back the pane id — which is what lets it drop you straight into what it just
/// made instead of leaving you to find it. (Tabs are still a first-class thing;
/// see [newTab].) No manual refresh: the live event stream surfaces the new
/// pane on its own.
Future<void> newTerminal(
  BuildContext context,
  WidgetRef ref,
  String workspaceId,
) async {
  final client = ref.read(bridgeClientProvider);
  final messenger = ScaffoldMessenger.of(context);
  final router = GoRouter.of(context);
  if (client == null) {
    messenger.showSnackBar(
      const SnackBar(content: Text('No bridge connection.')),
    );
    return;
  }
  messenger.showSnackBar(
    const SnackBar(
      content: Text('Opening a new terminal…'),
      duration: Duration(seconds: 1),
    ),
  );
  try {
    final pane = await client.createPane(workspaceId: workspaceId);
    if (!context.mounted) return;
    router.push('/terminal/${Uri.encodeComponent(pane.paneId)}');
  } on BridgeException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
  }
}
