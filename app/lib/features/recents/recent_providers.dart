import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/connection/connection_providers.dart';
import '../../data/bridge/models/snapshot.dart';
import '../priority/priority_providers.dart';

/// Which view an agent was opened in — the thing a Recent row has to put you
/// back into.
///
/// "Take me back to where I was" is the whole point of the section, and the
/// chat and the raw terminal are two genuinely different places to have been.
/// Landing in the transcript when you left off mid-`htop` is not "back".
enum OpenedView {
  transcript,
  terminal;

  /// The route that reopens this view for [paneId].
  String route(String paneId) {
    final p = Uri.encodeComponent(paneId);
    return switch (this) {
      OpenedView.transcript => '/transcript/$p',
      OpenedView.terminal => '/terminal/$p',
    };
  }

  static OpenedView parse(String? name) => OpenedView.values.firstWhere(
    (v) => v.name == name,
    orElse: () => OpenedView.transcript,
  );
}

/// One "I opened this" record: **where** (server + pane) and **how** (which
/// view), stamped with when.
///
/// Deliberately just those four fields. Everything a row displays — the task
/// title, the project, the status, the age — is read from live snapshot data at
/// render time, never from here. Caching a title would mean a Recent row could
/// disagree with the same agent's row three sections up, and it is also what
/// makes "the pane is gone, so the row goes" fall out for free: an entry with
/// nothing live behind it simply resolves to nothing.
class RecentOpen {
  const RecentOpen({
    required this.serverId,
    required this.paneId,
    required this.view,
    required this.openedAt,
  });

  final String serverId;
  final String paneId;
  final OpenedView view;

  /// Unix milliseconds. Only ever used for ordering, and only within this
  /// device's own history — it is not comparable to the bridge's activity
  /// timestamps and must not be mixed with them.
  final int openedAt;

  /// Identity of the *agent* this points at, stable across servers. The same
  /// pane id can exist on two different bridges, so the server has to be part
  /// of the key — this is the same rule [StarredAgents.starKey] follows, and
  /// the two keyspaces are compared against each other when Recent dedupes
  /// itself against Priority.
  String get key => recentKey(serverId, paneId);

  Map<String, dynamic> toJson() => {
    'server_id': serverId,
    'pane_id': paneId,
    'view': view.name,
    'opened_at': openedAt,
  };

  /// Null for anything that is not a usable record — a truncated write, a
  /// field that changed shape, an entry from a future version. Recent is a
  /// convenience, so a single bad row is dropped rather than allowed to throw
  /// and take the whole history (and the home screen) with it.
  static RecentOpen? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final serverId = raw['server_id'];
    final paneId = raw['pane_id'];
    if (serverId is! String || serverId.isEmpty) return null;
    if (paneId is! String || paneId.isEmpty) return null;
    final at = raw['opened_at'];
    return RecentOpen(
      serverId: serverId,
      paneId: paneId,
      view: OpenedView.parse(raw['view'] as String?),
      openedAt: at is int ? at : 0,
    );
  }
}

/// `"<serverId>::<paneId>"` — the key Recent, Priority and the home screen's
/// dedupe all speak.
String recentKey(String serverId, String paneId) => '$serverId::$paneId';

/// How many Recent rows the home screen shows.
///
/// Four, in the spirit of Priority's five: this is a shortcut back to what you
/// were just doing, not a second inbox. Past a handful it stops being "the one
/// I want is right there" and becomes another list to read — at which point the
/// agents list below it is already the better answer.
const int kRecentVisibleRows = 4;

/// How many opens are kept on disk, as opposed to shown.
///
/// Deeper than the visible cap on purpose: entries drop out silently when their
/// pane is gone, so a history exactly [kRecentVisibleRows] long would show
/// three rows after one worktree was removed and have nothing to backfill with.
/// Twenty-four is a few days of hopping around for the size of two pane ids.
const int kRecentStoreLimit = 24;

/// This device's own navigation history: the agents it most recently opened,
/// newest first.
///
/// **Not** the bridge's `recency_rank`, which is a different thing that sounds
/// the same. That rank orders agents by when *they* last did something, and it
/// is right for the flock list. This orders them by when *you* last looked at
/// them, which no server can know — an agent you opened two minutes ago belongs
/// at the top of Recent even if it has been silent for an hour, and one working
/// furiously that you have never opened does not belong in it at all.
///
/// Persisted in secure storage next to the starred set, for the same reason:
/// there is no schema to migrate, so it stays clear of the drift database.
final recentOpensProvider =
    AsyncNotifierProvider<RecentOpens, List<RecentOpen>>(RecentOpens.new);

class RecentOpens extends AsyncNotifier<List<RecentOpen>> {
  static const _key = 'gothalo.recent_agents';

  @override
  Future<List<RecentOpen>> build() async {
    final raw = await ref.watch(secureStorageProvider).read(key: _key);
    return decodeRecents(raw);
  }

  /// Record that this device just opened [paneId] on [serverId] in [view].
  ///
  /// Idempotent per agent: opening the same agent again moves it to the front
  /// and updates which view you were in, rather than filling the list with one
  /// agent. That is what makes the cap mean "the last four agents" instead of
  /// "the last four taps".
  Future<void> record({
    required String serverId,
    required String paneId,
    required OpenedView view,
  }) async {
    if (serverId.isEmpty || paneId.isEmpty) return;
    final entry = RecentOpen(
      serverId: serverId,
      paneId: paneId,
      view: view,
      openedAt: DateTime.now().millisecondsSinceEpoch,
    );
    // `await future`, NOT `state.asData?.value`. The very first record of a
    // cold start races the keystore read that [build] is still doing, and
    // reading `asData` there yields null — which would write a one-entry
    // history over everything the device had remembered. Awaiting resolves
    // instantly once loaded, so the common case costs nothing.
    List<RecentOpen> current;
    try {
      current = await future;
    } catch (_) {
      // The keystore itself failed. Recent is a convenience; starting a fresh
      // history beats propagating an error out of a post-frame callback.
      current = const [];
    }
    final next = [entry, ...current.where((e) => e.key != entry.key)];
    if (next.length > kRecentStoreLimit) {
      next.removeRange(kRecentStoreLimit, next.length);
    }
    state = AsyncData(next);
    await ref
        .read(secureStorageProvider)
        .write(key: _key, value: encodeRecents(next));
  }
}

/// The stored form: a JSON array, newest first.
String encodeRecents(List<RecentOpen> entries) =>
    jsonEncode([for (final e in entries) e.toJson()]);

/// Read the stored form back, dropping anything unreadable rather than
/// throwing. A corrupt blob costs the history, never the screen.
List<RecentOpen> decodeRecents(String? raw) {
  if (raw == null || raw.isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    final out = <RecentOpen>[];
    final seen = <String>{};
    for (final item in decoded) {
      final entry = RecentOpen.fromJson(item);
      // A duplicate can only come from a blob we did not write, but it would
      // render as the same agent twice, so it is dropped on the way in rather
      // than guarded against at every read site.
      if (entry != null && seen.add(entry.key)) out.add(entry);
    }
    return out;
  } catch (_) {
    return const [];
  }
}

/// A recent open resolved against live data — the agent as it is *now*, plus
/// the server it is on and the view to return to.
class RecentHit {
  const RecentHit({
    required this.server,
    required this.agent,
    required this.view,
  });

  final ServerSummary server;
  final Agent agent;
  final OpenedView view;

  String get key => recentKey(server.id, agent.paneId);

  /// Where tapping this row goes.
  String get route => view.route(agent.paneId);
}

/// Resolve stored opens against what each server currently reports.
///
/// The dropping rule is the whole of this function, and it is deliberately
/// silent in every case: an entry whose worktree was removed, whose pane was
/// closed, whose server was unpaired, or whose server is simply asleep resolves
/// to nothing and the section gets shorter. There is no dead row and no error —
/// a shortcut that cannot be taken is not a failure worth interrupting anyone
/// about, and an unreachable laptop coming back online silently restores its
/// rows on the next poll.
///
/// Order is the stored order (most recently opened first) and is never
/// re-sorted against anything the bridge says: this list exists precisely
/// because the bridge's own ordering answers a different question.
List<RecentHit> resolveRecents(
  List<RecentOpen> opens,
  List<ServerAgents> servers,
) {
  final byServer = {for (final s in servers) s.server.id: s};
  final out = <RecentHit>[];
  for (final open in opens) {
    final sa = byServer[open.serverId];
    // Unknown server (deleted), or one that failed to answer this round.
    if (sa == null || !sa.ok) continue;
    Agent? found;
    for (final a in sa.agents) {
      if (a.paneId == open.paneId) {
        found = a;
        break;
      }
    }
    if (found == null) continue; // pane closed, worktree removed, agent gone
    out.add(RecentHit(server: sa.server, agent: found, view: open.view));
  }
  return out;
}

/// The rows the Recent section actually renders.
///
/// [exclude] carries the keys of everything already on screen above it — the
/// whole Priority list, not just the rows the cap is showing. An agent that is
/// starred, or that needs you, is already the most prominent thing on the home
/// screen; repeating it three rows down as "recent" spends the shortcut on the
/// one agent that needs no shortcut. Excluding against the *whole* list rather
/// than the visible prefix also means expanding Priority cannot suddenly
/// duplicate a row.
///
/// The cap is applied **after** the exclusion, so a deduped-away entry is
/// backfilled by the next one rather than leaving a gap.
List<RecentHit> recentRows(
  List<RecentHit> hits, {
  Set<String> exclude = const {},
  int cap = kRecentVisibleRows,
}) {
  final out = <RecentHit>[];
  for (final hit in hits) {
    if (exclude.contains(hit.key)) continue;
    out.add(hit);
    if (out.length >= cap) break;
  }
  return out;
}

/// Every stored open resolved against every paired server's live agents.
///
/// Reads the same per-server providers Priority does, so Recent and Priority
/// can never disagree about whether an agent exists. `.value` rather than
/// `.asData?.value` for the reason spelled out in [priorityHitsProvider]: those
/// providers self-invalidate on a timer and are briefly `AsyncLoading` while
/// still carrying the previous value, and reading `asData` would blink every
/// recent row out of existence every few seconds.
final recentHitsProvider = Provider<List<RecentHit>>((ref) {
  final opens = ref.watch(recentOpensProvider).value ?? const <RecentOpen>[];
  if (opens.isEmpty) return const [];
  final all = ref.watch(serversProvider).value ?? const <ServerSummary>[];
  final servers = <ServerAgents>[];
  for (final s in all) {
    final sa = ref.watch(serverAgentsProvider(s.id)).value;
    if (sa != null) servers.add(sa);
  }
  return resolveRecents(opens, servers);
});
