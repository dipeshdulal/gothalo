import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/accessory_button.dart';
import '../transcript/quick_commands_providers.dart';

/// One control byte offered in the sheet: what it's called and what it sends.
class ControlKey {
  const ControlKey(this.label, this.bytes, this.hint);

  /// The caret form, which is how these are written everywhere else.
  final String label;
  final String bytes;

  /// What it does, in the words someone would use to look for it.
  final String hint;
}

/// The control bytes worth a button on a phone. Not "every Ctrl combination" —
/// that is what [_stickyCtrlHint] covers — but the ones you actually reach for
/// with no physical keyboard in front of you:
///
/// - `^C` interrupt, `^D` end of input, `^Z` suspend — the three that end or
///   detach from whatever is running.
/// - `^L` redraw. A phone repaint over a flaky tailnet garbles more often than a
///   desktop one, and this is the fix.
/// - `^R` reverse search. On a phone, recalling a command beats typing it by a
///   wide margin — arguably the single most valuable key here.
/// - `^U` kill line, `^W` kill word. Fixing a typo without forty backspaces.
/// - `^A` / `^E` line start and end, because a soft keyboard has no Home/End and
///   the arrow pad walks one character at a time.
///
/// `^C` is here as well as in the row: the row's is the emergency stop, this is
/// the canonical list, and a group missing the byte everyone knows would read
/// as an oversight.
const terminalControlKeys = [
  ControlKey('^C', '\x03', 'Interrupt'),
  ControlKey('^D', '\x04', 'End of input'),
  ControlKey('^Z', '\x1a', 'Suspend'),
  ControlKey('^L', '\x0c', 'Redraw'),
  ControlKey('^R', '\x12', 'Search history'),
  ControlKey('^U', '\x15', 'Kill line'),
  ControlKey('^W', '\x17', 'Kill word'),
  ControlKey('^A', '\x01', 'Line start'),
  ControlKey('^E', '\x05', 'Line end'),
];

const _stickyCtrlHint =
    'Arms Ctrl for the next key you type, for a combination not listed above.';

/// Everything the terminal's key row deliberately does not carry: the control
/// bytes beyond `^C`, the saved quick commands, and adding one.
///
/// This sheet exists so the row can be a fixed seven (see [AccessoryKeyRow]).
/// The quick commands in particular *had* to leave the row: they are
/// user-config, and a row that grows with your config is a row whose buttons
/// are never in the same place twice.
///
/// Every action closes the sheet, because every action's result is on the
/// terminal behind it. Multi-key work (walking a menu) is what the arrow pad is
/// for; this is for the single shot you came here to fire.
Future<void> showTerminalMoreSheet(
  BuildContext context, {
  required void Function(String bytes) onKey,
  required void Function(QuickCommand) onCommand,
  required bool stickyCtrl,
  required VoidCallback onToggleStickyCtrl,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => _MoreSheet(
      onKey: onKey,
      onCommand: onCommand,
      stickyCtrl: stickyCtrl,
      onToggleStickyCtrl: onToggleStickyCtrl,
    ),
  );
}

class _MoreSheet extends ConsumerWidget {
  const _MoreSheet({
    required this.onKey,
    required this.onCommand,
    required this.stickyCtrl,
    required this.onToggleStickyCtrl,
  });

  final void Function(String bytes) onKey;
  final void Function(QuickCommand) onCommand;
  final bool stickyCtrl;
  final VoidCallback onToggleStickyCtrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    // No filtering of the saved list here, unlike the old row: the reason a
    // command that merely fires Esc was dropped was that it cost a slot in a
    // strip with none to spare. A sheet has room, and quietly hiding something
    // the user saved is worse than showing it twice.
    final commands =
        ref.watch(quickCommandsProvider).asData?.value ??
        const <QuickCommand>[];

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        // Never more than most of the screen: the terminal behind it is the
        // thing being acted on and should stay in view.
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    color: scheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              _SheetHeading('Control keys'),
              const SizedBox(height: 8),
              _ButtonWrap(
                children: [
                  for (final k in terminalControlKeys)
                    AccessoryButton(
                      label: k.label,
                      semanticLabel: '${k.label} — ${k.hint}',
                      tooltip: k.hint,
                      onTap: () {
                        Navigator.pop(context);
                        onKey(k.bytes);
                      },
                    ),
                  // Sticky Ctrl survives the move out of the row, because the
                  // nine bytes above are a shortlist, not the space: ^K, ^P/^N,
                  // ^B/^F, ^X, ^G, ^] all matter to somebody, and a phone
                  // keyboard has no Ctrl key at all — without this they would be
                  // unreachable rather than merely slower. It arms and closes;
                  // the row's `⋯` lights up so the armed state is still visible
                  // from outside this sheet.
                  AccessoryButton(
                    label: 'Ctrl +',
                    active: stickyCtrl,
                    semanticLabel: stickyCtrl
                        ? 'Ctrl armed for the next key'
                        : 'Arm Ctrl for the next key',
                    tooltip: _stickyCtrlHint,
                    onTap: () {
                      Navigator.pop(context);
                      onToggleStickyCtrl();
                    },
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                _stickyCtrlHint,
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 20),
              _SheetHeading('Quick commands'),
              const SizedBox(height: 8),
              if (commands.isEmpty)
                Text(
                  'Nothing saved yet. A quick command is a prompt or a '
                  'keystroke you send often.',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                )
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final (i, c) in commands.indexed)
                      AccessoryButton(
                        label: c.label,
                        // Marks a command that fires a raw keystroke rather
                        // than typing text — the same cue the composer's chips
                        // use.
                        leading: c.key != null
                            ? Icons.keyboard_command_key
                            : null,
                        onTap: () {
                          Navigator.pop(context);
                          onCommand(c);
                        },
                        // Long-press to remove, exactly as in the row it left
                        // and in the transcript composer, so removing one means
                        // the same thing wherever you do it.
                        onLongPress: () async {
                          if (!await confirmRemoveQuickCommand(
                            context,
                            c.label,
                          )) {
                            return;
                          }
                          await ref
                              .read(quickCommandsProvider.notifier)
                              .removeAt(i);
                        },
                      ),
                  ],
                ),
              const SizedBox(height: 12),
              // The sheet stays open: the new command appears in the list
              // above, which is the confirmation that it saved.
              OutlinedButton.icon(
                onPressed: () => showAddQuickCommand(context, ref),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add a command'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A wrap of [AccessoryButton]s at their natural widths.
///
/// The [IntrinsicWidth] is load-bearing: a [Wrap] hands its children a bounded
/// maxWidth, and an AccessoryButton — a Container with an alignment — fills
/// whatever bounded width it is given. Without this every button becomes a
/// full-width slab and the wrap is a single tall column.
class _ButtonWrap extends StatelessWidget {
  const _ButtonWrap({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final child in children) IntrinsicWidth(child: child),
      ],
    );
  }
}

class _SheetHeading extends StatelessWidget {
  const _SheetHeading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        letterSpacing: 0.6,
      ),
    );
  }
}
