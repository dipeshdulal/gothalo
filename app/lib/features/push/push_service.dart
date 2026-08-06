import 'dart:ui' show DartPluginRegistrant;

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../core/firebase_web_options.dart';
import '../../data/bridge/bridge_providers.dart';
import 'notification_actions.dart';
import 'push_payload.dart';

part 'push_service.g.dart';

/// Channels. These ids are a contract with the bridge (`internal/server/notify.go`):
/// a push naming a channel this app never created is dropped silently by
/// Android. They are split so "an agent is waiting on you" can ring while "an
/// agent finished" stays quiet, and so either can be muted on its own.
const _blockedChannelId = 'gothalo_blocked';
const _doneChannelId = 'gothalo_done';

/// The pre-split channel, created by earlier versions. Removed on launch so its
/// stale settings don't linger in the system UI.
const _legacyChannelId = 'gothalo_agents';

/// Android notification id. Every gothalo notification uses id 0 and is
/// distinguished by its **tag** instead, because that is exactly how Firebase's
/// own SDK posts the notification block it renders when our process isn't
/// running (`notify(tag, 0, …)`). Matching it means the rich, action-bearing
/// notification we draw *replaces* the system-drawn one in place, rather than
/// appearing beside it as a duplicate.
const _notificationId = 0;

final _local = FlutterLocalNotificationsPlugin();

/// A tapped notification awaiting routing. The app shell watches this and
/// navigates — switching servers first when the alert came from a bridge other
/// than the active one.
final pendingDeepLink = ValueNotifier<DeepLinkTarget?>(null);

/// Group key for a server's notifications, so one machine's alerts stack under
/// a single summary instead of filling the shade.
String _groupKey(String serverId) => 'gothalo.server.$serverId';

/// Stable id for a server's summary notification. Distinct from
/// [_notificationId] so a summary never collides with an agent's own alert.
int _summaryId(String serverId) => 1 + (serverId.hashCode & 0x7ffffff);

/// Renders a push. FCM's `notification` block already put a plain version on
/// screen (that is what survives the app being killed); this replaces it with
/// one that carries the agent's choices as tappable actions.
Future<void> _show(PushPayload p) async {
  await _ensureLocal();
  final blocked = p.isBlocked;
  final body = p.body.isEmpty ? p.question : p.body;

  await _local.show(
    id: _notificationId,
    title: p.title.isEmpty ? 'Herdr agent' : p.title,
    body: body,
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        blocked ? _blockedChannelId : _doneChannelId,
        blocked ? 'Agent needs you' : 'Agent finished',
        channelDescription: blocked
            ? 'An agent is blocked and waiting for your answer.'
            : 'An agent finished its turn.',
        importance: blocked ? Importance.high : Importance.defaultImportance,
        priority: blocked ? Priority.high : Priority.defaultPriority,
        tag: p.tag,
        groupKey: _groupKey(p.serverId),
        // The question is usually longer than one line; without this the most
        // useful part of the notification is the part that gets ellipsized.
        // The title already names the server, so no summaryText — it would just
        // repeat it in the header line.
        styleInformation: BigTextStyleInformation(body),
        actions: blocked ? _actionsFor(p) : null,
      ),
    ),
    payload: p.encodeTarget(),
  );

  await _showSummary(p);
}

/// Action buttons for a blocked prompt.
///
/// Approve is offered only when we know the `seq` to guard it with — without
/// one, a tap could land on a prompt the agent has already moved past. Reject is
/// offered only when the prompt actually has a way to say no.
List<AndroidNotificationAction>? _actionsFor(PushPayload p) {
  final actions = <AndroidNotificationAction>[];
  if (p.seq != null) {
    final label = p.defaultOption?.label;
    actions.add(
      AndroidNotificationAction(
        kActionApprove,
        _shortLabel(label ?? 'Approve', fallback: 'Approve'),
        cancelNotification: true,
      ),
    );
  }
  if (p.declineOption != null) {
    actions.add(
      const AndroidNotificationAction(
        kActionReject,
        'Reject',
        cancelNotification: true,
      ),
    );
  }
  return actions.isEmpty ? null : actions;
}

/// Button labels are clipped hard by the system; a full choice line
/// ("Yes, and don't ask again for rm commands") reads as noise.
String _shortLabel(String label, {required String fallback}) {
  final l = label.trim();
  if (l.isEmpty || l.length > 16) return fallback;
  return l;
}

/// The group summary — the single collapsed row Android shows above a server's
/// stacked alerts.
///
/// Only posted once at least two alerts are actually on screen. A summary over a
/// single notification is not collapsed away by every launcher (Samsung's shows
/// it), which reads as a duplicate "Agent alerts" row sitting above the one real
/// alert.
Future<void> _showSummary(PushPayload p) async {
  if (await _activeCount(p.serverId) < 2) return;
  final server = p.serverName.isEmpty ? 'gothalo' : p.serverName;
  await _local.show(
    id: _summaryId(p.serverId),
    title: server,
    body: 'Agent alerts',
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        p.isBlocked ? _blockedChannelId : _doneChannelId,
        p.isBlocked ? 'Agent needs you' : 'Agent finished',
        groupKey: _groupKey(p.serverId),
        setAsGroupSummary: true,
        importance: Importance.high,
        priority: Priority.high,
        // The summary itself should never buzz; the alert under it already did.
        onlyAlertOnce: true,
      ),
    ),
  );
}

/// How many of a server's agent notifications are currently on screen.
///
/// Counted by tag prefix rather than group key: the notification Android drew
/// from the payload is not in our group, but it is the same alert and it is what
/// the user sees. Errors count as zero — a missing summary is invisible, an
/// unwanted one is not.
Future<int> _activeCount(String serverId) async {
  try {
    final active = await _local.getActiveNotifications();
    return active
        .where((n) => (n.tag ?? '').startsWith('$serverId/'))
        .length;
  } catch (_) {
    return 0;
  }
}

/// Clear the pane's notification (a no-op if it's already gone).
Future<void> _dismiss(PushPayload p) async {
  await _ensureLocal();
  if (p.pane.isEmpty) return;
  await _local.cancel(id: _notificationId, tag: p.tag);
  // The summary outlives its children otherwise, leaving a lone "Agent alerts"
  // row pointing at nothing.
  if (await _activeCount(p.serverId) < 2) {
    await _local.cancel(id: _summaryId(p.serverId));
  }
}

/// Background isolate entrypoint — renders pushes while the app is backgrounded
/// or terminated. Registered from `main()` via `onBackgroundMessage`.
///
/// The tray IS the alert. Nothing is written to disk: an alert says an agent is
/// blocked or done, which is live state the bridge already answers — a stored
/// copy could only go stale, and there is no question it answered that
/// Priority (for what wants you) or the transcript (for what happened) doesn't
/// answer better.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  DartPluginRegistrant.ensureInitialized();
  final p = PushPayload.from(message.data);
  // Android never routes the notification-bearing twin here while backgrounded,
  // but it does on some states/OEMs — and redrawing it would only duplicate what
  // is already on screen.
  if (p.isOsRendered) return;
  if (p.isDismiss) {
    await _dismiss(p);
    return;
  }
  await _show(p);
}

/// Foreground taps and action buttons.
@pragma('vm:entry-point')
void _onNotificationResponse(NotificationResponse response) {
  _handleResponse(response);
}

/// Taps and action buttons that arrive while the app is not running. This runs
/// in its own isolate, so it initialises plugins itself.
@pragma('vm:entry-point')
void notificationBackgroundResponse(NotificationResponse response) {
  DartPluginRegistrant.ensureInitialized();
  _handleResponse(response);
}

/// Route one notification interaction: an action button acts on the bridge
/// directly; a plain tap queues a deep-link for the shell to navigate.
void _handleResponse(NotificationResponse response) {
  final target = DeepLinkTarget.decode(response.payload);
  if (target == null) return;
  final action = response.actionId;
  if (action == kActionApprove || action == kActionReject) {
    unawaited(
      runNotificationAction(
        actionId: action!,
        target: target,
        options: target.options,
      ),
    );
    return;
  }
  pendingDeepLink.value = target;
}

/// Fire-and-forget, named so the intent is explicit at the call site.
void unawaited(Future<void> f) {
  f.catchError((Object e) => debugPrint('gothalo: $e'));
}

bool _localReady = false;
Future<void> _ensureLocal() async {
  if (_localReady) return;
  const init = InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
  );
  await _local.initialize(
    settings: init,
    onDidReceiveNotificationResponse: _onNotificationResponse,
    onDidReceiveBackgroundNotificationResponse: notificationBackgroundResponse,
  );
  final android = _local
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();
  await android?.createNotificationChannel(
    const AndroidNotificationChannel(
      _blockedChannelId,
      'Agent needs you',
      description: 'An agent is blocked and waiting for your answer.',
      importance: Importance.high,
    ),
  );
  await android?.createNotificationChannel(
    const AndroidNotificationChannel(
      _doneChannelId,
      'Agent finished',
      description: 'An agent finished its turn.',
      importance: Importance.defaultImportance,
    ),
  );
  await android?.deleteNotificationChannel(channelId: _legacyChannelId);
  _localReady = true;
}

/// Owns the push lifecycle: notification permission, the FCM token, foreground
/// handling, and (re)registering the token with the active bridge. Its value is
/// the current FCM token (null if unavailable), which the pairing flow reads to
/// send as `fcm_token`.
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
      // noise. The only thing still worth acting on is a dismiss, which clears a
      // tray entry raised earlier while we were backgrounded. The background
      // handler ([firebaseMessagingBackgroundHandler]) shows the tray when the
      // app isn't in the foreground.
      FirebaseMessaging.onMessage.listen((m) async {
        final p = PushPayload.from(m.data);
        // A foreground app receives BOTH halves of the alert pair; only the
        // app-rendered twin counts, or a dismiss would be handled twice.
        if (p.isOsRendered) return;
        if (p.isDismiss) {
          await _dismiss(p);
        }
      });
      messaging.onTokenRefresh.listen(_onToken);

      await _restoreLaunchDeepLink();

      // Re-register the token whenever the active bridge changes.
      ref.listen(bridgeClientProvider, (_, _) => _registerCurrent());

      // Web push needs the VAPID public key; native does not take one at all.
      // Without it the browser refuses the subscription, and the error reads
      // like a permissions failure rather than a missing key.
      _token = await messaging.getToken(
        vapidKey: kIsWeb ? firebaseWebVapidKey : null,
      );
      await _registerCurrent();
      return _token;
    } catch (e) {
      // Firebase not configured (no google-services.json) or push unavailable.
      debugPrint('Push disabled: $e');
      return null;
    }
  }

  /// Recover a deep-link from whichever notification launched the app.
  ///
  /// Two paths, because two different components may have drawn the
  /// notification: ours (when the app was alive to replace the system one) and
  /// Firebase's own (when the process was gone — precisely the case that used to
  /// go unhandled, so tapping a notification after a kill opened nothing).
  Future<void> _restoreLaunchDeepLink() async {
    final launch = await _local.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp ?? false) {
      final target = DeepLinkTarget.decode(
        launch!.notificationResponse?.payload,
      );
      if (target != null) {
        pendingDeepLink.value = target;
        return;
      }
    }
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) {
      _queueFromMessage(initial);
    }
    // A tap on a system-drawn notification while the app was merely backgrounded.
    FirebaseMessaging.onMessageOpenedApp.listen(_queueFromMessage);
  }

  void _queueFromMessage(RemoteMessage m) {
    final p = PushPayload.from(m.data);
    if (p.pane.isEmpty) return;
    pendingDeepLink.value = DeepLinkTarget(
      serverId: p.serverId,
      pane: p.pane,
      seq: p.seq,
      options: p.options,
    );
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
