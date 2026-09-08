import '../../core/firebase_web_config.dart';

/// Writes the fetched config where the service worker can read it. Native is a
/// no-op: its push path never touches the worker.
Future<void> writeWebConfigCache(FirebaseWebConfig cfg) async {}
