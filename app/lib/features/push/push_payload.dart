import 'dart:convert';

/// Values of the `render` payload key (mirrors `internal/server/notify.go`).
/// Every alert is sent twice — once in a shape Android renders unaided, once in
/// a shape this app can redraw with actions — and this says which is which.
const renderOS = 'os';
const renderApp = 'app';

/// One selectable choice from a blocked agent's prompt, as carried in a push.
class PushOption {
  const PushOption({
    required this.index,
    required this.label,
    required this.selected,
    required this.key,
  });

  /// 1-based menu number, or 0 for a choice reachable only via [key].
  final int index;
  final String label;

  /// The highlighted default — what a bare Approve accepts.
  final bool selected;

  /// Raw keystroke for an unnumbered choice (e.g. `esc` to decline).
  final String key;

  static List<PushOption> decode(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return list.whereType<Map<String, dynamic>>().map((o) {
        return PushOption(
          index: (o['index'] as num?)?.toInt() ?? 0,
          label: ((o['label'] as String?) ?? '').trim(),
          selected: o['selected'] == true,
          key: ((o['key'] as String?) ?? '').trim(),
        );
      }).toList();
    } catch (_) {
      return const [];
    }
  }
}

/// A gothalo push, parsed out of FCM's untyped `data` map.
///
/// Every field the app needs to act — which bridge, which pane, which state, at
/// which `seq` — travels in the payload rather than being inferred from app
/// state, because a push is handled in a background isolate that has no active
/// server, no snapshot, and possibly no UI at all.
class PushPayload {
  const PushPayload({
    required this.type,
    required this.serverId,
    required this.serverName,
    required this.pane,
    required this.status,
    required this.agentTitle,
    required this.title,
    required this.body,
    required this.question,
    required this.category,
    required this.seq,
    required this.options,
    required this.render,
  });

  final String type; // "alert" | "dismiss"
  final String serverId;
  final String serverName;

  /// The (possibly session-qualified) pane id — the deep-link target.
  final String pane;
  final String status; // "blocked" | "done"
  final String agentTitle;
  final String title;
  final String body;

  /// What the agent is actually asking, when the bridge could read it.
  final String question;

  /// Herdr's semantic class for the block, e.g. `dangerous_command_approval`.
  final String category;

  /// The agent's `state_change_seq` at the transition. Echoed back to
  /// `POST /approve`, which no-ops if the agent has since moved past it — the
  /// guard that makes approving from a stale notification safe.
  final int? seq;

  final List<PushOption> options;

  factory PushPayload.from(Map<String, dynamic> data) {
    String s(String k) => ((data[k] as String?) ?? '').trim();
    return PushPayload(
      type: s('type').isEmpty ? 'alert' : s('type'),
      serverId: s('server_id'),
      serverName: s('server_name'),
      pane: s('agent'),
      status: s('status'),
      agentTitle: s('agent_title'),
      title: s('title'),
      body: s('body'),
      question: s('question'),
      category: s('category'),
      seq: int.tryParse(s('state_change_seq')),
      options: PushOption.decode(data['options'] as String?),
      render: s('render'),
    );
  }

  /// Which of the alert pair this is: `os` for the notification-bearing message
  /// Android draws by itself, `app` for the data-only twin this code redraws
  /// with action buttons. Empty on a dismiss.
  final String render;

  bool get isDismiss => type == 'dismiss';
  bool get isBlocked => status == 'blocked';

  /// True for the message Android already drew. The app must not render it (it
  /// would duplicate) and must not log it (the twin does that) — it exists only
  /// so something appears when this process can't run at all.
  bool get isOsRendered => render == renderOS;

  /// Identity of the *subject* — one server's pane. The bridge sets the same
  /// value as the FCM notification tag, so the notification the app renders
  /// replaces the one Android rendered from the payload rather than duplicating
  /// it, and a later dismiss can cancel exactly that one.
  String get tag => '$serverId/$pane';

  /// The choice a bare "Approve" would accept, if the prompt named one.
  PushOption? get defaultOption {
    for (final o in options) {
      if (o.selected) return o;
    }
    return null;
  }

  /// The choice that declines: an explicit keystroke option (Claude's
  /// "esc to cancel") or, failing that, a numbered choice that isn't the
  /// default. Null when the prompt offers no way to say no.
  PushOption? get declineOption {
    for (final o in options) {
      if (o.key.isNotEmpty) return o;
    }
    for (final o in options) {
      if (!o.selected && o.index > 0) return o;
    }
    return null;
  }

  /// Everything a tap or a tray action needs, encoded as the notification's
  /// payload string.
  ///
  /// The choices ride along because an action button fires into a fresh isolate
  /// whose only input is this string: there is no message to re-read and no app
  /// state to consult, so "which keystroke declines this prompt" has to have
  /// been written down at render time.
  String encodeTarget() => jsonEncode({
    'server_id': serverId,
    'pane': pane,
    'seq': seq,
    'options': [
      for (final o in options)
        {
          'index': o.index,
          'label': o.label,
          'selected': o.selected,
          if (o.key.isNotEmpty) 'key': o.key,
        },
    ],
  });
}

/// Where a tapped notification should take the user: a pane on a specific
/// server. Carrying the server is the difference between opening the right
/// agent and opening whatever the app happened to have selected.
class DeepLinkTarget {
  const DeepLinkTarget({
    required this.serverId,
    required this.pane,
    this.seq,
    this.options = const [],
  });

  final String serverId;
  final String pane;
  final int? seq;

  /// The prompt's choices, as captured when the notification was rendered.
  final List<PushOption> options;

  static DeepLinkTarget? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = jsonDecode(raw);
      if (j is! Map<String, dynamic>) return null;
      final pane = ((j['pane'] as String?) ?? '').trim();
      if (pane.isEmpty) return null;
      return DeepLinkTarget(
        serverId: ((j['server_id'] as String?) ?? '').trim(),
        pane: pane,
        seq: (j['seq'] as num?)?.toInt(),
        options: PushOption.decode(jsonEncode(j['options'] ?? const [])),
      );
    } catch (_) {
      // Older notifications carried the bare pane id as their payload.
      return DeepLinkTarget(serverId: '', pane: raw);
    }
  }
}
