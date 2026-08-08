import 'package:flutter/material.dart';

import '../../../core/naming.dart';
import '../../../core/theme.dart';
import '../../../core/tokens.dart';
import '../../../core/widgets/agent_age.dart';
import '../../../core/widgets/live_activity_line.dart';
import '../../../core/widgets/panel_row.dart';
import '../../../core/widgets/status_mark.dart';
import '../../../data/bridge/models/snapshot.dart';
import '../../inbox/widgets/agent_avatar.dart';

/// The height of a [AgentRow.compact] row.
///
/// 48, not 44. 44 is the *minimum* comfortable tap target, and a list built
/// exactly at the minimum is a list you have to aim at — the first pass landed
/// there and read as cramped. Four pixels back is most of the comfort for
/// almost none of the density.
const double kCompactRowHeight = 48;

/// One agent, as a row. **The** agent row — there is not a second one.
///
/// Home lists the same agents up to three times over (Priority, Recent, grouped
/// by state) and the Flock screen lists them again per server. The fastest way
/// for those to drift is for each to grow its own tile, which is exactly what
/// had happened before this: the same agent looked like two different things
/// depending on which screen you reached it from. They share this one instead,
/// and the differences between surfaces are **flags**, not forks:
///
///  - [serverName] — omitted where the server is implied (inside one server's
///    flock) and shown where the list spans several.
///  - [showActivity] — the live "what is it doing right now" line, on the
///    surfaces with room for it.
///  - [onApprove] — the one-tap approve a blocked agent gets in the flock.
///  - [compact] — see below.
///
/// What it says, in order of what a glance needs: the task, how long it has
/// been in this state, its status, and then **where it lives** — which is the
/// project (`gothalo · feat/x`), never the space id or the pane id.
///
/// ### The compact variant
///
/// A dozen idle agents rendered as a dozen cards spends most of a phone screen
/// saying that nothing wants you. [AgentRow.compact] is the same row at a
/// deliberately lower rank: one [kCompactRowHeight] line, no card of its own
/// (compact rows share a single panel — see `CompactAgentPanel`), the avatar
/// dropped to a marker and the status label dropped entirely, since the section
/// heading above already says what it is. It is the same language one step
/// down, not a second list style.
class AgentRow extends StatelessWidget {
  const AgentRow({
    super.key,
    required this.agent,
    required this.onTap,
    this.serverName,
    this.starred = false,
    this.trailing,
    this.showActivity = false,
    this.onApprove,
  }) : compact = false;

  /// The dense variant, for agents that want nothing from you.
  const AgentRow.compact({
    super.key,
    required this.agent,
    required this.onTap,
    this.serverName,
  }) : compact = true,
       starred = false,
       trailing = null,
       showActivity = false,
       onApprove = null;

  final Agent agent;
  final VoidCallback onTap;

  /// The bridge this agent is on, or null to leave it off the row — which is
  /// the right answer whenever the surrounding screen is already scoped to one
  /// server, and on a single-server setup, where it would be the same word on
  /// every row.
  final String? serverName;

  /// Manually pinned — the small star that tells an automatic Priority row
  /// (blocked/done) from a deliberate one.
  final bool starred;

  /// An extra marker after the status, for a section that needs to say
  /// something about the row that the agent itself does not know — Recent uses
  /// it to say whether it will reopen the chat or the terminal.
  final Widget? trailing;

  /// Show the agent's most recent message under the title.
  final bool showActivity;

  /// One-tap approve for a blocked agent (D7/D8). Null leaves the button off.
  final VoidCallback? onApprove;

  /// Rendered as a dense single line rather than a card.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return compact ? _buildCompact(context) : _buildFull(context);
  }

  Widget _buildCompact(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Branch if the bridge knows it, else the project folder — the one piece of
    // "where" that fits on a line, and the piece that tells two agents in the
    // same repo apart.
    final where = [
      agent.gitLabel,
      if (serverName != null && serverName!.isNotEmpty) serverName!,
    ].where((s) => s.isNotEmpty).join(' · ');

    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: kCompactRowHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11),
          child: Row(
            children: [
              // A marker rather than the full avatar: still says which agent
              // this is, at a size that does not set the row's height.
              AgentAvatar(agent: agent.agent, radius: 9),
              const SizedBox(width: 10),
              Expanded(
                flex: 3,
                child: Text(
                  agent.displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (where.isNotEmpty) ...[
                const SizedBox(width: Space.md),
                Flexible(
                  flex: 2,
                  child: Text(
                    where,
                    maxLines: 1,
                    textAlign: TextAlign.right,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ).mono,
                  ),
                ),
              ],
              const SizedBox(width: Space.md),
              AgentAge(agent.sinceLastActivity),
            ],
          ),
        ),
      ),
    );
  }

  /// The standard row: two lines and nothing more.
  ///
  /// It used to cost about 130dp — a two-line title at generous leading, a
  /// meta line, and the age and the status each parked in their own corner of
  /// a third implied line, inside card padding sized for all of it. Seven
  /// agents filled a phone. It is now about 52dp: the title takes one line, the
  /// age and the status share the end of that same line, and the project sits
  /// under it. A dozen agents are scannable in roughly one screen.
  ///
  /// Nothing was dropped to get there — same six facts, laid out in two lines
  /// instead of three and a half.
  Widget _buildFull(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final blocked = agent.agentStatus == AgentStatus.blocked;
    return PanelRow(
      onTap: onTap,
      // The one tinted edge in a list of agents: one that is waiting on you
      // should be findable without reading a word of the row.
      borderColor: blocked ? scheme.error : null,
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AgentAvatar(agent: agent.agent, radius: 11),
              const SizedBox(width: Space.md),
              Expanded(
                child: Text(
                  agent.displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    height: 1.25,
                  ),
                ),
              ),
              const SizedBox(width: Space.md),
              if (starred) ...[
                Icon(Icons.star, size: 12, color: scheme.primary),
                const SizedBox(width: Space.sm),
              ],
              // The age and the status belong together — "done" is a state,
              // "done · 4m" is a decision — so they share the end of the title
              // line rather than each claiming a corner.
              AgentAge(agent.sinceLastActivity, emphasize: blocked),
              if (trailing case final t?) ...[
                const SizedBox(width: Space.md),
                t,
              ],
              const SizedBox(width: Space.md),
              StatusMark(agent.agentStatus),
            ],
          ),
          const SizedBox(height: 3),
          // Aligned under the title, not back under the avatar: the avatar
          // column is the row's gutter, so this reads as part of the agent only
          // when it lines up with the agent's text.
          Padding(
            padding: const EdgeInsets.only(left: 22 + Space.md),
            child: _ProjectLine(agent: agent, serverName: serverName),
          ),
          // The agent's most recent message, from the same widget and the same
          // `/agent-state` source the project view uses, so no two screens can
          // disagree about whether an agent is alive.
          if (showActivity)
            Padding(
              padding: const EdgeInsets.only(left: 22 + Space.md),
              child: LiveActivityLine(
                paneId: agent.paneId,
                status: agent.agentStatus,
              ),
            ),
          if (blocked && onApprove != null) ...[
            const SizedBox(height: Space.md),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  minimumSize: const Size(0, 28),
                ),
                onPressed: onApprove,
                icon: const Icon(Icons.check_circle_outline, size: 14),
                label: const Text('Approve'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// `gothalo · feat/x · studio` — the project, then the server.
///
/// One ellipsizing line rather than the stacked folder/branch/session rows the
/// flock list used to use: this is context for a row you are scanning past, not
/// the subject of it. The branch is set in mono and the accent because it is a
/// git ref; the repo and the server are prose, because they are names.
class _ProjectLine extends StatelessWidget {
  const _ProjectLine({required this.agent, required this.serverName});

  final Agent agent;
  final String? serverName;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dim = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);
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
            fontSize: 12,
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

/// A run of [AgentRow.compact] rows sharing one panel.
///
/// One panel rather than one per row is the point. Twelve hairline-edged boxes
/// is twelve times the visual weight of twelve lines in a box, for the same
/// twelve agents that want nothing from you — and it is still the same
/// language: a flat opaque surface held by an edge, just holding a list instead
/// of a single thing. The container itself is [PanelList], shared with the
/// projects list, which had the same problem.
class CompactAgentPanel extends StatelessWidget {
  const CompactAgentPanel({super.key, required this.rows, this.footer});

  final List<Widget> rows;

  /// The "show N more" control, drawn inside the panel below a divider.
  final Widget? footer;

  @override
  Widget build(BuildContext context) => PanelList(rows: rows, footer: footer);
}

/// The "show N more" / "show less" control at the foot of a capped section.
///
/// Used inside a [CompactAgentPanel] and as a standalone row under a run of
/// cards, because it is the same idea either way — a cap the user can lift —
/// and two controls that said that differently would read as two features. Same
/// wording and same chevron as Priority's expander, for the same reason.
class SectionExpander extends StatelessWidget {
  const SectionExpander({
    super.key,
    required this.hidden,
    required this.expanded,
    required this.onToggle,
  });

  final int hidden;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onToggle,
      child: SizedBox(
        height: kCompactRowHeight,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              expanded ? 'Show less' : 'Show $hidden more',
              style: TextStyle(
                color: scheme.primary,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            AnimatedRotation(
              turns: expanded ? 0.5 : 0,
              duration: Motion.fast,
              child: Icon(Icons.expand_more, size: 18, color: scheme.primary),
            ),
          ],
        ),
      ),
    );
  }
}
