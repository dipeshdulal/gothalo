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
          detail: project,
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

    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: Space.md),
      itemCount: repos.length,
      itemBuilder: (context, i) {
        final repo = repos[i];
        final members = groups[repo]!;
        return _ProjectGroup(
          repo: repo.isEmpty ? 'Untitled' : repo,
          members: [
            for (final w in members)
              (
                space: w,
                branch: git(w).worktree,
                agents: agents[w.workspaceId] ?? 0,
                terminals: terminals[w.workspaceId] ?? 0,
              ),
          ],
        );
      },
    );
  }
}

/// One repo and everything checked out from it — the main checkout, then its
/// worktrees on a rail beneath it.
///
/// Two problems at once. The rows each carried their own border, so a dozen
/// projects read as a grid of boxes rather than a list (the edge is not too
/// strong — the agent rows need exactly that contrast — there were simply too
/// many of them). And a worktree was a sibling row with a small indent, so
/// `gothalo` and its `feat-x` branch looked like two unrelated entries.
///
/// One [PanelList] per repo fixes both: one border round the group, hairlines
/// inside it, and a vertical rail plus a branch glyph down the left of the
/// children so the relationship is drawn rather than inferred from pixel
/// offsets.
class _ProjectGroup extends StatelessWidget {
  const _ProjectGroup({required this.repo, required this.members});

  final String repo;
  final List<
    ({WorkspaceInfo space, String? branch, int agents, int terminals})
  >
  members;

  @override
  Widget build(BuildContext context) {
    // A group whose checkout is not itself open is all branches — it still gets
    // a header naming the repo, so the branches have something to hang off.
    final hasCheckout = members.any((m) => m.branch == null);
    return PanelList(
      rows: [
        if (!hasCheckout) _RepoHeader(repo: repo),
        for (final m in members)
          _ProjectTile(
            repo: repo,
            space: m.space,
            branch: m.branch,
            agents: m.agents,
            terminals: m.terminals,
            // Everything except the repo's own checkout is a child of it.
            child: m.branch != null,
          ),
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
/// A child row is drawn on a rail: a hairline running down the left of the
/// group with a short branch glyph off it, so "this belongs to the thing above"
/// is visible rather than implied. The branch name is the child's subject (the
/// repo is already the group's), set in accent mono because it is a git ref.
class _ProjectTile extends StatelessWidget {
  const _ProjectTile({
    required this.repo,
    required this.space,
    required this.branch,
    required this.agents,
    required this.terminals,
    required this.child,
  });

  final String repo;
  final WorkspaceInfo space;

  /// The branch this checkout is on, or null for the repo's own checkout.
  final String? branch;
  final int agents;
  final int terminals;

  /// Drawn as a worktree hanging off the repo above it.
  final bool child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final blocked = space.agentStatus == AgentStatus.blocked;

    return InkWell(
      onTap: () =>
          context.push('/overview/${Uri.encodeComponent(space.workspaceId)}'),
      child: Padding(
        padding: EdgeInsets.fromLTRB(child ? 0 : 11, 9, 11, 9),
        child: Row(
          children: [
            if (child) ...[
              // The rail: a vertical hairline the child sits against, and a
              // short elbow into it. Drawn, not indented — an offset alone was
              // what made a worktree read as an oddly-spaced sibling.
              SizedBox(
                width: 26,
                height: 20,
                child: CustomPaint(
                  painter: _RailPainter(color: scheme.hairlineStrong),
                ),
              ),
              Icon(Icons.call_split, size: 13, color: scheme.primary),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  branch!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: scheme.primary,
                    fontWeight: FontWeight.w500,
                  ).mono,
                ),
              ),
            ] else ...[
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
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13.5,
                  ),
                ),
              ),
            ],
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
            const Spacer(),
            const SizedBox(width: Space.md),
            Text(
              _contents(agents, terminals),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5,
                color: scheme.onSurfaceVariant,
              ).mono,
            ),
          ],
        ),
      ),
    );
  }
}

/// The vertical rail plus the elbow into a child row.
class _RailPainter extends CustomPainter {
  const _RailPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    const x = 16.0;
    // Down the left of the group, through the full height of the row...
    canvas.drawLine(const Offset(x, -12), Offset(x, size.height / 2), paint);
    // ...then a short elbow into the branch glyph.
    canvas.drawLine(
      Offset(x, size.height / 2),
      Offset(size.width, size.height / 2),
      paint,
    );
  }

  @override
  bool shouldRepaint(_RailPainter old) => old.color != color;
}

/// "2 agents · 1 terminal" — what a project actually contains, in place of the
/// pane and tab counts it used to show. A project with neither reads as "empty"
/// rather than as "0 agents · 0 terminals", which is three words to say nothing.
String _contents(int agents, int terminals) {
  final parts = <String>[
    if (agents > 0) '$agents agent${agents == 1 ? '' : 's'}',
    if (terminals > 0) '$terminals terminal${terminals == 1 ? '' : 's'}',
  ];
  return parts.isEmpty ? 'empty' : parts.join(' · ');
}

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
