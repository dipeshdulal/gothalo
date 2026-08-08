import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_background.dart';
import '../../core/connection/connection_providers.dart';
import '../../core/naming.dart';
import '../../core/theme.dart';
import '../../core/tokens.dart';
import '../../core/widgets/panel_row.dart';
import '../../data/bridge/bridge_client.dart';
import '../../data/bridge/models/snapshot.dart';
import '../../core/widgets/action_chip.dart';
import '../agents/agent_groups.dart';
import '../agents/start_agent_sheet.dart';
import '../agents/widgets/agent_sections.dart';
import '../approvals/approve_action.dart';
import '../jump/jump_sheet.dart';
import '../herdr_actions.dart';
import '../overview/overview_screen.dart' show spaceCwdOf;
import '../push/enable_push_banner.dart';
import '../worktrees/new_worktree_sheet.dart';
import '../servers/add_edit_server_sheet.dart';
import '../spaces/open_space_sheet.dart';
import 'inbox_providers.dart';

/// The flock for the active server: an **Agents** tab (every agent,
/// attention-first) and a **Projects** tab (what is checked out on this
/// machine, one row per repo/branch). Pull to refresh on either. Tapping an
/// agent opens its chat; tapping a project opens it.
///
/// Herdr calls the second thing a workspace, or a space. The app does not —
/// see `lib/core/naming.dart` for the whole of that mapping.
class InboxScreen extends ConsumerWidget {
  const InboxScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(snapshotControllerProvider);
    final connection = ref.watch(activeConnectionProvider).asData?.value;
    // The shared agent list is written against a (server, agent) pair, because
    // home's spans several servers. Here there is exactly one, so it is lifted
    // from the active connection rather than looked up again.
    final summary = ServerSummary(
      id: connection?.id ?? '',
      name: connection?.name ?? '',
      baseUrl: connection?.baseUrl ?? '',
      isActive: true,
    );

    return AppBackground(
      asset: Backgrounds.flock,
      child: DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
            leading: IconButton(
              tooltip: 'Servers',
              onPressed: () => context.go('/'),
              icon: const Icon(Icons.dns_outlined),
            ),
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Flock'),
                if (connection != null)
                  Text(
                    connection.name,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: 'Jump to an agent',
                onPressed: () => showJumpSheet(context),
                icon: const Icon(Icons.bolt),
              ),
              // Overview + per-server settings are occasional visits, not
              // every-open actions — folded into one overflow menu so the bar
              // isn't five same-weight icons deep. Refresh dropped outright
              // (not just relocated): both tabs already pull-to-refresh, so
              // the button was a redundant affordance, not a demoted one.
              PopupMenuButton<_FlockMenuAction>(
                tooltip: 'More',
                icon: const Icon(Icons.more_vert),
                onSelected: (action) => switch (action) {
                  _FlockMenuAction.openSpace => showOpenSpaceSheet(context),
                  _FlockMenuAction.overview => context.push('/overview'),
                  _FlockMenuAction.timeline => context.push('/timeline'),
                  _FlockMenuAction.editServer => connection == null
                      ? null
                      : showEditServerSheet(context, connection.id),
                },
                // Only what the chip row above does not already carry — the
                // end state is chips for the frequent things and a short menu
                // for the rest, not both holding the same list.
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: _FlockMenuAction.overview,
                    child: _MenuRow(
                      icon: Icons.dashboard_outlined,
                      label: 'All projects',
                    ),
                  ),
                  if (connection != null)
                    const PopupMenuItem(
                      value: _FlockMenuAction.editServer,
                      child: _MenuRow(
                        icon: Icons.settings_outlined,
                        label: 'Edit this server',
                      ),
                    ),
                ],
              ),
            ],
            bottom: TabBar(
              tabs: [
                Tab(
                  text:
                      'Agents${_countSuffix(snapshot, (s) => s.agents.length)}',
                ),
                Tab(
                  text:
                      'Projects${_countSuffix(snapshot, (s) => s.workspaces.length)}',
                ),
              ],
            ),
          ),
          body: Column(
            children: [
              const EnablePushBanner(),
              _QuickActions(snapshot: snapshot),
              Expanded(
                child: snapshot.when(
                  skipLoadingOnRefresh: true,
                  skipLoadingOnReload: true,
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (err, _) => _ErrorState(error: err),
                  data: (snap) => TabBarView(
                    children: [
                      _Refreshable(
                        ref: ref,
                        child: _AgentsTab(snap: snap, server: summary),
                      ),
                      _Refreshable(
                        ref: ref,
                        child: _ProjectsTab(snap: snap),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _countSuffix(AsyncValue<Snapshot> snap, int Function(Snapshot) count) {
    final s = snap.asData?.value;
    return s == null ? '' : '  ${count(s)}';
  }
}

/// The frequent actions, as a single scrollable line of chips above the tabs.
///
/// They were all in the ⋮ overflow and the project screen's + menu, which is
/// the same complaint the whole rework is about: the useful thing is two taps
/// and a hunt away. Nothing here is new — every chip is an action this screen
/// or its project pages already offered.
///
/// **A chip that cannot act is not shown**, which is the rule the suggestions
/// bar already follows. "Start an agent" and "New terminal" need a project to
/// put them in, so they appear only once Herdr has one focused; with nothing
/// open the row is just "Open a project", which is the only thing there is to
/// do. It renders the shared [AppActionChip] rather than a second chip style.
class _QuickActions extends ConsumerWidget {
  const _QuickActions({required this.snapshot});

  final AsyncValue<Snapshot> snapshot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snap = snapshot.asData?.value;
    // The project actions need a target. Herdr focuses one workspace; that is
    // the one "here" means on a screen that is not scoped to a project.
    WorkspaceInfo? focused;
    for (final w in snap?.workspaces ?? const <WorkspaceInfo>[]) {
      if (w.focused) {
        focused = w;
        break;
      }
    }
    focused ??= (snap?.workspaces.length == 1)
        ? snap!.workspaces.first
        : null;

    final panes = focused == null
        ? const <Pane>[]
        : (snap?.panes.where((p) => p.workspaceId == focused!.workspaceId)
                  .toList() ??
              const <Pane>[]);
    final cwd = focused == null ? '' : spaceCwdOf(focused, panes);
    final project = focused == null
        ? ''
        : projectOf(focused, cwd).project;

    final chips = <Widget>[
      if (focused != null)
        AppActionChip(
          icon: Icons.rocket_launch_outlined,
          label: 'Start agent',
          // Named on purpose. This screen covers every project on the server,
          // so a bare "Start agent" would silently pick one of eleven. The chip
          // acts on the project Herdr has focused, and says which.
          detail: 'in $project',
          onTap: () => showStartAgentSheet(
            context,
            ref,
            target: StartAgentTarget(
              placement: StartAgentPlacement.newTab,
              id: focused!.workspaceId,
              where: 'A new tab in $project',
              defaultCwd: cwd,
            ),
          ),
        ),
      if (focused != null)
        AppActionChip(
          icon: Icons.terminal,
          label: 'New terminal',
          onTap: () => newTerminal(context, ref, focused!.workspaceId),
        ),
      // Needs a checkout to branch from, so it is absent for a project that is
      // not a git repo.
      if (focused != null && cwd.isNotEmpty)
        AppActionChip(
          icon: Icons.call_split,
          label: 'Start new work',
          onTap: () => showNewWorktreeSheet(
            context,
            ref,
            cwd: cwd,
            repoLabel: project,
          ),
        ),
      AppActionChip(
        icon: Icons.create_new_folder_outlined,
        label: 'Open a project',
        onTap: () => showOpenSpaceSheet(context),
      ),
      AppActionChip(
        icon: Icons.history,
        label: 'Activity',
        onTap: () => context.push('/timeline'),
      ),
    ];

    return SizedBox(
      // One line, never two: this round is spent compacting rows, and a chip
      // row that wraps gives the saving straight back.
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
        itemCount: chips.length,
        separatorBuilder: (_, _) => const SizedBox(width: Space.sm),
        itemBuilder: (_, i) => Center(child: chips[i]),
      ),
    );
  }
}

/// The choices in the Flock header's overflow menu.
enum _FlockMenuAction { openSpace, overview, timeline, editServer }

/// One row in the overflow menu: icon + label, laid out tighter than the
/// default [ListTile] so a two-item menu doesn't feel oversized.
class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(width: 12),
        Text(label),
      ],
    );
  }
}

class _Refreshable extends StatelessWidget {
  const _Refreshable({required this.ref, required this.child});
  final WidgetRef ref;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () => ref.read(snapshotControllerProvider.notifier).refresh(),
      child: child,
    );
  }
}

/// This server's agents, under the same state headings home uses.
///
/// It used to be a flat list with its own tile, so the same agent looked like a
/// different thing depending on whether you got here from home or from the
/// server. It now calls [buildAgentSections] — the identical grouping, the
/// identical rows, the identical idle compaction — with the server name left
/// off, since every row here is on the server named in the header.
///
/// Ordering is unchanged: the groups are in attention order and each group is
/// sorted by `Agent.byAttentionThenRecency`, which is the bridge's
/// `attention_rank` first and `recency_rank`/`last_activity_ts` within it.
class _AgentsTab extends ConsumerWidget {
  const _AgentsTab({required this.snap, required this.server});

  final Snapshot snap;

  /// The server every agent here belongs to. Carried so the shared row and the
  /// shared grouping get the same shape they get on home.
  final ServerSummary server;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (snap.agents.isEmpty) {
      return _EmptyState(projectsOpen: snap.workspaces.isNotEmpty);
    }
    final groups = groupAgents([
      for (final a in snap.agents) ServerAgentHit(server, a),
    ]);
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: Space.xl),
      children: buildAgentSections(
        context,
        ref,
        groups: groups,
        // Implied by the screen — this is one server's flock.
        showServer: false,
        showActivity: true,
        onApprove: (hit) => approveAgent(context, ref, hit.agent),
        onOpen: (hit) => context.push(
          '/transcript/${Uri.encodeComponent(hit.agent.paneId)}',
        ),
      ),
    );
  }
}

/// The server's projects — one row per Herdr workspace, named for the repo it
/// is checked out at and the branch it is on. A project's main checkout sorts
/// above its worktrees, which reads as the worktrees belonging under it.
/// Herdr's raw `w5`/`w8` workspace ids never appear.
class _ProjectsTab extends StatelessWidget {
  const _ProjectsTab({required this.snap});
  final Snapshot snap;

  @override
  Widget build(BuildContext context) {
    if (snap.workspaces.isEmpty) return const _EmptyState(projectsOpen: false);
    // Representative cwd per workspace (from its first pane) → git context, so
    // worktrees can be gathered under the repo they belong to.
    final cwdByWs = <String, String>{};
    for (final p in snap.panes) {
      cwdByWs.putIfAbsent(p.workspaceId, () => p.cwd);
    }
    ({String project, String? worktree}) git(WorkspaceInfo w) =>
        gitContextForCwd(cwdByWs[w.workspaceId] ?? '');

    // How many agents and how many terminals each project holds — the two
    // things it is actually made of, in place of the pane/tab counts, which
    // named Herdr's containers rather than their contents.
    final agentPanes = snap.agentPaneIds;
    final agents = <String, int>{};
    final terminals = <String, int>{};
    for (final p in snap.panes) {
      final bucket = agentPanes.contains(p.paneId) ? agents : terminals;
      bucket.update(p.workspaceId, (n) => n + 1, ifAbsent: () => 1);
    }

    // Grouped by repo, not listed flat. A repo and its worktrees were siblings
    // separated by a 12dp indent, which read as a flat list with odd spacing
    // rather than as "this project, and three branches of it". Now the group is
    // the unit: one panel, the checkout as its header, the branches on a rail
    // beneath it.
    final groups = <String, List<WorkspaceInfo>>{};
    for (final w in snap.workspaces) {
      groups.putIfAbsent(git(w).project, () => []).add(w);
    }
    final repos = groups.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    for (final list in groups.values) {
      list.sort((a, b) {
        // The main checkout heads its own group; worktrees follow in order.
        final wa = git(a).worktree == null ? 0 : 1;
        final wb = git(b).worktree == null ? 0 : 1;
        if (wa != wb) return wa - wb;
        return a.number.compareTo(b.number);
      });
    }

    // One panel for the whole list, not one per project. Ten outlined boxes
    // stacked (plus an eleventh nested round the group) is the border-density
    // problem again: the edge is right, there were too many of them. A repo's
    // group is now a *region* inside the single panel, marked by the rail down
    // its children rather than by a box of its own.
    final rows = <Widget>[];
    // Only the boundary between one project and the next gets a line. Inside a
    // group the rail does the work — a full-bleed separator cutting across it
    // was two systems claiming the same space, which is what read as odd.
    final boundaries = <int>{};
    for (final repo in repos) {
      final members = groups[repo]!;
      if (rows.isNotEmpty) boundaries.add(rows.length);
      final name = repo.isEmpty ? 'Untitled' : repo;
      final hasCheckout = members.any((w) => git(w).worktree == null);
      if (!hasCheckout) rows.add(_RepoHeader(repo: name));
      for (var i = 0; i < members.length; i++) {
        final w = members[i];
        rows.add(
          _ProjectTile(
            repo: name,
            space: w,
            branch: git(w).worktree,
            agents: agents[w.workspaceId] ?? 0,
            terminals: terminals[w.workspaceId] ?? 0,
            child: git(w).worktree != null,
            last: i == members.length - 1,
          ),
        );
      }
    }

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: Space.md),
      children: [
        PanelList(rows: rows, dividerBefore: boundaries.contains),
      ],
    );
  }
}

/// The repo's name when its own checkout is not open — a label, not a row you
/// can tap, because there is nothing behind it to open.
class _RepoHeader extends StatelessWidget {
  const _RepoHeader({required this.repo});

  final String repo;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(11, 9, 11, 7),
      child: Row(
        children: [
          Icon(
            Icons.folder_outlined,
            size: 15,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: Space.md),
          Flexible(
            child: Text(
              repo,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 13.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One checkout — the repo itself, or one of its worktrees.
///
/// A child is **indented** and the rail runs down the gutter that indent
/// creates, with a short elbow into the branch glyph. Before, the child's
/// content started at nearly the parent's own x and only the glyph hinted at
/// subordination; the rail also overlapped the text rather than living beside
/// it. Now the offset and the drawn line say the same thing, and the rail stops
/// at the last child rather than dangling past it.
class _ProjectTile extends StatelessWidget {
  const _ProjectTile({
    required this.repo,
    required this.space,
    required this.branch,
    required this.agents,
    required this.terminals,
    required this.child,
    required this.last,
  });

  final String repo;
  final WorkspaceInfo space;

  /// The branch this checkout is on, or null for the repo's own checkout.
  final String? branch;
  final int agents;
  final int terminals;

  /// Drawn as a worktree hanging off the repo above it.
  final bool child;

  /// The last row of its group — the rail stops halfway rather than running on
  /// into the next project.
  final bool last;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final blocked = space.agentStatus == AgentStatus.blocked;

    return InkWell(
      onTap: () =>
          context.push('/overview/${Uri.encodeComponent(space.workspaceId)}'),
      child: Container(
        // The repo's own checkout is the group's head, so it carries the raised
        // fill; its branches sit on the resting one. Fill, weight, indent and
        // rail all say the same thing at once — any one alone was not carrying
        // it, which is why two earlier rounds of "indent it more" did not read.
        color: child ? null : scheme.panelFillRaised,
        padding: EdgeInsets.fromLTRB(child ? 0 : 11, 9, 8, 9),
        child: Row(
          children: [
            if (child)
              // The gutter: the rail lives here, beside the content rather than
              // under it.
              SizedBox(
                width: _railGutter,
                height: 22,
                child: CustomPaint(
                  painter: _RailPainter(
                    color: scheme.hairlineStrong,
                    last: last,
                  ),
                ),
              ),
            Icon(
              child ? Icons.call_split : Icons.folder_outlined,
              size: child ? 13 : 15,
              color: child ? scheme.primary : scheme.onSurfaceVariant,
            ),
            SizedBox(width: child ? 6 : Space.md),
            // The identifier takes every pixel the counts do not need, and is
            // the last thing to truncate — it is what tells one row from
            // another.
            Expanded(
              child: Text(
                child ? branch! : repo,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: child
                    ? TextStyle(
                        fontSize: 12.5,
                        color: scheme.primary,
                        fontWeight: FontWeight.w500,
                      ).mono
                    : const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13.5,
                      ),
              ),
            ),
            // The focused project on the host — the "you are here" marker.
            if (space.focused) ...[
              const SizedBox(width: Space.md),
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: scheme.primary,
                ),
              ),
            ],
            if (blocked) ...[
              const SizedBox(width: Space.md),
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: scheme.error,
                ),
              ),
            ],
            const SizedBox(width: Space.md),
            // Fixed width, right-aligned: the column is a straight edge rather
            // than a function of how much happens to be open in each project.
            SizedBox(
              width: _countColumn,
              child: _Contents(agents: agents, terminals: terminals),
            ),
          ],
        ),
      ),
    );
  }
}

/// How much a worktree row is indented, and therefore how much room the rail
/// has to live in without touching the text.
const double _railGutter = 30;

/// The rail down a group's children, and the elbow into each one.
class _RailPainter extends CustomPainter {
  const _RailPainter({required this.color, required this.last});

  final Color color;

  /// The last child: the vertical stops at the elbow instead of carrying on
  /// into whatever follows the group.
  final bool last;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    const x = 18.0;
    final mid = size.height / 2;
    // Up past the top of this row, so the line joins the row above with no gap
    // — there are no separators inside a group for it to collide with.
    canvas.drawLine(Offset(x, -14), Offset(x, last ? mid : size.height + 14), paint);
    // ...and a short elbow out to the branch glyph.
    canvas.drawLine(Offset(x, mid), Offset(size.width, mid), paint);
  }

  @override
  bool shouldRepaint(_RailPainter old) => old.color != color || old.last != last;
}

/// What a project contains, as glyph + number rather than words.
///
/// It was spelled out — "1 agent · 7 terminals" — which cost twenty characters
/// on every row and repeated the same two nouns eleven times down the page,
/// while the row's actual *identifier* was being truncated to `gothalo
/// permissi…` to make room. The branch is the only thing telling one worktree
/// row from another, so the words go and the space goes to the name.
///
/// The terminal glyph is the one that marks a non-agent pane everywhere else,
/// so a terminal looks like a terminal on every screen. The agent glyph is
/// **not** the chat bubble it started as: a bubble reads as "messages", and
/// chat is already a distinct affordance in this app — the shortcut into an
/// agent's transcript. The per-kind [AgentAvatar] would be the most honest mark
/// but cannot stand for a count that mixes kinds, so this is a neutral agent
/// glyph instead. The numbers are set in JetBrains Mono, which is monospaced,
/// so 1 and 11 occupy the same column instead of jittering.
///
/// A zero is omitted rather than shown: a project with only terminals shows
/// only the terminal pair.
class _Contents extends StatelessWidget {
  const _Contents({required this.agents, required this.terminals});

  final int agents;
  final int terminals;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (agents == 0 && terminals == 0) {
      return Text(
        'empty',
        textAlign: TextAlign.right,
        style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant).mono,
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (agents > 0)
          _CountPair(
            icon: Icons.smart_toy_outlined,
            count: agents,
            semantics: '$agents agent${agents == 1 ? '' : 's'}',
          ),
        if (agents > 0 && terminals > 0) const SizedBox(width: Space.md),
        if (terminals > 0)
          _CountPair(
            icon: Icons.terminal,
            count: terminals,
            semantics: '$terminals terminal${terminals == 1 ? '' : 's'}',
          ),
      ],
    );
  }
}

/// One glyph and its number. [semantics] carries the words the glyph replaced,
/// so a screen reader still hears "4 agents".
class _CountPair extends StatelessWidget {
  const _CountPair({
    required this.icon,
    required this.count,
    required this.semantics,
  });

  final IconData icon;
  final int count;
  final String semantics;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      // Its own node, not merged into the row's: a screen reader should hear
      // "4 agents" as a fact about the project, not have it run together with
      // the repo name into one sentence.
      container: true,
      label: semantics,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: scheme.onSurfaceVariant),
          const SizedBox(width: 3),
          Text(
            '$count',
            style: TextStyle(
              fontSize: 10.5,
              color: scheme.onSurfaceVariant,
            ).mono,
          ),
        ],
      ),
    );
  }
}

/// The width every project row reserves for its counts, so the column is a
/// straight edge rather than a function of how much is open in each project.
const double _countColumn = 62;

/// The nothing-here state, in its two meaningfully different flavours.
///
/// With a project open, "no agents" is a normal lull — the operator starts one
/// and pulls to refresh. With **nothing** open the phone previously had nothing
/// to offer at all: no project means no terminal to split and no directory to
/// inherit, so the only route back in was walking to the desktop. That is the
/// case that gets the call to action.
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.projectsOpen});

  /// Whether the server has any project open at all. False is the empty-session
  /// case the "Open a project" flow exists for.
  final bool projectsOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(height: MediaQuery.of(context).size.height * 0.22),
        Icon(
          projectsOpen ? Icons.inbox_outlined : Icons.folder_off_outlined,
          size: 56,
          color: scheme.onSurfaceVariant,
        ),
        const SizedBox(height: 12),
        Center(
          child: Text(
            projectsOpen ? 'No agents right now' : 'Nothing open on this server',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        const SizedBox(height: 4),
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              projectsOpen
                  ? 'Start an agent in Herdr, then pull to refresh.'
                  : 'Nothing is open on this machine yet. Pick a project on '
                      'the host to open it — you can start an agent in it from '
                      'here afterwards.',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ),
        if (!projectsOpen) ...[
          const SizedBox(height: 20),
          Center(
            child: FilledButton.icon(
              onPressed: () => showOpenSpaceSheet(context),
              icon: const Icon(Icons.create_new_folder_outlined),
              label: const Text('Open a project'),
            ),
          ),
        ],
      ],
    );
  }
}

class _ErrorState extends ConsumerWidget {
  const _ErrorState({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final bridgeErr = error is BridgeException
        ? error as BridgeException
        : null;
    final isDown = bridgeErr?.isBridgeDown ?? false;
    final isAuth = bridgeErr?.isAuth ?? false;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(24),
      children: [
        SizedBox(height: MediaQuery.of(context).size.height * 0.18),
        Icon(
          isDown ? Icons.cloud_off_outlined : Icons.error_outline,
          size: 56,
          color: scheme.error,
        ),
        const SizedBox(height: 16),
        Center(
          child: Text(
            isDown
                ? 'Bridge unreachable'
                : isAuth
                ? 'Not authorized'
                : 'Couldn\'t load the flock',
            style: Theme.of(context).textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: Text(
            bridgeErr?.message ?? error.toString(),
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 24),
        Center(
          child: Wrap(
            spacing: 12,
            children: [
              FilledButton.icon(
                onPressed: () =>
                    ref.read(snapshotControllerProvider.notifier).refresh(),
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
              OutlinedButton.icon(
                onPressed: () => context.go('/'),
                icon: const Icon(Icons.dns_outlined),
                label: const Text('Servers'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
