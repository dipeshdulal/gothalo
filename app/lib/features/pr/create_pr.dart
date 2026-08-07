import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/bridge/bridge_client.dart';
import '../../data/bridge/bridge_providers.dart';

/// The **agent-performed** half of the suggestion mechanism: a suggestion whose
/// `performer` is `agent` is not something the app does, it is something the app
/// asks the agent in the pane to do — by sending it a message.
///
/// "Create PR" is the one that exists today, and it is why the distinction is
/// in the payload at all. The bridge deliberately never runs `git push` or
/// `gh pr create` (D29): the agent has the credentials, the repo conventions and
/// the context to write a real PR body, it works the same for claude / codex /
/// opencode / anything Herdr can host, and every step of it shows up in the
/// transcript where it can be watched and interrupted. The suggestion carries
/// the gate and the words; the agent does the work.
///
/// **The prompt is shown and editable before it is sent.** A phone tap that
/// silently commits and pushes is the wrong default for an irreversible,
/// outward-facing action, and the wording is exactly what a person will want to
/// adjust ("…and mention it supersedes #41").

/// The pane's git situation (`GET /diff?pane=…&context=1`).
///
/// Read at **tap time only**, as the pre-flight for the one action that reaches
/// outside the machine. The per-render gate is the suggestion itself — the
/// bridge already read this to decide whether to offer the chip — so this is not
/// a second opinion about whether a PR is possible, it is a re-check that the
/// answer has not changed in the seconds since the chip was drawn. An agent that
/// opened the PR while you were reading the screen is exactly the case worth
/// catching.
///
/// Never surfaces an error: every failure (no connection, a bridge too old to
/// send the `git` object) collapses to [GitContext.unknown], which reads as
/// "can't tell" and blocks the send rather than guessing.
final paneGitContextProvider =
    FutureProvider.autoDispose.family<GitContext, String>((ref, pane) async {
      final client = ref.watch(bridgeClientProvider);
      if (client == null) return GitContext.unknown;
      try {
        final result = await client.getDiff(pane, contextOnly: true);
        return result.git;
      } catch (_) {
        return GitContext.unknown;
      }
    });

/// Why a pull request can't be opened from this pane, or null when it can.
///
/// Mirrors the bridge's own gate (`suggest.createPR`) — deliberately, because
/// these are two different jobs on the same conditions. The bridge's version
/// decides whether to *offer*; this one decides whether to *send*, and unlike
/// the bridge it has to say why. A chip that has gone stale between being drawn
/// and being tapped should explain itself, not fail silently.
///
/// Ordered from "there is no repository" outwards, so the message names the
/// first thing that is actually wrong rather than a downstream symptom of it.
String? prBlockReason(GitContext git) {
  if (!git.repo) {
    return "This agent isn't working inside a git repository, so there's "
        'nothing to open a pull request from.';
  }
  if (git.branch.isEmpty) {
    return 'This checkout is on a detached HEAD — check out a branch before '
        'opening a pull request.';
  }
  if (git.remote.isEmpty) {
    return 'This repository has no git remote, so the branch has nowhere to be '
        'pushed.';
  }
  if (git.onDefaultBranch) {
    return 'This pane is on ${git.branch}, the default branch. Move the work '
        'onto a feature branch first.';
  }
  if (!git.hasWork) {
    final base = git.defaultBranch.isNotEmpty ? git.defaultBranch : 'the default branch';
    return 'Nothing to open a pull request with: no commits ahead of $base, '
        'and no uncommitted changes.';
  }
  return null;
}

/// Put an agent-performed [suggestion] in front of the user, then send it.
///
/// [preflight] is re-checked at tap time and, when it returns a sentence, that
/// sentence is shown instead of the editor. Only the pull request supplies one:
/// it is the single action here that reaches outside the host, so it is the
/// single one worth a round-trip to re-validate. The others are navigations.
Future<void> showAgentPromptSheet(
  BuildContext context,
  WidgetRef ref, {
  required PaneSuggestion suggestion,
  String agentKind = 'agent',
  Future<String?> Function()? preflight,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final client = ref.read(bridgeClientProvider);
  if (client == null) {
    messenger.showSnackBar(const SnackBar(content: Text('No bridge connection.')));
    return;
  }

  final blocked = preflight == null ? null : await preflight();
  if (!context.mounted) return;

  final sent = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _AgentPromptSheet(
      suggestion: suggestion,
      agentKind: agentKind,
      blocked: blocked,
    ),
  );
  if (sent == null || sent.isEmpty) return;

  try {
    // Same wire path as the composer: the body is pasted and the trailing \r
    // is delivered as a real Enter, so the agent receives it as one submitted
    // message.
    await client.sendText(suggestion.pane, '$sent\r');
    messenger.showSnackBar(
      SnackBar(
        content: Text('Sent to $agentKind — watch the transcript.'),
        duration: const Duration(seconds: 2),
      ),
    );
  } on BridgeException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
  }
}

/// The pull request's tap-time pre-flight — a fresh read of the pane's git
/// situation, and the sentence explaining it if the answer has changed.
Future<String?> prPreflight(WidgetRef ref, String pane) async {
  final git = await ref.refresh(paneGitContextProvider(pane).future);
  return prBlockReason(git);
}

/// The sheet body: what is about to be asked, the editable text, and Send.
/// Pops with the (possibly edited) prompt, or null if nothing is to be sent.
class _AgentPromptSheet extends StatefulWidget {
  const _AgentPromptSheet({
    required this.suggestion,
    required this.agentKind,
    required this.blocked,
  });

  final PaneSuggestion suggestion;
  final String agentKind;
  final String? blocked;

  @override
  State<_AgentPromptSheet> createState() => _AgentPromptSheetState();
}

class _AgentPromptSheetState extends State<_AgentPromptSheet> {
  late final TextEditingController _prompt;

  @override
  void initState() {
    super.initState();
    _prompt = TextEditingController(
      text: widget.blocked == null ? widget.suggestion.prompt : '',
    );
  }

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final blocked = widget.blocked;

    return Padding(
      // Lift the whole sheet above the keyboard rather than letting it overflow
      // — the editor is the point of this sheet, so it is always in use.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.merge_type, size: 20, color: scheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    widget.suggestion.label,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                      color: scheme.onSurface,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                // The bridge already wrote the one-line summary for the chip;
                // reusing it means the sheet and the chip cannot disagree about
                // what is being proposed.
                blocked == null
                    ? widget.suggestion.detail
                    : 'No longer available for this pane',
                style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 14),
              if (blocked != null)
                _Notice(message: blocked)
              else ...[
                // The prompt is editable in place: this is the message the
                // agent will receive verbatim, not a preview of one.
                TextField(
                  controller: _prompt,
                  minLines: 4,
                  maxLines: 8,
                  autofocus: false,
                  decoration: InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${widget.agentKind} runs this itself — committing, pushing '
                  'and `gh pr create` all happen in its transcript, where you '
                  'can watch and interrupt them.',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(blocked == null ? 'Cancel' : 'Close'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: blocked != null
                        ? null
                        : () => Navigator.pop(context, _prompt.text.trim()),
                    icon: const Icon(Icons.send, size: 18),
                    label: const Text('Send'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The blocked-reason panel — a tinted block rather than a snackbar, because
/// it is the answer to "why can't I do this?" and the user is entitled to read
/// it at their own pace.
class _Notice extends StatelessWidget {
  const _Notice({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 13, color: scheme.onSurface),
            ),
          ),
        ],
      ),
    );
  }
}
