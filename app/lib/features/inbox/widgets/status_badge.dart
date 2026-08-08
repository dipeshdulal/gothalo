import 'package:flutter/material.dart';

import '../../../core/theme.dart';
import '../../../core/tokens.dart';
import '../../../data/bridge/models/snapshot.dart';

/// A compact pill showing an agent's [AgentStatus] — icon + label, colored per
/// status and brightness. `working` gently spins its icon.
class StatusBadge extends StatelessWidget {
  const StatusBadge(this.status, {super.key});

  final AgentStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = status.colors(scheme);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: c.bg,
        borderRadius: Radii.smAll,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Icon(status: status, color: c.fg),
          const SizedBox(width: 6),
          Text(
            status.label,
            style: TextStyle(
              color: c.fg,
              fontWeight: FontWeight.w600,
              fontSize: 12,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

/// The badge icon; spins while `working` so an active agent reads as alive.
class _Icon extends StatefulWidget {
  const _Icon({required this.status, required this.color});

  final AgentStatus status;
  final Color color;

  @override
  State<_Icon> createState() => _IconState();
}

class _IconState extends State<_Icon> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  );

  @override
  void initState() {
    super.initState();
    _syncSpin();
  }

  @override
  void didUpdateWidget(_Icon old) {
    super.didUpdateWidget(old);
    if (old.status != widget.status) _syncSpin();
  }

  void _syncSpin() {
    if (widget.status == AgentStatus.working) {
      _controller.repeat();
    } else {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final icon = Icon(widget.status.icon, size: 14, color: widget.color);
    if (widget.status != AgentStatus.working) return icon;
    return RotationTransition(turns: _controller, child: icon);
  }
}
