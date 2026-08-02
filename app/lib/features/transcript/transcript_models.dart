/// Plain-Dart models for the `WS /agent-transcript` wire protocol
/// (`docs/CONTRACT-agent-transcript.md`). Hand-written on purpose — no
/// freezed/json_serializable so this feature never needs build_runner.
///
/// Every field falls back to a safe default rather than throwing, so a slightly
/// different frame from a future agent kind can never crash the chat view.
library;

/// The kinds of frame the server sends, one JSON object per line.
enum TranscriptFrameType { hello, entry, backlogComplete, unknown }

TranscriptFrameType _frameType(String? raw) => switch (raw) {
  'hello' => TranscriptFrameType.hello,
  'entry' => TranscriptFrameType.entry,
  'backlog_complete' => TranscriptFrameType.backlogComplete,
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
  });

  final TranscriptFrameType type;
  final HelloFrame? hello;
  final TranscriptEntry? entry;

  /// `entry.live` — false for backlog, true for the live tail.
  final bool live;

  /// `backlog_complete.count`.
  final int count;

  /// `hello.has_more` / `backlog_complete.has_more`.
  final bool hasMore;

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
  });

  final int protocol;
  final String pane;
  final String agentKind;
  final String sessionId;
  final int backlogCount;
  final int total;
  final bool hasMore;

  factory HelloFrame.fromJson(Map<String, dynamic> json) => HelloFrame(
    protocol: _asInt(json['protocol']),
    pane: json['pane'] as String? ?? '',
    agentKind: json['agent_kind'] as String? ?? '',
    sessionId: json['session_id'] as String? ?? '',
    backlogCount: _asInt(json['backlog_count']),
    total: _asInt(json['total']),
    hasMore: json['has_more'] == true,
  );
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
