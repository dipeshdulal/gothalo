import 'dart:convert';

import '../../data/bridge/models/snapshot.dart';

/// How many rows the widget's body can show before it runs out of height on the
/// smallest (2x2) cell. Kept here rather than in the layout because it decides
/// how much we serialize, not just how much we draw.
const kFleetWidgetRows = 3;

/// One server's contribution to the widget, as last seen by the app.
///
/// Buckets are stored per server rather than as one aggregate because the app
/// almost never has a live view of *every* server at once: the `/events` socket
/// covers only the active one, and the cross-server poll only runs while the
/// Priority screen is open. Writing an aggregate from whichever source fired
/// last would let the active server's update erase the others' counts.
class ServerCounts {
  const ServerCounts({
    required this.serverName,
    required this.needsYou,
    required this.working,
    required this.done,
    required this.total,
    required this.lines,
    required this.updatedAt,
  });

  /// An empty bucket for a server we can see but haven't read yet.
  const ServerCounts.empty(this.serverName)
    : needsYou = 0,
      working = 0,
      done = 0,
      total = 0,
      lines = const [],
      updatedAt = 0;

  final String serverName;

  /// Blocked — actively waiting on a human. Mirrors [PriorityHit.needsYou].
  final int needsYou;
  final int working;

  /// Finished and not yet looked at. Surfaced separately because "done" is not
  /// the same ask as "blocked" — see `docs/CONTRACT-notifications.md` §4.
  final int done;
  final int total;

  /// Titles of this server's attention-worthy agents, in the order every other
  /// surface lists them ([Agent.byAttentionThenRecency]).
  final List<String> lines;

  /// Unix ms when this bucket was last written.
  final int updatedAt;

  /// Read one server's agents into a bucket.
  factory ServerCounts.fromAgents(
    String serverName,
    List<Agent> agents,
    int nowMs,
  ) {
    var needsYou = 0;
    var working = 0;
    var done = 0;
    for (final a in agents) {
      switch (a.agentStatus) {
        case AgentStatus.blocked:
          needsYou++;
        case AgentStatus.working:
          working++;
        case AgentStatus.done:
          done++;
        case AgentStatus.idle:
        case AgentStatus.unknown:
          break;
      }
    }
    // The shared comparator, not a local one. The widget's rows are the head of
    // the list its own tap opens, so a private tiebreak here would put agent
    // three on the home screen and agent one on the Priority screen — exactly
    // the drift [Agent.byAttentionThenRecency] exists to prevent.
    final attention = agents.where((a) => a.agentStatus.needsAttention).toList()
      ..sort(Agent.byAttentionThenRecency);
    return ServerCounts(
      serverName: serverName,
      needsYou: needsYou,
      working: working,
      done: done,
      total: agents.length,
      lines: [
        for (final a in attention.take(kFleetWidgetRows)) a.displayTitle,
      ],
      updatedAt: nowMs,
    );
  }

  /// Whether this says the same thing as [other], ignoring when it was said.
  ///
  /// The live-snapshot feed fires on every `/events` frame, and a frame usually
  /// means something the widget does not show changed (output, a cursor, an
  /// unrelated pane). Comparing first keeps a busy fleet from spending ten
  /// platform-channel round trips a second rewriting the same three numbers.
  bool sameNumbers(ServerCounts? other) =>
      other != null &&
      other.serverName == serverName &&
      other.needsYou == needsYou &&
      other.working == working &&
      other.done == done &&
      other.total == total &&
      other.lines.length == lines.length &&
      other.lines.indexed.every((e) => lines[e.$1] == e.$2);

  Map<String, dynamic> toJson() => {
    'name': serverName,
    'n': needsYou,
    'w': working,
    'd': done,
    't': total,
    'lines': lines,
    'ts': updatedAt,
  };

  factory ServerCounts.fromJson(Map<String, dynamic> json) => ServerCounts(
    serverName: (json['name'] ?? '').toString(),
    needsYou: _int(json['n']),
    working: _int(json['w']),
    done: _int(json['d']),
    total: _int(json['t']),
    lines: [for (final l in (json['lines'] as List? ?? [])) l.toString()],
    updatedAt: _int(json['ts']),
  );
}

int _int(Object? v) => v is int ? v : int.tryParse('${v ?? ''}') ?? 0;

/// The whole fleet as the widget draws it: the merge of every server's bucket.
class FleetCounts {
  const FleetCounts({
    required this.needsYou,
    required this.working,
    required this.done,
    required this.total,
    required this.servers,
    required this.lines,
    required this.updatedAt,
  });

  static const empty = FleetCounts(
    needsYou: 0,
    working: 0,
    done: 0,
    total: 0,
    servers: 0,
    lines: [],
    updatedAt: 0,
  );

  final int needsYou;
  final int working;
  final int done;
  final int total;

  /// How many servers are paired at all. Zero is the one case the widget must
  /// word differently — "nothing needs you" and "this phone knows about no
  /// bridges" look identical in numbers and mean opposite things.
  final int servers;

  /// The lines the widget lists under the counts, already server-qualified when
  /// more than one server contributes.
  final List<String> lines;

  /// Unix ms of the freshest bucket. Not "now": the widget's honesty depends on
  /// saying how old the newest thing it knows is, and a server the app hasn't
  /// been able to reach contributes its last good numbers, not a blank.
  final int updatedAt;

  /// Merge every bucket into what the widget shows.
  ///
  /// Ordering of [lines] is best-effort: buckets carry their own attention
  /// order but nothing links the ranks across servers, so servers are
  /// interleaved by taking the most urgent line from each in turn. Getting the
  /// global order exactly right would need the agents themselves, which is more
  /// than a 2x2 cell can use.
  factory FleetCounts.merge(Map<String, ServerCounts> buckets) {
    if (buckets.isEmpty) return empty;
    var needsYou = 0;
    var working = 0;
    var done = 0;
    var total = 0;
    var updatedAt = 0;
    for (final b in buckets.values) {
      needsYou += b.needsYou;
      working += b.working;
      done += b.done;
      total += b.total;
      if (b.updatedAt > updatedAt) updatedAt = b.updatedAt;
    }

    final qualify = buckets.length > 1;
    final queues = [
      for (final b in buckets.values)
        [
          for (final l in b.lines)
            qualify && b.serverName.isNotEmpty ? '$l  ·  ${b.serverName}' : l,
        ],
    ];
    final lines = <String>[];
    for (var i = 0; lines.length < kFleetWidgetRows; i++) {
      var drew = false;
      for (final q in queues) {
        if (i >= q.length) continue;
        lines.add(q[i]);
        drew = true;
        if (lines.length == kFleetWidgetRows) break;
      }
      if (!drew) break;
    }

    return FleetCounts(
      needsYou: needsYou,
      working: working,
      done: done,
      total: total,
      servers: buckets.length,
      lines: lines,
      updatedAt: updatedAt,
    );
  }
}

/// Encode the per-server buckets for storage. Kept as one JSON string because
/// the widget store is a flat key/value map of primitives.
String encodeBuckets(Map<String, ServerCounts> buckets) =>
    jsonEncode({for (final e in buckets.entries) e.key: e.value.toJson()});

/// Decode buckets written by [encodeBuckets]. Anything unreadable decodes to an
/// empty map: a corrupt store must cost the widget its numbers, never the app.
Map<String, ServerCounts> decodeBuckets(String? raw) {
  if (raw == null || raw.isEmpty) return {};
  try {
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return {
      for (final e in map.entries)
        e.key: ServerCounts.fromJson(e.value as Map<String, dynamic>),
    };
  } catch (_) {
    return {};
  }
}
