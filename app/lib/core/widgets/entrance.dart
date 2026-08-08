import 'package:flutter/material.dart';

import '../tokens.dart';

/// Fades and lifts its child into place once, the first time it is built.
///
/// Used on list rows. Because a lazy list builds a row when it scrolls into
/// view, this doubles as a scroll-in effect for free — the list arrives as a
/// short cascade instead of appearing all at once.
///
/// [index] staggers rows against each other, but the delay is capped: a
/// per-row delay that keeps growing means row 30 of a long list waits over a
/// second, which stops reading as polish and starts reading as lag.
class Entrance extends StatefulWidget {
  const Entrance({
    super.key,
    required this.child,
    this.index = 0,
    this.offset = 6,
  });

  final Widget child;
  final int index;

  /// How far the child travels upward, in logical pixels. Small on purpose —
  /// this should register as weight, not as a slide.
  final double offset;

  /// The most any row will wait before starting.
  static const _maxDelay = Duration(milliseconds: 220);
  static const _perItem = Duration(milliseconds: 32);

  @override
  State<Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<Entrance>
    with SingleTickerProviderStateMixin {
  late final Duration _delay = _staggerFor(widget.index);
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: _delay + Motion.medium,
  );

  /// The stagger is a flat leading segment of the controller's own curve, not a
  /// [Future.delayed] that starts it late. A pending timer outlives the widget
  /// it belongs to: a `dispose` mid-flight leaves it queued, and any widget test
  /// that pumps a list of rows once — rather than settling it — fails on the
  /// timer still sitting there. An [Interval] is cancelled by disposing the
  /// controller, because it never existed as anything but part of the curve.
  late final Animation<double> _t = CurvedAnimation(
    parent: _c,
    curve: Interval(
      _delay.inMicroseconds / (_delay + Motion.medium).inMicroseconds,
      1,
      curve: Motion.curve,
    ),
  );

  static Duration _staggerFor(int index) {
    final delay = Entrance._perItem * index;
    if (delay <= Duration.zero) return Duration.zero;
    return delay < Entrance._maxDelay ? delay : Entrance._maxDelay;
  }

  @override
  void initState() {
    super.initState();
    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _t,
      builder: (context, child) => Opacity(
        opacity: _t.value,
        child: Transform.translate(
          offset: Offset(0, widget.offset * (1 - _t.value)),
          child: child,
        ),
      ),
      child: widget.child,
    );
  }
}
