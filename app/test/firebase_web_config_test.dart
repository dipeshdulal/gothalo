import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/core/firebase_web_config.dart';

Map<String, dynamic> _json() => {
      'apiKey': 'AIzaA',
      'authDomain': 'p.firebaseapp.com',
      'projectId': 'p',
      'storageBucket': 'p.firebasestorage.app',
      'messagingSenderId': '1',
      'appId': '1:1:web:x',
      'vapidKey': 'V',
    };

void main() {
  test('fromJson maps every field the bridge serves', () {
    final cfg = FirebaseWebConfig.fromJson(_json());
    final o = cfg.options;
    expect(o.apiKey, 'AIzaA');
    expect(o.authDomain, 'p.firebaseapp.com');
    expect(o.projectId, 'p');
    expect(o.storageBucket, 'p.firebasestorage.app');
    expect(o.messagingSenderId, '1');
    expect(o.appId, '1:1:web:x');
    expect(cfg.vapidKey, 'V');
  });

  test('fromJson rejects a half config instead of initialising with it', () {
    expect(
      () => FirebaseWebConfig.fromJson({'apiKey': 'AIzaA'}),
      throwsFormatException,
    );
    expect(
      () => FirebaseWebConfig.fromJson({..._json(), 'vapidKey': ''}),
      throwsFormatException,
    );
  });
}
