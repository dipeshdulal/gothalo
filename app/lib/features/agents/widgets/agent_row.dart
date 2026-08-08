import 'package:flutter/material.dart';

import '../../../core/naming.dart';
import '../../../core/theme.dart';
import '../../../core/tokens.dart';
import '../../../core/widgets/agent_age.dart';
import '../../../core/widgets/panel_row.dart';
import '../../../core/widgets/status_mark.dart';
import '../../../data/bridge/models/snapshot.dart';
import '../../inbox/widgets/agent_avatar.dart';

/// One agent, as a row.
///
/// The home screen lists the same agents three times over — as Priority, as
/// Recent, and grouped by state — and the fastest way for those to drift is for
/// each to grow its own tile. They share this one instead, so an agent looks
/// identical wherever it turns up and the eye can follow it between sections.
///
/// What it says, in order of what a glance needs: the task, how long it has
/// been in this state, its status, and then **where it lives** — which is the
/// project (`gothalo · feat/x`), never the space id or the pane id. The server
/// is named last and only when there is more than one, since on a single-server
/// setup it is the same word on every row.
class AgentRow extends StatelessWidget {
  const AgentRow({
    super.key,
    required this.agent,
    required this.onTap,
    this.serverName,
    this.starred = false,
    this.trailing,
  });

  final Agent agent;
  final VoidCallback onTap;

  /// The bridge this agent is on, or null to leave it off the row.
  final String? serverName;

  /// Manually pinned — the small star that tells an automatic Priority row
  /// (blocked/done) from a deliberate one.
  final bool starred;

  /// An extra marker after the status, for a section that needs to say
  /// something about the row that the agent itself does not know — Recent uses
  /// it to say whether it will reopen the chat or the terminal.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final blocked = agent.agentStatus == AgentStatus.blocked;
    return PanelRow(
      onTap: onTap,
      // The one tinted edge on the home screen: an agent that is waiting on you
      // should be findable without reading a word of the row.
      borderColor: blocked ? scheme.error : null,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AgentAvatar(agent: agent.agent, radius: 13),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  agent.displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: 3),
                _ProjectLine(agent: agent, serverName: serverName),
              ],
            ),
          ),
          const SizedBox(width: Space.md),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (starred) ...[
                    Icon(Icons.star, size: 13, color: scheme.primary),
                    const SizedBox(width: Space.sm),
                  ],
                  // How long it has been like this. "Done" is a state;
                  // "Done · 4m" is a decision.
                  AgentAge(agent.sinceLastActivity, emphasize: blocked),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (trailing case final t?) ...[
                    t,
                    const SizedBox(width: Space.md),
                  ],
                  StatusMark(agent.agentStatus),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// `gothalo · feat/x · studio` — the project, then the server.
///
/// One ellipsizing line rather than the stacked folder/branch/session rows the
/// flock list uses: on the home screen this is context for a row you are
/// scanning past, not the subject of it. The branch is set in mono and the
/// accent because it is a git ref; the repo and the server are prose, because
/// they are names.
class _ProjectLine extends StatelessWidget {
  const _ProjectLine({required this.agent, required this.serverName});

  final Agent agent;
  final String? serverName;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dim = TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant);
    final project = agent.projectName;
    final branch = agent.branchName;

    final spans = <InlineSpan>[];
    void sep() {
      if (spans.isNotEmpty) spans.add(TextSpan(text: '  ·  ', style: dim));
    }

    if (project.isNotEmpty) {
      sep();
      spans.add(TextSpan(text: project, style: dim));
    }
    if (branch != null && branch.isNotEmpty) {
      sep();
      spans.add(
        TextSpan(
          text: branch,
          style: TextStyle(
            fontSize: 11.5,
            color: scheme.primary,
            fontWeight: FontWeight.w500,
          ).mono,
        ),
      );
    }
    if (serverName != null && serverName!.isNotEmpty) {
      sep();
      spans.add(TextSpan(text: serverName!, style: dim));
    }
    // Nothing known about where it lives — better an empty line than a stray
    // separator or a pane id.
    if (spans.isEmpty) return const SizedBox.shrink();

    return Text.rich(
      TextSpan(children: spans),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
