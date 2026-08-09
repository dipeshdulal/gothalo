import 'package:flutter/material.dart';

import '../theme.dart';

/// One glyph and its number — "4 agents" without the words.
///
/// Shared by every surface that answers "what is open in here?" with compact
/// counts: the Flock's project row and the Projects page's headers both say
/// the same thing — so many agents, so many terminals — and used to print the
/// words eleven times down a column. The words are not gone; they moved into
/// [semantics], so a screen reader still hears "4 agents" while the eye reads
/// a 12px glyph and a mono number.
class CountPair extends StatelessWidget {
  const CountPair({
    super.key,
    required this.icon,
    required this.count,
    required this.semantics,
  });

  final IconData icon;
  final int count;

  /// The words the glyph replaced — "4 agents". Spoken rather than printed.
  final String semantics;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      // Its own node, not merged into the row's: a screen reader should hear
      // "4 agents" as a fact about the project, not have it run together with
      // the repo name into one sentence.
      container: true,
      label: semantics,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: scheme.onSurfaceVariant),
          const SizedBox(width: 3),
          Text(
            '$count',
            style: TextStyle(
              fontSize: 10.5,
              color: scheme.onSurfaceVariant,
            ).mono,
          ),
        ],
      ),
    );
  }
}
