import 'package:flutter/material.dart';

import '../theme.dart';

/// Renders how long an agent has been in its current state — the "50m" in
/// "Blocked · 50m".
///
/// This is the number that decides whether you act. Every other thing on a row
/// says WHAT an agent is; only this says how long it has been that way, and
/// "blocked" means something very different at ten seconds than at fifty
/// minutes.
///
/// Renders nothing at all when the duration is unknown. That is deliberate: the
/// bridge omits the age for an agent it cannot date, and showing "0s" there
/// would read as "just now" — precisely backwards for an agent that has been
/// parked for hours.
class AgentAge extends StatelessWidget {
  const AgentAge(this.since, {super.key, this.emphasize = false});

  /// Time since the agent last did anything, or null when unknown.
  final Duration? since;

  /// Draw attention to it — used where the wait is the point (a blocked agent).
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    final d = since;
    if (d == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Text(
      formatAgentAge(d),
      style: TextStyle(
        // A duration is an identifier-style value (it sits on the status line
        // next to the dot), so it is set in mono like the rest of them.
        fontFamily: AppTheme.monoFamily,
        fontSize: 11,
        fontWeight: emphasize ? FontWeight.w600 : FontWeight.w500,
        color: emphasize ? scheme.error : scheme.onSurfaceVariant,
      ),
    );
  }
}

/// Formats a duration the way a glance reads it: one unit, no decimals.
///
/// Precision is deliberately dropped as the span grows. Nobody deciding whether
/// to pick up their phone cares that an agent has been idle for 3h 14m rather
/// than 3h — but the difference between 30s and 30m decides it entirely, so the
/// short end keeps its resolution.
String formatAgentAge(Duration d) {
  final s = d.inSeconds;
  if (s < 60) return '${s}s';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  return '${d.inDays}d';
}
