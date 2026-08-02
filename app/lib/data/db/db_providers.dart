import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'database.dart';

part 'db_providers.g.dart';

/// The app-wide drift database. Kept alive for the whole session and closed on
/// dispose. Everything that persists (profiles, event history) goes through it.
@Riverpod(keepAlive: true)
AppDatabase database(Ref ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
}
