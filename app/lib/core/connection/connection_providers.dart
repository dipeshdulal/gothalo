import 'package:drift/drift.dart' show Value;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../data/db/database.dart';
import '../../data/db/db_providers.dart';
import 'connection.dart';

part 'connection_providers.g.dart';

/// Secure-storage key for the id of the currently selected server.
const _kActiveIdKey = 'gothalo.active_server_id';

/// Per-server bearer key. The bearer is a secret, so it lives in the platform
/// keystore, keyed by the server's id — never in the drift database.
String _bearerKey(String id) => 'gothalo.bearer.$id';

/// A lightweight, **non-secret** view of a saved server for the servers list.
/// Never carries the bearer.
class ServerSummary {
  const ServerSummary({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.isActive,
    this.bridgeVersion = 0,
  });

  final String id;
  final String name;
  final String baseUrl;
  final bool isActive;

  /// The bridge's capability level from `GET /info`; 0 when it has never
  /// answered.
  final int bridgeVersion;

  /// A bridge that has not identified itself cannot have its notifications
  /// attributed or routed — tapping one refuses rather than opening the wrong
  /// machine's pane. Worth surfacing in the list, since the alternative is
  /// discovering it only when a tap declines to go anywhere.
  bool get needsUpgrade => bridgeVersion == 0;
}

/// The encrypted key/value store for secrets (bearers + the active-server id).
@Riverpod(keepAlive: true)
FlutterSecureStorage secureStorage(Ref ref) => const FlutterSecureStorage();

/// Writes/reads servers: non-secret fields to drift, bearer to secure storage.
/// The single place server state is mutated, so the list and active connection
/// stay consistent.
@Riverpod(keepAlive: true)
ServersRepository serversRepository(Ref ref) => ServersRepository(ref);

class ServersRepository {
  ServersRepository(this._ref);
  final Ref _ref;

  AppDatabase get _db => _ref.read(databaseProvider);
  FlutterSecureStorage get _secure => _ref.read(secureStorageProvider);

  /// Add or update a server. Splits the [Connection] across the two stores.
  ///
  /// Deduped by `baseUrl`: adding or (re-)pairing a bridge that already exists
  /// updates that entry in place — refreshing its bearer — rather than creating
  /// a duplicate. Returns the effective saved connection (whose id may be the
  /// existing one) and whether it already existed.
  Future<({Connection saved, bool existed})> save(Connection c) async {
    final existing = await _db.profileByBaseUrl(c.baseUrl);
    final saved = existing == null ? c : c.copyWith(id: existing.id);
    await _db.upsertProfile(
      ProfilesCompanion(
        id: Value(saved.id),
        name: Value(saved.name),
        baseUrl: Value(saved.baseUrl),
        deviceId: Value(saved.deviceId),
        source: Value(saved.source.name),
      ),
    );
    await _secure.write(key: _bearerKey(saved.id), value: saved.bearer);
    return (saved: saved, existed: existing != null);
  }

  /// The bearer for a server, for prefilling the edit form. Secret — only used
  /// on-device in the editor, never surfaced in the list.
  Future<String?> bearerFor(String id) => _secure.read(key: _bearerKey(id));

  /// Remove a server and its bearer; clear the active pointer if it was active.
  Future<void> delete(String id) async {
    await _db.deleteProfile(id);
    await _secure.delete(key: _bearerKey(id));
    final active = await _ref.read(activeServerIdProvider.future);
    if (active == id) {
      await _ref.read(activeServerIdProvider.notifier).set(null);
    }
  }

  /// Seed the optional dev server (from `--dart-define`) on a fresh install and
  /// make it active, so the inbox is testable without pairing. No-op if no
  /// define was supplied or any server already exists.
  Future<void> ensureDevSeed() async {
    final seed = Connection.devSeed();
    if (seed == null) return;
    if (await _db.countProfiles() > 0) return;
    await save(seed);
    await _ref.read(activeServerIdProvider.notifier).set(seed.id);
  }
}

/// The id of the selected server, persisted in secure storage.
@Riverpod(keepAlive: true)
class ActiveServerId extends _$ActiveServerId {
  @override
  Future<String?> build() =>
      ref.watch(secureStorageProvider).read(key: _kActiveIdKey);

  Future<void> set(String? id) async {
    final secure = ref.read(secureStorageProvider);
    if (id == null) {
      await secure.delete(key: _kActiveIdKey);
    } else {
      await secure.write(key: _kActiveIdKey, value: id);
    }
    state = AsyncData(id);
  }
}

/// The list of saved servers (non-secret), reactive off drift, with the active
/// one flagged. Drives the servers screen.
@riverpod
Stream<List<ServerSummary>> servers(Ref ref) {
  final activeId = ref.watch(activeServerIdProvider).asData?.value;
  return ref.watch(databaseProvider).watchProfiles().map(
        (rows) => rows
            .map(
              (r) => ServerSummary(
                id: r.id,
                name: r.name,
                baseUrl: r.baseUrl,
                isActive: r.id == activeId,
                bridgeVersion: r.bridgeVersion,
              ),
            )
            .toList(),
      );
}

/// The active [Connection] (with its bearer), assembled from the active id +
/// its drift profile + its secure-storage bearer. Null when no server is
/// selected. Everything that talks to a bridge watches this.
@riverpod
Future<Connection?> activeConnection(Ref ref) async {
  final id = await ref.watch(activeServerIdProvider.future);
  if (id == null) return null;
  final row = await ref.watch(databaseProvider).profileById(id);
  if (row == null) return null;
  final bearer = await ref.watch(secureStorageProvider).read(key: _bearerKey(id));
  if (bearer == null || bearer.isEmpty) return null;
  return Connection(
    id: row.id,
    name: row.name,
    baseUrl: row.baseUrl,
    bearer: bearer,
    deviceId: row.deviceId,
    source: ConnectionSource.values.firstWhere(
      (s) => s.name == row.source,
      orElse: () => ConnectionSource.manual,
    ),
  );
}
