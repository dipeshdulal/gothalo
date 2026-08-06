import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/bridge/bridge_client.dart';
import '../../data/bridge/bridge_providers.dart';

/// One-tap "open a pull request for this work", done by **instructing the agent
/// already running in the pane** rather than by the bridge running git itself.
///
/// The bridge deliberately never runs `git push` or `gh pr create` (see
/// docs/CONTRACT-diff.md): the agent has the credentials, the repo conventions
/// and the context to write a real PR body, it works the same for claude /
/// codex / opencode / anything Herdr can host, and every step of it shows up in
/// the transcript where it can be watched and interrupted. All this feature
/// adds is a gate (is a PR even possible here?) and a prompt.
///
/// The prompt is shown and editable before it is sent. A phone tap that
/// silently commits and pushes is the wrong default for an irreversible,
/// outward-facing action, and the wording is exactly what a person will want to
/// adjust ("…and mention it supersedes #41").

/// The pane's git situation (`GET /diff?pane=…&context=1`) — the gate's input.
///
/// `autoDispose` and refetched each time a transcript screen is built: branch,
/// ahead-count and dirtiness all change under us while the agent works, and a
/// stale "3 commits ahead" is exactly the kind of thing that would offer a PR
/// for work that has already been merged.
///
/// Never surfaces an error: every failure (no connection, non-agent pane, a
/// bridge too old to send the `git` object) means the same thing to the UI —
/// we cannot show a PR button — so they all collapse to [GitContext.unknown]
/// rather than making each caller branch. `context=1` keeps this cheap enough
/// to run on screen build: it skips the working-tree diff entirely.
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
/// Ordered from "there is no repository" outwards, so the message names the
/// first thing that is actually wrong rather than a downstream symptom of it.
/// Every one of these is a state a person can fix, which is why they are
/// sentences rather than a disabled button with no explanation.
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

/// A one-line summary of what the PR would be made of, for the sheet header.
/// Only meaningful once [prBlockReason] has passed.
String prContextSummary(GitContext git) {
  final base = git.defaultBranch.isNotEmpty ? git.defaultBranch : 'default';
  return [
    '${git.branch} → $base',
    if (git.ahead > 0) '${git.ahead} commit${git.ahead == 1 ? '' : 's'} ahead',
    if (git.dirty) 'uncommitted changes',
    if (git.upstream.isEmpty) 'not pushed yet',
  ].join(' · ');
}

/// The default instruction sent to the agent.
///
/// **One line, deliberately.** `POST /send` pastes the body and then presses
/// Enter as a separate key event, which is what makes a message with a newline
/// in it agent-dependent: Claude Code turns on bracketed paste and treats an
/// embedded newline as a newline, but an agent that doesn't would read it as a
/// submit and fire the prompt off half-written. A single flowing line is
/// understood identically by every agent, and it still wraps readably in the
/// sheet's editor. (Numbered clauses keep the steps distinguishable without
/// needing the line breaks.)
///
/// It names the branch, the remote and the base explicitly rather than leaving
/// the agent to work them out: the app already knows them, and an agent that
/// guesses wrong pushes to the wrong place. When git couldn't name a default
/// branch the base is left out entirely — `gh pr create` resolves the repo's
/// own default, which is a better answer than a guess.
String buildPrPrompt(GitContext git) {
  final branch = git.branch.isNotEmpty ? git.branch : 'the current branch';
  final remote = git.remote.isNotEmpty ? git.remote : 'origin';
  final against =
      git.defaultBranch.isNotEmpty ? ' against ${git.defaultBranch}' : '';
  final commit = git.dirty
      ? 'commit everything outstanding with a Conventional Commits message '
            '(feat:/fix:/docs:/refactor:/test:), '
      : '';
  return 'Open a pull request for the work on $branch: $commit'
      'push the branch with `git push -u $remote $branch`, then open the PR'
      '$against with `gh pr create`, writing a title and body that say what '
      'changed and why. Stay on this branch — do not switch, rebase or '
      'force-push — and reply with the PR URL when it is open.';
}

/// Open the "Create pull request" sheet for [pane]: the gate's verdict, the
/// editable prompt, and one button that sends it to the agent.
///
/// The sheet is shown even when the action is blocked, carrying the reason.
/// A button that silently does nothing (or vanishes) teaches the user nothing;
/// "you're on main, move the work to a feature branch" teaches them the one
/// thing they need to do next.
Future<void> showCreatePrSheet(
  BuildContext context,
  WidgetRef ref, {
  required String pane,
  String agentKind = 'agent',
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final client = ref.read(bridgeClientProvider);
  if (client == null) {
    messenger.showSnackBar(const SnackBar(content: Text('No bridge connection.')));
    return;
  }

  // Re-read rather than trusting the value the button was drawn from: the tap
  // may come minutes after the screen was built, and the agent has very
  // possibly committed something in between.
  final git = await ref.refresh(paneGitContextProvider(pane).future);
  if (!context.mounted) return;

  final sent = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _CreatePrSheet(git: git, agentKind: agentKind),
  );
  if (sent == null || sent.isEmpty) return;

  try {
    // Same wire path as the composer: the body is pasted and the trailing \r
    // is delivered as a real Enter, so the agent receives it as one submitted
    // message.
    await client.sendText(pane, '$sent\r');
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

/// The sheet body: what the PR would be, the prompt to send, and Send/Cancel.
/// Pops with the (possibly edited) prompt, or null if nothing is to be sent.
class _CreatePrSheet extends StatefulWidget {
  const _CreatePrSheet({required this.git, required this.agentKind});

  final GitContext git;
  final String agentKind;

  @override
  State<_CreatePrSheet> createState() => _CreatePrSheetState();
}

class _CreatePrSheetState extends State<_CreatePrSheet> {
  late final TextEditingController _prompt;
  late final String? _blocked;

  @override
  void initState() {
    super.initState();
    _blocked = prBlockReason(widget.git);
    _prompt = TextEditingController(
      text: _blocked == null ? buildPrPrompt(widget.git) : '',
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
    final blocked = _blocked;

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
                    'Create pull request',
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
                blocked == null
                    ? prContextSummary(widget.git)
                    : 'Not available for this pane',
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
