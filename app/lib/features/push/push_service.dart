import 'dart:ui' show DartPluginRegistrant;

import 'package:drift/drift.dart' show Value;
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../data/bridge/bridge_providers.dart';
import '../../data/db/database.dart';
import '../../data/db/db_providers.dart';

part 'push_service.g.dart';

const _channelId = 'gothalo_agents';
const _channelName = 'Agent alerts';
const _channelDesc = 'Notifies when a Herdr agent is blocked or done.';

final _local = FlutterLocalNotificationsPlugin();

/// A pane id awaiting deep-link (set when a notification is tapped). The app
/// shell watches this and navigates to that agent's terminal.
final pendingDeepLink = ValueNotifier<String?>(null);

/// Stable, pane-keyed notification id: the same key is used to **show** a
/// notification and later to **cancel** it, so a "dismiss" push can clear the
/// exact one an earlier "blocked" push raised.
int notificationIdFor(String pane) =>
    pane.isEmpty ? 0 : (pane.hashCode & 0x7fffffff);

/// True for a dismiss push — the bridge sends `type:"dismiss"` when a blocked
/// agent is handled from anywhere (this phone, the desktop, another device, or
/// the agent moving on), so the tray notification should be cleared.
bool _isDismiss(Map<String, dynamic> data) =>
    (data['type'] as String?)?.trim() == 'dismiss';

/// Clear the pane's notification (a no-op if it's already gone).
Future<void> _dismissFromData(Map<String, dynamic> data) async {
  final agent = (data['agent'] as String?)?.trim() ?? '';
  if (agent.isEmpty) return;
  await _ensureLocal();
  await _local.cancel(id: notificationIdFor(agent));
}

/// Renders a notification from a **data-only** FCM payload. gothalo pushes carry
/// `title`, `body`, `agent` (== pane_id, the deep-link target) and `status`;
/// data-only messages don't auto-display, so we build the notification here.
Future<void> _showFromData(Map<String, dynamic> data) async {
  await _ensureLocal();
  final title = (data['title'] as String?)?.trim();
  final body = (data['body'] as String?)?.trim() ?? '';
  final agent = (data['agent'] as String?)?.trim() ?? '';
  await _local.show(
    id: notificationIdFor(agent),
    title: title == null || title.isEmpty ? 'Herdr agent' : title,
    body: body,
    notificationDetails: const NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDesc,
        importance: Importance.high,
        priority: Priority.high,
      ),
    ),
    payload: agent,
  );
}

/// How long alerts are kept before the log self-trims.
const _retention = Duration(days: 7);

/// Build an [AgentEventsCompanion] from a push payload. `agent` is the pane id;
/// `body` carries the agent's terminal title.
AgentEventsCompanion _eventFrom(Map<String, dynamic> data) {
  final agent = (data['agent'] as String?)?.trim() ?? '';
  final title =
      ((data['body'] as String?) ?? (data['title'] as String?) ?? '').trim();
  final status = (data['status'] as String?)?.trim() ?? '';
  return AgentEventsCompanion.insert(
    profileId: '',
    agent: '',
    paneId: agent,
    status: status,
    receivedAt: DateTime.now().millisecondsSinceEpoch,
    title: Value(title),
  );
}

/// Insert an alert and prune anything past the retention window.
Future<void> _logToDb(AppDatabase db, Map<String, dynamic> data) async {
  if (((data['agent'] as String?) ?? '').trim().isEmpty) return;
  await db.insertEvent(_eventFrom(data));
  await db.pruneOlderThan(
    DateTime.now().subtract(_retention).millisecondsSinceEpoch,
  );
}

/// Background isolate: a short-lived DB connection to log the alert.
Future<void> _logStandalone(Map<String, dynamic> data) async {
  final db = AppDatabase();
  try {
    await _logToDb(db, data);
  } catch (_) {
    // best-effort logging
  } finally {
    await db.close();
  }
}

/// Background isolate entrypoint — renders and logs pushes when the app is
/// backgrounded or terminated. Registered from `main()` via `onBackgroundMessage`.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  DartPluginRegistrant.ensureInitialized();
  if (_isDismiss(message.data)) {
    await _dismissFromData(message.data);
    return;
  }
  await _showFromData(message.data);
  await _logStandalone(message.data);
}

@pragma('vm:entry-point')
void _onNotificationTap(NotificationResponse response) {
  final pane = response.payload;
  if (pane != null && pane.isNotEmpty) pendingDeepLink.value = pane;
}

bool _localReady = false;
Future<void> _ensureLocal() async {
  if (_localReady) return;
  const init = InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
  );
  await _local.initialize(
    settings: init,
    onDidReceiveNotificationResponse: _onNotificationTap,
    onDidReceiveBackgroundNotificationResponse: _onNotificationTap,
  );
  await _local
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(
        const AndroidNotificationChannel(
          _channelId,
          _channelName,
          description: _channelDesc,
          importance: Importance.high,
        ),
      );
  _localReady = true;
}

/// Owns the push lifecycle: notification permission, the FCM token, foreground
/// rendering, and (re)registering the token with the active bridge. Its value
/// is the current FCM token (null if unavailable), which the pairing flow reads
/// to send as `fcm_token`.
@Riverpod(keepAlive: true)
class PushController extends _$PushController {
  String? _token;

  @override
  Future<String?> build() async {
    try {
      await _ensureLocal();

      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission();

      // Foreground: the app is open and the live event stream already reflects
      // this change, so we do NOT raise a tray notification — that would just be
      // noise. We only record it in the in-app alerts log (bell + list), or
      // clear a notification if it's a dismiss. The background handler
      // ([firebaseMessagingBackgroundHandler]) still shows the tray when the app
      // isn't in the foreground.
      FirebaseMessaging.onMessage.listen((m) async {
        if (_isDismiss(m.data)) {
          await _dismissFromData(m.data);
          return;
        }
        try {
          await _logToDb(ref.read(databaseProvider), m.data);
        } catch (_) {}
      });
      messaging.onTokenRefresh.listen(_onToken);

      // Cold start via a tapped notification → queue the deep-link.
      final launch = await _local.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp ?? false) {
        final pane = launch!.notificationResponse?.payload;
        if (pane != null && pane.isNotEmpty) pendingDeepLink.value = pane;
      }

      // Re-register the token whenever the active bridge changes.
      ref.listen(bridgeClientProvider, (_, _) => _registerCurrent());

      _token = await messaging.getToken();
      await _registerCurrent();
      return _token;
    } catch (e) {
      // Firebase not configured (no google-services.json) or push unavailable.
      debugPrint('Push disabled: $e');
      return null;
    }
  }

  Future<void> _onToken(String token) async {
    _token = token;
    state = AsyncData(token);
    await _registerCurrent();
  }

  /// POST the current token to the active bridge so it can push to this device.
  Future<void> _registerCurrent() async {
    final token = _token;
    final client = ref.read(bridgeClientProvider);
    if (token == null || client == null) return;
    try {
      await client.registerToken(token);
    } catch (_) {
      // best-effort; a refresh or reconnect will retry
    }
  }
}
