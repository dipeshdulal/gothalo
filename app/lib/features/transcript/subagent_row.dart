import 'package:flutter/material.dart';

import '../../core/theme.dart';
import 'transcript_models.dart';

/// One delegated conversation, drawn under the Task call that spawned it.
///
/// Metadata only — the child transcript is never read to draw this. Tapping
/// opens it as its own stream (`?subagent=`), which is where the cost is paid.
class SubagentRow extends StatelessWidget {
  const SubagentRow({
    super.key,
    required this.subagent,
    required this.running,
    required this.onOpen,
  });

  final Subagent subagent;

  /// The spawning Task call has no result yet. Derived by the ledger, not
  /// carried on the roster — the wire has no status field.
  final bool running;

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.only(left: 8, top: 4, bottom: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(
                Icons.account_tree_outlined,
                size: 14,
                color: scheme.primary,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    subagent.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.3,
                      color: scheme.onSurface,
                    ),
                  ),
                  Text(
                    subagent.agentType,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: AppTheme.monoFamily,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (running) ...[
              const SizedBox(width: 8),
              Text(
                'RUNNING',
                style: TextStyle(
                  fontSize: 10,
                  fontFamily: AppTheme.monoFamily,
                  letterSpacing: 0.5,
                  color: scheme.primary,
                ),
              ),
            ],
            const SizedBox(width: 4),
            Icon(
              Icons.chevron_right,
              size: 16,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}
