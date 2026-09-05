import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../core/widgets/agent_age.dart';
import 'transcript_models.dart';

/// One line above the composer saying how many delegated agents are still
/// working, and opening the list of them.
///
/// A session that parallelises puts its Task calls wherever the conversation
/// happened to be, so "what is running right now" was only answerable by
/// scrolling back through hundreds of entries looking for rows. This is the
/// answer without the scroll.
///
/// It occupies **no height at all** when nothing is running, which is most
/// sessions most of the time — the same rule the suggestions bar follows, and
/// for the same reason: a permanently-present empty strip costs more chat than
/// it ever saves.
///
/// A line rather than a row of chips because the labels are task descriptions
/// ("Survey the plugin API") and chip-width truncation loses the
/// part that tells them apart.
class RunningSubagentsBar extends StatelessWidget {
  const RunningSubagentsBar({
    super.key,
    required this.roster,
    required this.onOpen,
  });

  final SubagentRoster roster;
  final void Function(Subagent) onOpen;

  @override
  Widget build(BuildContext context) {
    final running = roster.running;
    if (running.isEmpty) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final n = running.length;

    return InkWell(
      onTap: () => _open(context, running),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.account_tree_outlined, size: 15, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '$n ${n == 1 ? 'agent' : 'agents'} running',
                style: TextStyle(
                  fontSize: 12.5,
                  color: scheme.onSurface,
                  fontFamily: AppTheme.monoFamily,
                ),
              ),
            ),
            Icon(
              Icons.keyboard_arrow_up,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  void _open(BuildContext context, List<Subagent> running) {
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'RUNNING AGENTS',
                      style: TextStyle(
                        fontSize: 11,
                        letterSpacing: 0.5,
                        fontFamily: AppTheme.monoFamily,
                        color: Theme.of(sheetContext).colorScheme.primary,
                      ),
                    ),
                  ),
                  Text(
                    '${running.length}',
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: AppTheme.monoFamily,
                      color: Theme.of(
                        sheetContext,
                      ).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final s in running)
                    _RunningRow(
                      subagent: s,
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        onOpen(s);
                      },
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// One agent in the sheet — the full description, since the whole reason for a
/// sheet over chips is that these labels do not survive truncation.
class _RunningRow extends StatelessWidget {
  const _RunningRow({required this.subagent, required this.onTap});

  final Subagent subagent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final age = subagent.sinceLastActivity;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(Icons.account_tree_outlined, size: 15, color: scheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    subagent.displayTitle,
                    style: TextStyle(fontSize: 13, color: scheme.onSurface),
                  ),
                  Text(
                    subagent.agentType,
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: AppTheme.monoFamily,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (age != null) ...[
              const SizedBox(width: 8),
              Text(
                formatAgentAge(age),
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: AppTheme.monoFamily,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, size: 16, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
