import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xterm/xterm.dart';

import '../../core/connection/connection.dart';
import '../../core/theme.dart';
import '../../core/widgets/pane_title.dart';
import '../../data/bridge/bridge_client.dart';
import '../../data/bridge/bridge_providers.dart';
import '../../data/bridge/models/snapshot.dart';
import '../../features/approvals/approve_action.dart';
import '../inbox/inbox_providers.dart';
import '../jump/jump_sheet.dart';

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

class _TerminalScreenState extends ConsumerState<TerminalScreen> {
  final terminal = Terminal(maxLines: 10000);
  bool _stickyCtrl = false;

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
  }

  @override
  void dispose() {
    _disposed = true;
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
          // The contract is binary-only. Text frames would have closed the
          // socket server-side; guard anyway so a stray frame can't crash us.
          if (message is List<int>) {
            _decoder?.add(message);
          } else if (message is String) {
            terminal.write(message);
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
    // A non-agent pane (plain shell, dev server, log) isn't in [agents] at
    // all — fall back to the flat pane list for its location, so the title
    // subtitle still has something to show.
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
        titleSpacing: 12,
        title: PaneTitle(
          title: agent?.displayTitle ?? widget.pane,
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
            tooltip: 'Overview',
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
                    theme: TerminalThemes.defaultTheme,
                    textStyle: const TerminalStyle(
                      fontFamily: AppTheme.monoFamily,
                    ),
                    padding: const EdgeInsets.all(8),
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
          if (_conn != _Conn.closed)
            _AccessoryKeyRow(
              stickyCtrl: _stickyCtrl,
              onToggleCtrl: () => setState(() => _stickyCtrl = !_stickyCtrl),
              onKey: _send,
            ),
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
                'This pane was closed',
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
                    label: const Text('Overview'),
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

/// D6: a toolbar above the soft keyboard that writes control bytes the on-screen
/// keyboard lacks — Esc/Tab/arrows, and a sticky-Ctrl toggle.
class _AccessoryKeyRow extends StatelessWidget {
  const _AccessoryKeyRow({
    required this.stickyCtrl,
    required this.onToggleCtrl,
    required this.onKey,
  });

  final bool stickyCtrl;
  final VoidCallback onToggleCtrl;
  final void Function(String bytes) onKey;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        color: scheme.surfaceContainerHigh,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _Key(label: 'Esc', onTap: () => onKey('\x1b')),
              _Key(label: 'Ctrl', active: stickyCtrl, onTap: onToggleCtrl),
              _Key(label: 'Tab', onTap: () => onKey('\t')),
              _Key(label: '↑', onTap: () => onKey('\x1b[A')),
              _Key(label: '↓', onTap: () => onKey('\x1b[B')),
              _Key(label: '←', onTap: () => onKey('\x1b[D')),
              _Key(label: '→', onTap: () => onKey('\x1b[C')),
              _Key(label: '^C', onTap: () => onKey('\x03')),
            ],
          ),
        ),
      ),
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({required this.label, required this.onTap, this.active = false});

  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Material(
        color: active ? scheme.primary : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minWidth: 44, minHeight: 40),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              label,
              style: TextStyle(
                color: active ? scheme.onPrimary : scheme.onSurface,
                fontWeight: FontWeight.w600,
                fontFamily: AppTheme.monoFamily,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
