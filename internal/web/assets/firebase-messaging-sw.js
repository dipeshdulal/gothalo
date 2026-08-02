// Service worker for background web-push (tab unfocused / phone locked).
// Firebase requires the config here too; it runs in a separate worker context.
importScripts("https://www.gstatic.com/firebasejs/10.12.2/firebase-app-compat.js");
importScripts("https://www.gstatic.com/firebasejs/10.12.2/firebase-messaging-compat.js");

// Activate a new SW immediately so code changes take effect on the next reload
// instead of waiting for all old tabs to close.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));

firebase.initializeApp({
  apiKey: "YOUR_WEB_API_KEY",
  authDomain: "YOUR_PROJECT_ID.firebaseapp.com",
  projectId: "YOUR_PROJECT_ID",
  storageBucket: "YOUR_PROJECT_ID.firebasestorage.app",
  messagingSenderId: "YOUR_SENDER_ID",
  appId: "1:YOUR_SENDER_ID:web:76e0a519870275262aadc8"
});

const messaging = firebase.messaging();

// The bridge sends DATA-ONLY messages, so this handler always fires in the
// background and we render the notification ourselves — the reliable path for
// a lock-screen banner on Android.
messaging.onBackgroundMessage((payload) => {
  const d = payload.data || {};
  self.registration.showNotification(d.title || "gothalo", {
    body: d.body || "",
    tag: "gothalo",
    renotify: true,          // re-alert even if a prior gothalo notification exists
    requireInteraction: true, // stay until tapped, don't auto-dismiss
    data: d,
  });
});

// Focus/open the app when the notification is tapped.
self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  event.waitUntil(clients.openWindow("/"));
});
