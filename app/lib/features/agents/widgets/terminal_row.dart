import 'package:flutter/material.dart';

import '../../../core/naming.dart';
import '../../../core/theme.dart';
import '../../../core/tokens.dart';
import '../../../core/widgets/panel_row.dart';
import '../../../data/bridge/models/snapshot.dart';

/// A **terminal** — a pane with no agent in it — as a row.
///
/// Deliberately not [AgentRow] with everything switched off. A terminal has no
/// status to report, no chat to open, no age that means anything and no
/// approval to give; a row built to carry all of that and then hide it is worse
/// than a row that never had it. What it does share is the *shape*: the same
/// [PanelRow], the same paddings, the same glyph size, the same mono treatment
/// for identifiers, the same overflow slot. So a terminal row and an agent row
/// read as the same family without pretending to be the same thing.
///
/// It says what a terminal actually is: what is running in it, and where. Never
/// its pane id — see `terminalTitle`.
class TerminalRow extends StatelessWidget {
  const TerminalRow({
    super.key,
    required this.pane,
    required this.onTap,
    this.menu,
    this.focused = false,
  });

  final Pane pane;
  final VoidCallback onTap;

  /// Split, close, start an agent here — the same slot the agent row's menu
  /// sits in, so the two line up down the page.
  final Widget? menu;

  /// The pane Herdr has focused on the host.
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cmd = pane.command;
    final running = cmd != null;
    return PanelRow(
      onTap: onTap,
      selected: focused,
      borderColor: focused ? scheme.primary : null,
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Sized to match the agent row's avatar so the two columns of
              // glyphs line up rather than stepping in and out.
              CircleAvatar(
                radius: 11,
                backgroundColor: scheme.wellFill,
                child: Icon(
                  running ? Icons.play_arrow_rounded : Icons.terminal,
                  size: 13,
                  color: running ? scheme.primary : scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: Space.md),
              Expanded(
                child: Text(
                  terminalTitle(pane),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  // A command and a folder are both identifiers.
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    height: 1.25,
                  ).mono,
                ),
              ),
              const SizedBox(width: Space.md),
              _KindTag(running: running),
              if (menu case final m?) ...[const SizedBox(width: 2), m],
            ],
          ),
          // Where it is running, on the same indented meta line an agent row
          // uses for its project.
          if (pane.locationLabel.isNotEmpty) ...[
            const SizedBox(height: 3),
            Padding(
              padding: const EdgeInsets.only(left: 22 + Space.md),
              child: Text(
                pane.locationLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurfaceVariant,
                ).mono,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A small mono tag marking a terminal as actively **running** a command
/// (accent dot + label) or sitting idle at a **shell**. Sits where an agent
/// row's [StatusMark] sits, and is built the same way, because it answers the
/// same question for a thing that has no agent status.
class _KindTag extends StatelessWidget {
  const _KindTag({required this.running});
  final bool running;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = running ? scheme.primary : scheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (running) ...[
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: 6),
        ],
        Text(
          running ? 'RUNNING' : 'SHELL',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
            color: color,
          ).mono,
        ),
      ],
    );
  }
}
