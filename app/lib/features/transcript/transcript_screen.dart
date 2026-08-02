import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/connection/connection.dart';
import '../../core/theme.dart';
import '../../data/bridge/bridge_client.dart';
import '../../data/bridge/bridge_providers.dart';
import '../../data/bridge/models/snapshot.dart';
import '../inbox/inbox_providers.dart';
import 'transcript_models.dart';

/// Where the transcript socket is in its lifecycle, for the app-bar dot.
enum _Conn { connecting, connected, disconnected, closed, failed }

/// The chat view for an agent pane — a phone-native rendering of the agent's
/// conversation over `WS /agent-transcript`.
///
/// This is the readable alternative to the raw PTY [TerminalScreen]. It manages
/// its own WebSocket (mirroring the terminal's connect/reconnect/dispose
/// lifecycle): a text-JSON stream of a `hello` frame, the ordered backlog, a
/// `backlog_complete` boundary, then the live tail. Entries are ordered and
/// de-duped on `seq`; a `tool_call` is merged with its `tool_result`
/// (correlated on `tool.id == result.for_id`) into one tool card. A permanent
/// pre-upgrade error (e.g. codex/opencode → 404 "transcript not supported")
/// shows a message instead of reconnecting forever.
class TranscriptScreen extends ConsumerStatefulWidget {
  const TranscriptScreen({super.key, required this.pane});

  final String pane;

  @override
  ConsumerState<TranscriptScreen> createState() => _TranscriptScreenState();
}

class _TranscriptScreenState extends ConsumerState<TranscriptScreen> {
  final ScrollController _scroll = ScrollController();
  final TextEditingController _composer = TextEditingController();

  BridgeClient? _client;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _reconnectTimer;
  int _attempts = 0;
  bool _disposed = false;
  _Conn _conn = _Conn.connecting;

  /// Entries by `seq` — the de-dupe key. [_ordered] is the seq-sorted view we
  /// render from, rebuilt when the set changes.
  final Map<int, TranscriptEntry> _bySeq = {};
  List<TranscriptEntry> _ordered = const [];

  /// Applied/observed tool results, keyed by the `tool.id` they answer, so a
  /// tool card can find its result no matter the arrival order.
  final Map<String, ToolResult> _resultsByForId = {};

  bool _backlogComplete = false;
  bool _sawBacklogComplete = false; // latched: don't re-spin on reconnect
  bool _pinnedToBottom = true;

  /// A permanent, non-retryable failure (bad token, unsupported kind, …).
  String? _failure;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _sub?.cancel();
    _channel?.sink.close(ws_status.normalClosure);
    _scroll.dispose();
    _composer.dispose();
    super.dispose();
  }

  /// Send the composer's text to the pane as input. The submit key is a carriage
  /// return (`\r`) — that's what a terminal sends for Enter; a line feed (`\n`)
  /// only inserts a newline in the agent's input box without submitting. An
  /// empty send is a bare Enter, which accepts a blocked agent's default prompt
  /// (one-tap "yes"). What you send reappears in the transcript via the live
  /// tail once the agent records it.
  Future<void> _sendComposer() async {
    final client = _client;
    if (client == null) return;
    final text = _composer.text;
    _composer.clear();
    try {
      await client.sendText(widget.pane, '$text\r');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e is BridgeException ? e.message : '$e')),
      );
    }
  }

  /// The `wss?://…/agent-transcript?pane=&token=` URL, derived from the
  /// connection's base URL exactly like the terminal's `/attach` (WS clients
  /// can't set an `Authorization` header, so the bearer rides in `?token=`).
  Uri _transcriptUri(Connection c) {
    final base = Uri.parse(c.baseUrl);
    return Uri(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: '/agent-transcript',
      queryParameters: {'pane': widget.pane, 'token': c.bearer},
    );
  }

  Future<void> _connect() async {
    final client = _client;
    if (client == null || _disposed) return;

    if (mounted) {
      setState(() {
        _conn = _Conn.connecting;
        _failure = null;
      });
    }

    try {
      final channel = WebSocketChannel.connect(
        _transcriptUri(client.connection),
      );
      _channel = channel;
      await channel.ready; // throws on a failed handshake (bad token, 404, …)
      if (_disposed) {
        channel.sink.close(ws_status.normalClosure);
        return;
      }
      _attempts = 0;
      if (mounted) setState(() => _conn = _Conn.connected);

      _sub = channel.stream.listen(
        _onMessage,
        onDone: _handleDrop,
        onError: (_) => _handleDrop(),
        cancelOnError: true,
      );
    } catch (e) {
      // A pre-upgrade HTTP error (401/404/500/502) means the socket never
      // opened. Some of these are permanent — don't reconnect into them.
      final permanent = _permanentFailureMessage(e);
      if (permanent != null) {
        if (mounted) {
          setState(() {
            _failure = permanent;
            _conn = _Conn.failed;
          });
        }
        return;
      }
      _handleDrop();
    }
  }

  /// Feed one WS text frame (or a newline-batched clump of them) into the
  /// model. Frames are text JSON, one object per line.
  void _onMessage(dynamic message) {
    if (message is! String) return; // the contract is text-only
    var touched = false;
    for (final line in const LineSplitter().convert(message)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      Map<String, dynamic> json;
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is! Map) continue;
        json = Map<String, dynamic>.from(decoded);
      } catch (_) {
        continue; // a malformed line shouldn't sink the stream
      }
      touched = _ingest(TranscriptFrame.fromJson(json)) || touched;
    }
    if (touched && mounted) {
      setState(_rebuildOrdered);
      _maybeAutoScroll();
    }
  }

  /// Apply one decoded frame. Returns true when it changed what we render.
  bool _ingest(TranscriptFrame frame) {
    switch (frame.type) {
      case TranscriptFrameType.hello:
        return false;
      case TranscriptFrameType.backlogComplete:
        if (_sawBacklogComplete) return false;
        _backlogComplete = true;
        _sawBacklogComplete = true;
        _pinnedToBottom = true; // jump to the live tail once backlog lands
        return true;
      case TranscriptFrameType.entry:
        final entry = frame.entry;
        if (entry == null || entry.seq <= 0) return false;
        if (entry.kind == EntryKind.toolResult && entry.result != null) {
          _resultsByForId[entry.result!.forId] = entry.result!;
        }
        if (_bySeq.containsKey(entry.seq)) return false; // de-dupe on seq
        _bySeq[entry.seq] = entry;
        return true;
      case TranscriptFrameType.unknown:
        return false;
    }
  }

  void _rebuildOrdered() {
    final list = _bySeq.values.toList()..sort((a, b) => a.seq.compareTo(b.seq));
    _ordered = list;
  }

  /// Socket closed or failed to open (a transient drop). Mirror the terminal:
  /// check whether the pane still exists before reconnecting so a closed pane
  /// or a finished agent stops the loop instead of retrying forever.
  void _handleDrop() {
    if (_disposed) return;
    _sub?.cancel();
    _sub = null;
    _channel = null;
    if (mounted) setState(() => _conn = _Conn.disconnected);
    _attempts++;
    unawaited(_checkGoneThenReconnect());
  }

  Future<void> _checkGoneThenReconnect() async {
    final client = _client;
    if (client == null || _disposed) return;
    ref.read(snapshotControllerProvider.notifier).refresh();

    bool gone = false;
    try {
      final snap = await client.getSnapshot();
      gone = !snap.panes.any((p) => p.paneId == widget.pane) &&
          !snap.agents.any((a) => a.paneId == widget.pane);
    } catch (_) {
      gone = false; // couldn't check → treat as transient, keep retrying
    }
    if (_disposed) return;

    if (gone) {
      _reconnectTimer?.cancel();
      if (mounted) setState(() => _conn = _Conn.closed);
      return;
    }

    final delay = Duration(seconds: _attempts.clamp(1, 8));
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, _connect);
  }

  /// Map a pre-upgrade handshake error to a human message when it's permanent
  /// (so we stop retrying); returns null for a transient drop worth retrying.
  String? _permanentFailureMessage(Object error) {
    final text = error.toString();
    final code = RegExp(r'\b(4\d\d|5\d\d)\b').firstMatch(text)?.group(1);
    return switch (code) {
      '401' || '403' =>
        'Not authorized for this transcript. The bearer token was rejected.',
      '404' =>
        "No transcript for this pane. This agent kind may not support a chat "
            "view yet — open the raw terminal instead.",
      '500' => 'The bridge failed to read the transcript for this pane.',
      _ => null, // 502 and unknown errors: transient, let the reconnect retry
    };
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final pinned = pos.pixels >= pos.maxScrollExtent - 80;
    if (pinned != _pinnedToBottom) {
      setState(() => _pinnedToBottom = pinned);
    }
  }

  /// Keep the view pinned to the newest entry unless the user scrolled up.
  void _maybeAutoScroll() {
    if (!_pinnedToBottom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  void _jumpToBottom() {
    setState(() => _pinnedToBottom = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    // Connect once a bridge client resolves, and re-target if it changes.
    final client = ref.watch(bridgeClientProvider);
    if (client != null && !identical(client, _client)) {
      _client = client;
      _reconnectTimer?.cancel();
      _sub?.cancel();
      _sub = null;
      _channel?.sink.close(ws_status.normalClosure);
      _attempts = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) => _connect());
    }

    final agents =
        ref.watch(snapshotControllerProvider).asData?.value.agents ??
        const <Agent>[];
    Agent? agent;
    for (final a in agents) {
      if (a.paneId == widget.pane) {
        agent = a;
        break;
      }
    }

    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(agent?.displayTitle ?? widget.pane),
        actions: [
          IconButton(
            tooltip: 'Raw terminal',
            onPressed: () => context.push(
              '/terminal/${Uri.encodeComponent(widget.pane)}',
            ),
            icon: const Icon(Icons.terminal),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12, left: 4),
            child: Tooltip(
              message: switch (_conn) {
                _Conn.connected => 'Live',
                _Conn.connecting => 'Connecting…',
                _Conn.disconnected => 'Reconnecting…',
                _Conn.closed => 'Closed',
                _Conn.failed => 'Unavailable',
              },
              child: Icon(
                _conn == _Conn.connected
                    ? Icons.circle
                    : Icons.circle_outlined,
                size: 12,
                color: switch (_conn) {
                  _Conn.connected => scheme.primary,
                  _Conn.connecting => scheme.onSurfaceVariant,
                  _Conn.disconnected => scheme.error,
                  _Conn.closed => scheme.onSurfaceVariant,
                  _Conn.failed => scheme.error,
                },
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(child: _buildBody(scheme)),
                  if (!_pinnedToBottom && _ordered.isNotEmpty)
                    Positioned(
                      right: 16,
                      bottom: 16,
                      child: FloatingActionButton.small(
                        onPressed: _jumpToBottom,
                        child: const Icon(Icons.arrow_downward),
                      ),
                    ),
                ],
              ),
            ),
            // Talk to the agent right from the chat — no need to drop to the raw
            // terminal. Disabled once the pane is gone/unavailable.
            _ComposerBar(
              controller: _composer,
              onSend: _sendComposer,
              enabled: _conn != _Conn.closed &&
                  _conn != _Conn.failed &&
                  _failure == null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    if (_failure != null) {
      return _CenteredNotice(
        icon: Icons.chat_bubble_outline,
        title: 'Transcript unavailable',
        message: _failure!,
        onTerminal: () =>
            context.push('/terminal/${Uri.encodeComponent(widget.pane)}'),
      );
    }
    if (_conn == _Conn.closed) {
      return _CenteredNotice(
        icon: Icons.tab_unselected,
        title: 'This pane was closed',
        message:
            'It was closed on the host or the agent finished. The conversation '
            'above is the last we received.',
        onTerminal: () =>
            context.push('/terminal/${Uri.encodeComponent(widget.pane)}'),
      );
    }
    if (!_backlogComplete) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_ordered.isEmpty) {
      return const _CenteredNotice(
        icon: Icons.chat_bubble_outline,
        title: 'Nothing here yet',
        message: 'No conversation entries for this pane.',
      );
    }

    // Skip standalone tool_result entries — they render inside their call.
    final visible = _ordered
        .where((e) => e.kind != EntryKind.toolResult)
        .toList(growable: false);

    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      itemCount: visible.length,
      itemBuilder: (context, i) {
        final entry = visible[i];
        return _EntryTile(
          entry: entry,
          result: entry.tool != null
              ? _resultsByForId[entry.tool!.id]
              : null,
        );
      },
    );
  }
}

/// Dispatches one entry to the right bubble/card by kind.
/// The bottom input bar — type a prompt (or an option number for a blocked
/// prompt) and send it to the agent. The send button submits with a trailing
/// newline; an empty send is a bare Enter (accepts a default prompt).
class _ComposerBar extends StatelessWidget {
  const _ComposerBar({
    required this.controller,
    required this.onSend,
    required this.enabled,
  });

  final TextEditingController controller;
  final Future<void> Function() onSend;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surfaceContainerHigh,
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              enabled: enabled,
              minLines: 1,
              maxLines: 5,
              keyboardType: TextInputType.multiline,
              decoration: InputDecoration(
                hintText: enabled ? 'Message the agent…' : 'Unavailable',
                filled: true,
                fillColor: scheme.surface,
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(22),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          IconButton.filled(
            tooltip: 'Send',
            onPressed: enabled ? onSend : null,
            icon: const Icon(Icons.send, size: 20),
          ),
        ],
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry, this.result});

  final TranscriptEntry entry;
  final ToolResult? result;

  @override
  Widget build(BuildContext context) {
    if (!entry.parsed && entry.kind == EntryKind.unknown) {
      return _RawEntry(entry: entry);
    }
    return switch (entry.kind) {
      EntryKind.message => _MessageBubble(entry: entry),
      EntryKind.thinking => _ThinkingBlock(entry: entry),
      EntryKind.toolCall => _ToolCard(entry: entry, result: result),
      EntryKind.attachment => _AttachmentChip(entry: entry),
      EntryKind.toolResult => const SizedBox.shrink(), // handled by its call
      EntryKind.unknown => _RawEntry(entry: entry),
    };
  }
}

/// User / assistant / system message — distinct alignment and tint per role.
class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.entry});

  final TranscriptEntry entry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = entry.text ?? '';
    final role = entry.role;

    if (role == EntryRole.system) {
      // System notes read as a centered, muted aside — not a chat party.
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        child: Center(
          child: SelectableText(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 12.5,
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
      );
    }

    final isUser = role == EntryRole.user;
    final bg = isUser ? scheme.primaryContainer : scheme.surfaceContainerHigh;
    final fg = isUser ? scheme.onPrimaryContainer : scheme.onSurface;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.86,
        ),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isUser ? 16 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 16),
          ),
        ),
        child: _ExpandableMarkdown(text: text, fg: fg, isUser: isUser),
      ),
    );
  }
}

/// A markdown body that collapses a long message to a preview — only the
/// preview is parsed and laid out until you expand it, so one huge reply can't
/// stall the scroll. Short messages render in full with no toggle.
class _ExpandableMarkdown extends StatefulWidget {
  const _ExpandableMarkdown({
    required this.text,
    required this.fg,
    required this.isUser,
  });

  final String text;
  final Color fg;
  final bool isUser;

  @override
  State<_ExpandableMarkdown> createState() => _ExpandableMarkdownState();
}

class _ExpandableMarkdownState extends State<_ExpandableMarkdown> {
  bool _expanded = false;
  static const _previewLines = 24;
  static const _maxChars = 1800;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = widget.fg;
    final text = widget.text;
    final lineCount = '\n'.allMatches(text).length + 1;
    final canCollapse = lineCount > _previewLines || text.length > _maxChars;

    var shown = text;
    if (canCollapse && !_expanded) {
      shown = text.split('\n').take(_previewLines).join('\n');
      if (shown.length > _maxChars) shown = shown.substring(0, _maxChars);
      shown = '$shown\n…';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        MarkdownBody(
          data: shown,
          selectable: true,
          fitContent: true,
          styleSheet: MarkdownStyleSheet(
            p: TextStyle(color: fg, fontSize: 14, height: 1.35),
            a: TextStyle(
              color: widget.isUser ? fg : scheme.primary,
              decoration: TextDecoration.underline,
            ),
            code: TextStyle(
              color: fg,
              fontFamily: AppTheme.monoFamily,
              fontSize: 12.5,
              backgroundColor: scheme.surface.withValues(alpha: 0.5),
            ),
            codeblockPadding: const EdgeInsets.all(10),
            codeblockDecoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(8),
            ),
            blockquoteDecoration: BoxDecoration(
              color: scheme.surface.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(6),
            ),
            listBullet: TextStyle(color: fg, fontSize: 14, height: 1.35),
            h1: TextStyle(color: fg, fontSize: 18, fontWeight: FontWeight.w700),
            h2: TextStyle(color: fg, fontSize: 16, fontWeight: FontWeight.w700),
            h3: TextStyle(color: fg, fontSize: 15, fontWeight: FontWeight.w700),
          ),
        ),
        if (canCollapse)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Text(
                _expanded ? 'Show less' : 'Show more',
                style: TextStyle(
                  color: widget.isUser ? fg : scheme.primary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Assistant reasoning — muted, italic, collapsed by default (it's secondary).
class _ThinkingBlock extends StatefulWidget {
  const _ThinkingBlock({required this.entry});

  final TranscriptEntry entry;

  @override
  State<_ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<_ThinkingBlock> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = widget.entry.text ?? '';
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.86,
        ),
        margin: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.psychology_outlined,
                      size: 15,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Thinking',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12.5,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
            if (_expanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 2, 8, 4),
                child: SelectableText(
                  text,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 13,
                    height: 1.35,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A `tool_call` merged with its `tool_result`: header (icon + label + ok/fail
/// chip) and an expandable body with the output summary and a tinted mini-diff.
class _ToolCard extends StatefulWidget {
  const _ToolCard({required this.entry, this.result});

  final TranscriptEntry entry;
  final ToolResult? result;

  @override
  State<_ToolCard> createState() => _ToolCardState();
}

class _ToolCardState extends State<_ToolCard> {
  bool _expanded = false;

  IconData _iconFor(String name) {
    switch (name.toLowerCase()) {
      case 'bash':
        return Icons.terminal;
      case 'edit':
      case 'write':
      case 'multiedit':
      case 'notebookedit':
        return Icons.edit_outlined;
      case 'read':
        return Icons.description_outlined;
      case 'webfetch':
      case 'websearch':
        return Icons.public;
      case 'grep':
      case 'glob':
        return Icons.search;
      case 'task':
        return Icons.smart_toy_outlined;
      default:
        return Icons.build_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tool = widget.entry.tool;
    final result = widget.result;
    if (tool == null) return const SizedBox.shrink();

    // The primary label under the header: a command / subtitle / file, mono.
    final mono = tool.command ?? tool.subtitle ?? tool.file ??
        tool.inputSummary;
    // The applied diff (on the result) is authoritative over the preview.
    final diff = result?.diff ?? tool.diff;
    final output = result?.outputSummary;
    final hasBody = (diff != null && diff.isNotEmpty) ||
        (output != null && output.isNotEmpty);
    final truncated = (result?.truncated ?? false) || tool.diffTruncated;

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.92,
        ),
        margin: const EdgeInsets.symmetric(vertical: 5),
        decoration: BoxDecoration(
          color: scheme.surfaceContainer,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.4)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: hasBody ? () => setState(() => _expanded = !_expanded) : null,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      _iconFor(tool.name),
                      size: 18,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                tool.title?.isNotEmpty == true
                                    ? tool.title!
                                    : tool.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                ),
                              ),
                              if (tool.file != null) ...[
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    tool.file!,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontFamily: AppTheme.monoFamily,
                                      fontSize: 12,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          if (mono != null && mono.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              mono,
                              maxLines: _expanded ? 6 : 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: AppTheme.monoFamily,
                                fontSize: 12,
                                height: 1.3,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    _ResultChip(result: result),
                    if (hasBody)
                      Icon(
                        _expanded ? Icons.expand_less : Icons.expand_more,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      ),
                  ],
                ),
              ),
            ),
            if (_expanded && hasBody)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (diff != null && diff.isNotEmpty)
                      _MiniDiff(diff: diff),
                    if (output != null && output.isNotEmpty) ...[
                      if (diff != null && diff.isNotEmpty)
                        const SizedBox(height: 8),
                      _OutputBlock(text: output),
                    ],
                    if (truncated)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          '… truncated',
                          style: TextStyle(
                            fontSize: 11,
                            fontStyle: FontStyle.italic,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// An ok / fail pill from the tool result. Absent while a live call has no
/// result yet — that reads as "still running".
class _ResultChip extends StatelessWidget {
  const _ResultChip({this.result});

  final ToolResult? result;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (result == null) {
      return SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: scheme.onSurfaceVariant,
        ),
      );
    }
    final ok = result!.ok;
    final green = const Color(0xFF00C853);
    final color = ok ? green : scheme.error;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            ok ? Icons.check_circle : Icons.error_outline,
            size: 13,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            ok ? 'ok' : 'fail',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// A unified diff rendered in mono, with `+` lines tinted green and `-` red.
class _MiniDiff extends StatelessWidget {
  const _MiniDiff({required this.diff});

  final String diff;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final addBg = (dark ? const Color(0xFF1B5E20) : const Color(0xFFA5D6A7))
        .withValues(alpha: dark ? 0.28 : 0.5);
    final delBg = (dark ? const Color(0xFFB71C1C) : const Color(0xFFEF9A9A))
        .withValues(alpha: dark ? 0.28 : 0.5);
    final lines = const LineSplitter().convert(diff);

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final line in lines)
              _diffLine(line, scheme, addBg, delBg),
          ],
        ),
      ),
    );
  }

  Widget _diffLine(String line, ColorScheme scheme, Color addBg, Color delBg) {
    Color? bg;
    Color fg = scheme.onSurface;
    if (line.startsWith('+') && !line.startsWith('+++')) {
      bg = addBg;
    } else if (line.startsWith('-') && !line.startsWith('---')) {
      bg = delBg;
    } else if (line.startsWith('@@')) {
      fg = scheme.primary;
    } else {
      fg = scheme.onSurfaceVariant;
    }
    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Text(
        line.isEmpty ? ' ' : line,
        style: TextStyle(
          fontFamily: AppTheme.monoFamily,
          fontSize: 11.5,
          height: 1.4,
          color: fg,
        ),
      ),
    );
  }
}

/// Plain textual tool output (stdout / content), mono, horizontally scrollable.
class _OutputBlock extends StatelessWidget {
  const _OutputBlock({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SelectableText(
          text,
          style: TextStyle(
            fontFamily: AppTheme.monoFamily,
            fontSize: 11.5,
            height: 1.4,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// A small chip for an attachment entry (`[image]`, a file, …).
class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({required this.entry});

  final TranscriptEntry entry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = (entry.text != null && entry.text!.isNotEmpty)
        ? entry.text!
        : '[attachment]';
    final isUser = entry.role == EntryRole.user;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.attachment, size: 15, color: scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// A `parsed:false` / unknown entry — show role + kind + text minimally so
/// nothing silently vanishes.
class _RawEntry extends StatelessWidget {
  const _RawEntry({required this.entry});

  final TranscriptEntry entry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final head = [entry.roleRaw, entry.kindRaw]
        .where((s) => s.isNotEmpty)
        .join(' · ');
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (head.isNotEmpty)
            Text(
              head,
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          if (entry.text != null && entry.text!.isNotEmpty) ...[
            const SizedBox(height: 4),
            SelectableText(
              entry.text!,
              style: const TextStyle(fontSize: 13, height: 1.35),
            ),
          ],
        ],
      ),
    );
  }
}

/// A full-screen centered notice (error / empty / closed states) with an
/// optional jump to the raw terminal.
class _CenteredNotice extends StatelessWidget {
  const _CenteredNotice({
    required this.icon,
    required this.title,
    required this.message,
    this.onTerminal,
  });

  final IconData icon;
  final String title;
  final String message;
  final VoidCallback? onTerminal;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
            if (onTerminal != null) ...[
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: onTerminal,
                icon: const Icon(Icons.terminal, size: 18),
                label: const Text('Open raw terminal'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
