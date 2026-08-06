import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// The browser's `Notification.permission`: 'default' (never asked),
/// 'granted', or 'denied'. Reported as 'denied' where the API itself is
/// missing (Safari outside an installed PWA), because asking can never
/// succeed there either.
String get webNotificationPermission {
  final notification = globalContext['Notification'];
  if (notification == null || notification.isUndefinedOrNull) return 'denied';
  final permission = (notification as JSObject)['permission'];
  return (permission as JSString?)?.toDart ?? 'denied';
}
