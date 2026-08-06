import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Opens the on-device SQLite file. `createInBackground` runs the database on
/// its own isolate so a slow query cannot jank the UI.
QueryExecutor openConnection() => LazyDatabase(() async {
      final dir = await getApplicationDocumentsDirectory();
      final file = File(p.join(dir.path, 'gothalo.sqlite'));
      return NativeDatabase.createInBackground(file);
    });
