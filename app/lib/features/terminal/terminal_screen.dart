import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../core/theme.dart';
import '../../data/bridge/bridge_providers.dart';

/// The live terminal — stubbed for now.
///
/// The `xterm` widget is wired up and a placeholder banner is written into the
/// buffer, but the backend `WS /attach` stream that would feed it isn't built
/// yet (Phase 2). Once it lands, connect a socket to [terminal] here. The
/// accessory key row (D6) is scaffolded below so the wiring is ready.
class TerminalScreen extends ConsumerStatefulWidget {
  const TerminalScreen({super.key, required this.pane});

  final String pane;

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends ConsumerState<TerminalScreen> {
  final terminal = Terminal(maxLines: 10000);
  bool _stickyCtrl = false;

  @override
  void initState() {
    super.initState();
    terminal.write(
      '\r\n  gothalo terminal — pane ${widget.pane}\r\n'
      '  \x1b[2mWS /attach is not wired yet (backend Phase 2).\x1b[0m\r\n'
      '  \x1b[2mThis buffer + key row are ready for the stream.\x1b[0m\r\n\r\n',
    );

    // When /attach exists, keystrokes route to the bridge instead of nowhere.
    terminal.onOutput = (data) {
      // TODO(phase2): forward to WS /attach for this pane.
    };
  }

  /// Sends a raw control sequence into the terminal's input path. With the
  /// socket wired, [terminal.textInput] flows to `onOutput` → the bridge.
  void _sendBytes(String data) {
    var out = data;
    if (_stickyCtrl && data.length == 1) {
      // Collapse the whole Ctrl-combo space into one toggle: letter & 0x1f (D6).
      out = String.fromCharCode(data.codeUnitAt(0) & 0x1f);
      setState(() => _stickyCtrl = false);
    }
    terminal.textInput(out);
    terminal.write(out); // local echo until the real stream feeds the buffer
  }

  @override
  Widget build(BuildContext context) {
    final connected = ref.watch(bridgeClientProvider) != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.pane),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Icon(
              connected ? Icons.circle : Icons.circle_outlined,
              size: 12,
              color: connected
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: TerminalView(
              terminal,
              theme: TerminalThemes.defaultTheme,
              textStyle: const TerminalStyle(fontFamily: AppTheme.monoFamily),
              padding: const EdgeInsets.all(8),
            ),
          ),
          _AccessoryKeyRow(
            stickyCtrl: _stickyCtrl,
            onToggleCtrl: () => setState(() => _stickyCtrl = !_stickyCtrl),
            onKey: _sendBytes,
          ),
        ],
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
              _Key(
                label: 'Ctrl',
                active: stickyCtrl,
                onTap: onToggleCtrl,
              ),
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
