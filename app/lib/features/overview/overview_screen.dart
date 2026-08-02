import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_background.dart';
import '../../core/theme.dart';
import '../../data/bridge/bridge_client.dart';
import '../../data/bridge/bridge_providers.dart';
import '../../data/bridge/models/snapshot.dart';
import '../approvals/approve_action.dart';
import '../inbox/inbox_providers.dart';
import '../inbox/widgets/agent_avatar.dart';
import '../inbox/widgets/status_badge.dart';

/// The Overview — the active server's multiplexer laid out like the desktop:
/// **workspace → tab → panes**, showing *every* pane (shells, dev servers, and
/// coding agents alike), with the focused pane outlined.
///
/// When [workspaceId] is set, the view is scoped to that one space; otherwise
/// it shows every space.
class OverviewScreen extends ConsumerWidget {
  const OverviewScreen({super.key, this.workspaceId});

  final String? workspaceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(snapshotControllerProvider);

    // Title = project; for a worktree space, show the branch beneath it.
    var title = workspaceId == null ? 'Overview' : 'Space';
    String? branch;
    if (workspaceId != null) {
      final snap = snapshot.asData?.value;
      final ws = snap?.workspaces.where((w) => w.workspaceId == workspaceId);
      final panes =
          snap?.panes.where((p) => p.workspaceId == workspaceId).toList() ??
              const [];
      final git = gitContextForCwd(panes.isEmpty ? '' : panes.first.cwd);
      branch = git.worktree;
      title = git.project.isNotEmpty
          ? git.project
          : (ws != null && ws.isNotEmpty && ws.first.label.isNotEmpty
              ? ws.first.label
              : 'Space');
    }

    return AppBackground(
      asset: Backgrounds.flock,
      child: Scaffold(
        appBar: AppBar(
          title: branch == null
              ? Text(title)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.call_split,
                            size: 13,
                            color: Theme.of(context).colorScheme.primary),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            branch,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.primary,
                              fontFamily: AppTheme.monoFamily,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
          actions: [
            // A space owns a workspace, so we can open a fresh terminal in it.
            if (workspaceId != null)
              IconButton(
                tooltip: 'New terminal',
                onPressed: () => _newTerminal(context, ref, workspaceId!),
                icon: const Icon(Icons.add),
              ),
            IconButton(
              tooltip: 'Refresh',
              onPressed: () =>
                  ref.read(snapshotControllerProvider.notifier).refresh(),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: snapshot.when(
          skipLoadingOnRefresh: true,
          skipLoadingOnReload: true,
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (err, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                err is BridgeException ? err.message : err.toString(),
                textAlign: TextAlign.center,
              ),
            ),
          ),
          data: (snap) {
            if (snap.panes.isEmpty) {
              return const Center(child: Text('No panes right now'));
            }
            // Per-space: real tabs across the top, panes inside the selected
            // tab. Global: the full workspace → tab → pane tree.
            if (workspaceId != null) {
              return _SpaceTabbedView(snap: snap, workspaceId: workspaceId!);
            }
            return RefreshIndicator(
              onRefresh: () =>
                  ref.read(snapshotControllerProvider.notifier).refresh(),
              child: _MultiplexerLayout(snap: snap, only: workspaceId),
            );
          },
        ),
      ),
    );
  }
}

/// A single space as real tabs (a `TabBar`) with that tab's panes inside —
/// mirroring the desktop multiplexer.
class _SpaceTabbedView extends ConsumerWidget {
  const _SpaceTabbedView({required this.snap, required this.workspaceId});
  final Snapshot snap;
  final String workspaceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tabs = snap.tabs.where((t) => t.workspaceId == workspaceId).toList()
      ..sort((a, b) => a.number.compareTo(b.number));
    final panesByTab = <String, List<Pane>>{};
    for (final p in snap.panes.where((p) => p.workspaceId == workspaceId)) {
      panesByTab.putIfAbsent(p.tabId, () => []).add(p);
    }
    final agentByPane = {for (final a in snap.agents) a.paneId: a};

    if (tabs.isEmpty) {
      return const Center(child: Text('No tabs in this space'));
    }

    return DefaultTabController(
      length: tabs.length,
      child: Column(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                for (final t in tabs)
                  Tab(
                    height: 44,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (t.focused)
                          const Padding(
                            padding: EdgeInsets.only(right: 6),
                            child: Icon(Icons.my_location, size: 14),
                          ),
                        Text(t.label.isEmpty ? _tabLabel(t.tabId) : t.label),
                        const SizedBox(width: 6),
                        Text(
                          '${t.paneCount}',
                          style: TextStyle(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [
                for (final t in tabs)
                  _PaneGrid(
                    panes: panesByTab[t.tabId] ?? const [],
                    agentByPane: agentByPane,
                    focusedPaneId: snap.focusedPaneId,
                    onRefresh: () =>
                        ref.read(snapshotControllerProvider.notifier).refresh(),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The panes of one tab, laid out as cards (splits) in a scrollable grid.
class _PaneGrid extends StatelessWidget {
  const _PaneGrid({
    required this.panes,
    required this.agentByPane,
    required this.focusedPaneId,
    required this.onRefresh,
  });

  final List<Pane> panes;
  final Map<String, Agent> agentByPane;
  final String focusedPaneId;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    if (panes.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 80),
          Center(child: Text('No panes in this tab')),
        ],
      );
    }
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12),
        itemCount: panes.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, i) => _PaneCard(
          pane: panes[i],
          agent: agentByPane[panes[i].paneId],
          focused: panes[i].paneId == focusedPaneId || panes[i].focused,
        ),
      ),
    );
  }
}

/// Renders workspaces → tabs → panes from the full snapshot.
class _MultiplexerLayout extends StatelessWidget {
  const _MultiplexerLayout({required this.snap, this.only});
  final Snapshot snap;
  final String? only;

  @override
  Widget build(BuildContext context) {
    // Ordered workspaces (by number), optionally scoped to one.
    final workspaces = [...snap.workspaces]
      ..sort((a, b) => a.number.compareTo(b.number));
    final scoped = only == null
        ? workspaces
        : workspaces.where((w) => w.workspaceId == only).toList();

    // Index tabs & panes for quick lookup.
    final tabsByWs = <String, List<TabInfo>>{};
    for (final t in snap.tabs) {
      tabsByWs.putIfAbsent(t.workspaceId, () => []).add(t);
    }
    final panesByTab = <String, List<Pane>>{};
    for (final p in snap.panes) {
      panesByTab.putIfAbsent(p.tabId, () => []).add(p);
    }
    final agentByPane = {for (final a in snap.agents) a.paneId: a};

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        for (final ws in scoped)
          _WorkspaceBlock(
            workspace: ws,
            tabs: (tabsByWs[ws.workspaceId] ?? [])
              ..sort((a, b) => a.number.compareTo(b.number)),
            panesByTab: panesByTab,
            agentByPane: agentByPane,
            focusedPaneId: snap.focusedPaneId,
          ),
      ],
    );
  }
}

class _WorkspaceBlock extends StatelessWidget {
  const _WorkspaceBlock({
    required this.workspace,
    required this.tabs,
    required this.panesByTab,
    required this.agentByPane,
    required this.focusedPaneId,
  });

  final WorkspaceInfo workspace;
  final List<TabInfo> tabs;
  final Map<String, List<Pane>> panesByTab;
  final Map<String, Agent> agentByPane;
  final String focusedPaneId;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = workspace.label.isNotEmpty
        ? workspace.label
        : (workspace.workspaceId.isEmpty ? 'Ungrouped' : workspace.workspaceId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
          child: Row(
            children: [
              Icon(Icons.workspaces_outline, size: 16, color: scheme.primary),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${workspace.paneCount} pane${workspace.paneCount == 1 ? '' : 's'}',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
              ),
              if (workspace.focused) ...[
                const SizedBox(width: 8),
                Icon(Icons.my_location, size: 13, color: scheme.primary),
              ],
            ],
          ),
        ),
        for (final tab in tabs)
          _TabRow(
            tab: tab,
            panes: panesByTab[tab.tabId] ?? const [],
            agentByPane: agentByPane,
            focusedPaneId: focusedPaneId,
          ),
      ],
    );
  }
}

class _TabRow extends StatelessWidget {
  const _TabRow({
    required this.tab,
    required this.panes,
    required this.agentByPane,
    required this.focusedPaneId,
  });

  final TabInfo tab;
  final List<Pane> panes;
  final Map<String, Agent> agentByPane;
  final String focusedPaneId;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = tab.label.isNotEmpty ? tab.label : _tabLabel(tab.tabId);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 8, right: 10),
            child: SizedBox(
              width: 34,
              child: Column(
                children: [
                  Icon(Icons.tab, size: 14, color: scheme.onSurfaceVariant),
                  const SizedBox(height: 2),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontFamily: AppTheme.monoFamily,
                      fontSize: 10.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: Column(
              children: [
                for (final p in panes)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _PaneCard(
                      pane: p,
                      agent: agentByPane[p.paneId],
                      focused: p.paneId == focusedPaneId || p.focused,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PaneCard extends ConsumerWidget {
  const _PaneCard({required this.pane, required this.focused, this.agent});
  final Pane pane;
  final Agent? agent;
  final bool focused;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final blocked = pane.agentStatus == AgentStatus.blocked;
    final isAgent = agent != null;
    final cmd = isAgent ? null : pane.command;
    // Agents show their task. A non-agent pane shows the running command if one
    // is in the foreground (`./gothalo serve`); an idle shell shows *where* it
    // is, which is what tells otherwise-identical shells apart.
    final headline = isAgent
        ? (pane.title.isNotEmpty ? pane.title : agent!.displayTitle)
        : (cmd ??
            (pane.locationLabel.isNotEmpty
                ? pane.locationLabel
                : (pane.title.isNotEmpty ? pane.title : pane.paneId)));
    // Leading glyph for non-agent panes: a running command gets a "play"
    // marker; an idle shell gets a folder (its location *is* the headline).
    final headlineIcon = isAgent
        ? null
        : (cmd != null ? Icons.play_arrow_rounded : Icons.folder_outlined);
    return Material(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () =>
              context.push('/terminal/${Uri.encodeComponent(pane.paneId)}'),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: focused ? scheme.primary : Colors.transparent,
                width: 2,
              ),
            ),
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // Agent panes get the agent avatar; other panes a terminal.
                    if (agent != null)
                      AgentAvatar(agent: agent!.agent, radius: 13)
                    else
                      CircleAvatar(
                        radius: 13,
                        backgroundColor: scheme.surfaceContainerHighest,
                        child: Icon(Icons.terminal,
                            size: 15, color: scheme.onSurfaceVariant),
                      ),
                    const SizedBox(width: 8),
                    // Agents: their status chip. Non-agents: a "running" or
                    // "shell" chip so the pane's kind reads at a glance.
                    if (isAgent)
                      StatusBadge(pane.agentStatus)
                    else
                      _KindChip(running: cmd != null),
                    const Spacer(),
                    if (focused)
                      Icon(Icons.my_location, size: 15, color: scheme.primary),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (headlineIcon != null) ...[
                      Icon(headlineIcon,
                          size: 14, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 5),
                    ],
                    Expanded(
                      child: Text(
                        headline,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: isAgent ? 14 : 13,
                          height: 1.25,
                          fontFamily: isAgent ? null : AppTheme.monoFamily,
                        ),
                      ),
                    ),
                  ],
                ),
                // A running command still shows *where* it runs, on a muted line
                // beneath the command itself.
                if (cmd != null && pane.locationLabel.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(Icons.folder_outlined,
                          size: 12, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          pane.locationLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontSize: 11.5,
                            fontFamily: AppTheme.monoFamily,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                if (blocked) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        minimumSize: const Size(0, 30),
                      ),
                      onPressed: agent == null
                          ? null
                          : () => approveAgent(context, ref, agent!),
                      icon: const Icon(Icons.check_circle_outline, size: 15),
                      label: const Text('Approve'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
  }
}

/// Create a fresh terminal (a new tab) in [workspaceId] and open it. Refreshes
/// the snapshot so the new pane shows up in the space too.
Future<void> _newTerminal(
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
    // No manual refresh: the live event stream surfaces the new pane on its own.
    if (!context.mounted) return;
    router.push('/terminal/${Uri.encodeComponent(pane.paneId)}');
  } on BridgeException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
  }
}

/// A small pill marking a non-agent pane as actively **running** a command
/// (accent-tinted with a dot) or an idle **shell**.
class _KindChip extends StatelessWidget {
  const _KindChip({required this.running});
  final bool running;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = running ? scheme.primary : scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: running
            ? scheme.primary.withValues(alpha: 0.14)
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (running) ...[
            Icon(Icons.circle, size: 7, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            running ? 'running' : 'shell',
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// `w5:t1` → `t1`.
String _tabLabel(String tabId) {
  final colon = tabId.indexOf(':');
  final t = colon >= 0 ? tabId.substring(colon + 1) : tabId;
  return t.isEmpty ? '—' : t;
}
