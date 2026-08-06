import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/bridge/bridge_client.dart';
import '../../data/bridge/bridge_providers.dart';

/// The slash commands a pane's agent accepts (`GET /commands`), for the
/// composer typeahead. See docs/CONTRACT-commands.md.
///
/// `autoDispose`, so the list is refetched when the transcript screen is next
/// opened rather than cached for the life of the app. Deliberate: a command file
/// the user writes on the desktop should show up on the phone by reopening the
/// screen, and this is a directory walk on the bridge, not an expensive call.
///
/// Never surfaces an error state — [BridgeClient.getCommands] already maps every
/// "no typeahead here" case (old bridge, plain pane, agent kind with no command
/// surface) to an empty list, and an empty list is exactly how the UI hides
/// itself. There is nothing for the user to act on, so there is nothing to show.
final slashCommandsProvider =
    FutureProvider.autoDispose.family<List<SlashCommand>, String>((
  ref,
  pane,
) async {
  final client = ref.watch(bridgeClientProvider);
  if (client == null) return const [];
  try {
    return await client.getCommands(pane);
  } catch (_) {
    return const [];
  }
});

/// The active `/…` token in the composer, if the typeahead should be showing.
///
/// The rule is deliberately strict — the token must start at the VERY beginning
/// of the composer and contain no whitespace:
///
///   - `"/comp"`      → query "comp"        (typeahead open)
///   - `"/"`          → query ""            (typeahead open, full list)
///   - `"/compact "`  → null                (a space means the command is
///                                           chosen and arguments are being
///                                           typed — get out of the way)
///   - `"see /foo"`   → null                (a slash mid-sentence is prose, not
///                                           a command; agents only accept a
///                                           slash command as the whole message)
///
/// Matching the agent's own rule matters more than being helpful: offering a
/// typeahead where the agent would not accept a command teaches the user a
/// behaviour that then fails.
class SlashQuery {
  const SlashQuery(this.query);

  /// The text after "/", lowercased. Empty right after the slash.
  final String query;

  /// Parses [text] with the caret at [caret], or null when no typeahead applies.
  /// The caret must sit inside the token — moving it away dismisses the list.
  static SlashQuery? parse(String text, int caret) {
    if (!text.startsWith('/')) return null;
    if (text.contains(RegExp(r'\s'))) return null;
    if (caret < 1 || caret > text.length) return null;
    return SlashQuery(text.substring(1).toLowerCase());
  }
}

/// Ranks [commands] against a typed [query], best first, dropping non-matches.
///
/// Three tiers, because "what I meant" is usually a prefix and only sometimes a
/// substring:
///   1. the name starts with the query        (`comp` → `compact`)
///   2. a namespace segment starts with it    (`comp` → `git:compare`)
///   3. the name contains it anywhere         (`pact` → `compact`)
///
/// Descriptions are deliberately NOT searched. They are written for an agent's
/// dispatcher and run to several sentences, so matching them turns a two-letter
/// query into a list of near-everything — the opposite of a typeahead's job.
/// Within a tier the bridge's ordering is preserved, which keeps the project's
/// own commands above generic built-ins.
List<SlashCommand> rankSlashCommands(
  List<SlashCommand> commands,
  String query,
) {
  if (query.isEmpty) return commands;

  final prefix = <SlashCommand>[];
  final segment = <SlashCommand>[];
  final contains = <SlashCommand>[];

  for (final c in commands) {
    final name = c.name.toLowerCase();
    if (name.startsWith(query)) {
      prefix.add(c);
    } else if (name.split(':').skip(1).any((s) => s.startsWith(query))) {
      segment.add(c);
    } else if (name.contains(query)) {
      contains.add(c);
    }
  }
  return [...prefix, ...segment, ...contains];
}

/// The typeahead list, shown directly above the composer while a [SlashQuery] is
/// active and at least one command matches.
///
/// Height-capped and scrollable: on a phone the keyboard already owns half the
/// screen, and a list that grows into the conversation would push away the very
/// context you are writing about.
class SlashCommandList extends StatelessWidget {
  const SlashCommandList({
    super.key,
    required this.commands,
    required this.onSelected,
  });

  final List<SlashCommand> commands;
  final void Function(SlashCommand) onSelected;

  /// Roughly four rows. Past that the list is a screen of its own and the user
  /// is better served by typing another letter.
  static const _maxHeight = 232.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(maxHeight: _maxHeight),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        border: Border(
          top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
      ),
      child: ListView.builder(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: commands.length,
        itemBuilder: (context, i) => _SlashRow(
          command: commands[i],
          onTap: () => onSelected(commands[i]),
        ),
      ),
    );
  }
}

class _SlashRow extends StatelessWidget {
  const _SlashRow({required this.command, required this.onTap});

  final SlashCommand command;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          '/${command.name}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (command.argumentHint.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Text(
                          command.argumentHint,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (command.description.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        command.description,
                        // One line: these descriptions are written for an
                        // agent's dispatcher and run long. See the capture in
                        // CONTRACT-commands.md.
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _SourceBadge(command: command),
          ],
        ),
      ),
    );
  }
}

/// The provenance badge. Built-ins read differently on purpose: they are the one
/// group the bridge cannot verify against disk, so they are shown as a plain
/// outline rather than the filled treatment that says "this really is installed
/// on your host".
class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.command});

  final SlashCommand command;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final builtin = command.isBuiltin;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: builtin ? null : scheme.secondaryContainer,
        border: builtin
            ? Border.all(color: scheme.outlineVariant)
            : null,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        command.badge,
        style: TextStyle(
          fontSize: 10,
          height: 1.4,
          color: builtin ? scheme.onSurfaceVariant : scheme.onSecondaryContainer,
        ),
      ),
    );
  }
}

/// Replaces the composer's `/…` token with the chosen command, leaving the caret
/// after it.
///
/// Inserts WITHOUT sending, the same choice the image drop makes: a command
/// often takes an argument, and even when it does not, auto-firing something
/// like `/clear` off a single tap is not a mistake worth making on a phone. One
/// deliberate tap on send stays in the loop.
///
/// A trailing space is appended only when the command declares an
/// [SlashCommand.argumentHint] — with one you are certainly typing more, without
/// one the message is already complete and a stray trailing space would be sent
/// verbatim.
void applySlashCommand(TextEditingController controller, SlashCommand command) {
  final insert = command.argumentHint.isNotEmpty
      ? '/${command.name} '
      : '/${command.name}';
  controller.value = TextEditingValue(
    text: insert,
    selection: TextSelection.collapsed(offset: insert.length),
  );
  HapticFeedback.selectionClick();
}
