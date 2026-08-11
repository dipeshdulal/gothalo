import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../core/tokens.dart';
import '../../core/widgets/panel_row.dart';
import '../../data/bridge/models/usage.dart';
import 'usage_providers.dart';

/// A compact, complete Claude usage card. It renders nothing until Claude is
/// actually configured on the active host, so a machine without Claude has no
/// dead provider card. There is no detail route: these are the full live windows
/// the bridge currently exposes.
class ClaudeUsageStrip extends ConsumerWidget {
  const ClaudeUsageStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usage = ref.watch(claudeUsageProvider).value;
    final card = usage == null || !usage.available
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.symmetric(vertical: Space.xs),
            child: PanelRow(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              child: Row(
                children: [
                  Icon(
                    Icons.speed_outlined,
                    size: 17,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Claude usage',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          'Live quota · refreshes every minute',
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                      ],
                    ),
                  ),
                  if (usage.fiveHour case final window?)
                    _UsageMetric(window: window, label: '5h'),
                  if (usage.sevenDay case final window?) ...[
                    const SizedBox(width: Space.lg),
                    _UsageMetric(window: window, label: '7d'),
                  ],
                ],
              ),
            ),
          );

    // Usage arrives independently of the snapshot. Animate its insertion so
    // Priority and the agent list do not jump when the quota request completes.
    return AnimatedSize(
      duration: Motion.medium,
      reverseDuration: Motion.medium,
      curve: Motion.curve,
      alignment: Alignment.topCenter,
      child: card,
    );
  }
}

class _UsageMetric extends StatelessWidget {
  const _UsageMetric({required this.window, required this.label});

  final UsageWindow window;
  final String label;

  @override
  Widget build(BuildContext context) =>
      _UsageRing(window: window, label: label, size: 46, strokeWidth: 4);
}

class _UsageRing extends StatelessWidget {
  const _UsageRing({
    required this.window,
    required this.label,
    this.size = 76,
    this.strokeWidth = 7,
  });

  final UsageWindow window;
  final String label;
  final double size;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    final percent = window.utilization.clamp(0, 100).toDouble();
    final color = usageColor(context, percent);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: size,
          height: size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                value: percent / 100,
                strokeWidth: strokeWidth,
                backgroundColor: Theme.of(
                  context,
                ).colorScheme.outlineVariant.withValues(alpha: 0.35),
                color: color,
              ),
              Text(
                '${percent.round()}%',
                style: TextStyle(
                  color: color,
                  fontSize: size < 60 ? 11 : 17,
                  fontWeight: FontWeight.w700,
                ).mono,
              ),
            ],
          ),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 10,
          ),
        ),
        if (window.resetsAt case final reset?)
          Text(
            formatUsageReset(reset),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 8.5,
            ),
          ),
      ],
    );
  }
}

Color usageColor(BuildContext context, double percent) {
  final scheme = Theme.of(context).colorScheme;
  return percent >= 90
      ? scheme.error
      : percent >= 70
      ? Colors.orange
      : scheme.primary;
}

String formatUsageReset(DateTime reset) {
  final remaining = reset.difference(DateTime.now());
  if (remaining.isNegative) return 'now';
  if (remaining.inDays > 0) {
    return 'in ${remaining.inDays}d ${remaining.inHours.remainder(24)}h';
  }
  if (remaining.inHours > 0) {
    return 'in ${remaining.inHours}h ${remaining.inMinutes.remainder(60)}m';
  }
  return 'in ${remaining.inMinutes}m';
}
