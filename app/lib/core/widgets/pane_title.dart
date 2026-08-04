import 'package:flutter/material.dart';

/// The shared app-bar title for a single pane, agent or not: a bold headline
/// on top, and a small muted subtitle line (git/location context, plus a
/// live-connection dot + label) underneath. Used by both the transcript
/// (agent chat) screen and the raw terminal screen, so a phone user gets the
/// same at-a-glance context — what this pane is, where it lives, whether it's
/// still connected — regardless of which view they're in. Previously each
/// screen's app bar spent its actions row on a standalone connection-status
/// icon; folding it into the subtitle here frees that space for actions that
/// actually change something.
class PaneTitle extends StatelessWidget {
  const PaneTitle({
    super.key,
    required this.title,
    required this.subtitle,
    required this.connLabel,
    required this.connColor,
  });

  final String title;

  /// Git/location context (e.g. a worktree + agent kind, or a shell's cwd).
  /// Empty when there's nothing worth showing beyond the connection label.
  final String subtitle;
  final String connLabel;
  final Color connColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.circle, size: 8, color: connColor),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                subtitle.isEmpty ? connLabel : '$subtitle · $connLabel',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
