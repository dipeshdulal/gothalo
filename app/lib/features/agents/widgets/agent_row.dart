import 'package:flutter/material.dart';

import '../../../core/naming.dart';
import '../../../core/theme.dart';
import '../../../core/tokens.dart';
import '../../../core/widgets/agent_age.dart';
import '../../../core/widgets/live_activity_line.dart';
import '../../../core/widgets/panel_row.dart';
import '../../../core/widgets/status_mark.dart';
import '../../../data/bridge/bridge_client.dart';
import '../../../data/bridge/models/snapshot.dart';
import '../../inbox/widgets/agent_avatar.dart';

/// The floor for a [AgentRow.compact] row, and the height of the expander that
/// follows a capped section.
///
/// A floor rather than a fixed height: the row now carries two lines and sizes
/// to them. It matters when a row has almost nothing to say — no project, no
/// age — and would otherwise collapse to something you have to aim at. 44 is
/// the *minimum* comfortable tap target and a list built exactly at the minimum
/// reads as cramped, so this sits above it.
const double kCompactRowHeight = 52;

/// The "show N more" / "show less" expander's strip. Taller than its text needs
/// because a 44px tap target is the comfortable minimum (see [kCompactRowHeight]),
/// but noticeably shorter than a row — the cap-lifting control should read as
/// lighter than the agents it hides.
const double kExpanderHeight = 44;

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
///  - [onStar] — an optional inline star action for Priority management.
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
    this.activityClient,
    this.onApprove,
    this.onStar,
    this.menu,
    this.focused = false,
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
       activityClient = null,
       onApprove = null,
       onStar = null,
       menu = null,
       focused = false;

  final Agent agent;
  final VoidCallback onTap;

  /// The bridge this agent is on, or null to leave it off the row — which is
  /// the right answer whenever the surrounding screen is already scoped to one
  /// server, and on a single-server setup, where it would be the same word on
  /// every row.
  final String? serverName;

  /// Manually pinned — the small star that tells an automatic Priority row
  /// (blocked/done) from a deliberate one. When [onStar] is set, it is also
  /// the tappable star control used to manage that pin.
  final bool starred;

  /// An extra marker after the status, for a section that needs to say
  /// something about the row that the agent itself does not know — Recent uses
  /// it to say whether it will reopen the chat or the terminal.
  final Widget? trailing;

  /// Show the agent's most recent message under the title.
  final bool showActivity;

  /// The bridge to use for the activity line. Needed by cross-server surfaces;
  /// null keeps the existing active-server lookup.
  final BridgeClient? activityClient;

  /// One-tap approve for a blocked agent (D7/D8). Null leaves the button off.
  final VoidCallback? onApprove;

  /// Optional star action. Priority uses this to keep its management affordance
  /// on the shared row instead of growing a second Priority-only row design.
  final VoidCallback? onStar;

  /// The overflow control at the end of the title line — restart, stop, split,
  /// close. Only the project view has one; it is a **flag on this row** rather
  /// than a reason to keep a second row implementation, which is how the
  /// project view ended up with a 250dp card for the same agent home showed in
  /// 56dp.
  final Widget? menu;

  /// This is the pane Herdr has focused on the host. Lifts the fill and tints
  /// the edge, the same "you are here" marker the project view always had.
  final bool focused;

  /// Rendered as a dense single line rather than a card.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return compact ? _buildCompact(context) : _buildFull(context);
  }

  /// The idle variant: the same two lines, at a lower rank.
  ///
  /// It was one line, and that was over-compressed — the title, the project,
  /// the branch and the age all competed for one row's width, so the two things
  /// that identify an agent both truncated at once ("Set up mlx serve for
  /// Dee…", "feat/transcript-s…"). The branch is precisely what tells two rows
  /// in the same repo apart, so losing it costs the row its point.
  ///
  /// So it is structurally the same as [_buildFull] now — title and status on
  /// the first line, project and age on the second — and **the hierarchy comes
  /// from weight instead of line count**: a smaller marker, a dimmer title, the
  /// status as a bare dot with no label, a meta line without the accent on the
  /// branch, tighter padding, and no card of its own (compact rows share one
  /// panel). Everything that says "secondary" says it quietly, and the row
  /// still reads.
  Widget _buildCompact(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: kCompactRowHeight),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // A marker rather than the full-size avatar: still says which
              // agent this is, at a weight that does not compete with the
              // working rows above.
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: AgentAvatar(agent: agent.agent, radius: 9),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            agent.displayTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w500,
                              // Dimmer than a working row's title. This is the
                              // main carrier of the hierarchy now that the line
                              // counts match.
                              color: scheme.onSurface.withValues(alpha: 0.78),
                            ),
                          ),
                        ),
                        const SizedBox(width: Space.md),
                        // The dot, without its label: the section heading above
                        // already says IDLE, so the word would be the same
                        // word on every row.
                        StatusMark(agent.agentStatus, withLabel: false),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Expanded(
                          child: _ProjectLine(
                            agent: agent,
                            serverName: serverName,
                            muted: true,
                          ),
                        ),
                        const SizedBox(width: Space.md),
                        AgentAge(agent.sinceLastActivity),
                      ],
                    ),
                  ],
                ),
              ),
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
      // should be findable without reading a word of the row. Blocked beats
      // focused — "this one is stuck" is more urgent than "this one is where
      // your cursor is".
      borderColor: blocked ? scheme.error : (focused ? scheme.primary : null),
      selected: focused,
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top-aligned, and outside the text column: a centred avatar — or
          // worse, a menu button with a 48dp tap target — used to set the
          // height of the *title line*, which pushed the meta line 18dp away
          // from the title it belongs to while sitting flush against the
          // activity line below it. The gap floated above the wrong thing.
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: AgentAvatar(agent: agent.agent, radius: 11),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
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
                    if (starred && onStar == null) ...[
                      Icon(Icons.star, size: 12, color: scheme.primary),
                      const SizedBox(width: Space.sm),
                    ],
                    // The age and the status belong together — "done" is a
                    // state, "done · 4m" is a decision — so they share the end
                    // of the title line rather than each claiming a corner.
                    AgentAge(agent.sinceLastActivity, emphasize: blocked),
                    if (trailing case final t?) ...[
                      const SizedBox(width: Space.md),
                      t,
                    ],
                    const SizedBox(width: Space.md),
                    StatusMark(agent.agentStatus),
                    if (onStar != null) ...[
                      const SizedBox(width: Space.sm),
                      SizedBox(
                        width: 28,
                        height: 28,
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          visualDensity: VisualDensity.compact,
                          tooltip: starred ? 'Unstar' : 'Star',
                          onPressed: onStar,
                          icon: Icon(
                            starred ? Icons.star : Icons.star_border,
                            size: 17,
                            color: starred
                                ? const Color(0xFFF5C043)
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                // Tight to the title: they are one thing, "this task, in this
                // project". The activity line below gets the larger gap,
                // because it is a different kind of content — what the agent
                // is saying, not what it is.
                const SizedBox(height: 2),
                _ProjectLine(agent: agent, serverName: serverName),
                // Carries its own 4dp top padding, which is that larger gap.
                if (showActivity)
                  LiveActivityLine(
                    paneId: agent.paneId,
                    status: agent.agentStatus,
                    client: activityClient,
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
          ),
          if (menu case final m?) ...[const SizedBox(width: 2), m],
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
  const _ProjectLine({
    required this.agent,
    required this.serverName,
    this.muted = false,
  });

  final Agent agent;
  final String? serverName;

  /// Drop the accent from the branch. The mono face still marks it as an
  /// identifier — which is the part doing the work of telling two rows apart —
  /// but an idle row should not carry the same colour as a working one.
  final bool muted;

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
            color: muted ? scheme.onSurfaceVariant : scheme.primary,
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
        height: kExpanderHeight,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              expanded ? 'Show less' : 'Show $hidden more',
              style: TextStyle(
                color: scheme.primary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            AnimatedRotation(
              turns: expanded ? 0.5 : 0,
              duration: Motion.fast,
              child: Icon(Icons.expand_more, size: 16, color: scheme.primary),
            ),
          ],
        ),
      ),
    );
  }
}
