import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/connection/connection_providers.dart';
import '../../data/bridge/models/snapshot.dart';
import 'recent_providers.dart';

/// Writes "this device opened this agent" into [recentOpensProvider], exactly
/// once per visit.
///
/// **Where this hook belongs, and why it is here.** The honest definition of
/// "opened" is *a screen for this agent came into existence*, and the only
/// place that fact lives is the screen's own [State]. Every other candidate
/// double-counts or under-counts:
///
///   - at the tap site — there are seven of them (home, Priority, flock,
///     overview, jump sheet, a notification tap, a suggestion) and a new one is
///     a new place to forget;
///   - in `build` unguarded — a transcript rebuilds on every frame of a
///     streaming reply, so the same agent would be "opened" hundreds of times a
///     minute;
///   - on a snapshot refresh — that is the bridge talking, not the user.
///
/// A [State] object is created once per navigation and destroyed on pop, so the
/// [_recorded] latch is exactly one visit. Re-pushing the same agent builds a
/// new [State] and records again, which is right: that *is* a second visit.
///
/// It is called from `build` rather than `initState` because the agent behind
/// the pane is not known until the snapshot has landed, and an entry is only
/// worth storing once we know there is an agent there — a plain shell opened as
/// a terminal is not a "recently opened agent" and would otherwise push real
/// ones out of the stored history.
mixin RecentOpenRecorder<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  bool _recorded = false;

  /// Record this visit. Safe to call from `build` on every frame; only the
  /// first call with a non-null [agent] does anything.
  void recordRecentOpen(Agent? agent, {required OpenedView view}) {
    if (_recorded || agent == null) return;
    final serverId = ref.read(activeConnectionProvider).asData?.value?.id;
    if (serverId == null || serverId.isEmpty) return;
    _recorded = true;
    final notifier = ref.read(recentOpensProvider.notifier);
    final paneId = agent.paneId;
    // Post-frame: writing provider state during a build is illegal, and this is
    // called from one.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      notifier.record(serverId: serverId, paneId: paneId, view: view);
    });
  }
}
