/// Plain-Dart models for the `WS /agent-transcript` wire protocol
/// (`docs/CONTRACT-agent-transcript.md`). Hand-written on purpose — no
/// freezed/json_serializable so this feature never needs build_runner.
///
/// Every field falls back to a safe default rather than throwing, so a slightly
/// different frame from a future agent kind can never crash the chat view.
library;

/// The kinds of frame the server sends, one JSON object per line.
enum TranscriptFrameType {
  hello,
  entry,
  backlogComplete,
  pageComplete,
  sessionChanged,
  unknown,
}

TranscriptFrameType _frameType(String? raw) => switch (raw) {
  'hello' => TranscriptFrameType.hello,
  'entry' => TranscriptFrameType.entry,
  'backlog_complete' => TranscriptFrameType.backlogComplete,
  'page_complete' => TranscriptFrameType.pageComplete,
  'session_changed' => TranscriptFrameType.sessionChanged,
  _ => TranscriptFrameType.unknown,
};

/// A decoded top-level frame: its [type], plus whichever payload it carries.
/// Only one of [hello]/[entry] is set (per [type]).
class TranscriptFrame {
  const TranscriptFrame({
    required this.type,
    this.hello,
    this.entry,
    this.live = false,
    this.count = 0,
    this.hasMore = false,
    this.oldestLoadedSeq = 0,
    this.hasOlder = false,
    this.fromSessionId = '',
    this.toSessionId = '',
  });

  final TranscriptFrameType type;
  final HelloFrame? hello;
  final TranscriptEntry? entry;

  /// `entry.live` — false for backlog/older pages, true for the live tail.
  final bool live;

  /// `backlog_complete.count`.
  final int count;

  /// `hello.has_more` / `backlog_complete.has_more`.
  final bool hasMore;

  /// `page_complete.oldest_loaded_seq` — the cursor for the next `load_older`.
  final int oldestLoadedSeq;

  /// `page_complete.has_older` — whether there's still more history to page up.
  final bool hasOlder;

  /// `session_changed.from` — the session this socket was following.
  final String fromSessionId;

  /// `session_changed.to` — the session it now follows.
  final String toSessionId;

  factory TranscriptFrame.fromJson(Map<String, dynamic> json) {
    final type = _frameType(json['type'] as String?);
    return switch (type) {
      TranscriptFrameType.hello => TranscriptFrame(
        type: type,
        hello: HelloFrame.fromJson(json),
        hasMore: json['has_more'] == true,
      ),
      TranscriptFrameType.entry => TranscriptFrame(
        type: type,
        live: json['live'] == true,
        entry: json['entry'] is Map
            ? TranscriptEntry.fromJson(
                Map<String, dynamic>.from(json['entry'] as Map),
              )
            : null,
      ),
      TranscriptFrameType.backlogComplete => TranscriptFrame(
        type: type,
        count: _asInt(json['count']),
        hasMore: json['has_more'] == true,
      ),
      TranscriptFrameType.pageComplete => TranscriptFrame(
        type: type,
        oldestLoadedSeq: _asInt(json['oldest_loaded_seq']),
        hasOlder: json['has_older'] == true,
      ),
      TranscriptFrameType.sessionChanged => TranscriptFrame(
        type: type,
        fromSessionId: json['from'] as String? ?? '',
        toSessionId: json['to'] as String? ?? '',
      ),
      TranscriptFrameType.unknown => TranscriptFrame(type: type),
    };
  }
}

/// The one-shot `hello` frame: identity + backlog stats.
class HelloFrame {
  const HelloFrame({
    required this.protocol,
    required this.pane,
    required this.agentKind,
    required this.sessionId,
    required this.backlogCount,
    required this.total,
    required this.hasMore,
    this.oldestLoadedSeq = 0,
    this.hasOlder = false,
    this.subagent = '',
    this.subagents = const [],
  });

  final int protocol;
  final String pane;
  final String agentKind;
  final String sessionId;
  final int backlogCount;
  final int total;
  final bool hasMore;

  /// The `?subagent=` this socket is streaming, or empty for the session's own
  /// transcript. A reconnect can tell from hello alone which conversation it
  /// landed in.
  final String subagent;

  /// The session's complete, FLAT subagent roster — every depth, not just the
  /// children of the conversation on screen (protocol 3). Empty is the norm.
  final List<Subagent> subagents;

  /// Absolute `seq` of the oldest entry in the newest page — the first
  /// `load_older.before_seq` cursor (protocol 2).
  final int oldestLoadedSeq;

  /// Whether entries older than [oldestLoadedSeq] exist (more to page up).
  final bool hasOlder;

  factory HelloFrame.fromJson(Map<String, dynamic> json) => HelloFrame(
    protocol: _asInt(json['protocol']),
    pane: json['pane'] as String? ?? '',
    agentKind: json['agent_kind'] as String? ?? '',
    sessionId: json['session_id'] as String? ?? '',
    backlogCount: _asInt(json['backlog_count']),
    total: _asInt(json['total']),
    hasMore: json['has_more'] == true,
    oldestLoadedSeq: _asInt(json['oldest_loaded_seq']),
    hasOlder: json['has_older'] == true,
    subagent: json['subagent'] as String? ?? '',
    subagents: _subagentsFromJson(json['subagents']),
  );
}

/// One delegated conversation advertised in `hello.subagents`.
///
/// Metadata only — enough to draw a row without opening the child transcript.
class Subagent {
  const Subagent({
    required this.agentId,
    required this.toolUseId,
    required this.agentType,
    required this.description,
    required this.spawnDepth,
    this.done = false,
    this.lastActivityTs,
  });

  /// Handle to stream this conversation — passed back as `?subagent=`.
  final String agentId;

  /// The Task call that spawned it. Equals the [ToolCall.id] of that call in
  /// whichever transcript is on screen, which is how a row finds its child.
  final String toolUseId;

  final String agentType;
  final String description;

  /// 1 for a child of the session, 2 for a child of a subagent. Display only —
  /// [SubagentRoster.forToolUse] rebuilds the tree without it.
  final int spawnDepth;

  /// The parent has been told this agent finished.
  ///
  /// The spawning Task call's result cannot answer this: an async agent's call
  /// returns within seconds while the child runs on for minutes. Absent (an
  /// older bridge) reads as running, because hiding a live agent is the worse
  /// failure.
  final bool done;

  /// When this conversation last wrote, in unix milliseconds. Null is unknown,
  /// never "just now".
  final int? lastActivityTs;

  bool get running => !done;

  factory Subagent.fromJson(Map<String, dynamic> json) => Subagent(
    agentId: json['agent_id'] as String? ?? '',
    toolUseId: json['tool_use_id'] as String? ?? '',
    agentType: json['agent_type'] as String? ?? '',
    description: json['description'] as String? ?? '',
    spawnDepth: _asInt(json['spawn_depth']),
    done: json['done'] == true,
    lastActivityTs: json['last_activity_ts'] == null
        ? null
        : _asInt(json['last_activity_ts']),
  );

  /// How long since this subagent wrote, or null when the bridge could not date
  /// it. Mirrors Agent.sinceLastActivity — render nothing rather than "0s".
  Duration? get sinceLastActivity {
    final ts = lastActivityTs;
    if (ts == null || ts <= 0) return null;
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ts));
    return d.isNegative ? Duration.zero : d;
  }

  /// The primary label for a row, falling back to the type when a subagent was
  /// spawned without a description.
  String get displayTitle => description.isNotEmpty ? description : agentType;
}

List<Subagent> _subagentsFromJson(Object? raw) {
  if (raw is! List) return const [];
  return [
    for (final e in raw)
      if (e is Map<String, dynamic>) Subagent.fromJson(e),
  ];
}

/// The session's roster, indexed by the tool call that spawned each entry.
///
/// One roster serves every depth: a subagent's own children are found by
/// matching their [Subagent.toolUseId] against the tool ids of the transcript
/// currently rendered, so drilling down needs no further round trip.
class SubagentRoster {
  SubagentRoster(List<Subagent> entries)
    : _byToolUse = {for (final s in entries) s.toolUseId: s};

  const SubagentRoster.empty() : _byToolUse = const {};

  final Map<String, Subagent> _byToolUse;

  bool get isEmpty => _byToolUse.isEmpty;

  /// The subagent a tool call spawned, or null when it spawned none.
  Subagent? forToolUse(String toolUseId) => _byToolUse[toolUseId];
}

/// The high-level shape of an entry, used to switch rendering.
enum EntryKind { message, thinking, toolCall, toolResult, attachment, unknown }

EntryKind _entryKind(String? raw) => switch (raw) {
  'message' => EntryKind.message,
  'thinking' => EntryKind.thinking,
  'tool_call' => EntryKind.toolCall,
  'tool_result' => EntryKind.toolResult,
  'attachment' => EntryKind.attachment,
  _ => EntryKind.unknown,
};

/// Who authored the entry.
enum EntryRole { user, assistant, system, unknown }

EntryRole _entryRole(String? raw) => switch (raw) {
  'user' => EntryRole.user,
  'assistant' => EntryRole.assistant,
  'system' => EntryRole.system,
  _ => EntryRole.unknown,
};

/// One normalized transcript entry. A single source line can expand into
/// several of these, so [id] is unique but [seq] is the thing to order and
/// de-dupe on (1-based monotonic across backlog + live).
class TranscriptEntry {
  const TranscriptEntry({
    required this.id,
    this.parentId,
    required this.seq,
    this.ts,
    required this.roleRaw,
    required this.kindRaw,
    this.text,
    this.tool,
    this.result,
    required this.parsed,
  });

  final String id;
  final String? parentId;
  final int seq;
  final String? ts;

  /// Raw strings kept alongside the parsed enums so a `parsed:false` entry from
  /// an unknown kind can still be shown minimally.
  final String roleRaw;
  final String kindRaw;

  final String? text;
  final ToolCall? tool;
  final ToolResult? result;
  final bool parsed;

  EntryRole get role => _entryRole(roleRaw);
  EntryKind get kind => _entryKind(kindRaw);

  /// When the agent wrote this entry, or null when the source line carried no
  /// timestamp.
  DateTime? get at {
    final raw = ts;
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toLocal();
  }

  factory TranscriptEntry.fromJson(Map<String, dynamic> json) {
    return TranscriptEntry(
      id: json['id'] as String? ?? '',
      parentId: json['parent_id'] as String?,
      seq: _asInt(json['seq']),
      ts: json['ts'] as String?,
      roleRaw: json['role'] as String? ?? '',
      kindRaw: json['kind'] as String? ?? '',
      text: json['text'] as String?,
      tool: json['tool'] is Map
          ? ToolCall.fromJson(Map<String, dynamic>.from(json['tool'] as Map))
          : null,
      result: json['result'] is Map
          ? ToolResult.fromJson(
              Map<String, dynamic>.from(json['result'] as Map),
            )
          : null,
      parsed: json['parsed'] != false, // default true; only false when stated
    );
  }
}

/// The `tool` object on a `tool_call` entry. Correlate with its result via
/// [id] == [ToolResult.forId].
class ToolCall {
  const ToolCall({
    required this.id,
    required this.name,
    this.title,
    this.subtitle,
    this.command,
    this.file,
    this.diff,
    this.diffTruncated = false,
    this.inputSummary,
  });

  final String id;
  final String name;
  final String? title;
  final String? subtitle;
  final String? command;
  final String? file;
  final String? diff;
  final bool diffTruncated;
  final String? inputSummary;

  factory ToolCall.fromJson(Map<String, dynamic> json) => ToolCall(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    title: json['title'] as String?,
    subtitle: json['subtitle'] as String?,
    command: json['command'] as String?,
    file: json['file'] as String?,
    diff: json['diff'] as String?,
    diffTruncated: json['diff_truncated'] == true,
    inputSummary: json['input_summary'] as String?,
  );
}

/// The `result` object on a `tool_result` entry.
class ToolResult {
  const ToolResult({
    required this.forId,
    required this.ok,
    this.outputSummary,
    this.diff,
    this.truncated = false,
  });

  final String forId;
  final bool ok;
  final String? outputSummary;
  final String? diff;
  final bool truncated;

  factory ToolResult.fromJson(Map<String, dynamic> json) => ToolResult(
    forId: json['for_id'] as String? ?? '',
    ok: json['ok'] != false, // absent ⇒ treat as ok
    outputSummary: json['output_summary'] as String?,
    diff: json['diff'] as String?,
    truncated: json['truncated'] == true,
  );
}

/// Tolerant int coercion — the wire is JSON so numbers arrive as [num], but a
/// stringified number shouldn't break parsing either.
int _asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}
