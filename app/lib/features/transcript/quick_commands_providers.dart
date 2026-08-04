import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/connection/connection_providers.dart';

/// One reusable prompt or keystroke, shown as a chip above the composer —
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
const _defaultQuickCommands = [
  QuickCommand(label: 'Interrupt', key: 'esc'),
];

/// Persisted, user-editable list of [QuickCommand]s. Stored in secure storage
/// like [starredAgentsProvider] — no schema, so it stays clear of the shared
/// drift database. One global list (not per-server/agent): a "run the tests"
/// nudge is just as useful wherever you're talking to an agent.
final quickCommandsProvider =
    AsyncNotifierProvider<QuickCommands, List<QuickCommand>>(
  QuickCommands.new,
);

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
    await ref.read(secureStorageProvider).write(
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
