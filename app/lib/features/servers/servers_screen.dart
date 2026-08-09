import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_background.dart';
import '../../core/connection/connection_providers.dart';
import '../../core/theme.dart';
import '../../core/tokens.dart';
import '../../core/widgets/action_chip.dart';
import '../../core/widgets/app_mark.dart';
import '../../core/widgets/entrance.dart';
import '../../core/widgets/panel_row.dart';
import '../../data/bridge/models/snapshot.dart';
import '../agents/agent_groups.dart';
import 'add_edit_server_sheet.dart';
import '../agents/widgets/agent_row.dart';
import '../agents/widgets/agent_sections.dart';
import '../priority/priority_providers.dart';
import '../priority/widgets/priority_overflow_bar.dart';
import '../recents/recent_providers.dart';

/// Home — **agents**, not servers.
///
/// The screen is named for the route it has always owned, but its subject has
/// changed: you no longer walk server → flock → agents to reach the thing you
/// were working on. Everything paired to this phone is on one page, in the
/// order a person actually wants it:
///
///   1. **Priority** — what needs you, plus what you starred. Unchanged: the
///      five-row cap, the "show N more" expander, the tally, and the rule that
///      a blocked agent is never hidden by the cap.
///   2. **Recent** — the projects/spaces and agents *this device* visited last.
///      Project chips return to the whole space; agent rows return straight to
///      the view you left them in. See [recentHitsProvider] for why this cannot
///      be the bridge's recency ordering.
///   3. **Agents** — every other agent on every server, grouped by state.
///   4. **Servers** — still here, still how you add, edit and open one. It is
///      no longer the way you find an agent.
///
/// The agent rows inside Recent and the state groups still show an agent at
/// most once: both are deduped against Priority, and the groups are deduped
/// against Recent. Project chips are separate workspace destinations and do
/// not claim the agent rows below them.
class ServersScreen extends ConsumerStatefulWidget {
  const ServersScreen({super.key});

  @override
  ConsumerState<ServersScreen> createState() => _ServersScreenState();
}

class _ServersScreenState extends ConsumerState<ServersScreen> {
  @override
  void initState() {
    super.initState();
    // Seed the optional dev server (from --dart-define) once on a fresh install.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(serversRepositoryProvider).ensureDevSeed();
    });
  }

  Future<void> _openServer(ServerSummary server) async {
    await ref.read(activeServerIdProvider.notifier).set(server.id);
    // push, not go: `go` replaces the whole stack, so Flock had no back entry
    // and the hardware back button exited the app. Pushing keeps home
    // underneath, so back returns here.
    if (mounted) context.push('/inbox');
  }

  /// Open an agent on [server]. The route is the caller's, because "back to
  /// where you were" means the transcript for most rows and the terminal for a
  /// Recent row that was left in one.
  Future<void> _open(ServerSummary server, String route) async {
    await ref.read(activeServerIdProvider.notifier).set(server.id);
    if (mounted) context.push(route);
  }

  Future<void> _openSpace(RecentSpaceHit hit) => _open(hit.server, hit.route);

  Future<void> _openAgent(ServerSummary server, Agent agent) =>
      // Agents open the chat/transcript view by default (with a terminal toggle).
      _open(server, '/transcript/${Uri.encodeComponent(agent.paneId)}');

  Future<void> _confirmDelete(ServerSummary server) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${server.name}?'),
        content: const Text(
          'This deletes the saved server and its token from this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(serversRepositoryProvider).delete(server.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final servers = ref.watch(serversProvider);
    final hits = ref.watch(priorityHitsProvider);
    // Priority is the top of this screen, not the whole of it: past a handful
    // of agents the section grew until everything below it was off the bottom.
    // Cut it at the cap and put the rest behind an expander — except for the
    // agents that need you, which the cap is not allowed to hide.
    final overflow = PriorityOverflow.of(
      hits,
      expanded: ref.watch(priorityExpandedProvider),
    );
    // Live per-server agent stats, keyed by server id — each server watched
    // independently so a reachable one renders immediately instead of waiting
    // on a sleeping one.
    //
    // `.value`, NOT `.asData?.value`: during each provider's own refetch the
    // state is AsyncLoading, which still carries the previous value but is not
    // AsyncData. Reading `asData` blanked the row back to "checking…" on every
    // tick, which defeats the point of refreshing at all.
    final serverAgents = watchAllServerAgents(ref);
    final byServer = {for (final sa in serverAgents) sa.server.id: sa};

    // Everything Priority owns — the whole list, not the visible prefix, so
    // expanding it can never duplicate a row further down the page.
    final claimed = {
      for (final h in overflow.all) recentKey(h.server.id, h.agent.paneId),
    };
    final recents = recentRows(ref.watch(recentHitsProvider), exclude: claimed);
    claimed.addAll(recents.map((r) => r.key));
    final recentSpaces = recentSpaceRows(ref.watch(recentSpaceHitsProvider));

    // The rest of the flock, grouped by what it is doing. Ordered inside each
    // group by the bridge's own attention-then-recency rule, so this list and
    // the per-server flock list never disagree about what comes first.
    final groups = groupAgentsByState(serverAgents, exclude: claimed);
    // Keep active state visible before the navigation shortcuts. Idle remains
    // below Recent because it is the least urgent part of the home surface.
    final activeGroups = groups.where((group) => !group.compact).toList();
    final idleGroups = groups.where((group) => group.compact).toList();

    // A single-server setup says the same server name on every row, which is
    // noise. Two or more and it is the thing that tells otherwise-identical
    // branches apart.
    final showServer = (servers.value?.length ?? 0) > 1;

    return AppBackground(
      asset: Backgrounds.servers,
      child: Scaffold(
        // No app bar: _StatusBand frames the status bar and the greeting
        // header owns the top of this screen.
        floatingActionButton: FloatingActionButton(
          onPressed: () => showAddServerSheet(context),
          tooltip: 'Add server manually',
          child: const Icon(Icons.add),
        ),
        body: Builder(
          builder: (context) => servers.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('$e')),
            data: (list) {
              if (list.isEmpty) return const _EmptyServers();
              // Home is the screen opened most often, so the cascade is short
              // and shallow: `Entrance` caps its stagger at 220ms whatever the
              // list length, and the rows are keyed by identity so a snapshot
              // tick — one every six seconds — rebuilds without replaying.
              var step = 0;
              Widget enter(Widget child, {Key? key}) =>
                  Entrance(key: key, index: step++, child: child);
              return Column(
                children: [
                  _StatusBand(),
                  Expanded(
                    child: RefreshIndicator(
                      onRefresh: () async =>
                          ref.invalidate(serverAgentsProvider),
                      child: ListView(
                        padding: EdgeInsets.only(
                          // No top inset here: _StatusBand above owns it.
                          // Bottom still needs to clear the FAB, and clear it
                          // on a gesture-nav phone too. A flat 96 was measured
                          // from the viewport, which sits *above* the system
                          // inset the FAB is also lifted by — so on a device
                          // with a home indicator the button landed on the
                          // last row. The inset has to be added, not assumed
                          // away.
                          bottom:
                              _fabClearance +
                              MediaQuery.paddingOf(context).bottom,
                        ),
                        children: [
                          // --- Greeting ---
                          enter(
                            _GreetingHeader(
                              needsYou: hits.where((h) => h.needsYou).length,
                            ),
                          ),

                          // --- Priority (needs you + starred) ---
                          enter(
                            SectionLabel(
                              'Priority',
                              trailing: _SectionAction(
                                label: 'Manage',
                                onTap: () => context.push('/priority'),
                              ),
                            ),
                          ),
                          if (hits.isEmpty)
                            enter(
                              _PriorityEmpty(
                                onManage: () => context.push('/priority'),
                              ),
                            )
                          else ...[
                            for (final h in overflow.visible)
                              enter(
                                key: ValueKey(
                                  'priority-${h.server.id}-${h.agent.paneId}',
                                ),
                                AgentRow(
                                  agent: h.agent,
                                  starred: h.starred,
                                  serverName: showServer ? h.server.name : null,
                                  onTap: () => _openAgent(h.server, h.agent),
                                ),
                              ),
                            PriorityOverflowBar(
                              overflow: overflow,
                              onToggle: () => ref
                                  .read(priorityExpandedProvider.notifier)
                                  .toggle(),
                            ),
                          ],

                          // --- Active agents ---
                          //
                          // Needs-you and Working are live state, so they stay
                          // above Recent. Priority normally claims Needs-you;
                          // splitting here keeps the ordering honest if that
                          // ever changes.
                          ...buildAgentSections(
                            context,
                            ref,
                            groups: activeGroups,
                            showServer: showServer,
                            onOpen: (hit) => _openAgent(hit.server, hit.agent),
                          ).map(enter),

                          // --- Recent projects/spaces + agents ---
                          //
                          // A project shortcut is separate from an agent
                          // shortcut, but both are the device's recent
                          // destinations and belong under one compact heading.
                          // A terminal-only space is useful here too. Like the
                          // agent history, dead or unreachable entries simply
                          // resolve away and the section is absent when empty.
                          if (recentSpaces.isNotEmpty ||
                              recents.isNotEmpty) ...[
                            enter(const SectionLabel('Recent')),
                            if (recentSpaces.isNotEmpty)
                              enter(
                                SizedBox(
                                  height: 44,
                                  child: ListView.separated(
                                    scrollDirection: Axis.horizontal,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: Space.gutter,
                                    ),
                                    itemCount: recentSpaces.length,
                                    separatorBuilder: (_, _) =>
                                        const SizedBox(width: Space.sm),
                                    itemBuilder: (_, i) {
                                      final project = recentSpaces[i];
                                      return Center(
                                        child: _RecentProjectChip(
                                          hit: project,
                                          serverName: showServer
                                              ? project.server.name
                                              : null,
                                          onTap: () => _openSpace(project),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ),
                            // Agent rows follow the project chips in the same
                            // Recent section.
                            for (final r in recents)
                              enter(
                                key: ValueKey('recent-${r.key}'),
                                AgentRow(
                                  agent: r.agent,
                                  serverName: showServer ? r.server.name : null,
                                  trailing: _ViewMark(view: r.view),
                                  onTap: () => _open(r.server, r.route),
                                ),
                              ),
                          ],

                          // --- Idle agents ---
                          //
                          // The same builder the Flock screen uses, so an agent looks
                          // identical whichever way you reached it.
                          ...buildAgentSections(
                            context,
                            ref,
                            groups: idleGroups,
                            showServer: showServer,
                            onOpen: (hit) => _openAgent(hit.server, hit.agent),
                          ).map(enter),

                          // --- Servers ---
                          enter(const SectionLabel('Servers')),
                          for (final s in list)
                            enter(
                              key: ValueKey('server-${s.id}'),
                              _ServerTile(
                                server: s,
                                summary: byServer[s.id],
                                onTap: () => _openServer(s),
                                onEdit: () =>
                                    showEditServerSheet(context, s.id),
                                onDelete: () => _confirmDelete(s),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The greeting at the top of home: time-of-day hello, today's date, and one
/// line about whether anything needs you. It is the screen's headline — the one
/// thing shown before any list — so it reads at a glance, then gets out of the
/// way. The state line reuses the terminal-native idiom from [StatusMark]: a
/// status dot (red = needs you, teal = all clear) beside a small uppercase mono
/// label.
class _GreetingHeader extends StatelessWidget {
  const _GreetingHeader({required this.needsYou});

  /// Blocked agents across all servers — the thing the greeting should own up
  /// to immediately, because it's the one reason to look at this screen.
  final int needsYou;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final greeting = switch (now.hour) {
      < 12 => 'Good morning',
      < 17 => 'Good afternoon',
      _ => 'Good evening',
    };

    final needs = needsYou > 0;
    final color = needs ? scheme.error : scheme.primary;
    final stateLabel = needs ? '$needsYou NEED YOU' : 'ALL CLEAR';

    return Padding(
      // Roomier up top — this is the screen's headline, so it wants to sit
      // clear of the status bar rather than pressed against it. The bottom is
      // tighter than a section label's own top pad: the greeting owns the
      // spacing down to the Priority heading, so it doesn't double it.
      padding: const EdgeInsets.fromLTRB(
        Space.gutter,
        Space.xl + Space.md,
        Space.gutter,
        Space.sm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The circular brand mark beside the greeting — the only place it
          // reads on this screen now that the bar is gone.
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: AppMark(radius: 22),
          ),
          const SizedBox(width: Space.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  greeting,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: Space.xs),
                Text(
                  _friendlyDate(now),
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant)
                      .mono,
                ),
                const SizedBox(height: Space.md),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: color,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      stateLabel,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.8,
                        color: color,
                      ).mono,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Today's date as a phrase, e.g. "Saturday, Aug 8". Hand-rolled rather than
/// intl so the header needs no date-package dependency or locale setup.
String _friendlyDate(DateTime d) {
  const weekdays = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${weekdays[d.weekday - 1]}, ${months[d.month - 1]} ${d.day}';
}

/// How much room the floating "add server" button needs at the foot of the
/// list, before the device's own bottom inset is added on top.
///
/// 16 (the FAB's margin) + 56 (the FAB) + 16 (breathing room under it).
const double _fabClearance = 88;

/// The text action that sits on a section header ("Manage"), sized to the
/// header rather than as a full [TextButton], which would out-weigh the label
/// it is attached to.
class _SectionAction extends StatelessWidget {
  const _SectionAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: Radii.xsAll,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: scheme.primary,
          ),
        ),
      ),
    );
  }
}

/// Which view a Recent row will reopen — `CHAT` or `TERM`.
///
/// Small, mono and muted: it is a promise about where the tap goes, not a
/// status. Without it two rows for the same agent (opened once in each view)
/// would be indistinguishable, and more importantly a tap that lands somewhere
/// other than where you left off reads as the app losing your place.
class _ViewMark extends StatelessWidget {
  const _ViewMark({required this.view});

  final OpenedView view;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Text(
      switch (view) {
        OpenedView.transcript => 'CHAT',
        OpenedView.terminal => 'TERM',
      },
      style: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.8,
        color: scheme.onSurfaceVariant,
      ).mono,
    );
  }
}

/// A recently visited project as a deliberately small horizontal shortcut.
/// The project list is already available deeper in the app; this section only
/// needs to expose a handful of direct destinations without becoming a second
/// vertical list.
class _RecentProjectChip extends StatelessWidget {
  const _RecentProjectChip({
    required this.hit,
    required this.serverName,
    required this.onTap,
  });

  final RecentSpaceHit hit;
  final String? serverName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final detailChildren = <Widget>[];

    void addText(String value) {
      if (detailChildren.isNotEmpty) {
        detailChildren.add(const SizedBox(width: 6));
      }
      detailChildren.add(
        Text(
          value,
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11.5).mono,
        ),
      );
    }

    void addCount(IconData icon, int count) {
      if (detailChildren.isNotEmpty) {
        detailChildren.add(const SizedBox(width: 8));
      }
      detailChildren.add(Icon(icon, size: 13, color: scheme.onSurfaceVariant));
      detailChildren.add(const SizedBox(width: 2));
      detailChildren.add(
        Text(
          '$count',
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11.5),
        ),
      );
    }

    if (hit.branch != null) addText(hit.branch!);
    if (serverName != null) addText(serverName!);
    if (hit.agentCount > 0) {
      addCount(Icons.smart_toy_outlined, hit.agentCount);
    }
    if (hit.terminalCount > 0) {
      addCount(Icons.terminal, hit.terminalCount);
    }

    return AppActionChip(
      icon: hit.branch == null ? Icons.folder_outlined : Icons.call_split,
      label: hit.project,
      detailChild: detailChildren.isEmpty
          ? null
          : Row(mainAxisSize: MainAxisSize.min, children: detailChildren),
      color: hit.needsAttention ? scheme.error : null,
      onTap: onTap,
    );
  }
}

class _PriorityEmpty extends StatelessWidget {
  const _PriorityEmpty({required this.onManage});
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PanelRow(
      onTap: onManage,
      child: Row(
        children: [
          Icon(Icons.check_circle_outline, size: 18, color: scheme.primary),
          const SizedBox(width: Space.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Nothing needs you',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
                ),
                const SizedBox(height: 2),
                Text(
                  'Agents waiting on you show up here. Tap to star more.',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right, size: 18, color: scheme.onSurfaceVariant),
        ],
      ),
    );
  }
}

class _ServerTile extends StatelessWidget {
  const _ServerTile({
    required this.server,
    required this.summary,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  final ServerSummary server;
  final ServerAgents? summary;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // "need you" == blocked (waiting for input); done is finished, not waiting.
    final attention =
        summary?.agents
            .where((a) => a.agentStatus == AgentStatus.blocked)
            .length ??
        0;

    return PanelRow(
      onTap: onTap,
      selected: server.isActive,
      borderColor: server.isActive ? scheme.primary : null,
      padding: const EdgeInsets.fromLTRB(10, 9, 4, 9),
      child: Row(
        children: [
          Icon(
            Icons.dns_outlined,
            size: 18,
            color: server.isActive ? scheme.primary : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: Space.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        server.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13.5,
                        ),
                      ),
                    ),
                    if (server.isActive) ...[
                      const SizedBox(width: Space.md),
                      Text(
                        'ACTIVE',
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.8,
                          color: scheme.primary,
                        ).mono,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  _hostLabel(server.baseUrl),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 11.5,
                  ).mono,
                ),
                const SizedBox(height: 2),
                _StatsLine(
                  summary: summary,
                  attention: attention,
                  needsUpgrade: server.needsUpgrade,
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'Server actions',
            iconSize: 18,
            icon: Icon(Icons.more_horiz, color: scheme.onSurfaceVariant),
            onSelected: (v) => v == 'edit' ? onEdit() : onDelete(),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('Edit')),
              PopupMenuItem(value: 'delete', child: Text('Remove')),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatsLine extends StatelessWidget {
  const _StatsLine({
    required this.summary,
    required this.attention,
    required this.needsUpgrade,
  });
  final ServerAgents? summary;
  final int attention;

  /// This bridge has never reported a version — see [ServerSummary.needsUpgrade].
  final bool needsUpgrade;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (summary == null) {
      return Text(
        'checking…',
        style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11.5),
      );
    }
    if (!summary!.ok) {
      return Text(
        'unreachable',
        style: TextStyle(color: scheme.error, fontSize: 11.5),
      );
    }
    final count = summary!.agents.length;
    // Wrap, not Row: with "update bridge" *and* "N need you" on a 360dp phone
    // this overflowed by 15px, because a Row of unbounded Texts inside a fixed
    // column has nowhere to go. Both notes are short and both matter, so they
    // fold onto a second line rather than one of them being clipped.
    return Wrap(
      spacing: 6,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          '$count agent${count == 1 ? '' : 's'}',
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11.5),
        ),
        // A bridge that has never identified itself can't have its notifications
        // attributed or routed. Worth showing — the alternative is discovering
        // it only when a notification tap declines to open anything — but it is
        // a nudge, not an alarm: everything else about the server works, so it
        // sits quietly next to the agent count rather than beside the name.
        if (needsUpgrade) ...[
          const Tooltip(
            message:
                'Update gothalo on this machine to route its notifications',
            child: Icon(
              Icons.warning_amber_rounded,
              size: 14,
              color: _warnColor,
            ),
          ),
          const SizedBox(width: 4),
          // Labelled, not icon-only: a tooltip needs a long-press on a phone, so
          // a bare glyph says "something is wrong" without saying what — which
          // is worse than saying nothing. Mirrors the "N need you" idiom used
          // for attention on this same line.
          const Text(
            'update bridge',
            style: TextStyle(
              color: _warnColor,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
        if (attention > 0) ...[
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: scheme.error,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            '$attention need you',
            style: TextStyle(
              color: scheme.error,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }
}

/// Amber for "works, but needs attention" — distinct from the error red used
/// for an unreachable server, because this one is reachable and fine apart from
/// notification routing.
const _warnColor = Color(0xFFFFB300);

/// host[:port] for the tile subtitle — keeps the port (e.g. :5338) visible.
String _hostLabel(String baseUrl) {
  final uri = Uri.tryParse(baseUrl);
  if (uri == null || uri.host.isEmpty) return baseUrl;
  return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
}

/// The slim strip the status bar sits on. With edge-to-edge rendering the
/// system status bar is transparent over our content, and floating icons on
/// the flat page reads as "broken" — this band gives that area a defined
/// surface and a hairline edge, so the top of the screen reads as one frame.
class _StatusBand extends StatelessWidget {
  const _StatusBand();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: MediaQuery.paddingOf(context).top,
      decoration: BoxDecoration(
        color: scheme.wellFill,
        border: Border(bottom: BorderSide(color: scheme.hairline, width: 1)),
      ),
    );
  }
}

class _EmptyServers extends StatelessWidget {
  const _EmptyServers();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.dns_outlined, size: 56, color: scheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              'No servers yet',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              'Add a gothalo bridge to see your agents. Enter its URL and token, '
              'or pair by scanning a QR.',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => context.push('/pair'),
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Pair via QR'),
            ),
            const SizedBox(height: 10),
            TextButton.icon(
              onPressed: () => showAddServerSheet(context),
              icon: const Icon(Icons.add),
              label: const Text('Add manually'),
            ),
          ],
        ),
      ),
    );
  }
}
