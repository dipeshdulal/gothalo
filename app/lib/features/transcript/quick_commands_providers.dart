import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/connection/connection_providers.dart';

/// One reusable prompt or keystroke, shown as a button in the composer's
/// actions row and in the terminal's accessory bar —
/// the Termius/Blink "snippets" table stake gothalo lacked (see
/// docs/RESEARCH-feature-ideas.md, #7). Exactly one of [text]/[key] is set:
/// [text] is typed and submitted like a composer message; [key] sends a raw
/// keystroke (e.g. "esc" to interrupt) via the same path as a
/// [key]-only [BlockedOption].
class QuickCommand {
  const QuickCommand({required this.label, this.text, this.key})
    : assert(
        (text == null) != (key == null),
        'QuickCommand needs exactly one of text/key',
      );

  final String label;
  final String? text;
  final String? key;

  Map<String, dynamic> toJson() => {
    'label': label,
    if (text != null) 'text': text,
    if (key != null) 'key': key,
  };

  factory QuickCommand.fromJson(Map<String, dynamic> j) => QuickCommand(
    label: (j['label'] as String?) ?? '',
    text: j['text'] as String?,
    key: j['key'] as String?,
  );
}

/// The starter set shown before the user has customized anything. Kept to
/// just the one thing that's actually hard to do otherwise — Esc has no
/// on-screen key on a phone keyboard — rather than guessing at generically
/// useful prompts; those are exactly what "+ Add" is for.
const _defaultQuickCommands = [QuickCommand(label: 'Interrupt', key: 'esc')];

/// Persisted, user-editable list of [QuickCommand]s. Stored in secure storage
/// like [starredAgentsProvider] — no schema, so it stays clear of the shared
/// drift database. One global list (not per-server/agent): a "run the tests"
/// nudge is just as useful wherever you're talking to an agent.
final quickCommandsProvider =
    AsyncNotifierProvider<QuickCommands, List<QuickCommand>>(QuickCommands.new);

class QuickCommands extends AsyncNotifier<List<QuickCommand>> {
  static const _key = 'gothalo.quick_commands';

  @override
  Future<List<QuickCommand>> build() async {
    final raw = await ref.watch(secureStorageProvider).read(key: _key);
    if (raw == null || raw.isEmpty) return _defaultQuickCommands;
    try {
      return (jsonDecode(raw) as List)
          .map((e) => QuickCommand.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return _defaultQuickCommands;
    }
  }

  Future<void> _persist(List<QuickCommand> next) async {
    state = AsyncData(next);
    await ref
        .read(secureStorageProvider)
        .write(
          key: _key,
          value: jsonEncode(next.map((c) => c.toJson()).toList()),
        );
  }

  Future<void> add(QuickCommand cmd) async {
    final next = [...(state.asData?.value ?? const <QuickCommand>[]), cmd];
    await _persist(next);
  }

  Future<void> removeAt(int index) async {
    final current = state.asData?.value ?? const <QuickCommand>[];
    if (index < 0 || index >= current.length) return;
    final next = [...current]..removeAt(index);
    await _persist(next);
  }
}

/// The long-press "remove this quick command?" confirm, shared by every surface
/// that shows the list — the transcript composer and the terminal's accessory
/// bar — so removing one means the same thing wherever you do it.
Future<bool> confirmRemoveQuickCommand(
  BuildContext context,
  String label,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Remove quick command?'),
      content: Text('"$label" will be removed.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Remove'),
        ),
      ],
    ),
  );
  return ok == true;
}

/// Opens the add-command dialog and persists the result to [quickCommandsProvider].
Future<void> showAddQuickCommand(BuildContext context, WidgetRef ref) {
  return showDialog<void>(
    context: context,
    builder: (context) => AddQuickCommandDialog(
      onAdd: (cmd) => ref.read(quickCommandsProvider.notifier).add(cmd),
    ),
  );
}

/// A small form for a custom quick command: a label, and either typed text
/// (submitted like a message / typed into the terminal) or a raw key name (for
/// something like "esc" — advanced, so it's a secondary field, not the default).
class AddQuickCommandDialog extends StatefulWidget {
  const AddQuickCommandDialog({super.key, required this.onAdd});
  final void Function(QuickCommand) onAdd;

  @override
  State<AddQuickCommandDialog> createState() => _AddQuickCommandDialogState();
}

class _AddQuickCommandDialogState extends State<AddQuickCommandDialog> {
  final _label = TextEditingController();
  final _text = TextEditingController();
  final _key = TextEditingController();

  @override
  void dispose() {
    _label.dispose();
    _text.dispose();
    _key.dispose();
    super.dispose();
  }

  bool get _valid =>
      _label.text.trim().isNotEmpty &&
      (_text.text.trim().isNotEmpty) != (_key.text.trim().isNotEmpty);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add quick command'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _label,
            decoration: const InputDecoration(labelText: 'Label'),
            onChanged: (_) => setState(() {}),
          ),
          TextField(
            controller: _text,
            decoration: const InputDecoration(
              labelText: 'Text to send',
              helperText: 'What gets typed and submitted',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Text('— or —', style: TextStyle(fontSize: 11)),
          ),
          TextField(
            controller: _key,
            decoration: const InputDecoration(
              labelText: 'Raw key (advanced)',
              helperText: 'e.g. "esc" — for a keystroke, not text',
            ),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _valid
              ? () {
                  final text = _text.text.trim();
                  final key = _key.text.trim();
                  widget.onAdd(
                    QuickCommand(
                      label: _label.text.trim(),
                      text: text.isNotEmpty ? text : null,
                      key: key.isNotEmpty ? key : null,
                    ),
                  );
                  Navigator.pop(context);
                }
              : null,
          child: const Text('Add'),
        ),
      ],
    );
  }
}
