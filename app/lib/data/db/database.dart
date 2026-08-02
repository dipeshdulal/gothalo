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
  int get schemaVersion => 1;

  /// Saved connection profiles, most recently named first.
  Stream<List<Profile>> watchProfiles() =>
      (select(profiles)..orderBy([(t) => OrderingTerm(expression: t.name)]))
          .watch();

  Future<void> upsertProfile(ProfilesCompanion profile) =>
      into(profiles).insertOnConflictUpdate(profile);

  Future<Profile?> profileById(String id) =>
      (select(profiles)..where((t) => t.id.equals(id))).getSingleOrNull();

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
}

LazyDatabase _open() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'gothalo.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}
