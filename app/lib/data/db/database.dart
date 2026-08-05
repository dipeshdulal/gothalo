import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'database.g.dart';

/// Saved bridge connections — the **non-secret** half of a [Connection].
///
/// The bearer token is deliberately absent here: secrets go to
/// `flutter_secure_storage`, keyed by [id]. This table only holds what is safe
/// to sit in plain SQLite.
class Profiles extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get baseUrl => text()();
  TextColumn get deviceId => text().nullable()();
  TextColumn get source => text().withDefault(const Constant('manual'))();

  /// The bridge's own id (`GET /info` → `server_id`), as opposed to [id], which
  /// is this phone's local id for the saved entry.
  ///
  /// Every push carries the sending bridge's `server_id`, and a phone is paired
  /// with several bridges under the *same* FCM token — so this column is the
  /// only thing that can answer "which of my servers did this alert come from",
  /// and therefore which server a notification tap should open. Empty until the
  /// bridge has been reached once (or for a bridge too old to report one).
  TextColumn get serverId => text().withDefault(const Constant(''))();

  @override
  Set<Column> get primaryKey => {id};
}

/// A durable log of agent state changes we were pushed about (`blocked`/`done`).
///
/// `/snapshot` is a *point-in-time* view; once an agent moves on, the moment it
/// blocked is gone. This table is the app's persistent inbox history so those
/// moments survive. `stateChangeSeq` is Herdr's monotonic seq for the agent and
/// backs idempotent approvals (D8) — an approve tap no-ops if the agent is no
/// longer blocked at this seq.
class AgentEvents extends Table {
  IntColumn get rowId => integer().autoIncrement()();
  TextColumn get profileId => text()();

  /// The bridge that sent the push (its `server_id`). Recorded straight from the
  /// payload because a push arrives in a background isolate that has no notion
  /// of an "active" server — attribution has to come from the message itself,
  /// not from whatever the UI happened to be showing.
  TextColumn get serverId => text().withDefault(const Constant(''))();
  TextColumn get serverName => text().withDefault(const Constant(''))();
  TextColumn get agent => text()();
  TextColumn get paneId => text()();
  TextColumn get workspaceId => text().withDefault(const Constant(''))();
  TextColumn get title => text().withDefault(const Constant(''))();

  /// The status this event represents (stored as its enum name).
  TextColumn get status => text()();

  /// Herdr's `state_change_seq` for the agent at the time of the event.
  IntColumn get stateChangeSeq => integer().nullable()();

  /// When the event landed on this device (unix millis, UTC).
  IntColumn get receivedAt => integer()();

  /// Whether the user has acted on / dismissed this event.
  BoolColumn get handled => boolean().withDefault(const Constant(false))();
}

@DriftDatabase(tables: [Profiles, AgentEvents])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor]) : super(executor ?? _open());

  @override
  int get schemaVersion => 2;

  /// v1 → v2 adds server attribution: which bridge a saved profile is, and which
  /// bridge each pushed alert came from. All three columns default to empty, so
  /// existing rows stay valid and simply read as "unattributed" until the app
  /// next reaches that bridge.
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.addColumn(profiles, profiles.serverId);
        await m.addColumn(agentEvents, agentEvents.serverId);
        await m.addColumn(agentEvents, agentEvents.serverName);
      }
    },
  );

  /// Saved connection profiles, most recently named first.
  Stream<List<Profile>> watchProfiles() =>
      (select(profiles)..orderBy([(t) => OrderingTerm(expression: t.name)]))
          .watch();

  Future<void> upsertProfile(ProfilesCompanion profile) =>
      into(profiles).insertOnConflictUpdate(profile);

  Future<Profile?> profileById(String id) =>
      (select(profiles)..where((t) => t.id.equals(id))).getSingleOrNull();

  /// Look up a saved server by its base URL, so re-adding/re-pairing the same
  /// bridge updates the existing entry instead of creating a duplicate.
  /// Look up a saved server by the *bridge's* id — the reverse map a push needs:
  /// payload `server_id` → the local profile whose base URL and bearer can act
  /// on it.
  Future<Profile?> profileByServerId(String serverId) async {
    if (serverId.isEmpty) return null;
    return (select(profiles)
          ..where((t) => t.serverId.equals(serverId))
          ..limit(1))
        .getSingleOrNull();
  }

  /// Record the bridge id a saved server reported from `GET /info`.
  Future<void> setProfileServerId(String id, String serverId) =>
      (update(profiles)..where((t) => t.id.equals(id)))
          .write(ProfilesCompanion(serverId: Value(serverId)));

  Future<Profile?> profileByBaseUrl(String baseUrl) =>
      (select(profiles)..where((t) => t.baseUrl.equals(baseUrl)))
          .getSingleOrNull();

  Future<int> countProfiles() async {
    final c = countAll();
    final row = await (selectOnly(profiles)..addColumns([c])).getSingle();
    return row.read(c) ?? 0;
  }

  Future<void> deleteProfile(String id) =>
      (delete(profiles)..where((t) => t.id.equals(id))).go();

  /// The event/inbox history for a profile, newest first. Reactive: the inbox
  /// history UI rebuilds the instant a new event is inserted.
  Stream<List<AgentEvent>> watchEvents(String profileId, {int limit = 200}) =>
      (select(agentEvents)
            ..where((t) => t.profileId.equals(profileId))
            ..orderBy([
              (t) => OrderingTerm(
                expression: t.receivedAt,
                mode: OrderingMode.desc,
              ),
            ])
            ..limit(limit))
          .watch();

  Future<int> insertEvent(AgentEventsCompanion event) =>
      into(agentEvents).insert(event);

  Future<void> markHandled(int rowId) =>
      (update(agentEvents)..where((t) => t.rowId.equals(rowId)))
          .write(const AgentEventsCompanion(handled: Value(true)));

  /// The full alerts log across all servers, newest first. Reactive.
  Stream<List<AgentEvent>> watchAllEvents({int limit = 300}) =>
      (select(agentEvents)
            ..orderBy([
              (t) => OrderingTerm(
                expression: t.receivedAt,
                mode: OrderingMode.desc,
              ),
            ])
            ..limit(limit))
          .watch();

  /// Number of unread (unhandled) alerts of any kind.
  Stream<int> watchUnreadCount() {
    final count = agentEvents.rowId.count();
    final query = selectOnly(agentEvents)
      ..addColumns([count])
      ..where(agentEvents.handled.equals(false));
    return query.map((row) => row.read(count) ?? 0).watchSingle();
  }

  /// Number of alerts still **asking** something of you — drives the bell badge.
  ///
  /// Deliberately narrower than [watchUnreadCount]: a `done` notice is a
  /// completion, not a request, and counting it made the badge read as "3 things
  /// need you" when nothing did. A blocked alert stops counting once it is
  /// handled — which now happens both when you open Alerts and when the bridge
  /// tells us the block resolved anywhere (see [markResolved]).
  Stream<int> watchNeedsYouCount() {
    final count = agentEvents.rowId.count();
    final query = selectOnly(agentEvents)
      ..addColumns([count])
      ..where(
        agentEvents.handled.equals(false) & agentEvents.status.equals('blocked'),
      );
    return query.map((row) => row.read(count) ?? 0).watchSingle();
  }

  /// The same needs-you count, split by originating bridge, so the servers list
  /// can show which machine wants you rather than one undifferentiated number.
  /// Keyed by `server_id`; alerts from a bridge too old to send one group under
  /// the empty string.
  Stream<Map<String, int>> watchNeedsYouByServer() {
    final count = agentEvents.rowId.count();
    final query = selectOnly(agentEvents)
      ..addColumns([agentEvents.serverId, count])
      ..where(
        agentEvents.handled.equals(false) & agentEvents.status.equals('blocked'),
      )
      ..groupBy([agentEvents.serverId]);
    return query.map((row) {
      return MapEntry(row.read(agentEvents.serverId) ?? '', row.read(count) ?? 0);
    }).watch().map(Map.fromEntries);
  }

  /// Reconcile the needs-you count against live state: mark every outstanding
  /// blocked alert handled whose pane is no longer blocked on the server.
  ///
  /// The dismiss push ([markResolved]) is the fast path, but it is a *push* — a
  /// frozen, offline or force-stopped app never sees it, and that alert then
  /// counts against the badge forever. A snapshot says what is true right now,
  /// so reconciling against it lets the count heal itself instead of drifting
  /// upward every time a message is missed.
  ///
  /// Scoped to one server: [stillBlocked] comes from that server's snapshot and
  /// says nothing about any other machine's panes.
  Future<int> resolveStaleBlocked({
    required String serverId,
    required Set<String> stillBlocked,
  }) {
    if (serverId.isEmpty) return Future.value(0);
    final q = update(agentEvents)
      ..where(
        (t) =>
            t.handled.equals(false) &
            t.status.equals('blocked') &
            // Alerts predating server attribution carry an empty id; they can
            // only have come from the one server this phone was paired with.
            (t.serverId.equals(serverId) | t.serverId.equals('')) &
            t.paneId.isNotIn(stillBlocked.toList()),
      );
    return q.write(const AgentEventsCompanion(handled: Value(true)));
  }

  /// Mark a pane's outstanding blocked alerts as handled, because the block is
  /// over — whoever answered it. Called when the bridge pushes a dismiss, which
  /// is what keeps the badge honest without the user opening the app.
  Future<int> markResolved({
    required String serverId,
    required String paneId,
  }) {
    final q = update(agentEvents)
      ..where(
        (t) =>
            t.paneId.equals(paneId) &
            t.handled.equals(false) &
            t.status.equals('blocked') &
            // An empty server id means the alert predates attribution; don't let
            // one bridge clear another's alerts, but do clear the unattributed.
            (t.serverId.equals(serverId) | t.serverId.equals('')),
      );
    return q.write(const AgentEventsCompanion(handled: Value(true)));
  }

  Future<void> markAllHandled() =>
      (update(agentEvents)..where((t) => t.handled.equals(false)))
          .write(const AgentEventsCompanion(handled: Value(true)));

  Future<void> clearEvents() => delete(agentEvents).go();

  /// Retention: drop alerts older than [cutoffMillis] (unix millis). Called
  /// after each insert so the log self-trims.
  Future<void> pruneOlderThan(int cutoffMillis) =>
      (delete(agentEvents)
            ..where((t) => t.receivedAt.isSmallerThanValue(cutoffMillis)))
          .go();
}

LazyDatabase _open() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'gothalo.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}
