import 'package:dio/dio.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'firebase_web_options.dart';

/// Firebase web config fetched at runtime from the active bridge
/// (`GET /firebase-config`), so a generically-built web client initialises
/// against whichever bridge it pairs with instead of the project compiled in.
///
/// [baked] is the setup-script values compiled into this build. Native never
/// looks past it; web uses it only when the bridge has nothing to serve
/// (push stays inert, exactly as before).
class FirebaseWebConfig {
  const FirebaseWebConfig({required this.options, required this.vapidKey});

  final FirebaseOptions options;
  final String vapidKey;

  static const baked = FirebaseWebConfig(
    options: firebaseWebOptions,
    vapidKey: firebaseWebVapidKey,
  );

  factory FirebaseWebConfig.fromJson(Map<String, dynamic> json) {
    String need(String key) {
      final v = json[key];
      if (v is! String || v.isEmpty) {
        throw FormatException('firebase-config: missing "$key"');
      }
      return v;
    }

    return FirebaseWebConfig(
      options: FirebaseOptions(
        apiKey: need('apiKey'),
        authDomain: need('authDomain'),
        projectId: need('projectId'),
        storageBucket: need('storageBucket'),
        messagingSenderId: need('messagingSenderId'),
        appId: need('appId'),
      ),
      vapidKey: need('vapidKey'),
    );
  }

  /// Fetch from a bridge. Null when the bridge has no web push configured
  /// (404), is unreachable, or answers garbage — all "push stays inert" cases
  /// the caller already handles by falling back to [baked].
  static Future<FirebaseWebConfig?> fetch(String baseUrl) async {
    try {
      final res = await Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 5),
        ),
      ).get<Map<String, dynamic>>('$baseUrl/firebase-config');
      final data = res.data;
      if (data == null) return null;
      return FirebaseWebConfig.fromJson(data);
    } catch (_) {
      return null;
    }
  }
}

/// The effective web config. Starts [FirebaseWebConfig.baked]; the push
/// controller replaces it with the active bridge's config once fetched.
class FirebaseWebConfigNotifier extends Notifier<FirebaseWebConfig> {
  @override
  FirebaseWebConfig build() => FirebaseWebConfig.baked;

  void set(FirebaseWebConfig cfg) => state = cfg;
}

final firebaseWebConfigProvider =
    NotifierProvider<FirebaseWebConfigNotifier, FirebaseWebConfig>(
      FirebaseWebConfigNotifier.new,
    );
