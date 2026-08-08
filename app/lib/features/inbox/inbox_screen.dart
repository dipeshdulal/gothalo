import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_background.dart';
import '../../core/connection/connection_providers.dart';
import '../../core/theme.dart';
import '../../core/widgets/live_activity_line.dart';
import '../../data/bridge/bridge_client.dart';
import '../../data/bridge/models/snapshot.dart';
import '../approvals/approve_action.dart';
import '../jump/jump_sheet.dart';
import '../push/enable_push_banner.dart';
import '../spaces/open_space_sheet.dart';
import 'inbox_providers.dart';
import 'widgets/agent_avatar.dart';
import 'widgets/status_badge.dart';

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
                      : context.push('/servers/${connection.id}/edit'),
                },
                itemBuilder: (context) => [
                  // Also reachable from the empty state, which is where it
                  // matters most; here so it does not disappear the moment the
                  // server has one space open.
                  const PopupMenuItem(
                    value: _FlockMenuAction.openSpace,
                    child: _MenuRow(
                      icon: Icons.create_new_folder_outlined,
                      label: 'Open a project',
                    ),
                  ),
                  const PopupMenuItem(
                    value: _FlockMenuAction.overview,
                    child: _MenuRow(
                      icon: Icons.dashboard_outlined,
                      label: 'All projects',
                    ),
                  ),
                  const PopupMenuItem(
                    value: _FlockMenuAction.timeline,
                    child: _MenuRow(icon: Icons.history, label: 'Activity'),
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
                        child: _AgentsTab(snap: snap),
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

/// Flat, attention-first list of every agent.
class _AgentsTab extends StatelessWidget {
  const _AgentsTab({required this.snap});
  final Snapshot snap;

  @override
  Widget build(BuildContext context) {
    if (snap.agents.isEmpty) {
      return _EmptyState(projectsOpen: snap.workspaces.isNotEmpty);
    }
    final agents = snap.agentsSorted;
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: agents.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
      itemBuilder: (context, i) => _AgentTile(agent: agents[i]),
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
    // worktrees sort right under their parent project.
    final cwdByWs = <String, String>{};
    for (final p in snap.panes) {
      cwdByWs.putIfAbsent(p.workspaceId, () => p.cwd);
    }
    ({String project, String? worktree}) git(WorkspaceInfo w) =>
        gitContextForCwd(cwdByWs[w.workspaceId] ?? '');

    final spaces = [...snap.workspaces]
      ..sort((a, b) {
        final ca = git(a), cb = git(b);
        final p = ca.project.toLowerCase().compareTo(cb.project.toLowerCase());
        if (p != 0) return p;
        final wa = ca.worktree == null ? 0 : 1;
        final wb = cb.worktree == null ? 0 : 1;
        if (wa != wb) return wa - wb; // main checkout before its worktrees
        return a.number.compareTo(b.number);
      });

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

    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: spaces.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
      itemBuilder: (context, i) => _ProjectTile(
        space: spaces[i],
        git: git(spaces[i]),
        agents: agents[spaces[i].workspaceId] ?? 0,
        terminals: terminals[spaces[i].workspaceId] ?? 0,
      ),
    );
  }
}

/// One project. A worktree checkout is marked with a branch icon and indented
/// under the repo it belongs to. Tapping opens it.
class _ProjectTile extends StatelessWidget {
  const _ProjectTile({
    required this.space,
    required this.git,
    required this.agents,
    required this.terminals,
  });
  final WorkspaceInfo space;
  final ({String project, String? worktree}) git;
  final int agents;
  final int terminals;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isWt = git.worktree != null;
    final label = isWt
        ? git.worktree!
        : (space.label.isNotEmpty
              ? space.label
              : (space.workspaceId.isEmpty ? 'Ungrouped' : space.workspaceId));
    final blocked = space.agentStatus == AgentStatus.blocked;
    // The old list was over-bold (w600); dropping to w500 is the real fix for
    // that. A worktree name additionally gets teal + mono (it's a branch ref);
    // a plain project name stays in the UI font — all-mono everywhere read as
    // too much.
    final nameColor = isWt ? scheme.primary : scheme.onSurface;
    return InkWell(
      onTap: () => context
          .push('/overview/${Uri.encodeComponent(space.workspaceId)}'),
      child: Padding(
        padding: EdgeInsets.only(
          left: isWt ? 28 : 16,
          right: 16,
          top: 10,
          bottom: 10,
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: space.focused
                    ? scheme.primary.withValues(alpha: 0.18)
                    : scheme.surfaceContainerHighest,
                shape: BoxShape.circle,
              ),
              child: Icon(
                isWt ? Icons.call_split : Icons.folder_outlined,
                size: 18,
                color: space.focused
                    ? scheme.primary
                    : (isWt ? scheme.primary : scheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            // Mono only for a worktree name — it's literally a
                            // branch, and the teal-mono pairing reads as "this
                            // is a git ref". A project name is just a directory
                            // label, so it stays in the UI font; all-mono
                            // everywhere felt off. Weight is the lighter fix
                            // for the "too bold" complaint, not the font.
                            fontFamily: isWt ? AppTheme.monoFamily : null,
                            fontWeight: FontWeight.w500,
                            fontSize: isWt ? 14.5 : 15,
                            color: nameColor,
                          ),
                        ),
                      ),
                      // The focused space on the host — the "you are here"
                      // marker, matching the overview's own focused indicator.
                      if (space.focused) ...[
                        const SizedBox(width: 8),
                        Icon(Icons.my_location, size: 13, color: scheme.primary),
                      ],
                      if (blocked) ...[
                        const SizedBox(width: 8),
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: scheme.error,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _contents(agents, terminals),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right, size: 20, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

class _AgentTile extends ConsumerWidget {
  const _AgentTile({required this.agent});

  final Agent agent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final hasBranch = agent.hasBranch;
    final dim = scheme.onSurfaceVariant;
    final showFolder = agent.gitContext.project.isNotEmpty;

    return InkWell(
      onTap: () =>
          context.push('/transcript/${Uri.encodeComponent(agent.paneId)}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AgentAvatar(agent: agent.agent),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // The task itself — the star of the row. Up to two lines so
                      // long Herdr titles stay readable instead of hard-truncating.
                      Text(
                        agent.displayTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                          height: 1.25,
                        ),
                      ),
                      // Project folder + branch/worktree (teal) each on their own
                      // full-width line so long names ellipsize instead of
                      // overflowing. Internal ids (pane, workspace) are not shown —
                      // the pane id is still used under the hood for navigation.
                      if (showFolder) ...[
                        const SizedBox(height: 6),
                        _GitLine(
                          icon: Icons.folder_outlined,
                          text: agent.gitContext.project,
                          color: dim,
                        ),
                      ],
                      if (hasBranch) ...[
                        SizedBox(height: showFolder ? 3 : 6),
                        _GitLine(
                          icon: Icons.call_split,
                          text: agent.branchName ?? '',
                          color: scheme.primary,
                          bold: true,
                        ),
                      ],
                      // Which Herdr session hosts this agent; the default session
                      // is implied and not shown.
                      if (!agent.isDefaultSession) ...[
                        SizedBox(height: (showFolder || hasBranch) ? 3 : 6),
                        _GitLine(
                          icon: Icons.layers_outlined,
                          text: agent.sessionName,
                          color: dim,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    const SizedBox(height: 2),
                    StatusBadge(agent.agentStatus),
                    // One-tap approve for a blocked agent (D7/D8). The bridge picks
                    // the confirm keystroke and no-ops a stale tap.
                    if (agent.agentStatus == AgentStatus.blocked) ...[
                      const SizedBox(height: 8),
                      FilledButton.tonal(
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          minimumSize: const Size(0, 32),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onPressed: () => approveAgent(context, ref, agent),
                        child: const Text('Approve'),
                      ),
                    ],
                  ],
                ),
              ],
            ),
            // "What's it doing right now" — only for a working agent; an
            // idle/blocked/done one has nothing that changes to poll for.
            // On its own row below the title/status Row (not squeezed beside
            // the status badge, which can be wide enough to truncate it to
            // nothing), but indented to line up under the title text rather
            // than running back under the avatar — the avatar column is the
            // row's visual gutter, so this reads as "part of this agent" only
            // when it aligns with the agent's text, not the artwork.
            // No extra top gap here — LiveActivityLine carries its own small
            // top padding, so a SizedBox on top of that just double-spaced it.
            // Shown for every status, not just working: a settled agent's last
            // message is the most useful thing a tile can carry, and the line
            // is now served from the agent's transcript rather than a costly
            // scrollback read. LiveActivityLine polls only while working.
            Padding(
              // avatar diameter (radius 20 * 2) + the 12px gap to the title.
              padding: const EdgeInsets.only(left: 52),
              child: LiveActivityLine(
                paneId: agent.paneId,
                status: agent.agentStatus,
              ),
            ),
          ],
        ),
      ),
    );
  }
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

/// A full-width monospace metadata line (leading icon + text), used for the
/// project folder and branch on an agent row. The text takes the remaining
/// width and ellipsizes, so a long branch name never overflows the row.
class _GitLine extends StatelessWidget {
  const _GitLine({
    required this.icon,
    required this.text,
    required this.color,
    this.bold = false,
  });

  final IconData icon;
  final String text;
  final Color color;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontFamily: AppTheme.monoFamily,
              fontSize: 12,
              fontWeight: bold ? FontWeight.w500 : FontWeight.w400,
            ),
          ),
        ),
      ],
    );
  }
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
