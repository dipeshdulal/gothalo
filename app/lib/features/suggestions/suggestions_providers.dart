import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../data/bridge/bridge_client.dart';
import '../../data/bridge/bridge_providers.dart';
import '../inbox/inbox_providers.dart';

part 'suggestions_providers.g.dart';

/// A cheap fingerprint of how the snapshot currently sees one pane: its agent's
/// status, or `none` for a plain pane, or `gone` once the pane has closed.
///
/// This exists so [paneSuggestions] can be **event-driven rather than polled**.
/// The snapshot is already pushed over `WS /events`, and Riverpod only
/// propagates a change when this string actually differs — so an agent going
/// working → idle refetches the suggestions once, and the twenty heartbeat and
/// unrelated-pane frames in between cost nothing.
///
/// Status is the right trigger because it is when the answers change: an agent
/// that just finished a turn is an agent that has just written the files the
/// "Review changes" chip is about.
@riverpod
String paneSignal(Ref ref, String pane) {
  final snap = ref.watch(snapshotControllerProvider).asData?.value;
  if (snap == null) return 'unknown';
  for (final a in snap.agents) {
    if (a.paneId == pane) return a.agentStatus.name;
  }
  for (final p in snap.panes) {
    if (p.paneId == pane) return 'none';
  }
  return 'gone';
}

/// The one-tap actions worth offering for [pane] right now (`GET
/// /suggestions`).
///
/// Refetched when the screen opens and whenever [paneSignal] moves — never on a
/// timer. Combined with the bridge's own short per-pane cache, that keeps the
/// whole feature at roughly one Herdr round-trip per thing that actually
/// happened in the pane.
///
/// Never throws: the client already collapses "nothing to offer", "no such
/// pane" and "bridge too old" into an empty list, and a transport failure is
/// swallowed here. A row of chips is a convenience, and a convenience that can
/// put an error on the screen is not one.
@riverpod
Future<List<PaneSuggestion>> paneSuggestions(Ref ref, String pane) async {
  final client = ref.watch(bridgeClientProvider);
  if (client == null || pane.isEmpty) return const [];
  ref.watch(paneSignalProvider(pane));
  try {
    return await client.getSuggestions(pane);
  } catch (_) {
    return const [];
  }
}
