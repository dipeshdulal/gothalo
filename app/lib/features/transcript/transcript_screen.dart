import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart' show ImageSource;
import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/connection/connection.dart';
import '../../core/theme.dart';
import '../../core/widgets/accessory_button.dart';
import '../../core/widgets/agent_age.dart';
import '../../core/widgets/pane_title.dart';
import '../../data/bridge/bridge_client.dart';
import '../../data/bridge/bridge_providers.dart';
import '../../data/bridge/models/snapshot.dart';
import '../attach/image_attach.dart';
import '../herdr_actions.dart';
import '../inbox/inbox_providers.dart';
import '../jump/jump_sheet.dart';
import 'quick_commands_providers.dart';
import 'slash_commands.dart';
import 'transcript_models.dart';

/// Where the transcript socket is in its lifecycle, for the app-bar dot.
enum _Conn { connecting, connected, disconnected, closed, failed }

/// The destructive per-agent actions in the chat's overflow menu.
enum _AgentLifecycleAction { restart, stop }

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
  const TranscriptScreen({
    super.key,
    required this.pane,
    this.openPrompt = false,
  });

  final String pane;

  /// Surface the blocked prompt's options sheet as soon as it is known —
  /// set when arriving from a notification tap, where the user is coming
  /// specifically to answer.
  final bool openPrompt;

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

  /// How many failed handshakes to sit behind the spinner before saying so.
  /// Reconnect backoff is 1s, 2s, 3s…, so this surfaces after ~15s of silence
  /// rather than spinning indefinitely on an error we cannot classify.
  static const _maxSilentAttempts = 5;
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

  /// Set the first time the backlog finishes so the very next layout jumps to
  /// the newest entry (standard chat open-at-bottom). Consumed once; after that
  /// the ordinary pinned-to-bottom rule takes over.
  bool _needInitialSettle = false;

  /// True while the initial settle-to-bottom loop runs. Scroll events are
  /// ignored during it, so the lazy list growing beneath us (which momentarily
  /// looks like "scrolled up") can't clear [_pinnedToBottom] and abort the loop.
  bool _settling = false;

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

  /// Pick → upload → path, shared with the terminal screen's key row (see
  /// [ImageAttachController]). Its progress and failures render in the
  /// [ImageUploadStatus] strip above the composer.
  final ImageAttachController _attach = ImageAttachController();

  /// Whether the agent is still blocked, as a listenable the options sheet can
  /// follow.
  ///
  /// The sheet is a separate Navigator route, so it does not rebuild when this
  /// screen does. Without this it kept offering choices for a block that had
  /// already been answered elsewhere — from the desktop, the tray, or another
  /// device — because the only thing that ever removed it was the user tapping
  /// something. The card behind it vanished on the very same state change; the
  /// sheet in front of it did not.
  final ValueNotifier<bool> _blocked = ValueNotifier(false);

  /// The active `/…` token in the composer, or null when the typeahead should be
  /// hidden. Recomputed on every composer change (text AND caret — moving the
  /// caret out of the token dismisses the list just as typing a space does).
  SlashQuery? _slash;

  @override
  void initState() {
    super.initState();
    _autoPromptPending = widget.openPrompt;
    _scroll.addListener(_onScroll);
    _composer.addListener(_onComposerChanged);
    // Repaints the upload strip and greys the paperclip while one is in flight.
    _attach.addListener(_onAttachChanged);
  }

  void _onAttachChanged() {
    if (mounted) setState(() {});
  }

  /// Keeps [_slash] in step with the composer. Only calls setState when the
  /// typeahead's visibility or query actually changes — this fires on every
  /// keystroke, and rebuilding the whole transcript for each one is exactly the
  /// cost that would make typing feel heavy.
  void _onComposerChanged() {
    final next = SlashQuery.parse(
      _composer.text,
      _composer.selection.baseOffset,
    );
    if (next?.query == _slash?.query) return;
    setState(() => _slash = next);
  }

  /// Publish the live blocked-ness to anything following it. Called from every
  /// path that assigns [_agentState], so a resolution reaches the sheet no
  /// matter which one observed it.
  void _publishBlocked() {
    final s = _agentState;
    _blocked.value = s != null && s.isBlocked;
  }

  /// Arm of [TranscriptScreen.openPrompt]: still waiting for the first agent
  /// state on a notification-tap visit.
  bool _autoPromptPending = false;

  /// Opened from a notification: surface the prompt's options sheet without
  /// the extra tap on the approval card. Runs at most once, on the first agent
  /// state — if the agent has already moved past the prompt by then, the
  /// moment has passed and no sheet appears.
  void _maybeAutoOpenPrompt(AgentState s) {
    if (!_autoPromptPending) return;
    _autoPromptPending = false;
    if (!s.isBlocked || s.options.isEmpty) return;
    final question = (s.blockedQuestion?.trim().isNotEmpty ?? false)
        ? s.blockedQuestion!.trim()
        : (s.headline.isNotEmpty ? s.headline : 'Approve?');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showBlockedOptionsSheet(
        context,
        question: question,
        options: s.options,
        danger: s.blockSeverity == BlockSeverity.danger,
        blocked: _blocked,
        onApprove: _approveDefault,
        onOption: _handleOption,
        onFreeText: _sendAnswer,
      );
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _sub?.cancel();
    _channel?.sink.close(ws_status.normalClosure);
    _agentStateTimer?.cancel();
    _scroll.dispose();
    _composer.removeListener(_onComposerChanged);
    _composer.dispose();
    _attach.removeListener(_onAttachChanged);
    _attach.dispose();
    _blocked.dispose();
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
      // All this screen needs from the card is the live status and the blocked
      // prompt, both of which come from the pane's current screen. The agent's
      // actual history arrives over /agent-transcript, so the card never asks
      // for scrollback (see BridgeClient.getAgentState).
      final s = await client.getAgentState(widget.pane);
      if (mounted) {
        setState(() => _agentState = s);
        _publishBlocked();
        _maybeAutoOpenPrompt(s);
      }
    } catch (_) {
      // Non-agent / gone / transient — no bar.
      if (mounted && _agentState != null) {
        setState(() => _agentState = null);
        _publishBlocked();
      }
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
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

  /// Approve the highlighted default via idempotent `POST /approve {agent, seq}`
  /// (the bridge picks the confirm key and no-ops a stale seq). The seq comes
  /// from the live snapshot for this pane. Optimistically hide the card; the
  /// next poll confirms.
  Future<void> _approveDefault() async {
    final client = _client;
    if (client == null) return;
    final agents =
        ref.read(snapshotControllerProvider).asData?.value.agents ??
        const <Agent>[];
    var seq = 0;
    for (final a in agents) {
      if (a.paneId == widget.pane) {
        seq = a.stateChangeSeq ?? 0;
        break;
      }
    }
    setState(() => _agentState = null);
    _publishBlocked();
    try {
      final res = await client.approve(widget.pane, seq);
      if (!res.applied && res.reason != null && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(res.reason!)));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e is BridgeException ? e.message : '$e')),
      );
    }
  }

  /// Pick a non-default option. A keyed option (no menu number, e.g. Esc to
  /// decline) sends that raw keystroke; a numbered one types its number and
  /// submits via `POST /send {pane, text:'<index>\n'}` (the bridge turns the
  /// trailing newline into a real Enter). Optimistically hide the card.
  void _handleOption(BlockedOption opt) {
    if (opt.isKeyed) {
      _client?.sendKey(widget.pane, opt.key!);
    } else {
      _client?.sendText(widget.pane, '${opt.index}\n');
    }
    setState(() => _agentState = null);
    _publishBlocked();
  }

  /// Send a free-form answer typed in the options sheet. Same wire path as the
  /// composer (trailing `\r` so the bridge submits it as a real Enter) and the
  /// same optimistic echo, so a typed answer appears immediately whichever
  /// surface it came from. Clears the card like picking an option does.
  void _sendAnswer(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    setState(() {
      _pending.add(trimmed);
      _pinnedToBottom = true;
      _agentState = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
    _client?.sendText(widget.pane, '$trimmed\r').catchError((Object e) {
      if (!mounted) return;
      setState(() => _pending.remove(trimmed));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e is BridgeException ? e.message : '$e')),
      );
    });
  }

  /// Fire a quick command: a keyed one sends its raw keystroke (e.g. Esc to
  /// interrupt); a text one submits like a composer message (a trailing `\n`
  /// so the bridge turns it into a real Enter, same as the composer itself).
  void _handleQuickCommand(QuickCommand cmd) {
    if (cmd.key != null) {
      _client?.sendKey(widget.pane, cmd.key!);
    } else {
      _client?.sendText(widget.pane, '${cmd.text}\n');
    }
  }

  /// Attach a screenshot or photo to the prompt: pick it, upload it, and drop
  /// the path the bridge wrote into the composer — **without sending**, so the
  /// user writes the prompt around it. The flow itself lives in
  /// [ImageAttachController], shared with the terminal screen.
  Future<void> _attachImage(ImageSource source) => _attach.attach(
    client: _client,
    pane: widget.pane,
    source: source,
    onPath: (path) {
      if (mounted) _insertIntoComposer(path);
    },
  );

  /// Insert [path] at the composer's cursor, leaving the caret after it so the
  /// user can keep typing.
  ///
  /// Spacing is fixed up rather than assumed: appended straight onto an existing
  /// word the path would fuse into it and the agent would be handed a filename
  /// that doesn't exist. A path containing whitespace is quoted for the same
  /// reason — an agent reading a bare path stops at the first space.
  void _insertIntoComposer(String path) {
    final quoted = attachPathText(path);
    final value = _composer.value;
    final base = value.text;
    // A field that has never been focused reports an invalid (-1) selection;
    // that means "no cursor yet", so append.
    final sel = value.selection;
    final start = sel.isValid ? sel.start : base.length;
    final end = sel.isValid ? sel.end : base.length;

    final prefix = base.substring(0, start);
    final suffix = base.substring(end);
    final lead = prefix.isEmpty || prefix.endsWith(' ') || prefix.endsWith('\n')
        ? ''
        : ' ';
    final insert = '$lead$quoted ';

    _composer.value = TextEditingValue(
      text: '$prefix$insert$suffix',
      selection: TextSelection.collapsed(offset: prefix.length + insert.length),
    );
  }

  /// The command / file context being approved — pulled from the most recent
  /// tool_call still awaiting a result (the one blocking), falling back to the
  /// parsed `/agent-state` detail. Lets the approval card show *what* it does.
  String? _approvalContext() {
    for (final e in _ordered.reversed) {
      if (e.kind != EntryKind.toolCall || e.tool == null) continue;
      final t = e.tool!;
      if (_resultsByForId[t.id] != null) {
        break; // resolved → not the pending one
      }
      final ctx = _firstText([t.command, t.file, t.inputSummary, t.title]);
      if (ctx != null) return ctx;
      break;
    }
    final d = _agentState?.detail.trim() ?? '';
    return d.isEmpty ? null : d;
  }

  /// The status strip above the composer. Only a blocked agent with a **real
  /// prompt** gets an actionable approval card; a working agent gets the
  /// thinking indicator. Everything else (just-waiting, idle, done) shows
  /// nothing — the composer alone is enough, a lone "waiting" label is
  /// redundant.
  Widget _bottomStatus() {
    final s = _agentState;
    if (s != null && s.isBlocked) {
      final opts = s.options;
      final hasPrompt =
          (s.blockedQuestion?.trim().isNotEmpty ?? false) || opts.isNotEmpty;
      if (hasPrompt) {
        return _ApprovalCard(
          state: s,
          options: opts,
          blocked: _blocked,
          contextLine: _approvalContext(),
          onApprove: _approveDefault,
          onOption: _handleOption,
          onFreeText: _sendAnswer,
        );
      }
    }
    if (s != null && s.isWorking) return const _ThinkingIndicator();
    return const SizedBox.shrink();
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

  /// Ask the bridge, over plain HTTP, why the WebSocket handshake keeps being
  /// rejected — and return its own explanation.
  ///
  /// Dart's WebSocket client reports a rejected upgrade as a bare "not upgraded
  /// to websocket" with no status and no body, so the reason the bridge sent is
  /// unreachable from the handshake (see [_permanentFailureMessage]). The same
  /// URL fetched without an Upgrade header answers with the real status and a
  /// sentence saying what is wrong, because the endpoint deliberately fails
  /// BEFORE upgrading.
  ///
  /// Worth the extra round trip only once retries are exhausted. Guessing
  /// instead — the previous behaviour — told operators their agent kind "may not
  /// support a chat view" when the truth was that the agent was sitting on a
  /// trust prompt and had not reported its session id yet, which sends them to
  /// debug entirely the wrong thing.
  Future<String?> _serverFailureReason(Connection c) async {
    try {
      final ws = _transcriptUri(c);
      final probe = ws.replace(scheme: ws.scheme == 'wss' ? 'https' : 'http');
      final res = await Dio().getUri<String>(
        probe,
        options: Options(
          responseType: ResponseType.plain,
          receiveTimeout: const Duration(seconds: 5),
          // The interesting answers ARE the error statuses, so don't throw on
          // them.
          validateStatus: (_) => true,
        ),
      );
      final body = (res.data ?? '').trim();
      if (body.isEmpty || body.length > 300) return null;
      // Go's default mux 404 explains nothing; only pass on a message the
      // endpoint actually wrote.
      if (body.toLowerCase() == '404 page not found') return null;
      return body;
    } catch (_) {
      return null;
    }
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
      if (_needInitialSettle) {
        _needInitialSettle = false;
        _settleToBottom(); // first paint after backlog → land on the newest
      } else {
        _maybeAutoScroll();
      }
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
        _needInitialSettle = true; // open at the newest entry, like a chat
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
      gone =
          !snap.panes.any((p) => p.paneId == widget.pane) &&
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

    // Retries are exhausted and the pane still exists, so the bridge is
    // refusing this transcript for a reason it can state. Ask it rather than
    // guess — see _serverFailureReason.
    if (_attempts >= _maxSilentAttempts && _failure == null) {
      final reason = await _serverFailureReason(client.connection);
      if (_disposed) return;
      if (reason != null) {
        _reconnectTimer?.cancel();
        if (mounted) setState(() => _failure = reason);
        return;
      }
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
    // Ignore scroll churn while the initial settle is still re-jumping to the
    // bottom — otherwise the list growing beneath us reads as "scrolled up".
    if (_settling) return;
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
    channel.sink.add(
      jsonEncode({
        'type': 'load_older',
        'before_seq': _oldestSeq,
        'limit': 150,
      }),
    );
    if (mounted) setState(() {}); // show the top loader
  }

  /// Keep the view pinned to the newest entry unless the user scrolled up.
  void _maybeAutoScroll() {
    if (!_pinnedToBottom || _settling) return;
    // Delegate to the same settler the initial backlog uses instead of a single
    // blind jump: on this lazily-built, center-anchored list maxScrollExtent is
    // only an estimate until off-screen rows lay out, so one jump undershoots
    // and the next frame jumps again — which, on a fast-streaming agent, reads
    // as the view "blinking"/jittering. The settler only jumps when actually
    // off the bottom and re-checks across a few frames until it settles; the
    // _settling guard coalesces bursts of frames into one settle sequence.
    _settleToBottom(tries: 3);
  }

  /// Reliably land on the newest entry after the initial backlog. The list is
  /// lazily built under a `center` anchor, so `maxScrollExtent` is only an
  /// estimate until off-screen rows lay out — one jump undershoots. Re-jump
  /// across a few frames until the position stops moving. Bails the moment the
  /// user scrolls up (`_pinnedToBottom` clears), so it never fights paging or a
  /// deliberate scroll into history.
  void _settleToBottom({int tries = 6}) {
    if (!_pinnedToBottom || _disposed) return;
    _settling = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || !_scroll.hasClients) {
        _settling = false;
        return;
      }
      final max = _scroll.position.maxScrollExtent;
      if ((_scroll.position.pixels - max).abs() > 1.5) {
        _scroll.jumpTo(max);
      }
      if (tries > 1) {
        _settleToBottom(tries: tries - 1);
      } else {
        _settling = false; // done — hand control back to _onScroll
      }
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
    // bridgeClientProvider yields null while the active connection is being
    // resolved, so this never adopts a client for the wrong server.
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

    // The slash typeahead's matches, or empty when it should not show — no
    // active `/…` token, the fetch has not landed, or nothing matches what was
    // typed. Watched unconditionally (hooks cannot be conditional) but the
    // provider is cheap and returns an empty list for every pane without a
    // command surface, so a non-claude pane costs one 200 and renders nothing.
    final slashMatches = switch (_slash) {
      final q? => rankSlashCommands(
        ref.watch(slashCommandsProvider(widget.pane)).asData?.value ?? const [],
        q.query,
      ),
      null => const <SlashCommand>[],
    };

    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: AppTheme.scaffoldBase(Theme.of(context).brightness),
      appBar: AppBar(
        title: PaneTitle(
          title: agent?.displayTitle ?? widget.pane,
          subtitle: [
            // Age FIRST: the subtitle ellipsises, and this is the part that
            // decides whether you act. Trailing it behind the branch and kind
            // meant it was the first thing cut off on a long branch name.
            //
            // Reading a slow conversation without it, there is no way to tell a
            // turn that just started from one that stalled twenty minutes ago.
            if (agent?.sinceLastActivity case final age?)
              '${agent!.agentStatus.name} ${formatAgentAge(age)}',
            if (agent != null) agent.gitLabel,
            if (agent != null) agent.agent,
          ].where((s) => s.isNotEmpty).join(' · '),
          connLabel: switch (_conn) {
            _Conn.connected => 'Live',
            _Conn.connecting => 'Connecting…',
            _Conn.disconnected => 'Reconnecting…',
            _Conn.closed => 'Closed',
            _Conn.failed => 'Unavailable',
          },
          connColor: switch (_conn) {
            _Conn.connected => scheme.primary,
            _Conn.connecting => scheme.onSurfaceVariant,
            _Conn.disconnected => scheme.error,
            _Conn.closed => scheme.onSurfaceVariant,
            _Conn.failed => scheme.error,
          },
        ),
        actions: [
          // Jump moved down to the composer's actions row, where the thumb
          // already is — the app bar is a stretch away on a phone.
          IconButton(
            tooltip: 'Changes',
            onPressed: () =>
                context.push('/diff/${Uri.encodeComponent(widget.pane)}'),
            icon: const Icon(Icons.difference_outlined),
          ),
          // Lifecycle lives in an overflow, not as bar buttons: these two kill
          // running work, and a one-tap target next to "Changes" is exactly the
          // wrong affordance for that. Both confirm before acting.
          PopupMenuButton<_AgentLifecycleAction>(
            tooltip: 'Agent actions',
            icon: const Icon(Icons.more_vert),
            onSelected: (action) {
              final kind = agent?.agent ?? 'agent';
              switch (action) {
                case _AgentLifecycleAction.restart:
                  restartAgent(context, ref, widget.pane, kind: kind);
                case _AgentLifecycleAction.stop:
                  stopAgent(context, ref, widget.pane, kind: kind);
              }
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(
                value: _AgentLifecycleAction.restart,
                child: ListTile(
                  leading: Icon(Icons.restart_alt),
                  title: Text('Restart agent'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: _AgentLifecycleAction.stop,
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
            // Real approval → an actionable card; just-waiting → a soft cue;
            // working → a live "thinking…" indicator (see _bottomStatus).
            _bottomStatus(),
            // Directly above the toolbar that started the upload, so progress
            // and the button that caused it read as one thing. Renders nothing
            // while idle.
            ImageUploadStatus(controller: _attach),
            // Everything about *how* you're talking to the agent (attach an
            // image, mode, quick commands, raw terminal) lives down here with
            // the composer as ONE scrollable chip row, not the app bar — a
            // cluttered header, and a fragmented "chip pinned left / icon
            // pinned right / second row below" layout, both read worse than
            // one consistent strip.
            // While the slash typeahead is up it REPLACES the actions row rather
            // than stacking on top of it. Two reasons: with a keyboard open the
            // phone has no room for both above the composer, and mid-command the
            // chips are not what you are reaching for — the list is.
            if (slashMatches.isNotEmpty)
              SlashCommandList(
                commands: slashMatches,
                onSelected: (c) => applySlashCommand(_composer, c),
              )
            else
              _ComposerActionsRow(
                modeLabel: _agentState?.permissionMode != null
                    ? _modeLabel(_agentState!.permissionMode!)
                    : null,
                onCycleMode: _cycleMode,
                onOpenTerminal: () => context.push(
                  '/terminal/${Uri.encodeComponent(widget.pane)}',
                ),
                onJump: () => showJumpSheet(context, currentPane: widget.pane),
                onQuickCommand: _handleQuickCommand,
                enabled:
                    _conn != _Conn.closed &&
                    _conn != _Conn.failed &&
                    _failure == null,
              ),
            // Talk to the agent right from the chat — no need to drop to the raw
            // terminal. Disabled once the pane is gone/unavailable.
            _ComposerBar(
              controller: _composer,
              onSend: _sendComposer,
              onAttachImage: _attach.uploading
                  ? null
                  : () => showImageSourceSheet(context, onPick: _attachImage),
              hintText: _agentState?.isBlocked == true
                  ? 'Type a number, or your own reply…'
                  : null,
              enabled:
                  _conn != _Conn.closed &&
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
      // Give up spinning after a few failed handshakes. Dart's WebSocket client
      // reports a rejected upgrade as a bare "not upgraded to websocket" with no
      // HTTP status, so _permanentFailureMessage cannot recognise a 404 and the
      // reconnect loop would otherwise sit behind this spinner forever.
      if (_attempts >= _maxSilentAttempts) {
        return _CenteredNotice(
          icon: Icons.chat_bubble_outline,
          title: 'Transcript unavailable',
          message:
              'Could not open a transcript for this pane after several tries. '
              'This agent kind may not support a chat view yet — open the raw '
              'terminal instead.',
          onTerminal: () =>
              context.push('/terminal/${Uri.encodeComponent(widget.pane)}'),
        );
      }
      return const Center(child: CircularProgressIndicator());
    }
    if (_ordered.isEmpty) {
      // A connected socket with an empty backlog means the agent is live but
      // hasn't spoken — a brand-new pane, before its first message. The tail is
      // running, so anything typed below appears here without reconnecting.
      return const _CenteredNotice(
        icon: Icons.chat_bubble_outline,
        title: 'No messages yet',
        message:
            'This agent hasn\'t said anything so far. '
            'Send it a prompt below to get started.',
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

    DateTime? prevAt;
    var prevWasTool = false;
    for (final e in entries) {
      // A pause before an ASSISTANT entry is the agent working — the thing you
      // want to see when a turn felt slow. A pause before a USER entry is you
      // being away from your phone, which is not news and would otherwise
      // litter the transcript with hours-long "gaps" every night.
      final at = e.at;
      if (at != null && prevAt != null && e.role == EntryRole.assistant) {
        final gap = at.difference(prevAt);
        if (gap >= _minShownGap) {
          flush();
          // A gap that follows a tool call is mostly the TOOL running, not the
          // model thinking. Calling that "thought" overstates it, so the label
          // only claims thinking when the pause really was the agent's own.
          blocks.add(_GapBlock(gap, afterTool: prevWasTool));
        }
      }
      if (at != null) prevAt = at;
      prevWasTool =
          e.kind == EntryKind.toolCall || e.kind == EntryKind.toolResult;

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
    _GapBlock(:final gap, :final afterTool) => _GapLine(
      gap: gap,
      afterTool: afterTool,
    ),
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

/// A pause the AGENT spent working, rendered between the entries it separates.
class _GapBlock extends _Block {
  const _GapBlock(this.gap, {this.afterTool = false});
  final Duration gap;

  /// The pause followed a tool call, so most of it was the tool running.
  final bool afterTool;
}

/// The shortest pause worth drawing.
///
/// A minute, not a few seconds. The first attempt used 10s and marked almost
/// every tool call — "took 14s", "took 17s", "took 37s" down the whole
/// transcript. All true, none of it useful: nothing you would do differently,
/// and enough of it to bury the one pause that mattered.
///
/// The bar is whether you would have NOTICED the wait. Under a minute you would
/// not, so the marker earns nothing and costs a row.
const _minShownGap = Duration(minutes: 1);

/// The time between two entries, drawn as a quiet timeline marker.
///
/// It answers a question the transcript otherwise hides: a long turn looks
/// identical to a fast one once it is on screen, so there is no way to tell
/// where the time went when a session felt slow.
///
/// Deliberately centred and low-contrast rather than left-aligned with an icon.
/// The first attempt sat at the left margin with a "⋯" glyph, which read as a
/// typing indicator or a failed message — it competed with the conversation
/// instead of annotating it. Metadata should recede; centring it also matches
/// the day separators, so it is legible as "a marker, not a message".
class _GapLine extends StatelessWidget {
  const _GapLine({required this.gap, this.afterTool = false});

  final Duration gap;

  /// The pause followed a tool call, so most of it was the tool running.
  final bool afterTool;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Center(
        child: Text(
          afterTool
              ? 'took ${formatAgentAge(gap)}'
              : 'thought ${formatAgentAge(gap)}',
          style: TextStyle(
            fontSize: 10.5,
            letterSpacing: 0.3,
            fontWeight: FontWeight.w500,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }
}

/// First non-blank string in [xs] (trimmed), or null.
String? _firstText(List<String?> xs) {
  for (final x in xs) {
    if (x != null && x.trim().isNotEmpty) return x.trim();
  }
  return null;
}

/// Shown above the composer when an agent is blocked on a **real prompt** — an
/// approval or a question with choices. Renders the question, the command/
/// context being approved, and the options as buttons: the highlighted default
/// is a prominent Approve (→ `/approve`), other choices type their number
/// (→ `/send`). Styled by `blocked.category` — red + lock only for
/// dangerous_command_approval / tool_approval, softer for other permission
/// grants, neutral for a plain question panel.
class _ApprovalCard extends StatelessWidget {
  const _ApprovalCard({
    required this.state,
    required this.options,
    required this.onFreeText,
    required this.contextLine,
    required this.onApprove,
    required this.onOption,
    required this.blocked,
  });

  final AgentState state;
  final List<BlockedOption> options;

  /// Live blocked-ness, handed to the options sheet so it can close itself when
  /// the block is answered somewhere else.
  final ValueListenable<bool> blocked;

  /// Sends a free-form answer typed in the options sheet. Needed because a menu
  /// can itself offer "Other (type your answer)" — Hermes's clarify panel does —
  /// so the sheet must reach the keyboard without the composer underneath it.
  final void Function(String) onFreeText;
  final String? contextLine;
  final VoidCallback onApprove;
  final void Function(BlockedOption) onOption;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final severity = state.blockSeverity;
    final (Color bg, Color accent, IconData icon) = switch (severity) {
      BlockSeverity.danger => (
        scheme.errorContainer.withValues(alpha: 0.55),
        scheme.error,
        Icons.lock_outline,
      ),
      BlockSeverity.permission => (
        scheme.errorContainer.withValues(alpha: 0.3),
        scheme.error,
        Icons.lock_outline,
      ),
      BlockSeverity.question => (
        scheme.surfaceContainerHighest.withValues(alpha: 0.7),
        scheme.primary,
        Icons.forum_outlined,
      ),
    };
    final categoryLabel = state.blockedCategoryLabel;
    final question = (state.blockedQuestion?.trim().isNotEmpty ?? false)
        ? state.blockedQuestion!.trim()
        : (state.headline.isNotEmpty ? state.headline : 'Approve?');

    return Container(
      width: double.infinity,
      color: bg,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (categoryLabel != null) ...[
            _CategoryPill(
              label: categoryLabel,
              icon: icon,
              accent: accent,
              strong: severity == BlockSeverity.danger,
            ),
            const SizedBox(height: 8),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2, right: 8),
                child: Icon(icon, size: 16, color: accent),
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
          if (contextLine != null && contextLine!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: scheme.surface.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.5),
                ),
              ),
              child: Text(
                contextLine!,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: AppTheme.monoFamily,
                  fontSize: 12,
                  height: 1.35,
                  color: scheme.onSurface,
                ),
              ),
            ),
          ],
          if (options.isNotEmpty) ...[
            const SizedBox(height: 10),
            // The choices live in a sheet rather than inline. Inline, this card
            // was unbounded in the body Column alongside the composer, so a
            // prompt with several options plus an open keyboard overflowed the
            // viewport (Hermes's clarify panel offers five). The sheet sizes and
            // scrolls itself, so the card's height no longer depends on how many
            // choices an agent happens to offer.
            _OpenOptionsButton(
              count: options.length,
              danger: severity == BlockSeverity.danger,
              onTap: () => showBlockedOptionsSheet(
                context,
                question: question,
                options: options,
                blocked: blocked,
                danger: severity == BlockSeverity.danger,
                onApprove: onApprove,
                onOption: onOption,
                onFreeText: onFreeText,
              ),
            ),
          ] else ...[
            const SizedBox(height: 6),
            Text(
              'Type your answer below.',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5),
            ),
          ],
        ],
      ),
    );
  }
}

/// One row in the approval card's option list — a full-width tappable choice,
/// stacked vertically rather than wrapped as chips so long labels (a real
/// menu can have several, e.g. Claude's disambiguation prompts) read cleanly
/// instead of crowding into a chip cloud of mismatched widths. The default
/// (`primary`) is filled and accent-coloured with a check; every other choice
/// is a plain outlined row, each fronted by a small badge — the number to
/// The approval card's single action when the agent offered a menu: a full-width
/// button that opens the choices in a sheet. It replaces the inline list so the
/// card's height is fixed no matter how many options there are.
class _OpenOptionsButton extends StatelessWidget {
  const _OpenOptionsButton({
    required this.count,
    required this.danger,
    required this.onTap,
  });

  final int count;
  final bool danger;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = danger ? scheme.error : scheme.primary;
    return Material(
      color: accent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                count == 1 ? 'Choose 1 option' : 'Choose one of $count options',
                style: TextStyle(
                  color: danger ? scheme.onError : scheme.onPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                Icons.keyboard_arrow_up,
                size: 18,
                color: danger ? scheme.onError : scheme.onPrimary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Show a blocked agent's choices in a bottom sheet.
///
/// The sheet carries a text field as well as the option list. That is not a
/// convenience: a menu can offer "Other (type your answer)" (Hermes's clarify
/// panel does), and while the sheet is up it covers the screen's composer — so
/// without its own input there would be no way to answer such a prompt at all.
///
/// It is `isScrollControlled` and padded by the keyboard inset, so opening the
/// keyboard lifts the sheet instead of overflowing it; the option list scrolls
/// within whatever height is left.
Future<void> showBlockedOptionsSheet(
  BuildContext context, {
  required String question,
  required List<BlockedOption> options,
  required bool danger,
  required ValueListenable<bool> blocked,
  required VoidCallback onApprove,
  required void Function(BlockedOption) onOption,
  required void Function(String) onFreeText,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => _BlockedOptionsSheet(
      question: question,
      options: options,
      danger: danger,
      blocked: blocked,
      onApprove: onApprove,
      onOption: onOption,
      onFreeText: onFreeText,
    ),
  );
}

class _BlockedOptionsSheet extends StatefulWidget {
  const _BlockedOptionsSheet({
    required this.question,
    required this.options,
    required this.danger,
    required this.blocked,
    required this.onApprove,
    required this.onOption,
    required this.onFreeText,
  });

  final String question;
  final List<BlockedOption> options;
  final bool danger;

  /// Live blocked-ness of the agent this sheet is answering for.
  final ValueListenable<bool> blocked;
  final VoidCallback onApprove;
  final void Function(BlockedOption) onOption;
  final void Function(String) onFreeText;

  @override
  State<_BlockedOptionsSheet> createState() => _BlockedOptionsSheetState();
}

class _BlockedOptionsSheetState extends State<_BlockedOptionsSheet> {
  final _answer = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.blocked.addListener(_onBlockedChanged);
  }

  /// Close when the agent is no longer blocked.
  ///
  /// The block can be answered anywhere — the desktop Herdr UI, the tray's
  /// Approve, another paired device — and none of those touch this sheet. Left
  /// open it offers choices for a question that no longer exists; picking one
  /// is a no-op (`/approve` is guarded by `state_change_seq`) but the UI has
  /// already lied about the current state by then.
  ///
  /// The pop is deferred to the next frame: this fires from a ValueNotifier
  /// during the parent's state update, and popping a route mid-build is not
  /// allowed.
  ///
  /// Both guards below are load-bearing. Answering here *also* unblocks the
  /// agent, so this listener fires on the user's own tap — and `mounted` alone
  /// does not save us, because during the pop animation the state is still
  /// mounted. The second pop then lands on the transcript screen underneath and
  /// closes it too.
  void _onBlockedChanged() {
    if (widget.blocked.value || _closing) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _closing) return;
      // Only dismiss while this sheet is genuinely the top route: if anything
      // else has been pushed over it, or it is already on its way out, a pop
      // here would close somebody else's screen.
      final route = ModalRoute.of(context);
      if (route == null || !route.isCurrent) return;
      _closing = true;
      Navigator.of(context).pop();
    });
  }

  /// Set the moment we start closing ourselves, so the blocked-listener can tell
  /// "the user answered here" from "it was answered elsewhere".
  bool _closing = false;

  void _close() {
    if (_closing) return;
    _closing = true;
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    widget.blocked.removeListener(_onBlockedChanged);
    _answer.dispose();
    super.dispose();
  }

  void _pick(BlockedOption o) {
    _close();
    if (o.selected) {
      widget.onApprove();
    } else {
      widget.onOption(o);
    }
  }

  void _submitTyped() {
    final text = _answer.text.trim();
    if (text.isEmpty) return;
    _close();
    widget.onFreeText(text);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasSelected = widget.options.any((o) => o.selected);
    // Leave room for the drag handle and the sheet's own chrome; the list
    // scrolls inside whatever remains once the keyboard has taken its share.
    final maxListHeight = MediaQuery.sizeOf(context).height * 0.45;

    return Padding(
      // Lift the whole sheet above the keyboard rather than letting it overflow.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.question,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxListHeight),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: widget.options.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (_, i) => _OptionRow(
                    option: widget.options[i],
                    primary:
                        widget.options[i].selected || (!hasSelected && i == 0),
                    danger: widget.danger,
                    onTap: () => _pick(widget.options[i]),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // The free-text path — for "Other (type your answer)" and for any
              // prompt where none of the offered choices is what you want.
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _answer,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _submitTyped(),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: 'Or type your answer…',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _submitTyped,
                    icon: const Icon(Icons.send),
                    tooltip: 'Send answer',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// type, or the raw key name (e.g. "ESC") for a [BlockedOption.isKeyed] choice
/// that has no menu number at all.
class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.option,
    required this.primary,
    required this.danger,
    required this.onTap,
  });

  final BlockedOption option;
  final bool primary;
  final bool danger;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = danger ? scheme.error : scheme.primary;
    final bg = primary ? accent : scheme.surface.withValues(alpha: 0.6);
    final fg = primary
        ? (danger ? scheme.onError : scheme.onPrimary)
        : scheme.onSurface;
    final badgeText = option.isKeyed
        ? option.key!.toUpperCase()
        : '${option.index}';

    return Material(
      color: bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: primary
            ? BorderSide.none
            : BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: primary
                      ? fg.withValues(alpha: 0.18)
                      : scheme.surfaceContainerHighest,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  badgeText,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: fg,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  option.label,
                  style: TextStyle(
                    color: fg,
                    fontWeight: primary ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
              if (primary) ...[
                const SizedBox(width: 8),
                Icon(Icons.check, size: 18, color: fg),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A small pill labelling a block's category (from `blocked.category`), e.g.
/// "Dangerous command" or "Tool permission". Filled/strong for a danger-class
/// block, outlined otherwise.
class _CategoryPill extends StatelessWidget {
  const _CategoryPill({
    required this.label,
    required this.icon,
    required this.accent,
    required this.strong,
  });

  final String label;
  final IconData icon;
  final Color accent;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: strong ? accent : accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
        border: strong
            ? null
            : Border.all(color: accent.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 12,
            color: strong ? Theme.of(context).colorScheme.onError : accent,
          ),
          const SizedBox(width: 4),
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
              color: strong ? Theme.of(context).colorScheme.onError : accent,
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown while the agent is working: a bar sweeping left-to-right along the
/// seam between the transcript and the composer's controls.
///
/// Just the bar — no "thinking…" label, because the motion already says it, and
/// a word costs a line of transcript on a phone. A bar rather than the chat-app
/// pulsing dots, too: dots say "someone is typing a reply", where this is a
/// machine holding a turn open for anything from two seconds to ten minutes,
/// and a sweep reads as ongoing work rather than an imminent message.
class _ThinkingIndicator extends StatelessWidget {
  const _ThinkingIndicator();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LinearProgressIndicator(
      minHeight: 2,
      backgroundColor: scheme.outlineVariant.withValues(alpha: 0.3),
      color: scheme.primary,
      semanticsLabel: 'The agent is working',
    );
  }
}

/// One row above the composer for everything that's an action about *how*
/// you're talking to the agent rather than the chat itself: the Claude
/// permission-mode switcher, quick-command snippets (see
/// docs/RESEARCH-feature-ideas.md, #7), "+" to add one, a jump to another
/// agent, and a jump to the raw terminal.
///
/// Built from the same [AccessoryButton] as the terminal's key bar, spread
/// evenly and scrolling as one strip when it overflows. It had been Material
/// chips, which read as a different toolbar from the terminal's for what is
/// the same job on the next screen over. Attaching an image is not here — it
/// acts on the message being written, so it lives inside the composer pill.
class _ComposerActionsRow extends ConsumerWidget {
  const _ComposerActionsRow({
    required this.modeLabel,
    required this.onCycleMode,
    required this.onOpenTerminal,
    required this.onJump,
    required this.onQuickCommand,
    required this.enabled,
  });

  final String? modeLabel;
  final VoidCallback onCycleMode;
  final VoidCallback onOpenTerminal;
  final VoidCallback onJump;
  final void Function(QuickCommand) onQuickCommand;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final commands = ref.watch(quickCommandsProvider).asData?.value ?? const [];

    return Container(
      decoration: BoxDecoration(
        // Two M3 steps below the buttons' own `surfaceContainerHighest`, not
        // one: at one step the buttons and the bar behind them are close enough
        // to read as a single flat slab.
        color: scheme.surfaceContainerLow,
        border: Border(
          top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.4)),
        ),
      ),
      // Same generous side margins as the terminal's bar: a curved screen's
      // glass falls away at the edge, and SafeArea covers a notch, not a curve.
      // Tighter vertically — this row and the composer under it are one block,
      // and every dp here is a dp of transcript.
      padding: const EdgeInsets.fromLTRB(22, 8, 22, 4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final buttons = <Widget>[
            if (modeLabel != null)
              AccessoryButton(
                label: modeLabel!,
                leading: Icons.tune,
                onTap: onCycleMode,
                semanticLabel: 'Permission mode: $modeLabel',
                tooltip: 'Cycle permission mode',
              ),
            for (final c in commands)
              AccessoryButton(
                label: c.label,
                // Marks a command that fires a raw keystroke rather than
                // typing text.
                leading: c.key != null ? Icons.keyboard_command_key : null,
                onTap: enabled ? () => onQuickCommand(c) : () {},
                onLongPress: () async {
                  final all =
                      ref.read(quickCommandsProvider).asData?.value ??
                      const <QuickCommand>[];
                  final i = all.indexOf(c);
                  if (i < 0) return;
                  if (await confirmRemoveQuickCommand(context, c.label)) {
                    await ref.read(quickCommandsProvider.notifier).removeAt(i);
                  }
                },
              ),
            AccessoryButton(
              icon: Icons.add,
              onTap: () => showAddQuickCommand(context, ref),
              semanticLabel: 'Add a quick command',
              tooltip: 'Add a quick command',
            ),
            // Jump and Terminal are both "leave this conversation for another
            // view". They live here rather than in the app bar because this is
            // where a thumb already is — the app bar is a stretch away at the
            // top of a phone.
            AccessoryButton(
              icon: Icons.bolt,
              onTap: onJump,
              semanticLabel: 'Jump to an agent',
              tooltip: 'Jump to an agent',
            ),
            AccessoryButton(
              icon: Icons.terminal,
              onTap: onOpenTerminal,
              semanticLabel: 'Open the raw terminal',
              tooltip: 'Open the raw terminal',
            ),
          ];

          // Spread evenly while everything fits; scroll as one strip once the
          // user's own commands push it past the edge. A uniform strip running
          // off the edge stays legible where a half-clipped chip does not.
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: constraints.maxWidth),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (var i = 0; i < buttons.length; i++) ...[
                    if (i > 0) const SizedBox(width: 6),
                    buttons[i],
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The bottom input bar — type a prompt (or an option number for a blocked
/// prompt) and send it to the agent. The send button submits with a trailing
/// newline; an empty send is a bare Enter (accepts a default prompt).
class _ComposerBar extends StatefulWidget {
  const _ComposerBar({
    required this.controller,
    required this.onSend,
    required this.onAttachImage,
    required this.enabled,
    this.hintText,
  });

  final TextEditingController controller;
  final Future<void> Function() onSend;

  /// Attaching acts on the message being written, so it lives inside the input
  /// pill rather than out in the actions row — the same place every messaging
  /// app puts it, and one fewer button competing in that row. Null while an
  /// upload is already in flight: one at a time, so the progress bar always
  /// describes the upload the user is actually watching.
  final Future<void> Function()? onAttachImage;
  final bool enabled;

  /// Overrides the default hint — e.g. while an approval card is up, to make
  /// clear that typing here answers it just as well as tapping a button.
  final String? hintText;

  @override
  State<_ComposerBar> createState() => _ComposerBarState();
}

class _ComposerBarState extends State<_ComposerBar> {
  static const _green = Color(0xFF00C853);
  final FocusNode _focus = FocusNode();
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChange);
    widget.controller.addListener(_onTextChange);
    _hasText = widget.controller.text.trim().isNotEmpty;
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    widget.controller.removeListener(_onTextChange);
    super.dispose();
  }

  void _onFocusChange() => setState(() {});

  void _onTextChange() {
    final has = widget.controller.text.trim().isNotEmpty;
    if (has != _hasText) setState(() => _hasText = has);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = widget.enabled;
    final focused = _focus.hasFocus;

    return Container(
      // One tone with the actions row above, so the two read as a single block
      // of controls rather than two stacked bars. The input pill's own darker
      // `surface` then reads as a well sunk into it.
      color: scheme.surfaceContainerLow,
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // The input pill: the message text field.
          Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOut,
              padding: const EdgeInsets.fromLTRB(4, 0, 16, 0),
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: BorderRadius.circular(26),
                border: Border.all(
                  color: focused
                      ? _green.withValues(alpha: 0.7)
                      : scheme.outlineVariant.withValues(alpha: 0.5),
                  width: focused ? 1.5 : 1,
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _AttachButton(
                    onTap: enabled ? widget.onAttachImage : null,
                    scheme: scheme,
                  ),
                  Expanded(
                    child: TextField(
                      controller: widget.controller,
                      focusNode: _focus,
                      enabled: enabled,
                      minLines: 1,
                      maxLines: 5,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      style: const TextStyle(fontSize: 15, height: 1.3),
                      decoration: InputDecoration(
                        isCollapsed: true,
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 12,
                        ),
                        hintText: !enabled
                            ? 'Unavailable'
                            : (widget.hintText ?? 'Message the agent…'),
                        hintStyle: TextStyle(color: scheme.onSurfaceVariant),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Prominent green paper-plane send.
          _SendButton(
            enabled: enabled,
            active: _hasText,
            onTap: enabled ? widget.onSend : null,
          ),
        ],
      ),
    );
  }
}

/// The paperclip inside the composer pill. Greyed while an upload is already in
/// flight (the caller passes null then) so a second pick can't start one the
/// progress bar isn't describing.
class _AttachButton extends StatelessWidget {
  const _AttachButton({required this.onTap, required this.scheme});

  final Future<void> Function()? onTap;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Attach an image',
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap == null ? null : () => onTap!(),
          child: SizedBox(
            width: 40,
            height: 44,
            child: Icon(
              Icons.add_photo_alternate_outlined,
              size: 21,
              semanticLabel: 'Attach an image',
              color: onTap == null
                  ? scheme.onSurfaceVariant.withValues(alpha: 0.4)
                  : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// The circular green paper-plane send button. Full green when there's text to
/// send, softer when the field is empty (a bare send is still valid — it accepts
/// a blocked agent's default), muted when the composer is disabled.
class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.enabled,
    required this.active,
    required this.onTap,
  });

  static const _green = Color(0xFF00C853);
  final bool enabled;
  final bool active;
  final Future<void> Function()? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Color bg = !enabled
        ? scheme.surfaceContainerHighest
        : (active ? _green : _green.withValues(alpha: 0.65));
    final Color fg = enabled
        ? Colors.white
        : scheme.onSurfaceVariant.withValues(alpha: 0.6);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: 48,
      height: 48,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap == null ? null : () => onTap!(),
          child: Center(child: Icon(Icons.send_rounded, size: 22, color: fg)),
        ),
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
                style: TextStyle(
                  color: scheme.onPrimaryContainer,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 3),
              Icon(
                Icons.schedule,
                size: 12,
                color: scheme.onPrimaryContainer.withValues(alpha: 0.7),
              ),
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
      final cmd =
          _firstNonEmpty([
            tool.command,
            tool.inputSummary,
            tool.subtitle,
            tool.title,
          ]) ??
          tool.name;
      return _Primary(Icons.terminal, '\$ $cmd', mono: true);
    case _ToolClass.edit:
      final file =
          _firstNonEmpty([
            tool.file,
            _basename(tool.inputSummary),
            tool.title,
          ]) ??
          tool.name;
      return _Primary(Icons.edit_outlined, file, mono: true);
    case _ToolClass.read:
      final file =
          _firstNonEmpty([
            tool.file,
            _basename(tool.inputSummary),
            tool.subtitle,
          ]) ??
          tool.name;
      return _Primary(Icons.description_outlined, file, mono: true);
    case _ToolClass.search:
      final pattern =
          _firstNonEmpty([
            tool.command,
            tool.subtitle,
            tool.inputSummary,
            tool.title,
          ]) ??
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

    // The rail's left edge sits on the same gutter as the assistant message
    // text above it (both are inside the body's horizontal:12 sliver, and the
    // message adds left:4) — so there's no left-margin jog switching between a
    // paragraph and its tool rows. The rail spans the whole group's height; the
    // row content is a small, consistent inset to its right.
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 2, 8),
      child: Container(
        padding: const EdgeInsets.only(left: 8),
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
    final diff = (result?.diff?.isNotEmpty ?? false) ? result!.diff : tool.diff;
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
            // Status marker on the right (trailing), like the previous
            // rendering — the ✓/✗/spinner ends each row.
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: _StatusDot(running: running, ok: ok),
            ),
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
          // Full-width from the ledger gutter — no extra left inset, so the
          // details/output box doesn't start under the command text and waste
          // the left space. (Right edge stays flush to the row.)
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 8),
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
            for (final line in lines) _diffLine(line, scheme, addBg, delBg),
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
    final head = [
      entry.roleRaw,
      entry.kindRaw,
    ].where((s) => s.isNotEmpty).join(' · ');
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
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
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
