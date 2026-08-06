import 'package:drift/drift.dart';

import 'open/open.dart';

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

  /// The bridge's capability level from `GET /info`. Zero means it has never
  /// answered — either too old to have the endpoint, or not reached yet — which
  /// is also the state in which its pushes cannot be attributed or routed.
  IntColumn get bridgeVersion => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [Profiles])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor]) : super(executor ?? _open());

  @override
  int get schemaVersion => 4;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      // v1 → v2 added server attribution to profiles. It also added two columns
      // to the since-dropped agent_events table; those statements are gone
      // rather than kept for fidelity, because v4 drops the table outright and
      // adding a column to something about to be deleted only risks failing the
      // upgrade for no gain.
      if (from < 2) {
        await m.addColumn(profiles, profiles.serverId);
      }
      // v2 → v3 records what each bridge can do, so an out-of-date one is
      // visible in the servers list rather than only discovered by a
      // notification tap that refuses to route.
      if (from < 3) {
        await m.addColumn(profiles, profiles.bridgeVersion);
      }
      // v3 → v4 drops the pushed-alert log. An alert only ever said an agent
      // was blocked or done — live state the bridge answers directly, so a
      // stored copy could only be a staler version of an answer we already
      // have. The tray is the alert; Priority owns what needs you, and the
      // transcript owns what happened.
      if (from < 4) {
        await m.database.customStatement('DROP TABLE IF EXISTS agent_events');
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

  /// Record what a saved server reported from `GET /info` — its bridge id and
  /// capability level.
  Future<void> setProfileIdentity(
    String id, {
    required String serverId,
    required int bridgeVersion,
  }) =>
      (update(profiles)..where((t) => t.id.equals(id))).write(
        ProfilesCompanion(
          serverId: Value(serverId),
          bridgeVersion: Value(bridgeVersion),
        ),
      );

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

}

QueryExecutor _open() => openConnection();
