import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/connection/connection_providers.dart';
import '../../data/bridge/models/snapshot.dart';
import '../priority/priority_providers.dart';
import '../recents/recent_providers.dart';

/// One agent on one server — the pair every home-screen section is a list of.
class ServerAgentHit {
  const ServerAgentHit(this.server, this.agent);
  final ServerSummary server;
  final Agent agent;

  String get key => recentKey(server.id, agent.paneId);
}

/// A named group of agents on the home screen.
class AgentGroup {
  const AgentGroup({
    required this.label,
    required this.agents,
    required this.cap,
    this.emphasize = false,
    this.compact = false,
  });

  final String label;
  final List<ServerAgentHit> agents;

  /// How many rows this section shows before the rest go behind an expander.
  final int cap;

  /// Draw the header in the attention colour — true only for the group that is
  /// waiting on a human.
  final bool emphasize;

  /// Render as dense single lines in one shared panel rather than as a card
  /// each. See [kIdleVisibleRows].
  final bool compact;
}

/// How many rows a **card** section shows before the rest go behind a
/// "show N more" — needs-you and working.
///
/// Five, matching Priority's cap, because it is the same judgement: five
/// two-line rows is about as much as the top of a screen can give one section
/// before everything under it is off the bottom.
const int kSectionVisibleRows = 5;

/// How many rows the **idle** section shows before the rest go behind a
/// "show N more".
///
/// A dozen idle agents is an ordinary state of this machine, and as full cards
/// they took most of the screen to say that nothing wants you.
///
/// Tighter than [kSectionVisibleRows] despite these rows being less than half
/// the height: what this section hides is by definition not urgent, so the
/// space is better spent on the sections that are.
const int kIdleVisibleRows = 3;

/// Which agent sections the user has expanded, this session.
///
/// Keyed by the section's label, and **shared by every screen that renders the
/// list** — home and the Flock tab — for the same reason `priorityExpanded` is
/// shared by home and the Priority screen: it is one list shown at two scopes,
/// and having "Idle" open in one place and shut in the other reads as a bug.
///
/// A plain [Notifier], not autoDispose, so opening an agent and coming back
/// keeps the choice; a cold start comes back collapsed, which is the state that
/// fits the screen.
class SectionExpanded extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  bool isExpanded(String label) => state.contains(label);

  void toggle(String label) {
    final next = {...state};
    if (!next.remove(label)) next.add(label);
    state = next;
  }
}

final sectionExpandedProvider =
    NotifierProvider<SectionExpanded, Set<String>>(SectionExpanded.new);

/// A section split into the rows it shows now and the rows it holds back.
class SectionCap {
  const SectionCap._({
    required this.visible,
    required this.hidden,
    required this.hasOverflow,
    required this.capGaveWay,
  });

  /// Split [rows] at [cap].
  ///
  /// Expanded, or short enough, shows everything. Collapsed shows the first
  /// [cap] rows — **except** that an agent which needs you is never hidden: if
  /// one falls past the cap the cut stretches to cover it. That is #107's rule,
  /// and it now holds in every section on every screen rather than only in
  /// Priority: more blocked agents than the cap is the one case where a long
  /// list is the correct answer, so the cap gives way rather than burying the
  /// rows the app exists for.
  ///
  /// The cut is a plain prefix, never a re-sort. The list arrives in
  /// [Agent.byAttentionThenRecency] order and this only ever truncates it, so
  /// what you see is the top of the same list every other surface shows.
  factory SectionCap.of(
    List<ServerAgentHit> rows, {
    required bool expanded,
    required int cap,
  }) {
    var cut = rows.length;
    if (rows.length > cap) {
      cut = cap;
      for (var i = rows.length - 1; i >= cut; i--) {
        if (rows[i].agent.agentStatus == AgentStatus.blocked) {
          cut = i + 1;
          break;
        }
      }
    }
    final show = expanded || cut >= rows.length
        ? rows
        : rows.sublist(0, cut);
    return SectionCap._(
      visible: show,
      hidden: expanded ? 0 : rows.length - cut,
      // True while expanded too: otherwise the control that opened the section
      // would vanish the moment it was used, with no way back.
      hasOverflow: rows.length > cut,
      capGaveWay: !expanded && cut > cap,
    );
  }

  final List<ServerAgentHit> visible;

  /// How many rows the cap is holding back right now — zero while expanded.
  final int hidden;

  /// The cap is in play at all, so the section needs its expander.
  final bool hasOverflow;

  /// The cap was overridden to keep every blocked agent on screen.
  final bool capGaveWay;
}

/// Every agent across every reachable server, minus [exclude], grouped by what
/// it is doing.
///
/// Three groups, in the order a person triages: **needs you** (blocked or
/// finished), **working**, **idle**. An empty group is omitted rather than
/// rendered as a heading with nothing under it.
///
/// The groups are not peers visually. Needs-you and working rows are cards;
/// idle is [compact] — dense lines in one shared panel, capped. The contrast
/// is the point: on a machine with two working agents and twelve idle ones,
/// the two should not be outnumbered fourteen to one for attention.
///
/// This is a pure function of the servers it is handed so the grouping, the
/// ordering and the exclusion can be pinned without a bridge. Ordering inside a
/// group is [Agent.byAttentionThenRecency] — the same comparator the flock list
/// and Priority use, because two lists of the same agents in two different
/// orders is worse than either order is good.
///
/// Unreachable servers contribute nothing. Their state is reported once, in the
/// Servers section, rather than as a hole in the middle of the agent list.
List<AgentGroup> groupAgentsByState(
  List<ServerAgents> servers, {
  Set<String> exclude = const {},
}) => groupAgents([
  for (final sa in servers)
    if (sa.ok)
      for (final agent in sa.agents) ServerAgentHit(sa.server, agent),
], exclude: exclude);

/// The grouping itself, over hits that have already been paired with a server.
///
/// Split from [groupAgentsByState] so the Flock screen — which has one server's
/// snapshot rather than a list of servers — reaches the *same* grouping instead
/// of growing its own. The two screens differ in where the agents come from,
/// not in how they are ordered or bucketed, and that is exactly the difference
/// that must not become two implementations.
List<AgentGroup> groupAgents(
  List<ServerAgentHit> hits, {
  Set<String> exclude = const {},
}) {
  final needsYou = <ServerAgentHit>[];
  final working = <ServerAgentHit>[];
  final idle = <ServerAgentHit>[];

  for (final hit in hits) {
    if (exclude.contains(hit.key)) continue;
    switch (hit.agent.agentStatus) {
      case AgentStatus.blocked:
      case AgentStatus.done:
        needsYou.add(hit);
      case AgentStatus.working:
        working.add(hit);
      case AgentStatus.idle:
      case AgentStatus.unknown:
        idle.add(hit);
    }
  }

  for (final list in [needsYou, working, idle]) {
    list.sort((a, b) => Agent.byAttentionThenRecency(a.agent, b.agent));
  }

  return [
    if (needsYou.isNotEmpty)
      AgentGroup(
        label: 'Needs you',
        agents: needsYou,
        cap: kSectionVisibleRows,
        emphasize: true,
      ),
    if (working.isNotEmpty)
      AgentGroup(
        label: 'Working',
        agents: working,
        cap: kSectionVisibleRows,
      ),
    if (idle.isNotEmpty)
      AgentGroup(
        label: 'Idle',
        agents: idle,
        cap: kIdleVisibleRows,
        compact: true,
      ),
  ];
}
