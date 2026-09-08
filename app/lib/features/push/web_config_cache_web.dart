import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import '../../core/firebase_web_config.dart';

/// IndexedDB slot shared with the service worker. Names must match
/// `internal/web/assets/firebase-messaging-sw.js` exactly:
/// database `gothalo-fcm`, store `kv`, key `config`.
const _dbName = 'gothalo-fcm';
const _store = 'kv';
const _key = 'config';

/// Mirror the effective config into IndexedDB so the service worker — which
/// cannot see Dart state — initialises Firebase against the same project as
/// the page. Fire-and-forget safe: every path completes, never throws.
Future<void> writeWebConfigCache(FirebaseWebConfig cfg) {
  final done = Completer<void>();
  void finish() {
    if (!done.isCompleted) done.complete();
  }

  try {
    final idb = globalContext['indexedDB'] as JSObject?;
    if (idb == null) {
      finish();
      return Future.value();
    }
    final open =
        idb.callMethod('open'.toJS, _dbName.toJS, 1.toJS) as JSObject;
    open['onupgradeneeded'] = ((JSAny _) {
      (open['result'] as JSObject).callMethod(
        'createObjectStore'.toJS,
        _store.toJS,
      );
    }).toJS;
    open['onsuccess'] = ((JSAny _) {
      try {
        final db = open['result'] as JSObject;
        final tx = db.callMethod(
          'transaction'.toJS,
          _store.toJS,
          'readwrite'.toJS,
        ) as JSObject;
        final store =
            tx.callMethod('objectStore'.toJS, _store.toJS) as JSObject;
        store.callMethod('put'.toJS, _configJS(cfg), _key.toJS);
        void finished(JSAny _) => finish();
        tx['oncomplete'] = finished.toJS;
        tx['onerror'] = finished.toJS;
      } catch (_) {
        finish();
      }
    }).toJS;
    open['onerror'] = ((JSAny _) => finish()).toJS;
  } catch (_) {
    finish();
  }
  return done.future.timeout(
    const Duration(seconds: 3),
    onTimeout: finish,
  );
}

JSObject _configJS(FirebaseWebConfig cfg) {
  // Non-null by construction: fromJson rejects missing fields and baked
  // carries the setup-script values.
  final o = cfg.options;
  final js = JSObject();
  js['apiKey'] = o.apiKey.toJS;
  js['authDomain'] = o.authDomain!.toJS;
  js['projectId'] = o.projectId.toJS;
  js['storageBucket'] = o.storageBucket!.toJS;
  js['messagingSenderId'] = o.messagingSenderId.toJS;
  js['appId'] = o.appId.toJS;
  js['vapidKey'] = cfg.vapidKey.toJS;
  return js;
}
