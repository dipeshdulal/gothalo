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
/// (correlated on `tool.id == result.for_id`) into one collapsed row, and runs
/// of consecutive tool calls group into an indented ledger under the assistant
/// message. A permanent pre-upgrade error (e.g. codex/opencode → 404
/// "transcript not supported") shows a message instead of reconnecting forever.
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

  /// Pagination cursor (protocol 2): [_oldestSeq] is the oldest seq we hold —
  /// pass it as `load_older.before_seq` to page up; [_hasOlder] gates it.
  int _oldestSeq = 0;
  bool _hasOlder = false;
  bool _loadingOlder = false;

  /// The oldest `seq` of the *first* page — the fixed anchor between "initial +
  /// live" (below the [_centerKey]) and older pages loaded on scroll-up (above
  /// it). Prepending above the center never moves the viewport, so the scroll
  /// holds steady natively.
  int _anchorSeq = 0;
  final _centerKey = GlobalKey();

  /// A permanent, non-retryable failure (bad token, unsupported kind, …).
  String? _failure;

  /// The blocked prompt (question + options), polled from `/agent-state`, shown
  /// as an approval bar while the agent is blocked; null/not-blocked otherwise.
  /// Polling (not the snapshot flag) is the source of truth so the bar clears
  /// the instant the agent unblocks and refreshes for each new prompt.
  AgentState? _agentState;
  Timer? _agentStateTimer;

  /// Messages sent from the composer but not yet echoed back in the transcript
  /// (a busy agent queues them). Shown optimistically so a send is never
  /// invisible; each is dropped when its matching user message arrives.
  final List<String> _pending = [];

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
    _agentStateTimer?.cancel();
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
    final trimmed = text.trim();
    // Show it right away (a busy agent won't echo it until it drains the queue).
    if (trimmed.isNotEmpty) {
      setState(() {
        _pending.add(trimmed);
        _pinnedToBottom = true;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
    }
    try {
      await client.sendText(widget.pane, '$text\r');
    } catch (e) {
      if (!mounted) return;
      // The send failed — drop the optimistic echo and say why.
      setState(() => _pending.remove(trimmed));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e is BridgeException ? e.message : '$e')),
      );
    }
  }

  /// Poll the parsed agent card so the approval bar always reflects the live
  /// blocked state (clears on unblock, refreshes for a new prompt) — independent
  /// of the snapshot, which can lag.
  void _startAgentStatePolling() {
    _agentStateTimer?.cancel();
    _pollAgentState();
    _agentStateTimer = Timer.periodic(
      const Duration(milliseconds: 1500),
      (_) => _pollAgentState(),
    );
  }

  Future<void> _pollAgentState() async {
    final client = _client;
    if (client == null || _disposed) return;
    try {
      final s = await client.getAgentState(widget.pane);
      if (mounted) setState(() => _agentState = s);
    } catch (_) {
      // Non-agent / gone / transient — no bar.
      if (mounted && _agentState != null) setState(() => _agentState = null);
    }
  }

  /// Cycle the Claude permission mode (one Shift+Tab), then refresh the card so
  /// the chip shows the new value.
  Future<void> _cycleMode() async {
    final client = _client;
    if (client == null) return;
    try {
      await client.cycleAgentMode(widget.pane);
      await _pollAgentState();
    } on BridgeException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    }
  }

  /// A short, readable label for a permission mode; unknown values pass through.
  String _modeLabel(String m) => switch (m) {
        'default' => 'manual',
        'acceptEdits' => 'accept edits',
        'plan' => 'plan',
        'auto' => 'auto',
        'bypassPermissions' => 'bypass',
        _ => m,
      };

  /// Act on a tapped option: the highlighted default is a bare Enter (accepts
  /// the default); any other choice types its number. Sent as raw input (`\r`)
  /// so it works even if the snapshot's seq is stale. Optimistically hide the
  /// bar; the next poll confirms.
  void _handleOption(BlockedOption opt) {
    _client?.sendText(widget.pane, opt.selected ? '\r' : '${opt.index}\r');
    setState(() => _agentState = null);
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
        final h = frame.hello;
        if (h != null) {
          _oldestSeq = h.oldestLoadedSeq;
          _hasOlder = h.hasOlder;
          _anchorSeq = h.oldestLoadedSeq; // fix the center at the first page
        }
        return false;
      case TranscriptFrameType.pageComplete:
        if (frame.oldestLoadedSeq > 0) _oldestSeq = frame.oldestLoadedSeq;
        _hasOlder = frame.hasOlder;
        _loadingOlder = false;
        return true;
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
        // A real user message landed → drop its matching optimistic echo.
        if (entry.role == EntryRole.user && entry.kind == EntryKind.message) {
          _pending.remove((entry.text ?? '').trim());
        }
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
    // Near the real top (min extent goes negative once older pages exist) →
    // page up. Relative to minScrollExtent so it fires only at the actual top,
    // not every time the viewport sits near the center anchor.
    if (pos.pixels <= pos.minScrollExtent + 400) _loadOlder();
  }

  /// Request the next older page over the transcript socket (the one inbound
  /// frame `/agent-transcript` accepts). Older entries land *above* the center
  /// anchor, so the viewport holds steady with no scroll math.
  void _loadOlder() {
    final channel = _channel;
    if (_loadingOlder || !_hasOlder || _oldestSeq <= 1 || channel == null) {
      return;
    }
    _loadingOlder = true;
    channel.sink.add(jsonEncode({
      'type': 'load_older',
      'before_seq': _oldestSeq,
      'limit': 150,
    }));
    if (mounted) setState(() {}); // show the top loader
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
      _startAgentStatePolling();
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
          // Claude permission mode: a tap cycles it (Shift+Tab). Shown only when
          // /agent-state reports one (Claude panes).
          if (_agentState?.permissionMode != null)
            Padding(
              padding: const EdgeInsets.only(right: 2),
              child: ActionChip(
                avatar: const Icon(Icons.tune, size: 15),
                label: Text(_modeLabel(_agentState!.permissionMode!)),
                labelStyle: const TextStyle(fontSize: 12),
                visualDensity: VisualDensity.compact,
                onPressed: _cycleMode,
              ),
            ),
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
            // Blocked → show the pending question + options as tappable buttons.
            if (_agentState?.isBlocked == true)
              _ApprovalBar(
                state: _agentState!,
                onOption: _handleOption,
              )
            // Working → a live "thinking…" indicator so the chat feels alive.
            else if (_agentState?.isWorking == true)
              const _ThinkingIndicator(),
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

    // Split at the fixed anchor: the first page onward (+ live tail + pending)
    // renders BELOW the center; older pages loaded on scroll-up render ABOVE it.
    // Prepending above the center never shifts the viewport — no scroll math.
    final belowEntries = <TranscriptEntry>[];
    final aboveEntries = <TranscriptEntry>[];
    for (final e in visible) {
      (e.seq < _anchorSeq ? aboveEntries : belowEntries).add(e);
    }
    // Collapse each run of consecutive tool_calls into one indented ledger, so
    // the chat reads as prose + a compact tool ledger rather than a wall of
    // cards. Grouping happens per-segment; a run that straddles the page anchor
    // just renders as two adjacent ledgers (harmless, and rare).
    final below = _toBlocks(belowEntries);
    final above = _toBlocks(aboveEntries);

    return CustomScrollView(
      controller: _scroll,
      center: _centerKey,
      slivers: [
        // Top spinner while paging up (furthest-up sliver).
        if (_loadingOlder)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          ),
        // Older pages — a before-center sliver lays out upward, so index 0 sits
        // just above the center; feed it newest-first to keep chronological
        // order reading top→bottom.
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) => _blockWidget(above[above.length - 1 - i]),
              childCount: above.length,
            ),
          ),
        ),
        SliverToBoxAdapter(key: _centerKey, child: const SizedBox.shrink()),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) => i < below.length
                  ? _blockWidget(below[i])
                  : _PendingBubble(text: _pending[i - below.length]),
              childCount: below.length + _pending.length,
            ),
          ),
        ),
      ],
    );
  }

  /// Group a flat entry list into render blocks: a run of consecutive
  /// `tool_call` entries becomes one [_ToolGroupBlock]; everything else stays a
  /// standalone [_EntryBlock].
  List<_Block> _toBlocks(List<TranscriptEntry> entries) {
    final blocks = <_Block>[];
    List<TranscriptEntry>? run;
    void flush() {
      if (run != null) {
        blocks.add(_ToolGroupBlock(run!));
        run = null;
      }
    }

    for (final e in entries) {
      if (e.kind == EntryKind.toolCall) {
        (run ??= <TranscriptEntry>[]).add(e);
      } else {
        flush();
        blocks.add(_EntryBlock(e));
      }
    }
    flush();
    return blocks;
  }

  Widget _blockWidget(_Block block) => switch (block) {
        _EntryBlock(:final entry) => _EntryTile(entry: entry),
        _ToolGroupBlock(:final calls) => _ToolLedger(
            calls: calls,
            resultFor: (id) => _resultsByForId[id],
          ),
      };
}

/// A unit of the rendered transcript: either a standalone entry or a grouped
/// run of tool calls.
sealed class _Block {
  const _Block();
}

class _EntryBlock extends _Block {
  const _EntryBlock(this.entry);
  final TranscriptEntry entry;
}

class _ToolGroupBlock extends _Block {
  const _ToolGroupBlock(this.calls);
  final List<TranscriptEntry> calls;
}

/// Dispatches one entry to the right bubble/card by kind.
/// Shown above the composer while the agent is blocked: the pending question and
/// its options as tappable buttons (the default is highlighted). Tapping the
/// default approves via `/approve`; any other option types its number.
class _ApprovalBar extends StatelessWidget {
  const _ApprovalBar({required this.state, required this.onOption});

  final AgentState state;
  final void Function(BlockedOption) onOption;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final maxW = MediaQuery.sizeOf(context).width * 0.82;
    final question = (state.blockedQuestion?.isNotEmpty ?? false)
        ? state.blockedQuestion!
        : (state.headline.isNotEmpty ? state.headline : 'Waiting for you');

    return Container(
      width: double.infinity,
      color: scheme.errorContainer.withValues(alpha: 0.32),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2, right: 8),
                child: Icon(Icons.pan_tool_outlined,
                    size: 15, color: scheme.error),
              ),
              Expanded(
                child: Text(
                  question,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
          if (state.options.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final o in state.options)
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxW),
                    child: o.selected
                        ? FilledButton(
                            onPressed: () => onOption(o),
                            child: Text(o.label,
                                maxLines: 2, overflow: TextOverflow.ellipsis),
                          )
                        : OutlinedButton(
                            onPressed: () => onOption(o),
                            child: Text(o.label,
                                maxLines: 2, overflow: TextOverflow.ellipsis),
                          ),
                  ),
              ],
            ),
          ] else
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Type your answer below.',
                style:
                    TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5),
              ),
            ),
        ],
      ),
    );
  }
}

/// A live "thinking…" indicator shown above the composer while the agent is
/// working — three pulsing dots, like a chat typing indicator.
class _ThinkingIndicator extends StatefulWidget {
  const _ThinkingIndicator();

  @override
  State<_ThinkingIndicator> createState() => _ThinkingIndicatorState();
}

class _ThinkingIndicatorState extends State<_ThinkingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.surfaceContainerHigh,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        children: [
          SizedBox(
            width: 30,
            height: 8,
            child: AnimatedBuilder(
              animation: _c,
              builder: (context, _) => Row(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(3, (i) {
                  // Stagger each dot's pulse so they ripple left-to-right.
                  final t = (_c.value - i * 0.2) % 1.0;
                  final pulse = (1 - (t * 2 - 1).abs()).clamp(0.0, 1.0);
                  return Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Opacity(
                      opacity: 0.35 + 0.65 * pulse,
                      child: Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'thinking…',
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontStyle: FontStyle.italic,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

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
  const _EntryTile({required this.entry});

  final TranscriptEntry entry;

  @override
  Widget build(BuildContext context) {
    if (!entry.parsed && entry.kind == EntryKind.unknown) {
      return _RawEntry(entry: entry);
    }
    return switch (entry.kind) {
      EntryKind.message => _MessageBubble(entry: entry),
      EntryKind.thinking => _ThinkingBlock(entry: entry),
      // Tool calls/results are grouped into a _ToolLedger upstream; if one ever
      // reaches here standalone, drop it rather than double-render.
      EntryKind.toolCall => const SizedBox.shrink(),
      EntryKind.attachment => _AttachmentChip(entry: entry),
      EntryKind.toolResult => const SizedBox.shrink(),
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

    // Assistant: full-width, no bubble — the reply flows like a document, which
    // reads far better for long content. Only the user's own messages get a
    // right-aligned bubble.
    if (!isUser) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
        child: _ExpandableMarkdown(
          text: text,
          fg: scheme.onSurface,
          isUser: false,
        ),
      );
    }

    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.82,
        ),
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
            bottomLeft: Radius.circular(16),
            bottomRight: Radius.circular(4),
          ),
        ),
        child: _ExpandableMarkdown(
          text: text,
          fg: scheme.onPrimaryContainer,
          isUser: true,
        ),
      ),
    );
  }
}

/// An optimistic "you" bubble for a message sent but not yet echoed back by the
/// agent — right-aligned like a real user message, dimmed with a clock so it
/// clearly reads as pending/queued.
class _PendingBubble extends StatelessWidget {
  const _PendingBubble({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerRight,
      child: Opacity(
        opacity: 0.6,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.82,
          ),
          margin: const EdgeInsets.symmetric(vertical: 5),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(16),
              topRight: Radius.circular(16),
              bottomLeft: Radius.circular(16),
              bottomRight: Radius.circular(4),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                text,
                style: TextStyle(color: scheme.onPrimaryContainer, height: 1.35),
              ),
              const SizedBox(height: 3),
              Icon(Icons.schedule,
                  size: 12, color: scheme.onPrimaryContainer.withValues(alpha: 0.7)),
            ],
          ),
        ),
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
/// Per-tool compact treatment. Classifies by raw name; unknown kinds fall to
/// [other] (input_summary), so a new tool never renders blank.
enum _ToolClass { bash, edit, read, search, web, task, other }

_ToolClass _classifyTool(String name) => switch (name.toLowerCase()) {
      'bash' => _ToolClass.bash,
      'edit' || 'write' || 'multiedit' || 'notebookedit' => _ToolClass.edit,
      'read' => _ToolClass.read,
      'grep' || 'glob' => _ToolClass.search,
      'webfetch' || 'websearch' => _ToolClass.web,
      'task' => _ToolClass.task,
      _ => _ToolClass.other,
    };

/// The one-line primary content for a tool row: an icon, the text, and whether
/// to render the text monospaced.
class _Primary {
  const _Primary(this.icon, this.text, {this.mono = false});
  final IconData icon;
  final String text;
  final bool mono;
}

/// Build the compact primary line for a tool, keyed off its class. Always uses
/// existing structured fields and falls back to `input_summary`/name, so it
/// never crashes on a missing field.
_Primary _primaryFor(_ToolClass cls, ToolCall tool) {
  switch (cls) {
    case _ToolClass.bash:
      final cmd = _firstNonEmpty(
              [tool.command, tool.inputSummary, tool.subtitle, tool.title]) ??
          tool.name;
      return _Primary(Icons.terminal, '\$ $cmd', mono: true);
    case _ToolClass.edit:
      final file = _firstNonEmpty(
              [tool.file, _basename(tool.inputSummary), tool.title]) ??
          tool.name;
      return _Primary(Icons.edit_outlined, file, mono: true);
    case _ToolClass.read:
      final file = _firstNonEmpty(
              [tool.file, _basename(tool.inputSummary), tool.subtitle]) ??
          tool.name;
      return _Primary(Icons.description_outlined, file, mono: true);
    case _ToolClass.search:
      final pattern = _firstNonEmpty(
              [tool.command, tool.subtitle, tool.inputSummary, tool.title]) ??
          tool.name;
      return _Primary(Icons.search, pattern, mono: true);
    case _ToolClass.web:
      final u =
          _firstNonEmpty([tool.subtitle, tool.inputSummary, tool.title]) ??
              tool.name;
      return _Primary(Icons.public, u);
    case _ToolClass.task:
      final t =
          _firstNonEmpty([tool.title, tool.subtitle, tool.inputSummary]) ??
              tool.name;
      return _Primary(Icons.smart_toy_outlined, t);
    case _ToolClass.other:
      final t =
          _firstNonEmpty([tool.inputSummary, tool.subtitle, tool.title]) ??
              tool.name;
      return _Primary(Icons.build_outlined, t);
  }
}

String? _firstNonEmpty(List<String?> xs) {
  for (final x in xs) {
    if (x != null && x.trim().isNotEmpty) return x.trim();
  }
  return null;
}

String _basename(String? path) {
  if (path == null || path.isEmpty) return '';
  final parts = path.split('/').where((s) => s.isNotEmpty).toList();
  return parts.isEmpty ? path : parts.last;
}

/// Count added/removed lines in a unified diff (ignoring the `+++`/`---`
/// headers) — the `+N -M` collapsed stat for an edit.
(int, int) _diffStat(String diff) {
  var added = 0, removed = 0;
  for (final l in const LineSplitter().convert(diff)) {
    if (l.startsWith('+') && !l.startsWith('+++')) {
      added++;
    } else if (l.startsWith('-') && !l.startsWith('---')) {
      removed++;
    }
  }
  return (added, removed);
}

/// A run of tool calls, indented under the assistant message that spawned them
/// with a left rail — so the chat reads as prose plus a compact tool ledger.
class _ToolLedger extends StatelessWidget {
  const _ToolLedger({required this.calls, required this.resultFor});

  final List<TranscriptEntry> calls;
  final ToolResult? Function(String id) resultFor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rows = <Widget>[];
    for (final c in calls) {
      final tool = c.tool;
      if (tool == null) continue;
      rows.add(_ToolRow(tool: tool, result: resultFor(tool.id)));
    }
    if (rows.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 2, 8),
      child: Container(
        padding: const EdgeInsets.only(left: 10),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.6),
              width: 2,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: rows,
        ),
      ),
    );
  }
}

/// One tool call merged with its result into a single collapsed row. Success is
/// just a green tick (no redundant "ok" text, output hidden); a failure turns
/// the row red and shows its reason inline; diffs/output expand on tap.
class _ToolRow extends StatefulWidget {
  const _ToolRow({required this.tool, this.result});

  final ToolCall tool;
  final ToolResult? result;

  @override
  State<_ToolRow> createState() => _ToolRowState();
}

class _ToolRowState extends State<_ToolRow> {
  static const _green = Color(0xFF00C853);
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tool = widget.tool;
    final result = widget.result;
    final cls = _classifyTool(tool.name);

    final running = result == null;
    final ok = result?.ok ?? true;
    final failed = result != null && !result.ok;

    // The applied diff (on the result) is authoritative over the preview.
    final diff =
        (result?.diff?.isNotEmpty ?? false) ? result!.diff : tool.diff;
    final output = result?.outputSummary;
    final hasDiff = diff != null && diff.isNotEmpty;
    // Errors surface their output inline; success hides trivial/empty output so
    // the tick is the whole confirmation.
    final hasOutput = !failed && output != null && output.trim().isNotEmpty;
    final expandable = hasDiff || hasOutput;
    final truncated = (result?.truncated ?? false) || tool.diffTruncated;

    // A subtle collapsed size hint: the +N -M stat for edits, the match/line
    // count otherwise, and a plain "truncated" when the payload was capped.
    String? hint;
    if (cls == _ToolClass.edit && hasDiff) {
      final (a, d) = _diffStat(diff);
      if (a > 0 || d > 0) hint = '+$a -$d';
    } else if (cls == _ToolClass.search &&
        output != null &&
        !output.contains('\n') &&
        output.trim().length <= 40) {
      hint = output.trim();
    } else if (hasDiff || hasOutput) {
      final body = hasDiff ? diff : output!;
      final n = '\n'.allMatches(body).length + 1;
      if (n > 1) hint = '+$n lines';
    }
    if (truncated && hint == null) hint = 'truncated';

    final p = _primaryFor(cls, tool);
    final iconColor = failed ? scheme.error : scheme.primary;

    final row = InkWell(
      onTap: expandable ? () => setState(() => _expanded = !_expanded) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _StatusDot(running: running, ok: ok),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(p.icon, size: 15, color: iconColor),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                p.text,
                maxLines: _expanded ? 4 : 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: p.mono ? AppTheme.monoFamily : null,
                  fontSize: 12.5,
                  height: 1.3,
                  color: scheme.onSurface,
                ),
              ),
            ),
            if (hint != null) ...[
              const SizedBox(width: 8),
              Text(
                hint,
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurfaceVariant,
                  fontFamily: AppTheme.monoFamily,
                ),
              ),
            ],
            if (expandable)
              Padding(
                padding: const EdgeInsets.only(left: 2),
                child: Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: scheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        row,
        // A failure shows its reason inline — no expand needed.
        if (failed && output != null && output.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 23, bottom: 6),
            child: Text(
              output.trim(),
              style: TextStyle(fontSize: 12, height: 1.3, color: scheme.error),
            ),
          ),
        if (_expanded && expandable)
          Padding(
            padding: const EdgeInsets.only(left: 23, top: 2, bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (hasDiff) _MiniDiff(diff: diff),
                if (hasOutput) ...[
                  if (hasDiff) const SizedBox(height: 8),
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
    );
  }
}

/// The leading status marker for a tool row: a spinner while running, a bare
/// green tick on success (the confirmation in itself), a red mark on failure.
class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.running, required this.ok});

  final bool running;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (running) {
      return SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: scheme.onSurfaceVariant,
        ),
      );
    }
    return Icon(
      ok ? Icons.check : Icons.error_outline,
      size: 16,
      color: ok ? _ToolRowState._green : scheme.error,
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
