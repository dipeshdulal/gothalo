import 'package:drift/drift.dart';

// Conditional import: the web build must never see dart:ffi, and the native
// build must never pull in the wasm loader. Dart resolves this at compile time,
// so each platform only ever compiles the half it can run.
export 'open_native.dart' if (dart.library.js_interop) 'open_web.dart';

/// The signature both implementations satisfy.
typedef OpenConnection = QueryExecutor Function();
