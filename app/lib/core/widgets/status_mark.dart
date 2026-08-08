import 'package:flutter/material.dart';

import '../../data/bridge/models/snapshot.dart';
import '../theme.dart';

/// An agent's status as a coloured dot + small uppercase mono label — the
/// terminal-native replacement for the filled status pill. The dot carries the
/// status colour (colour stays on status alone); the label stays muted.
class StatusMark extends StatelessWidget {
  const StatusMark(this.status, {super.key, this.withLabel = true});

  final AgentStatus status;

  /// False keeps just the dot — for a row where the label reads redundantly.
  final bool withLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dot = status.dot(scheme);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(shape: BoxShape.circle, color: dot),
        ),
        if (withLabel) ...[
          const SizedBox(width: 6),
          Text(
            status.label.toUpperCase(),
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
              color: scheme.onSurfaceVariant,
            ).mono,
          ),
        ],
      ],
    );
  }
}
