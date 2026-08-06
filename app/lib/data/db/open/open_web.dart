import 'package:drift/drift.dart';
import 'package:drift/wasm.dart';

/// Opens the browser-side database.
///
/// There is no file system here: drift runs sqlite3 compiled to WebAssembly and
/// persists through whichever storage the browser allows — OPFS where available,
/// falling back to IndexedDB. Both assets are served alongside the app, which is
/// why they live in `web/`.
///
/// The fallback is silent by design: a browser that lacks OPFS still works, just
/// with a slower backend, and this table only holds saved server profiles — not
/// something worth refusing to start over.
QueryExecutor openConnection() => LazyDatabase(() async {
      final result = await WasmDatabase.open(
        databaseName: 'gothalo',
        sqlite3Uri: Uri.parse('sqlite3.wasm'),
        driftWorkerUri: Uri.parse('drift_worker.js'),
      );
      return result.resolvedExecutor;
    });
