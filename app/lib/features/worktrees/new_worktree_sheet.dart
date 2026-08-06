import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../data/bridge/bridge_client.dart';
import '../../data/bridge/bridge_providers.dart';
import '../agents/agent_kind_picker.dart';
import '../agents/agent_lifecycle_providers.dart';

/// Create a git worktree from the phone and, optionally, put an agent to work
/// in it in the same gesture.
///
/// The two halves used to be unrelated: you made a worktree here and then went
/// looking for its space in the Overview to start an agent in it. On a phone
/// that is three screens for one intention — "branch off and get something
/// working on it" — so the toggle below folds the second half into the first.
///
/// It is a **composition of two documented calls**, not a new bridge endpoint:
/// `worktree.create` over the allowlisted proxy, then `POST /agent/start`
/// against the root pane that call just returned. Both are already validated
/// server-side and both are individually atomic, and the state in between them
/// is not a broken one — it is exactly what the toggle-off flow produces, a
/// worktree with an idle shell. See `docs/CONTRACT-worktree-launch.md`.
///
/// With the toggle off this behaves exactly as it did before: one call, one
/// snackbar, no agent list fetched.
Future<void> showNewWorktreeSheet(
  BuildContext context,
  WidgetRef ref, {
  required String cwd,
  required String repoLabel,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: _NewWorktreeSheet(cwd: cwd, repoLabel: repoLabel),
    ),
  );
}

/// The one line shown after a worktree was created AND its agent started.
///
/// Three outcomes, not two: the prompt is optional, and when one was asked for
/// the bridge can still report the agent up with the message undelivered
/// (`prompt_sent:false` + `prompt_error`). Saying "started and given your
/// message" there would be a lie the operator only discovers by opening a chat
/// that is sitting idle.
String worktreeLaunchSummary({
  required String branch,
  required StartAgentResult agent,
  required bool promptAsked,
}) {
  if (!promptAsked) return '$branch created — ${agent.kind} started';
  if (agent.promptSent) {
    return '$branch created — ${agent.kind} started and given your message';
  }
  return '$branch created — ${agent.kind} started, but your message was not '
      'delivered';
}

/// What to say when the worktree exists and the agent does not.
///
/// This is the failure that matters here: the operator asked for one thing and
/// got most of it, so a bare "request failed" would describe neither what is now
/// on the host nor what still needs doing. The message leads with the part that
/// succeeded — the worktree is real, it is open, it is not going to be cleaned
/// up — and then gives the bridge's own sentence for the part that did not.
String worktreeAgentFailure({
  required String branch,
  required String kind,
  required String error,
}) {
  return 'The "$branch" worktree was created and is open on the host, but '
      '$kind did not start in it.\n\n$error';
}

class _NewWorktreeSheet extends ConsumerStatefulWidget {
  const _NewWorktreeSheet({required this.cwd, required this.repoLabel});

  final String cwd;
  final String repoLabel;

  @override
  ConsumerState<_NewWorktreeSheet> createState() => _NewWorktreeSheetState();
}

class _NewWorktreeSheetState extends ConsumerState<_NewWorktreeSheet> {
  final _branch = TextEditingController();
  final _prompt = TextEditingController();

  bool _withAgent = false;
  String? _kind;

  /// Which leg is in flight, so the sheet can show progress rather than a
  /// spinner with no subject. A start routinely takes 5–30s (Herdr blocks until
  /// it has verified the agent is really up), which is far too long to leave
  /// unexplained.
  bool _creating = false;
  bool _starting = false;

  /// Set the moment the worktree exists. From here on the branch field is
  /// locked and cancelling no longer means "nothing happened" — so the buttons
  /// change with it.
  CreatedWorktree? _created;

  /// The agent leg's failure, kept on screen instead of thrown at a snackbar:
  /// it is a two-part outcome, and it comes with something to do about it.
  String? _agentError;

  bool get _busy => _creating || _starting;

  @override
  void dispose() {
    _branch.dispose();
    _prompt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final created = _created;

    return PopScope(
      // Back-swiping out mid-launch would leave the outcome with nowhere to be
      // reported. The buttons are disabled while busy for the same reason.
      canPop: !_busy,
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.call_split, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('New worktree in ${widget.repoLabel}',
                      style: text.titleMedium),
                ),
              ],
            ),
            const SizedBox(height: 18),

            TextField(
              controller: _branch,
              autofocus: true,
              // Locked once the checkout exists: the name is spent, and the
              // only thing left to retry is the agent.
              enabled: !_busy && created == null,
              decoration: const InputDecoration(
                labelText: 'Branch name',
                hintText: 'feat/my-change',
              ),
              style: const TextStyle(
                  fontFamily: AppTheme.monoFamily, fontSize: 13),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (_canSubmit) _create();
              },
            ),
            const SizedBox(height: 8),

            SwitchListTile(
              value: _withAgent,
              onChanged: _busy || created != null
                  ? null
                  : (v) => setState(() => _withAgent = v),
              contentPadding: EdgeInsets.zero,
              title: const Text('Start an agent in it'),
              subtitle: Text(
                'Launches in the new worktree’s first pane, once it exists.',
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),

            if (_withAgent) ...[
              const SizedBox(height: 8),
              Text('Agent', style: text.labelLarge),
              const SizedBox(height: 8),
              AgentKindField(
                // Watched here rather than at the top of build so a bare
                // worktree never pays for the round trip: the toggle being off
                // means the provider is not a dependency at all.
                agents: ref.watch(availableAgentsProvider),
                selected: _kind,
                onSelect: (k) => setState(() => _kind = k),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _prompt,
                enabled: !_busy,
                minLines: 2,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'First message (optional)',
                  hintText: 'What should it work on?',
                  alignLabelWithHint: true,
                ),
              ),
            ],

            if (_busy || _agentError != null) ...[
              const SizedBox(height: 18),
              _Progress(
                branch: _branch.text.trim(),
                kind: _kind ?? 'agent',
                withAgent: _withAgent,
                creating: _creating,
                created: created,
                starting: _starting,
                failed: _agentError != null,
              ),
            ],

            if (created != null && _agentError != null) ...[
              const SizedBox(height: 14),
              _Outcome(
                created: created,
                message: worktreeAgentFailure(
                  branch: _branch.text.trim(),
                  kind: _kind ?? 'the agent',
                  error: _agentError!,
                ),
              ),
            ],

              const SizedBox(height: 20),
              _actions(context, created),
            ],
          ),
        ),
      ),
    );
  }

  /// True when the form has everything the chosen flow needs.
  bool get _canSubmit =>
      !_busy &&
      _branch.text.trim().isNotEmpty &&
      (!_withAgent || _kind != null);

  Widget _actions(BuildContext context, CreatedWorktree? created) {
    // After a partial failure the worktree is already made, so "Cancel" would
    // be a lie and "Create" is done. What is left is retrying the agent, or
    // walking away knowing the worktree stays.
    if (created != null && _agentError != null) {
      return Row(
        children: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('Leave it empty'),
          ),
          const Spacer(),
          FilledButton.icon(
            onPressed: _busy || _kind == null ? null : _retryAgent,
            icon: const Icon(Icons.refresh),
            label: const Text('Try again'),
          ),
        ],
      );
    }
    return Row(
      children: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        const Spacer(),
        FilledButton.icon(
          onPressed: _canSubmit ? _create : null,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(_withAgent
                  ? Icons.rocket_launch_outlined
                  : Icons.add_rounded),
          label: Text(_withAgent ? 'Create & start' : 'Create'),
        ),
      ],
    );
  }

  /// Leg one: the worktree. On failure nothing was created, so the sheet stays
  /// exactly as it was and the operator fixes the branch name in place.
  Future<void> _create() async {
    final client = ref.read(bridgeClientProvider);
    final messenger = ScaffoldMessenger.of(context);
    // Captured before any await: on success this sheet is popped first, and a
    // popped sheet's context can no longer navigate.
    final navigator = Navigator.of(context);
    final router = GoRouter.of(context);
    if (client == null) {
      messenger.showSnackBar(
          const SnackBar(content: Text('No bridge connection.')));
      return;
    }
    final branch = _branch.text.trim();
    if (branch.isEmpty) return;

    setState(() {
      _creating = true;
      _agentError = null;
    });
    final CreatedWorktree created;
    try {
      final result = await client.herdrCommand('worktree.create', {
        'cwd': widget.cwd,
        'branch': branch,
        'label': branch,
      });
      created = CreatedWorktree.fromResult(result);
    } on BridgeException catch (e) {
      // Nothing was created — "branch already exists", a dirty repo, a bad
      // path. The sheet stays open on the field that fixes it.
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
      if (mounted) setState(() => _creating = false);
      return;
    }
    if (!mounted) {
      // Swiped away mid-create. The worktree exists regardless, and nothing was
      // started into it — both halves of that have to reach the operator.
      messenger.showSnackBar(SnackBar(
        content: Text(_withAgent
            ? 'Worktree "$branch" created. No agent was started — the sheet '
                'was closed before it could be.'
            : 'Worktree "$branch" created'),
        duration: const Duration(seconds: 4),
      ));
      return;
    }
    setState(() {
      _creating = false;
      _created = created;
    });

    if (!_withAgent) {
      // The unchanged path: same call, same snackbar, same timing as before the
      // toggle existed.
      navigator.pop();
      messenger.showSnackBar(SnackBar(
        content: Text('Worktree "$branch" created'),
        duration: const Duration(seconds: 1),
      ));
      return;
    }
    await _startAgent(client, messenger, navigator, router, created, branch);
  }

  /// Leg two, and the retry path — the worktree is never re-created.
  Future<void> _retryAgent() async {
    final created = _created;
    if (created == null) return;
    final client = ref.read(bridgeClientProvider);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final router = GoRouter.of(context);
    if (client == null) {
      messenger.showSnackBar(
          const SnackBar(content: Text('No bridge connection.')));
      return;
    }
    await _startAgent(
        client, messenger, navigator, router, created, _branch.text.trim());
  }

  Future<void> _startAgent(
    BridgeClient client,
    ScaffoldMessengerState messenger,
    NavigatorState navigator,
    GoRouter router,
    CreatedWorktree created,
    String branch,
  ) async {
    // Herdr answers worktree.create with the root pane, so there is nothing to
    // look up. If it ever answers without one, say so instead of picking a pane
    // by guesswork — an agent started in the wrong checkout is not a mistake a
    // retry undoes.
    if (created.rootPaneId.isEmpty) {
      setState(() {
        _starting = false;
        _agentError = 'Herdr did not report a root pane for the new worktree, '
            'so there was nowhere to start it. Open the space and start one '
            'from there.';
      });
      return;
    }

    final prompt = _prompt.text.trim();
    setState(() {
      _starting = true;
      _agentError = null;
    });
    try {
      final result = await client.startAgent(
        kind: _kind!,
        // The existing-pane form: the root pane is already sitting in the new
        // checkout, so passing cwd would be both redundant and a 400 (the
        // bridge rejects cwd with pane_id — a shell at a prompt cannot be moved
        // without typing into it).
        paneId: created.rootPaneId,
        prompt: prompt,
      );
      // The messenger and the router were captured from an ancestor, so both
      // outlive this sheet: a launch the operator swiped away from still
      // reports, it just has no sheet left to pop.
      if (mounted) navigator.pop();
      messenger.showSnackBar(SnackBar(
        content: Text(worktreeLaunchSummary(
          branch: branch,
          agent: result,
          promptAsked: prompt.isNotEmpty,
        )),
        duration: const Duration(seconds: 3),
      ));
      // Straight into the new agent's chat — the pane id comes back
      // session-qualified precisely so no lookup is needed in between.
      router.push('/transcript/${Uri.encodeComponent(result.paneId)}');
    } on BridgeException catch (e) {
      final message = worktreeAgentFailure(
        branch: branch,
        kind: _kind ?? 'the agent',
        error: e.message,
      );
      if (!mounted) {
        // No sheet left to hold the outcome panel — but a half-made worktree is
        // the last thing to report by staying quiet about.
        messenger.showSnackBar(SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 8),
        ));
        return;
      }
      setState(() {
        _starting = false;
        _agentError = e.message;
      });
    }
  }
}

/// The two legs of the flow as a live checklist.
///
/// A single spinner would be wrong here: the operator needs to know which half
/// they are waiting on, because only one of them can leave something behind.
class _Progress extends StatelessWidget {
  const _Progress({
    required this.branch,
    required this.kind,
    required this.withAgent,
    required this.creating,
    required this.created,
    required this.starting,
    required this.failed,
  });

  final String branch;
  final String kind;
  final bool withAgent;
  final bool creating;
  final CreatedWorktree? created;
  final bool starting;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StepRow(
          label: created != null
              ? 'Worktree "$branch" created'
              : 'Creating worktree "$branch"…',
          running: creating,
          done: created != null,
        ),
        if (withAgent) ...[
          const SizedBox(height: 8),
          _StepRow(
            label: failed
                ? '$kind did not start'
                : starting
                    ? 'Starting $kind in it…'
                    : 'Start $kind in it',
            running: starting,
            done: false,
            failed: failed,
          ),
          if (starting) ...[
            const SizedBox(height: 8),
            Text(
              'The server waits until the agent is really up — this can take a '
              'few seconds.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ],
      ],
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.label,
    required this.running,
    required this.done,
    this.failed = false,
  });

  final String label;
  final bool running;
  final bool done;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Widget leading;
    if (running) {
      leading = const SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (failed) {
      leading = Icon(Icons.error_outline, size: 16, color: scheme.error);
    } else if (done) {
      leading = Icon(Icons.check_circle, size: 16, color: scheme.primary);
    } else {
      leading = Icon(Icons.circle_outlined,
          size: 16, color: scheme.onSurfaceVariant);
    }
    final tint = failed
        ? scheme.error
        : running || done
            ? scheme.onSurface
            : scheme.onSurfaceVariant;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 16, height: 16, child: Center(child: leading)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: tint, height: 1.3),
          ),
        ),
      ],
    );
  }
}

/// The half-succeeded state, spelled out and kept on screen.
class _Outcome extends StatelessWidget {
  const _Outcome({required this.created, required this.message});

  final CreatedWorktree created;
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SheetNotice(
            icon: Icons.warning_amber_rounded,
            color: scheme.error,
            text: message,
          ),
          if (created.checkoutPath.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              created.checkoutPath,
              style: TextStyle(
                fontFamily: AppTheme.monoFamily,
                fontSize: 11,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
