import 'package:flutter/material.dart';

import '../../../core/theme.dart';
import '../../../core/tokens.dart';
import '../../../data/bridge/models/snapshot.dart';
import '../priority_providers.dart';

/// The footer under a capped Priority section: what the cap is holding back,
/// and the control that reveals it.
///
/// Collapsed it reads `3 need you · 5 done · 2 idle    Show 8 more ⌄` — the
/// tally covers the **whole** list, not just the hidden part, so a collapsed
/// section still says what it is sitting on rather than only how much of it is
/// missing. Expanded it drops to `Show less ⌃`; the counts are then redundant
/// with the rows themselves.
///
/// Renders nothing when there is no overflow, so the two-agent case is exactly
/// as it was.
class PriorityOverflowBar extends StatelessWidget {
  const PriorityOverflowBar({
    super.key,
    required this.overflow,
    required this.onToggle,
  });

  final PriorityOverflow overflow;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    if (!overflow.hasOverflow) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final expanded = overflow.expanded;

    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 12, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: expanded
                  ? const SizedBox.shrink()
                  : Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        for (final t in overflow.tally)
                          _CountChip(status: t.status, count: t.count),
                      ],
                    ),
            ),
            const SizedBox(width: 8),
            Text(
              expanded ? 'Show less' : 'Show ${overflow.hiddenCount} more',
              style: TextStyle(
                color: scheme.primary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            AnimatedRotation(
              turns: expanded ? 0.5 : 0,
              duration: Motion.fast,
              child: Icon(Icons.expand_more, size: 20, color: scheme.primary),
            ),
          ],
        ),
      ),
    );
  }
}

/// One `N need you` flat chip, in that status's own colours so the summary
/// reads in the same palette as the dots on the rows above it (and works in
/// both themes for free). A low-alpha status tint is the one place colour
/// other than the accent is allowed — it is status.
class _CountChip extends StatelessWidget {
  const _CountChip({required this.status, required this.count});

  final AgentStatus status;
  final int count;

  @override
  Widget build(BuildContext context) {
    final c = status.colors(Theme.of(context).colorScheme);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: c.bg,
        borderRadius: Radii.xsAll,
        border: Border.all(color: c.fg.withValues(alpha: 0.30)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(shape: BoxShape.circle, color: c.fg),
          ),
          const SizedBox(width: 5),
          Text(
            _label(status, count),
            style: TextStyle(
              color: c.fg,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.1,
            ),
          ),
        ],
      ),
    );
  }
}

/// "3 need you" rather than "3 blocked": the summary is read at a glance from
/// the home screen, where what matters is whether it is *your* turn — the
/// per-row badge already spells the state out.
String _label(AgentStatus status, int count) => switch (status) {
  AgentStatus.blocked => '$count need you',
  AgentStatus.done => '$count done',
  AgentStatus.working => '$count working',
  AgentStatus.idle => '$count idle',
  AgentStatus.unknown => '$count unknown',
};
