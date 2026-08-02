import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'inbox/inbox_providers.dart';
import 'priority/priority_providers.dart';

/// Re-pull Herdr state across **every** surface after a mutating action
/// (approve, new terminal, …). Two things this gets right that an inline
/// one-provider refresh did not:
///
/// - **Scope** — refreshes both the active-server snapshot (inbox, overview,
///   terminal) *and* the cross-server aggregate (dashboard, priority), so the
///   change shows wherever you are, not only where you acted.
/// - **Timing** — Herdr applies the change a beat *after* the action lands (the
///   approve keystroke goes in, then the agent transitions blocked → working).
///   A single immediate refetch races that and re-reads the pre-transition
///   state, so we pull now and again shortly after to settle on the real one.
Future<void> refreshHerdrState(WidgetRef ref) async {
  void pull() {
    ref.invalidate(allServersAgentsProvider);
    ref.read(snapshotControllerProvider.notifier).refresh();
  }

  pull(); // immediate — feels responsive
  // A couple of spaced follow-ups: the agent may not leave `blocked` (or reach
  // `done`) within the first second, and a single early refetch would miss it.
  for (final gap in const [Duration(milliseconds: 700), Duration(seconds: 1)]) {
    await Future<void>.delayed(gap);
    try {
      pull();
    } catch (_) {
      // Surface disposed (navigated away) before this follow-up — its providers
      // refetch on next build regardless, so just stop.
      return;
    }
  }
}
