import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart' show ImageSource;
import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xterm/xterm.dart';

import '../../core/connection/connection.dart';
import '../../core/naming.dart';
import '../../core/theme.dart';
import '../../core/widgets/pane_title.dart';
import '../../data/bridge/bridge_client.dart';
import '../../data/bridge/bridge_providers.dart';
import '../../data/bridge/models/snapshot.dart';
import '../../features/approvals/approve_action.dart';
import '../attach/image_attach.dart';
import '../inbox/inbox_providers.dart';
import '../jump/jump_sheet.dart';
import '../recents/record_open.dart';
import '../recents/recent_providers.dart';
import '../suggestions/pane_suggestions_bar.dart';
import '../transcript/quick_commands_providers.dart';
import 'accessory_key_row.dart';
import 'direction_pad.dart';
import 'pty_mouse_handler.dart';
import 'terminal_more_sheet.dart';

/// Where the live-terminal socket is in its lifecycle, for the app-bar dot.
/// [closed] is terminal: the pane no longer exists (closed on the host or the
/// agent finished), so we stop reconnecting.
enum _Conn { connecting, connected, disconnected, closed }

/// The live terminal — a real WebSocket to the bridge's `WS /attach`.
///
/// Binary frames both ways (per `docs/API.md`): the bridge streams raw PTY
/// bytes which are decoded and written into the [Terminal] buffer, and every
/// keystroke — from the on-screen keyboard (`terminal.onOutput`) or the D6
/// accessory key row — is sent back as a binary frame. On an unexpected drop we
/// reconnect with backoff and re-fetch `/snapshot` (the resilience story is
/// reconnect, not mosh-style state sync). The subprocess dies with the socket.
class TerminalScreen extends ConsumerStatefulWidget {
  const TerminalScreen({super.key, required this.pane});

  final String pane;

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends ConsumerState<TerminalScreen>
    with RecentOpenRecorder {
  /// [PtyMouseHandler] replaces xterm's wheel encoding so a drag on an
  /// alt-screen pane actually scrolls the application — see its doc comment.
  final terminal = Terminal(
    maxLines: 10000,
    mouseHandler: const PtyMouseHandler(),
  );
  /// Sticky Ctrl (D6): armed from the more-sheet, consumed by the next single
  /// character sent. Lives here rather than in the sheet because the sheet
  /// closes the moment it is armed — and the key row lights `⋯` while it is.
  bool _stickyCtrl = false;

  /// Whether the arrow pad is popped open. Static so it stays as you left it
  /// while hopping between panes — there's no prefs store yet, so this is
  /// session-scoped rather than persisted.
  static bool _padOpen = false;

  /// The terminal's focus, held here so the pad's keyboard key can summon and
  /// dismiss the soft keyboard: focus is what drives xterm's text-input
  /// connection, and therefore whether the keyboard is up.
  final _termFocus = FocusNode();

  /// Pick → upload → path, shared with the transcript composer (see
  /// [ImageAttachController]). Here the path is *typed*, so it works for
  /// whatever is running in the pane rather than only for an agent.
  final ImageAttachController _attach = ImageAttachController();

  BridgeClient? _client;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  ByteConversionSink? _decoder;
  Timer? _reconnectTimer;
  int _attempts = 0;
  bool _disposed = false;
  _Conn _conn = _Conn.connecting;

  /// Coalesces resize signals. `onResize` fires continuously while the soft
  /// keyboard slides open/closed; sending each one flashes the screen with a
  /// full agent repaint. We debounce so exactly one resize goes out once the
  /// viewport settles — the PTY still ends at the right size (so content is
  /// restored after the keyboard closes) with a single clean repaint.
  Timer? _resizeDebounce;
  int _pendingCols = 0;
  int _pendingRows = 0;

  @override
  void initState() {
    super.initState();
    // Keystrokes typed into the TerminalView flow here → out to the bridge as
    // binary. No local echo: the PTY stream is the single source of truth.
    terminal.onOutput = _send;
    // Viewport changes (first layout, rotation, keyboard show/hide) flow here →
    // out as a resize control frame so the remote PTY matches the phone's width.
    terminal.onResize = _sendResize;
    // The pad's keyboard key shows which way it will go, so it has to repaint
    // when focus changes by any other route (tapping the buffer, Back).
    _termFocus.addListener(_onFocusChange);
    // Repaints the upload strip above the key row while an image is going out.
    _attach.addListener(_onAttachChanged);
  }

  void _onFocusChange() {
    if (mounted) setState(() {});
  }

  void _onAttachChanged() {
    if (mounted) setState(() {});
  }

  /// Summon or dismiss the soft keyboard. Unfocusing tears down xterm's text
  /// input connection, which is what actually lowers the keyboard.
  void _toggleKeyboard() {
    if (_termFocus.hasFocus) {
      _termFocus.unfocus();
    } else {
      _termFocus.requestFocus();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _termFocus.removeListener(_onFocusChange);
    _termFocus.dispose();
    _attach.removeListener(_onAttachChanged);
    _attach.dispose();
    _reconnectTimer?.cancel();
    _resizeDebounce?.cancel();
    _sub?.cancel();
    _channel?.sink.close(ws_status.normalClosure);
    super.dispose();
  }

  /// The `wss?://…/attach?pane=&token=` URL derived from the connection's base
  /// URL (`https`→`wss`, `http`→`ws`). WS clients can't reliably set an
  /// `Authorization` header, so the bearer rides in `?token=` per the contract.
  Uri _attachUri(Connection c) {
    final base = Uri.parse(c.baseUrl);
    return Uri(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: '/attach',
      queryParameters: {'pane': widget.pane, 'token': c.bearer},
    );
  }

  Future<void> _connect() async {
    final client = _client;
    if (client == null || _disposed) return;

    if (mounted) setState(() => _conn = _Conn.connecting);

    // Fresh UTF-8 decoder per connection — Herdr repaints the whole screen on
    // attach, so nothing carries over from a prior socket.
    _decoder = const Utf8Decoder(
      allowMalformed: true,
    ).startChunkedConversion(_TerminalSink(terminal));

    try {
      final channel = WebSocketChannel.connect(_attachUri(client.connection));
      _channel = channel;
      await channel.ready; // throws if the handshake fails (bad token, no host)
      if (_disposed) {
        channel.sink.close(ws_status.normalClosure);
        return;
      }
      _attempts = 0;
      if (mounted) setState(() => _conn = _Conn.connected);
      // Send our real geometry up front — onResize only fires on *change*, and
      // the viewport is usually already sized by the time the socket is ready,
      // so without this the PTY would stay at its default 80×24. Immediate (not
      // debounced) so the fresh PTY is sized before any interaction.
      _pendingCols = terminal.viewWidth;
      _pendingRows = terminal.viewHeight;
      _flushResize();

      _sub = channel.stream.listen(
        (message) {
          // Binary frames are terminal bytes; text frames are out-of-band
          // control messages from the bridge (see [_handleControl]).
          if (message is List<int>) {
            _decoder?.add(message);
          } else if (message is String) {
            _handleControl(message);
          }
        },
        onDone: _handleDrop,
        onError: (_) => _handleDrop(),
        cancelOnError: true,
      );
    } catch (_) {
      _handleDrop();
    }
  }

  /// A text frame is an out-of-band control message from the bridge. The only
  /// one today is `{"type":"mode","agent":bool}`, sent when the pane's occupant
  /// changed and the bridge swapped the backend feeding this same socket —
  /// typing `claude` into a plain shell, or that agent exiting back to it.
  ///
  /// Anything that isn't a JSON object is written through rather than dropped:
  /// terminal bytes are supposed to arrive as binary frames, but losing output
  /// is worse than rendering a stray one.
  void _handleControl(String message) {
    Object? decoded;
    try {
      decoded = jsonDecode(message);
    } catch (_) {
      decoded = null;
    }
    if (decoded is! Map) {
      terminal.write(message);
      return;
    }
    if (decoded['type'] == 'mode') {
      _resetTerminal();
      // The next backend paints from scratch, and an agent PTY starts at the
      // default 80×24 — onResize only fires on *change*, so tell it our real
      // geometry the way a fresh connection does.
      _pendingCols = terminal.viewWidth;
      _pendingRows = terminal.viewHeight;
      _flushResize();
    }
  }

  /// Wipe the emulator between backends. The two streams are different shapes
  /// of output — an agent's alt-screen TUI versus whole-frame repaints of a
  /// plain shell — and one's leftovers corrupt the other: an alt-screen that
  /// was never exited leaves every following frame painting into a buffer the
  /// user cannot scroll back through.
  void _resetTerminal() {
    if (terminal.isUsingAltBuffer) {
      terminal.useMainBuffer();
    }
    terminal.buffer.clear();
    terminal.write('\x1b[H'); // cursor home; clear() only refills the lines
    // A swap can split a multi-byte sequence across the two streams, so the
    // decoder starts fresh too.
    _decoder = const Utf8Decoder(
      allowMalformed: true,
    ).startChunkedConversion(_TerminalSink(terminal));
  }

  /// Socket closed or failed to open. Before reconnecting, find out whether the
  /// pane still exists: a pane closed on the host (or a finished agent) will
  /// never come back, so we stop and show a terminal [_Conn.closed] state
  /// instead of reconnecting forever. A transient network drop (snapshot also
  /// unreachable) keeps reconnecting with capped backoff.
  void _handleDrop() {
    if (_disposed) return;
    _sub?.cancel();
    _sub = null;
    _channel = null;
    if (mounted) setState(() => _conn = _Conn.disconnected);

    if (_attempts == 0) {
      terminal.write(
        '\r\n\x1b[2m— connection lost, reconnecting… —\x1b[0m\r\n',
      );
    }
    _attempts++;
    unawaited(_checkGoneThenReconnect());
  }

  Future<void> _checkGoneThenReconnect() async {
    final client = _client;
    if (client == null || _disposed) return;
    // Keep the rest of the app's snapshot fresh too.
    ref.read(snapshotControllerProvider.notifier).refresh();

    bool gone = false;
    try {
      final snap = await client.getSnapshot();
      gone =
          !snap.panes.any((p) => p.paneId == widget.pane) &&
          !snap.agents.any((a) => a.paneId == widget.pane);
    } catch (_) {
      // Couldn't reach the bridge to check → treat as a transient drop and
      // keep retrying rather than falsely declaring the pane closed.
      gone = false;
    }
    if (_disposed) return;

    if (gone) {
      _reconnectTimer?.cancel();
      terminal.write('\r\n\x1b[2m— this pane was closed —\x1b[0m\r\n');
      if (mounted) setState(() => _conn = _Conn.closed);
      return;
    }

    final delay = Duration(seconds: _attempts.clamp(1, 8));
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, _connect);
  }

  /// Sends [data] to the PTY stdin as a **binary** frame. Applies sticky-Ctrl
  /// (D6) to a single character: letter & 0x1f collapses the whole Ctrl-combo
  /// space into one toggle.
  void _send(String data) {
    final channel = _channel;
    if (channel == null || _conn != _Conn.connected) return;

    var out = data;
    if (_stickyCtrl && data.length == 1) {
      out = String.fromCharCode(data.codeUnitAt(0) & 0x1f);
      setState(() => _stickyCtrl = false);
    }
    channel.sink.add(Uint8List.fromList(utf8.encode(out)));
  }

  /// Fire a [QuickCommand] into the raw PTY. A text command is typed and
  /// submitted (a trailing CR — what a terminal Enter sends); a keyed command
  /// (e.g. "esc" to interrupt) becomes its control byte. Unlike the transcript,
  /// which routes these over the bridge's /send, here they're just raw bytes on
  /// the same channel as the keyboard.
  void _handleQuickCommand(QuickCommand cmd) {
    if (cmd.key != null) {
      _send(_keyBytes(cmd.key!));
    } else {
      _send('${cmd.text}\r');
    }
  }

  /// Attach a screenshot or photo: pick it, upload it to this pane, and type
  /// the path the bridge wrote into the terminal.
  ///
  /// Typed, not sent over `/send`, so it lands wherever the keyboard lands —
  /// Claude's prompt box, a shell's command line, a `vim` buffer. The bridge
  /// resolves the drop directory from the pane itself, so this works on a pane
  /// with no agent in it too: the result is a path, and a path is just text.
  Future<void> _attachImage(ImageSource source) => _attach.attach(
    client: _client,
    pane: widget.pane,
    source: source,
    onPath: _typePath,
  );

  /// Type [path] into the PTY **without a carriage return**, the same as the
  /// transcript dropping it into the composer: the user writes the prompt
  /// around it and submits when they mean to. A trailing space keeps the next
  /// word off the filename.
  void _typePath(String path) {
    if (!mounted) return;
    if (_conn != _Conn.connected) {
      // The upload succeeded but there is no stream to type into. Name the file
      // anyway — it is on disk, and the next thing the user needs is where.
      _attach.fail('Not connected, so the path was not typed. It is at $path');
      return;
    }
    _send('${attachPathText(path)} ');
    // The path alone is not a prompt; bring the keyboard up so the sentence
    // around it can be written straight away.
    _termFocus.requestFocus();
  }

  /// Maps a quick command's key name to the bytes a terminal expects. Falls
  /// back to sending the name literally so a typo just types instead of doing
  /// nothing.
  String _keyBytes(String key) => switch (key.toLowerCase().trim()) {
    'esc' || 'escape' => '\x1b',
    'enter' || 'return' => '\r',
    'tab' => '\t',
    'up' => '\x1b[A',
    'down' => '\x1b[B',
    'left' => '\x1b[D',
    'right' => '\x1b[C',
    'ctrl+c' || '^c' => '\x03',
    'ctrl+d' || '^d' => '\x04',
    _ => key,
  };

  /// Sends the terminal geometry to the bridge as a **text** control frame
  /// (`{"type":"resize","cols":C,"rows":R}`) — distinct from the binary PTY
  /// byte stream. The bridge resizes the remote PTY so line-editing redraws
  /// (autocomplete, history recall, wrapping) stay aligned with the phone's
  /// viewport. Fired on first layout and on every later resize.
  void _sendResize(int cols, int rows, int pixelWidth, int pixelHeight) {
    if (cols <= 0 || rows <= 0) return;
    // Debounce: onResize fires repeatedly during the keyboard's slide animation;
    // hold off until it settles, then send one resize (in _flushResize).
    _pendingCols = cols;
    _pendingRows = rows;
    _resizeDebounce?.cancel();
    _resizeDebounce = Timer(const Duration(milliseconds: 150), _flushResize);
  }

  /// Sends the latest pending geometry as one resize control frame.
  void _flushResize() {
    final channel = _channel;
    if (channel == null || _conn != _Conn.connected) return;
    if (_pendingCols <= 0 || _pendingRows <= 0) return;
    channel.sink.add(
      jsonEncode({
        'type': 'resize',
        'cols': _pendingCols,
        'rows': _pendingRows,
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Connect once a bridge client is available (activeConnection resolves
    // async), and reconnect if it changes underneath us.
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

    // The agent behind this pane, for the app-bar approve affordance.
    final snap = ref.watch(snapshotControllerProvider).asData?.value;
    final agents = snap?.agents ?? const <Agent>[];
    Agent? agent;
    for (final a in agents) {
      if (a.paneId == widget.pane) {
        agent = a;
        break;
      }
    }
    // "I was just in this agent's terminal" — recorded so the home screen's
    // Recent section can put you back in the terminal rather than the chat.
    // Once per visit; see [RecentOpenRecorder].
    recordRecentOpen(agent, view: OpenedView.terminal);

    // A non-agent pane (plain shell, dev server, log) isn't in [agents] at
    // all — fall back to the flat pane list, which is what names it: a
    // terminal is called after what is running in it and where, never after
    // its pane id.
    Pane? pane;
    if (agent == null) {
      for (final p in snap?.panes ?? const <Pane>[]) {
        if (p.paneId == widget.pane) {
          pane = p;
          break;
        }
      }
    }
    // Non-null (and final) only when this pane's agent is blocked — safe to
    // capture in the button's callback.
    final approvable = agent?.agentStatus == AgentStatus.blocked ? agent : null;

    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: AppTheme.scaffoldBase(Theme.of(context).brightness),
      appBar: AppBar(
        title: PaneTitle(
          // An agent pane is titled by its task. A terminal is titled by what
          // is running in it and the project it is running in — `shell ·
          // gothalo`, `npm run dev · gothalo`. `w1N:p3` was never a name; it
          // is the address we dial, and it is not shown. The pane id survives
          // as the last resort only for the window between pushing this route
          // and the snapshot arriving, when we genuinely know nothing else.
          title: agent?.displayTitle ??
              (pane != null ? terminalTitle(pane) : widget.pane),
          subtitle: agent != null
              ? [
                  agent.gitLabel,
                  agent.agent,
                ].where((s) => s.isNotEmpty).join(' · ')
              : (pane?.locationLabel ?? ''),
          connLabel: switch (_conn) {
            _Conn.connected => 'Live',
            _Conn.connecting => 'Connecting…',
            _Conn.disconnected => 'Reconnecting…',
            _Conn.closed => 'Closed',
          },
          connColor: switch (_conn) {
            _Conn.connected => scheme.primary,
            _Conn.connecting => scheme.onSurfaceVariant,
            _Conn.disconnected => scheme.error,
            _Conn.closed => scheme.onSurfaceVariant,
          },
        ),
        actions: [
          IconButton(
            tooltip: 'Jump to an agent',
            onPressed: () => showJumpSheet(context, currentPane: widget.pane),
            icon: const Icon(Icons.bolt),
          ),
          if (approvable != null)
            IconButton(
              tooltip: 'Approve',
              onPressed: () => approveAgent(context, ref, approvable),
              icon: const Icon(Icons.check_circle_outline),
              color: scheme.primary,
            ),
          // The chat/transcript view is only meaningful for an agent pane.
          if (agent != null)
            IconButton(
              tooltip: 'Chat view',
              onPressed: () => context.push(
                '/transcript/${Uri.encodeComponent(widget.pane)}',
              ),
              icon: const Icon(Icons.chat_bubble_outline),
            ),
          IconButton(
            tooltip: 'Projects',
            onPressed: () => context.push('/overview'),
            icon: const Icon(Icons.grid_view_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: TerminalView(
                    terminal,
                    focusNode: _termFocus,
                    theme: TerminalThemes.defaultTheme,
                    textStyle: const TerminalStyle(
                      fontFamily: AppTheme.monoFamily,
                    ),
                    padding: const EdgeInsets.all(8),
                  ),
                ),
                // The arrow pad, popped open by the accessory row's toggle and
                // anchored just above it. Kept mounted while closed so a
                // held-then-hidden key can still cancel its own repeat.
                if (_conn != _Conn.closed)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 8,
                    child: Align(
                      // Centred, not tucked into the corner: the thumb reaches
                      // either side of it equally, and it reads as part of the
                      // bar below rather than something stuck to one edge.
                      alignment: Alignment.bottomCenter,
                      child: IgnorePointer(
                        ignoring: !_padOpen,
                        child: AnimatedScale(
                          // Grows up out of the bar rather than appearing on
                          // top of the text all at once.
                          scale: _padOpen ? 1 : 0.85,
                          alignment: Alignment.bottomCenter,
                          duration: const Duration(milliseconds: 120),
                          curve: Curves.easeOutCubic,
                          child: AnimatedOpacity(
                            opacity: _padOpen ? 1 : 0,
                            duration: const Duration(milliseconds: 120),
                            child: DirectionPad(onKey: _send),
                          ),
                        ),
                      ),
                    ),
                  ),
                // The pane is gone — dim the last frame and offer a way out
                // rather than sitting on a stale terminal.
                if (_conn == _Conn.closed)
                  Positioned.fill(
                    child: _ClosedOverlay(
                      onBack: () {
                        if (context.canPop()) context.pop();
                      },
                      onOverview: () => context.push('/overview'),
                    ),
                  ),
              ],
            ),
          ),
          // No point typing into a pane that no longer exists.
          if (_conn != _Conn.closed) ...[
            // Context chips for whatever is actually running in this pane —
            // open the dev server it is serving, review the agent's changes,
            // resolve a stopped rebase, start an agent in an idle shell.
            // Renders nothing at all when the bridge has nothing to offer,
            // which is the usual case.
            //
            // This screen is where it earns its place: the chat view already
            // carries a diff button in its app bar, and a plain shell pane —
            // where the dev server usually runs — has no chat view at all, so
            // the terminal is the only surface where every one of these is
            // otherwise several taps away.
            PaneSuggestionsBar(pane: widget.pane),
            // Directly above the bar whose button started the upload, so
            // progress and the button that caused it read as one thing. Renders
            // nothing while idle.
            ImageUploadStatus(controller: _attach),
            AccessoryKeyRow(
              padOpen: _padOpen,
              onTogglePad: () => setState(() => _padOpen = !_padOpen),
              keyboardOpen: _termFocus.hasFocus,
              onToggleKeyboard: _toggleKeyboard,
              // `⋯` stays lit while sticky Ctrl is armed from the sheet — the
              // only trace of the armed state once the sheet has closed.
              moreArmed: _stickyCtrl,
              onMore: () => showTerminalMoreSheet(
                context,
                onKey: _send,
                onCommand: _handleQuickCommand,
                stickyCtrl: _stickyCtrl,
                onToggleStickyCtrl: () =>
                    setState(() => _stickyCtrl = !_stickyCtrl),
              ),
              onKey: _send,
              uploading: _attach.uploading,
              onAttachImage: () =>
                  showImageSourceSheet(context, onPick: _attachImage),
            ),
          ],
        ],
      ),
    );
  }
}

/// Bridges the chunked UTF-8 decoder's string output straight into the terminal
/// buffer. Chunked (not per-frame) decoding so a multi-byte sequence split
/// across two binary frames still renders correctly.
class _TerminalSink implements Sink<String> {
  _TerminalSink(this.terminal);

  final Terminal terminal;

  @override
  void add(String data) => terminal.write(data);

  @override
  void close() {}
}

/// Shown over the last (now-stale) terminal frame once the pane is gone: a scrim
/// with a short explanation and a way out, instead of a frozen terminal.
class _ClosedOverlay extends StatelessWidget {
  const _ClosedOverlay({required this.onBack, required this.onOverview});

  final VoidCallback onBack;
  final VoidCallback onOverview;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.scrim.withValues(alpha: 0.6),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.tab_unselected, size: 44, color: scheme.onSurface),
              const SizedBox(height: 12),
              Text(
                'This terminal was closed',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              Text(
                'It was closed on the host or the agent finished. The last screen is shown above.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OutlinedButton.icon(
                    onPressed: onOverview,
                    icon: const Icon(Icons.grid_view_outlined, size: 18),
                    label: const Text('Projects'),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: onBack,
                    icon: const Icon(Icons.arrow_back, size: 18),
                    label: const Text('Back'),
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
