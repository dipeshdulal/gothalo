import 'package:firebase_core/firebase_core.dart';

/// Firebase configuration for the **web** build.
///
/// Native builds don't need this: Android reads `google-services.json` and iOS
/// its plist, both picked up automatically by `Firebase.initializeApp()`. The
/// web has no such file, so the values have to be compiled in.
///
/// These are the same values the bridge already serves in
/// `internal/web/assets/firebase-messaging-sw.js` — the service worker and the
/// page must agree on the project, or the token minted by one is meaningless to
/// the other.
///
/// None of this is secret. A Firebase web `apiKey` identifies a project; it does
/// not authorise anything on its own, which is why it ships inside every web app
/// that uses Firebase. Access is controlled by IAM and security rules, not by
/// hiding this.
const firebaseWebOptions = FirebaseOptions(
  apiKey: 'YOUR_WEB_API_KEY',
  authDomain: 'YOUR_PROJECT_ID.firebaseapp.com',
  projectId: 'YOUR_PROJECT_ID',
  storageBucket: 'YOUR_PROJECT_ID.firebasestorage.app',
  messagingSenderId: 'YOUR_SENDER_ID',
  appId: '1:YOUR_SENDER_ID:web:76e0a519870275262aadc8',
);

/// The public half of the VAPID pair, which web push requires and native push
/// does not.
///
/// FCM signs its push requests with the private half; the browser refuses a
/// subscription that cannot be tied back to a known sender, so
/// `getToken(vapidKey:)` fails outright without it — with an error that reads
/// like a permissions problem rather than a missing key.
///
/// Also public, and also already served in the bridge's receiver page.
const firebaseWebVapidKey =
    'YOUR_VAPID_PUBLIC_KEY';
