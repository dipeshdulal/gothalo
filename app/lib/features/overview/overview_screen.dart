import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_background.dart';
import '../../core/naming.dart';
import '../../core/theme.dart';
import '../../core/tokens.dart';
import '../../core/widgets/app_mark.dart';
import '../../core/widgets/entrance.dart';
import '../../core/widgets/flat_app_bar.dart';
import '../../core/widgets/live_activity_line.dart';
import '../../core/widgets/panel_row.dart';
import '../../core/widgets/status_mark.dart';
import '../../data/bridge/bridge_client.dart';
import '../../data/bridge/models/snapshot.dart';
import '../agents/start_agent_sheet.dart';
import '../approvals/approve_action.dart';
import '../herdr_actions.dart';
import '../inbox/inbox_providers.dart';
import '../inbox/widgets/agent_avatar.dart';
import '../worktrees/new_worktree_sheet.dart';

/// **Projects** — the active server as a list of the things you are working on,
/// rather than as a picture of the multiplexer.
///
/// This screen used to render Herdr's own shape: workspace → tab → pane, with a
/// tab strip across the top of a single space. That is an accurate drawing of
/// the data model and the wrong subject. What is actually on the host is a
/// handful of **projects** (a repo, usually at a branch), each with some
/// **agents** working in it and some **terminals** open in it. Tabs are how
/// Herdr arranges panes on a screen you are not looking at; they say nothing
/// from a phone, so they are gone from the layout and survive only where they
/// carry a capability (see [_PaneCard]'s menu).
///
/// Every capability the tree had is still here: start / restart / stop an
/// agent, split and close, approve a blocked agent, open the chat, start new
/// work on a branch, and finish work (removing the checkout, optionally
/// deleting the branch).
///
/// When [workspaceId] is set the view is scoped to that one project; otherwise
/// it lists them all.
class OverviewScreen extends ConsumerWidget {
  const OverviewScreen({super.key, this.workspaceId});

  final String? workspaceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(snapshotControllerProvider);

    // A scoped project whose workspace disappears from the snapshot — its
    // worktree was removed here, from the desktop, or another device — leaves
    // this screen dead. React to that live and pop back, so we never sit on a
    // stale/empty screen. (workspaceId is constant for this widget, so the
    // conditional listen is stable across rebuilds.)
    if (workspaceId != null) {
      ref.listen(snapshotControllerProvider, (_, next) {
        final snap = next.asData?.value;
        if (snap == null) return;
        final gone =
            !snap.workspaces.any((w) => w.workspaceId == workspaceId) &&
            !snap.panes.any((p) => p.workspaceId == workspaceId);
        if (gone && context.mounted && context.canPop()) {
          context.pop();
        }
      });
    }

    // The scoped project's identity: repo on top, branch beneath it.
    var project = 'Project';
    String? branch;
    String projectCwd = '';
    if (workspaceId != null) {
      final snap = snapshot.asData?.value;
      final matches = snap?.workspaces.where(
        (w) => w.workspaceId == workspaceId,
      );
      final ws = matches == null || matches.isEmpty ? null : matches.first;
      final panes =
          snap?.panes.where((p) => p.workspaceId == workspaceId).toList() ??
          const <Pane>[];
      projectCwd = spaceCwdOf(ws, panes);
      final named = projectOf(ws, projectCwd);
      project = named.project;
      branch = named.branch;
    }

    return AppBackground(
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: FlatAppBar(
          title: workspaceId == null
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    AppMark(radius: 14),
                    SizedBox(width: 10),
                    Text('Projects'),
                  ],
                )
              : (branch == null
                    ? Text(project)
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(project),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.call_split,
                                size: 13,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  branch,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  // The branch is an identifier: mono, per the
                                  // rule.
                                  style: TextStyle(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    fontFamily: AppTheme.monoFamily,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      )),
          actions: [
            // A project owns a workspace, so we can open a fresh terminal in it.
            if (workspaceId != null)
              IconButton(
                tooltip: 'New terminal',
                onPressed: () => newTerminal(context, ref, workspaceId!),
                icon: const Icon(Icons.add),
              ),
            if (workspaceId != null)
              PopupMenuButton<String>(
                tooltip: 'Project actions',
                icon: const Icon(Icons.more_vert),
                onSelected: (v) {
                  switch (v) {
                    case 'agent':
                      showStartAgentSheet(
                        context,
                        ref,
                        target: StartAgentTarget(
                          placement: StartAgentPlacement.newTab,
                          id: workspaceId!,
                          where: 'A new tab in $project',
                          defaultCwd: projectCwd,
                        ),
                      );
                    case 'tab':
                      newTab(context, ref, workspaceId!);
                    case 'worktree':
                      showNewWorktreeSheet(
                        context,
                        ref,
                        cwd: projectCwd,
                        repoLabel: project,
                      );
                    case 'remove':
                      removeWorktree(
                        context,
                        ref,
                        workspaceId!,
                        branch ?? project,
                      );
                  }
                },
                itemBuilder: (ctx) => [
                  // First, because dispatching work is the reason to open a
                  // project from a phone.
                  const PopupMenuItem(
                    value: 'agent',
                    child: ListTile(
                      leading: Icon(Icons.rocket_launch_outlined),
                      title: Text('Start an agent'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'tab',
                    child: ListTile(
                      leading: Icon(Icons.tab_outlined),
                      title: Text('New tab'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  if (projectCwd.isNotEmpty)
                    const PopupMenuItem(
                      value: 'worktree',
                      child: ListTile(
                        leading: Icon(Icons.call_split),
                        title: Text('Start new work…'),
                        subtitle: Text('On a new branch'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  if (branch != null)
                    PopupMenuItem(
                      value: 'remove',
                      child: ListTile(
                        leading: Icon(
                          Icons.delete_outline,
                          color: Theme.of(ctx).colorScheme.error,
                        ),
                        title: const Text('Finish this work…'),
                        subtitle: const Text('Remove the checkout'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                ],
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
              return const Center(child: Text('Nothing open on this server'));
            }
            return RefreshIndicator(
              onRefresh: () =>
                  ref.read(snapshotControllerProvider.notifier).refresh(),
              child: workspaceId == null
                  ? _AllProjects(snap: snap)
                  : _OneProject(snap: snap, workspaceId: workspaceId!),
            );
          },
        ),
      ),
    );
  }
}

/// One project's contents, split into the two things a person recognises: the
/// **agents** working in it, and the **terminals** open in it.
///
/// The old layout was a `TabBar` with a `TabBarView` under it, so a project's
/// three agents could sit behind three tabs with exactly one visible at a time —
/// on a phone, where you came here to see what is running. Everything is now on
/// one scroll, agents first.
///
/// **Tabs did not go away**; they stopped being the structure. They are a real
/// feature and Herdr's word for them is a browser word, not multiplexer jargon,
/// so they are a *filter* over the list: [_TabFilter] below, shown only when a
/// project actually has more than one, and carrying rename and close on a
/// long-press. A project with one tab shows no strip at all — a row reading "1"
/// is a control that can do nothing.
class _OneProject extends ConsumerStatefulWidget {
  const _OneProject({required this.snap, required this.workspaceId});

  final Snapshot snap;
  final String workspaceId;

  @override
  ConsumerState<_OneProject> createState() => _OneProjectState();
}

class _OneProjectState extends ConsumerState<_OneProject> {
  /// The tab being shown alone, or null for "everything in this project".
  ///
  /// Null is the default and the resting state: the reason for flattening the
  /// tabs was that one-tab-at-a-time hid work. The filter is there for a
  /// project with enough in it that you want to narrow — and for reaching a
  /// tab's own actions.
  String? _onlyTab;

  @override
  Widget build(BuildContext context) {
    final snap = widget.snap;
    final all = snap.panes
        .where((p) => p.workspaceId == widget.workspaceId)
        .toList();
    if (all.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.only(top: FlatAppBar.padding(context)),
        children: const [
          SizedBox(height: 64),
          Center(child: Text('Nothing open in this project')),
        ],
      );
    }
    final tabs = snap.tabs
        .where((t) => t.workspaceId == widget.workspaceId)
        .toList()
      ..sort((a, b) => a.number.compareTo(b.number));
    // A filter pointing at a tab that has since been closed would silently show
    // nothing; fall back to everything.
    final active = tabs.any((t) => t.tabId == _onlyTab) ? _onlyTab : null;
    final panes = active == null
        ? all
        : all.where((p) => p.tabId == active).toList();

    final index = _PaneIndex.of(snap);
    final split = _splitPanes(panes, index);

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.only(
        // Exactly the bar's height and no more. The list starts immediately
        // under the header — the gap that used to sit here was the tab strip's
        // own generous chrome plus a `Column` that reserved room whether or not
        // there was a strip to put in it.
        top: FlatAppBar.padding(context),
        bottom: Space.xl,
      ),
      children: [
        if (tabs.length > 1)
          _TabFilter(
            tabs: tabs,
            active: active,
            counts: {
              for (final t in tabs)
                t.tabId: all.where((p) => p.tabId == t.tabId).length,
            },
            onSelect: (id) => setState(() => _onlyTab = id),
          ),
        ..._paneSection(
          label: 'Agents',
          panes: split.agents,
          index: index,
          snap: snap,
          startAt: 0,
        ),
        ..._paneSection(
          label: 'Terminals',
          panes: split.terminals,
          index: index,
          snap: snap,
          startAt: split.agents.length,
        ),
      ],
    );
  }
}

/// The tab strip, as a filter rather than as the page's structure.
///
/// `All` first and selected by default, then one chip per tab. Chips rather
/// than a `TabBar`: a TabBar reads as "these are the only things there are",
/// which is exactly the impression the flattening removed, and it cost ~44dp of
/// chrome plus its own padding whether or not a project had tabs worth showing.
///
/// A tab's own actions — rename, close — hang off a long-press on its chip,
/// the same gesture the old strip used, so nothing about tabs became
/// unreachable when they stopped being the layout.
class _TabFilter extends ConsumerWidget {
  const _TabFilter({
    required this.tabs,
    required this.active,
    required this.counts,
    required this.onSelect,
  });

  final List<TabInfo> tabs;
  final String? active;
  final Map<String, int> counts;
  final void Function(String? tabId) onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Space.gutter,
        Space.md,
        Space.gutter,
        Space.xs,
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _TabChip(
              label: 'All',
              count: counts.values.fold(0, (a, b) => a + b),
              selected: active == null,
              onTap: () => onSelect(null),
            ),
            for (final t in tabs) ...[
              const SizedBox(width: Space.sm),
              _TabChip(
                label: tabLabelFor(t),
                count: counts[t.tabId] ?? 0,
                selected: active == t.tabId,
                onTap: () => onSelect(t.tabId),
                onLongPress: () => _showTabMenu(context, ref, t),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A tab's name for the strip: what it was renamed to, else `Tab 2` — never the
/// bare `wN:t2`, and never a lone digit, which reads as a stray number rather
/// than a control.
String tabLabelFor(TabInfo tab) {
  final label = tab.label.trim();
  if (label.isNotEmpty) return label;
  return tab.number > 0 ? 'Tab ${tab.number}' : 'Tab';
}

/// One chip in the tab strip — flat, tight-cornered, hairline-edged, in the
/// same language as everything else. Selected lifts the fill and tints the edge
/// with the accent rather than filling it, so colour stays on status.
class _TabChip extends StatelessWidget {
  const _TabChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
    this.onLongPress,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      type: MaterialType.transparency,
      borderRadius: Radii.smAll,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          // 32 tall inside a 44 tap slot: the chip is small, the target is not.
          constraints: const BoxConstraints(minHeight: 32),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? scheme.panelFillRaised : scheme.panelFill,
            borderRadius: Radii.smAll,
            border: Border.all(
              color: selected ? scheme.primary : scheme.hairline,
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: selected ? scheme.primary : scheme.onSurface,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '$count',
                style: TextStyle(
                  fontSize: 10.5,
                  color: scheme.onSurfaceVariant,
                ).mono,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A tab's own actions, on a long-press of its chip.
///
/// A menu rather than a second visible control: renaming and closing a tab are
/// occasional, and a strip of chips has no room for two affordances each. This
/// is the same gesture the old `TabBar` used, so the capability moved with the
/// control rather than being lost with it.
Future<void> _showTabMenu(
  BuildContext context,
  WidgetRef ref,
  TabInfo tab,
) async {
  final scheme = Theme.of(context).colorScheme;
  final label = tabLabelFor(tab);
  final choice = await showModalBottomSheet<String>(
    context: context,
    useSafeArea: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            dense: true,
            title: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.drive_file_rename_outline),
            title: const Text('Rename tab'),
            onTap: () => Navigator.pop(ctx, 'rename'),
          ),
          ListTile(
            leading: Icon(Icons.close, color: scheme.error),
            title: const Text('Close tab'),
            onTap: () => Navigator.pop(ctx, 'close'),
          ),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  switch (choice) {
    case 'rename':
      await renameTabDialog(context, ref, tab.tabId, currentLabel: tab.label);
    case 'close':
      await closeTab(context, ref, tab.tabId, label: tab.label);
  }
}

/// Every project on the server, each with its agents and terminals under it.
class _AllProjects extends StatelessWidget {
  const _AllProjects({required this.snap});

  final Snapshot snap;

  @override
  Widget build(BuildContext context) {
    final index = _PaneIndex.of(snap);
    final panesByWs = <String, List<Pane>>{};
    for (final p in snap.panes) {
      panesByWs.putIfAbsent(p.workspaceId, () => []).add(p);
    }

    // A workspace with a checkout is a project; one without is still a place
    // panes live, so it is listed rather than hidden.
    final blocks = <_ProjectRef>[];
    for (final ws in snap.workspaces) {
      final panes = panesByWs[ws.workspaceId] ?? const <Pane>[];
      final named = projectOf(ws, spaceCwdOf(ws, panes));
      blocks.add(
        _ProjectRef(
          workspace: ws,
          panes: panes,
          project: named.project,
          branch: named.branch,
          needsAttention: panes.any(
            (p) => index.agentByPane[p.paneId]?.agentStatus.needsAttention ?? false,
          ),
        ),
      );
    }
    // Projects that need a human float up; then by name; then the main checkout
    // ahead of its worktrees, which reads as the worktrees belonging under it.
    blocks.sort((a, b) {
      final aa = a.needsAttention ? 0 : 1;
      final ab = b.needsAttention ? 0 : 1;
      if (aa != ab) return aa - ab;
      final n = a.project.toLowerCase().compareTo(b.project.toLowerCase());
      if (n != 0) return n;
      final wa = a.branch == null ? 0 : 1;
      final wb = b.branch == null ? 0 : 1;
      if (wa != wb) return wa - wb;
      return a.workspace.number.compareTo(b.workspace.number);
    });

    final needsYou =
        snap.agents.where((a) => a.agentStatus.needsAttention).toList()
          ..sort(Agent.byAttentionThenRecency);

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.only(
        top: FlatAppBar.padding(context),
        bottom: Space.xl,
      ),
      children: [
        _StatusStrip(agents: snap.agents),
        if (needsYou.isNotEmpty)
          _NeedsYouSection(agents: needsYou, index: index),
        for (final block in blocks)
          _ProjectBlock(block: block, index: index, snap: snap),
      ],
    );
  }
}

/// One project heading plus its agents and terminals.
class _ProjectBlock extends StatelessWidget {
  const _ProjectBlock({
    required this.block,
    required this.index,
    required this.snap,
  });

  final _ProjectRef block;
  final _PaneIndex index;
  final Snapshot snap;

  @override
  Widget build(BuildContext context) {
    final split = _splitPanes(block.panes, index);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ProjectHeader(
          project: block.project,
          branch: block.branch,
          agents: split.agents.length,
          terminals: split.terminals.length,
          focused: block.workspace.focused,
          onTap: () => context.push(
            '/overview/${Uri.encodeComponent(block.workspace.workspaceId)}',
          ),
        ),
        for (final p in [...split.agents, ...split.terminals])
          _PaneCard(
            pane: p,
            agent: index.agentByPane[p.paneId],
            focused: p.paneId == snap.focusedPaneId || p.focused,
            tab: index.tabById[p.tabId],
            siblings: index.paneCountForTab(p.tabId),
          ),
      ],
    );
  }
}

/// A project as a heading: the repo, the branch it is on, and what is in it.
///
/// Not a [SectionLabel] because that uppercases its text, and an uppercased
/// branch name is a different string — `FEAT/UI-FOUNDATION` is not a ref you
/// could type. The repo reads as a name and the branch as an identifier, which
/// is the same split the rest of the app makes.
class _ProjectHeader extends StatelessWidget {
  const _ProjectHeader({
    required this.project,
    required this.branch,
    required this.agents,
    required this.terminals,
    required this.focused,
    required this.onTap,
  });

  final String project;
  final String? branch;
  final int agents;
  final int terminals;
  final bool focused;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final parts = <String>[
      if (agents > 0) '$agents agent${agents == 1 ? '' : 's'}',
      if (terminals > 0) '$terminals terminal${terminals == 1 ? '' : 's'}',
    ];
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Space.gutter,
          Space.lg,
          Space.gutter,
          Space.sm,
        ),
        child: Row(
          children: [
            Flexible(
              child: Text(
                project,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (branch != null) ...[
              const SizedBox(width: Space.md),
              Icon(Icons.call_split, size: 12, color: scheme.primary),
              const SizedBox(width: 3),
              Flexible(
                child: Text(
                  branch!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: scheme.primary,
                    fontWeight: FontWeight.w500,
                  ).mono,
                ),
              ),
            ],
            if (focused) ...[
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
            const Spacer(),
            if (parts.isNotEmpty)
              Text(
                parts.join(' · '),
                style: TextStyle(
                  fontSize: 10.5,
                  color: scheme.onSurfaceVariant,
                ).mono,
              ),
            Icon(Icons.chevron_right, size: 16, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

/// A project block's inputs, resolved once so the sort and the render agree.
class _ProjectRef {
  const _ProjectRef({
    required this.workspace,
    required this.panes,
    required this.project,
    required this.branch,
    required this.needsAttention,
  });

  final WorkspaceInfo workspace;
  final List<Pane> panes;
  final String project;
  final String? branch;
  final bool needsAttention;
}

/// The lookups every section needs, built once per snapshot instead of once per
/// block.
class _PaneIndex {
  const _PaneIndex({
    required this.agentByPane,
    required this.paneById,
    required this.tabById,
    required this.panesPerTab,
  });

  factory _PaneIndex.of(Snapshot snap) {
    final panesPerTab = <String, int>{};
    for (final p in snap.panes) {
      panesPerTab.update(p.tabId, (n) => n + 1, ifAbsent: () => 1);
    }
    return _PaneIndex(
      agentByPane: {for (final a in snap.agents) a.paneId: a},
      paneById: {for (final p in snap.panes) p.paneId: p},
      tabById: {for (final t in snap.tabs) t.tabId: t},
      panesPerTab: panesPerTab,
    );
  }

  final Map<String, Agent> agentByPane;
  final Map<String, Pane> paneById;
  final Map<String, TabInfo> tabById;
  final Map<String, int> panesPerTab;

  /// How many panes share a pane's tab — what decides whether "rename this
  /// terminal" is an honest description of renaming its tab.
  int paneCountForTab(String tabId) => panesPerTab[tabId] ?? 1;
}

/// Panes split into agents and terminals, each in the order that section wants.
({List<Pane> agents, List<Pane> terminals}) _splitPanes(
  List<Pane> panes,
  _PaneIndex index,
) {
  final agents = <Pane>[];
  final terminals = <Pane>[];
  for (final p in panes) {
    (index.agentByPane.containsKey(p.paneId) ? agents : terminals).add(p);
  }
  // Agents in the app-wide order: what needs you first, then what moved last.
  agents.sort((a, b) {
    final aa = index.agentByPane[a.paneId];
    final ab = index.agentByPane[b.paneId];
    if (aa == null || ab == null) return 0;
    return Agent.byAttentionThenRecency(aa, ab);
  });
  // Terminals by what they are called, so the list is stable frame to frame
  // rather than shuffling with snapshot order.
  terminals.sort(
    (a, b) =>
        terminalTitle(a).toLowerCase().compareTo(terminalTitle(b).toLowerCase()),
  );
  return (agents: agents, terminals: terminals);
}

/// A labelled run of pane cards, or nothing at all when there are none — an
/// "AGENTS" heading over empty space says less than no heading.
List<Widget> _paneSection({
  required String label,
  required List<Pane> panes,
  required _PaneIndex index,
  required Snapshot snap,
  required int startAt,
}) {
  if (panes.isEmpty) return const [];
  return [
    SectionLabel(label, trailing: _MonoCount(panes.length)),
    for (var i = 0; i < panes.length; i++)
      Entrance(
        index: startAt + i,
        child: _PaneCard(
          pane: panes[i],
          agent: index.agentByPane[panes[i].paneId],
          focused:
              panes[i].paneId == snap.focusedPaneId || panes[i].focused,
          tab: index.tabById[panes[i].tabId],
          siblings: index.paneCountForTab(panes[i].tabId),
        ),
      ),
  ];
}

class _MonoCount extends StatelessWidget {
  const _MonoCount(this.value, {this.color});

  final int value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Text(
      '$value',
      style: TextStyle(
        fontSize: 10.5,
        color: color ?? scheme.onSurfaceVariant,
      ).mono,
    );
  }
}

/// A row of status counts across every agent — "does everything look okay?"
/// at a glance, before scrolling into the projects to find out.
/// Purely informational for now (not yet tappable to filter/scroll).
class _StatusStrip extends StatelessWidget {
  const _StatusStrip({required this.agents});
  final List<Agent> agents;

  @override
  Widget build(BuildContext context) {
    if (agents.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final counts = <AgentStatus, int>{};
    for (final a in agents) {
      counts[a.agentStatus] = (counts[a.agentStatus] ?? 0) + 1;
    }
    // Fixed, meaningful order regardless of iteration order above.
    const order = [
      AgentStatus.blocked,
      AgentStatus.working,
      AgentStatus.done,
      AgentStatus.idle,
      AgentStatus.unknown,
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Space.gutter,
        Space.md,
        Space.gutter,
        Space.xs,
      ),
      child: Wrap(
        spacing: Space.sm,
        runSpacing: Space.sm,
        children: [
          for (final status in order)
            if (counts[status] != null)
              _StatusCount(
                status: status,
                count: counts[status]!,
                scheme: scheme,
              ),
        ],
      ),
    );
  }
}

/// One `N working` flat chip — status colour on the dot and a low-alpha tint on
/// the fill, so the strip reads as status rather than decoration.
class _StatusCount extends StatelessWidget {
  const _StatusCount({
    required this.status,
    required this.count,
    required this.scheme,
  });

  final AgentStatus status;
  final int count;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final c = status.colors(scheme);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: c.bg,
        borderRadius: Radii.smAll,
        border: Border.all(color: c.fg.withValues(alpha: 0.30)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(shape: BoxShape.circle, color: c.fg),
          ),
          const SizedBox(width: 5),
          Text(
            '$count ${status.label}',
            style: TextStyle(
              color: c.fg,
              fontWeight: FontWeight.w600,
              fontSize: 11.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// The agents that need a human right now (blocked or done), flattened across
/// every project and shown ahead of them — so a blocked agent buried in the
/// seventh project isn't only discoverable by scrolling all the way there.
/// Reuses [_PaneCard] for a consistent look with the blocks below.
class _NeedsYouSection extends StatelessWidget {
  const _NeedsYouSection({required this.agents, required this.index});

  final List<Agent> agents;
  final _PaneIndex index;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The one section that gets a colour: it is the reason to open the
        // screen at all, and it reads at a glance in the accentless run of
        // project headings below it.
        SectionLabel(
          'Needs you',
          color: scheme.error,
          trailing: _MonoCount(agents.length, color: scheme.error),
        ),
        for (final a in agents)
          if (index.paneById[a.paneId] case final pane?)
            _PaneCard(
              pane: pane,
              agent: a,
              focused: false,
              tab: index.tabById[pane.tabId],
              siblings: index.paneCountForTab(pane.tabId),
            ),
      ],
    );
  }
}

class _PaneCard extends ConsumerWidget {
  const _PaneCard({
    required this.pane,
    required this.focused,
    this.agent,
    this.tab,
    this.siblings = 1,
  });

  final Pane pane;
  final Agent? agent;
  final bool focused;

  /// The tab holding this pane. Never shown; it is the handle behind "rename
  /// this terminal" and "close all of this split".
  final TabInfo? tab;

  /// How many panes share [tab].
  final int siblings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final blocked = pane.agentStatus == AgentStatus.blocked;
    final isAgent = agent != null;
    final cmd = isAgent ? null : pane.command;
    // Agents show their task. A terminal shows what is running in it and the
    // project it is running in — never its pane id.
    final headline = isAgent
        ? (pane.title.isNotEmpty ? pane.title : agent!.displayTitle)
        : terminalTitle(pane);
    // Leading glyph for a terminal: a running command gets a "play" marker; an
    // idle shell gets a terminal glyph.
    final headlineIcon = isAgent
        ? null
        : (cmd != null ? Icons.play_arrow_rounded : Icons.terminal);
    // The focused pane is tinted teal and the blocked one red — the border does
    // double duty here, and blocked wins, because "this one is stuck" is more
    // urgent than "this one is where your cursor is".
    return PanelRow(
      selected: focused,
      borderColor: blocked ? scheme.error : (focused ? scheme.primary : null),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      // Agents open the chat/transcript view (with a terminal toggle);
      // terminals open the raw terminal directly.
      onTap: () => context.push(
        '${isAgent ? '/transcript' : '/terminal'}/${Uri.encodeComponent(pane.paneId)}',
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Agent panes get the agent avatar; terminals a terminal glyph.
              if (agent != null)
                AgentAvatar(agent: agent!.agent, radius: 13)
              else
                CircleAvatar(
                  radius: 13,
                  backgroundColor: scheme.wellFill,
                  child: Icon(
                    Icons.terminal,
                    size: 15,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              const SizedBox(width: 8),
              // Agents: their status dot. Terminals: a small mono kind tag.
              if (isAgent)
                StatusMark(pane.agentStatus)
              else
                _KindTag(running: cmd != null),
              const Spacer(),
              if (focused)
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: scheme.primary,
                  ),
                ),
              // Agent panes get a shortcut into the chat/transcript view.
              if (isAgent) ...[
                const SizedBox(width: 4),
                InkResponse(
                  onTap: () => context.push(
                    '/transcript/${Uri.encodeComponent(pane.paneId)}',
                  ),
                  radius: 18,
                  child: Icon(
                    Icons.chat_bubble_outline,
                    size: 16,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
              // Split / close (Herdr parity via /herdr), plus the agent
              // lifecycle: an idle terminal can host a new agent, and one
              // already hosting an agent can restart or stop it.
              PopupMenuButton<String>(
                tooltip: isAgent ? 'Agent actions' : 'Terminal actions',
                padding: EdgeInsets.zero,
                iconSize: 18,
                icon: Icon(Icons.more_horiz, color: scheme.onSurfaceVariant),
                onSelected: (v) {
                  switch (v) {
                    case 'start-agent':
                      showStartAgentSheet(
                        context,
                        ref,
                        target: StartAgentTarget(
                          placement: StartAgentPlacement.existingPane,
                          id: pane.paneId,
                          where: 'In ${terminalTitle(pane)}',
                          defaultCwd: pane.cwd,
                        ),
                      );
                    case 'restart-agent':
                      restartAgent(
                        context,
                        ref,
                        pane.paneId,
                        kind: agent!.agent,
                      );
                    case 'stop-agent':
                      stopAgent(context, ref, pane.paneId, kind: agent!.agent);
                    case 'rename':
                      renameTabDialog(
                        context,
                        ref,
                        pane.tabId,
                        currentLabel: tab?.label ?? '',
                      );
                    case 'split':
                      splitPane(context, ref, pane.paneId);
                    case 'close':
                      closePane(
                        context,
                        ref,
                        pane.paneId,
                        label: headline,
                        subject: isAgent ? 'agent' : 'terminal',
                      );
                    case 'close-group':
                      closeTab(context, ref, pane.tabId);
                  }
                },
                itemBuilder: (ctx) => [
                  // Offered only on a pane with no agent in it. A pane running
                  // a dev server is rejected by the bridge, but it's a terminal
                  // either way — only an agent pane is a definitively wrong
                  // target, and it gets restart/stop instead.
                  if (!isAgent)
                    const PopupMenuItem(
                      value: 'start-agent',
                      child: ListTile(
                        leading: Icon(Icons.rocket_launch_outlined),
                        title: Text('Start an agent here'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  // Herdr renames *tabs*, not panes — but when a tab holds one
                  // pane, which is what everything the app creates looks like,
                  // renaming the tab is exactly renaming this terminal, and
                  // that is a subject the user recognises. On a split tab it is
                  // not offered, because it would silently rename the sibling
                  // panes too and there is no honest label for that.
                  if (!isAgent && pane.tabId.isNotEmpty && siblings == 1)
                    const PopupMenuItem(
                      value: 'rename',
                      child: ListTile(
                        leading: Icon(Icons.drive_file_rename_outline),
                        title: Text('Rename…'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  if (isAgent) ...[
                    const PopupMenuItem(
                      value: 'restart-agent',
                      child: ListTile(
                        leading: Icon(Icons.restart_alt),
                        title: Text('Restart agent'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                    PopupMenuItem(
                      value: 'stop-agent',
                      child: ListTile(
                        leading: Icon(
                          Icons.stop_circle_outlined,
                          color: Theme.of(ctx).colorScheme.error,
                        ),
                        title: const Text('Stop agent'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ],
                  const PopupMenuItem(
                    value: 'split',
                    child: ListTile(
                      leading: Icon(Icons.splitscreen_outlined),
                      title: Text('Split'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  PopupMenuItem(
                    value: 'close',
                    child: ListTile(
                      leading: Icon(
                        Icons.close,
                        color: Theme.of(ctx).colorScheme.error,
                      ),
                      title: Text(isAgent ? 'Close agent' : 'Close terminal'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  // The whole split at once — the capability tab-close carried,
                  // named for what the user can see (several panes sharing one
                  // screen) rather than for the tab holding them.
                  if (pane.tabId.isNotEmpty && siblings > 1)
                    PopupMenuItem(
                      value: 'close-group',
                      child: ListTile(
                        leading: Icon(
                          Icons.close_fullscreen,
                          color: Theme.of(ctx).colorScheme.error,
                        ),
                        title: const Text('Close all in this split'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (headlineIcon != null) ...[
                Icon(headlineIcon, size: 14, color: scheme.onSurfaceVariant),
                const SizedBox(width: 5),
              ],
              Expanded(
                child: Text(
                  headline,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: isAgent ? 14 : 12.5,
                    height: 1.25,
                    // A terminal's name is built from a command and a folder,
                    // both identifiers; a task title is prose.
                    fontFamily: isAgent ? null : AppTheme.monoFamily,
                  ),
                ),
              ),
            ],
          ),
          // The agent's most recent message — the same line the Flock list
          // carries, from the same widget and the same `/agent-state` source,
          // so a project and the flock can never disagree about whether an
          // agent is alive. It sits under the task rather than beside the
          // status dot, and stays one ellipsized line with its height reserved,
          // so a long message can't reflow the panel or shove the Approve
          // button around.
          if (isAgent)
            LiveActivityLine(paneId: pane.paneId, status: agent!.agentStatus),
          // A terminal running a command still shows *where* it runs, on a
          // muted line beneath the command itself. The name already carries the
          // project, so this is the more specific path within it.
          if (cmd != null && pane.locationLabel.isNotEmpty) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(
                  Icons.folder_outlined,
                  size: 12,
                  color: scheme.onSurfaceVariant,
                ),
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
    );
  }
}

/// A small mono tag marking a terminal as actively **running** a command
/// (accent dot + label) or sitting idle at a **shell**.
class _KindTag extends StatelessWidget {
  const _KindTag({required this.running});
  final bool running;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = running ? scheme.primary : scheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (running) ...[
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: 5),
        ],
        Text(
          running ? 'RUNNING' : 'SHELL',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
            color: color,
          ).mono,
        ),
      ],
    );
  }
}

/// Where a project lives — the directory a new agent started in it should
/// default to.
///
/// The workspace's own checkout path is the only authoritative answer, and it is
/// used whenever Herdr reports one. A pane's cwd is NOT a substitute: panes
/// wander into subdirectories and linked worktrees, so a single project
/// routinely spans several directories at once (a repo root, its `app/`, and
/// three `worktrees/*` checkouts is an ordinary spread). Picking the first pane
/// in snapshot order therefore defaults the start sheet to an arbitrary one of
/// them — which is the bug this replaces.
///
/// Only when a project has no checkout at all (a plain `~` workspace) does this
/// fall back to the panes, and then to the SHALLOWEST cwd they share rather than
/// an incidental one: the common ancestor is the closest thing to "where this
/// project lives" that the panes can tell us.
String spaceCwdOf(WorkspaceInfo? workspace, List<Pane> panes) {
  final checkout = workspace?.worktree?.checkoutPath ?? '';
  if (checkout.isNotEmpty) return checkout;
  if (panes.isEmpty) return '';

  var shallowest = panes.first.cwd;
  for (final p in panes) {
    if (p.cwd.isEmpty) continue;
    if (shallowest.isEmpty ||
        '/'.allMatches(p.cwd).length < '/'.allMatches(shallowest).length) {
      shallowest = p.cwd;
    }
  }
  return shallowest;
}
