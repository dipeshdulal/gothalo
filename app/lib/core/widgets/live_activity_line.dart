import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/bridge/bridge_client.dart';
import '../../data/bridge/bridge_providers.dart';

/// A one-line "what's it doing right now" under a working agent's tile —
/// Vercel's live build-step pattern applied to agents (see
/// docs/RESEARCH-feature-ideas.md, #3). Lazily polls `GET /agent-state` for
/// just this pane on its own slow timer, independent of the tile's own
/// rebuild cycle, so the inbox/priority lists feel alive without opening
/// each agent — and independent of `/snapshot`'s cadence, so this doesn't
/// need a bridge change (the "quick win" version of the idea, not the
/// `/snapshot`-carries-it "medium" version).
///
/// Callers should only mount this for a **working** agent — polling an idle
/// one would burn a request for a line that never changes. It disappears
/// (renders nothing) until the first successful poll, and again if a poll
/// ever comes back with nothing to show, rather than holding a stale line
/// after the agent moves on.
class LiveActivityLine extends ConsumerStatefulWidget {
  const LiveActivityLine({super.key, required this.paneId, this.client});

  final String paneId;

  /// The client to poll with. Omit to use the active server's
  /// [bridgeClientProvider] (the common case — inbox tiles are always the
  /// active server). Pass one explicitly for a cross-server list like
  /// Priority, whose tiles each belong to whichever server they were
  /// fetched from, not necessarily the active one.
  final BridgeClient? client;

  @override
  ConsumerState<LiveActivityLine> createState() => _LiveActivityLineState();
}

class _LiveActivityLineState extends ConsumerState<LiveActivityLine> {
  // Slow relative to the transcript screen's 1.5s — this runs once per
  // *tile*, potentially several at once, and only needs to feel "alive" at
  // a glance, not real-time.
  static const _pollEvery = Duration(seconds: 5);

  Timer? _timer;
  String? _line;

  @override
  void initState() {
    super.initState();
    _poll();
    _timer = Timer.periodic(_pollEvery, (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    final client = widget.client ?? ref.read(bridgeClientProvider);
    if (client == null) return;
    try {
      // This line answers "what is it doing RIGHT NOW", which lives on the
      // pane's current screen — the card's default source. It deliberately does
      // not ask for scrollback history (see BridgeClient.getAgentState): that
      // would scroll the pane on the operator's desktop, once per tile per poll
      // across a whole list of working agents.
      final state = await client.getAgentState(widget.paneId);
      if (!mounted) return;
      final detail = state.detail.trim();
      final firstLine =
          detail.isNotEmpty ? detail.split('\n').first.trim() : '';
      final line = firstLine.isNotEmpty ? firstLine : state.headline.trim();
      setState(() => _line = line.isEmpty ? null : line);
    } on BridgeException {
      // Best-effort — a transient failure just leaves the last known line
      // (or none) rather than flashing an error into a list tile.
    }
  }

  @override
  Widget build(BuildContext context) {
    final line = _line;
    if (line == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Icon(Icons.circle, size: 6, color: scheme.primary),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              line,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontStyle: FontStyle.italic,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
