import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/database.dart';
import '../../data/db/db_providers.dart';

/// The full alerts log (pushed blocked/done events), newest first. Reactive off
/// drift, so it updates the instant a push is logged.
final alertsProvider = StreamProvider<List<AgentEvent>>(
  (ref) => ref.watch(databaseProvider).watchAllEvents(),
);

/// Count of unread alerts — drives the bell badge on the Flock screen.
final unreadAlertsProvider = StreamProvider<int>(
  (ref) => ref.watch(databaseProvider).watchUnreadCount(),
);
