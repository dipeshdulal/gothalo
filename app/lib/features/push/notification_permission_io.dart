/// Native platforms may ask for notification permission without a user
/// gesture, so the startup path handles it and no banner is ever needed.
String get webNotificationPermission => 'granted';
