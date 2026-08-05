import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/bridge/bridge_client.dart';
import '../../data/bridge/bridge_providers.dart';
import '../../data/bridge/models/snapshot.dart';

/// Last known line per pane, surviving the tiles that display it.
///
/// The line used to live in each tile's State, so it died whenever the tile
/// did — and tiles die constantly: switching between Agents and Spaces disposes
/// the whole list. Every row then came back blank and refetched, so the list
/// was empty for a beat each time you changed tab, for information the app had
/// already fetched seconds earlier.
///
/// Deliberately NOT autoDispose: outliving the widget is the entire point. It
/// holds one short string per pane, and entries are simply overwritten by the
/// next poll.
final _activityLines = NotifierProvider<_ActivityLines, Map<String, String>>(
  _ActivityLines.new,
);

class _ActivityLines extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() => const {};

  void set(String pane, String? line) {
    if (line == null || line.isEmpty) {
      // Keep the previous line rather than blanking the row. An empty read is
      // almost always transient (the agent between messages), and a row that
      // flickers to nothing reads as a bug.
      return;
    }
    if (state[pane] == line) return;
    state = {...state, pane: line};
  }
}

/// A one-line "what's it doing right now" under a working agent's tile —
/// Vercel's live build-step pattern applied to agents (see
/// docs/RESEARCH-feature-ideas.md, #3). Lazily polls `GET /agent-state` for
/// just this pane on its own slow timer, independent of the tile's own
/// rebuild cycle, so the inbox/priority lists feel alive without opening
/// each agent — and independent of `/snapshot`'s cadence, so this doesn't
/// need a bridge change (the "quick win" version of the idea, not the
/// `/snapshot`-carries-it "medium" version).
///
/// Mount it for **any** agent. What it shows, and how hard it works to keep it
/// fresh, both follow [status]:
///
/// | status | line | refresh |
/// |---|---|---|
/// | working | what it's doing right now | every [_pollEvery] |
/// | blocked | the question it's waiting on | once |
/// | idle / done | the last thing it said | once |
///
/// The one-shot cases matter: a settled agent's line does not change, so a
/// timer would burn a request per tile for nothing. It re-fetches when [status]
/// changes, which is exactly when the line becomes stale.
///
/// This used to be working-only, because the line came from a scrollback read
/// that scrolled the operator's pane and cost a herdr round-trip. It is now
/// served from the agent's own transcript, so showing it everywhere is cheap.
///
/// The line survives the tile: see [_activityLines].
class LiveActivityLine extends ConsumerStatefulWidget {
  const LiveActivityLine({
    super.key,
    required this.paneId,
    required this.status,
    this.client,
  });

  final String paneId;

  /// The agent's current status, from the snapshot. Drives both what the line
  /// shows and whether it polls; a change re-fetches.
  final AgentStatus status;

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

  @override
  void initState() {
    super.initState();
    _poll();
    _syncTimer();
  }

  @override
  void didUpdateWidget(LiveActivityLine old) {
    super.didUpdateWidget(old);
    // A status change is precisely when a settled agent's line goes stale — it
    // just said something new, or started/stopped working. Re-fetch and re-arm.
    if (old.status != widget.status || old.paneId != widget.paneId) {
      _poll();
      _syncTimer();
    }
  }

  /// Only a working agent needs a repeating poll; every other state produces a
  /// line that cannot change until the status itself does.
  void _syncTimer() {
    _timer?.cancel();
    _timer = null;
    if (widget.status == AgentStatus.working) {
      _timer = Timer.periodic(_pollEvery, (_) => _poll());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// The line for the current status: a blocked agent's question is what you
  /// need to see, and for everything else the newest prose — which is the
  /// current activity while working, and the last reply once settled.
  String _lineFor(AgentState state) {
    if (state.isBlocked) {
      final q = state.blockedQuestion?.trim() ?? '';
      if (q.isNotEmpty) return q;
    }
    final detail = state.detail.trim();
    final firstLine = detail.isNotEmpty ? detail.split('\n').first.trim() : '';
    return firstLine.isNotEmpty ? firstLine : state.headline.trim();
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
      ref.read(_activityLines.notifier).set(widget.paneId, _lineFor(state));
    } on BridgeException {
      // Best-effort — a transient failure just leaves the last known line
      // (or none) rather than flashing an error into a list tile.
    }
  }

  @override
  Widget build(BuildContext context) {
    final line = ref.watch(_activityLines)[widget.paneId];
    final scheme = Theme.of(context).colorScheme;

    // The space is reserved whether or not there is a line yet.
    //
    // Collapsing to zero height when empty made every tile change size twice:
    // once when the first poll landed, and again whenever a fetch came back
    // empty. Because this widget is per-tile and fetches on mount, switching
    // between Agents and Spaces remounted the whole list and every row grew a
    // few pixels a moment later — the list visibly resettling under your thumb
    // each time you changed tab.
    //
    // Visibility with maintainSize is what keeps the row's height in the layout
    // while there is nothing to show, so a tile is the same height from its
    // first frame. The text is already maxLines: 1, so the *content* never
    // affected height — only its presence did.
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Visibility(
        visible: line != null,
        maintainSize: true,
        maintainAnimation: true,
        maintainState: true,
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
                // A space, not an empty string: an empty Text can collapse to
                // zero height, which would defeat the whole point.
                line ?? ' ',
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
      ),
    );
  }
}
