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

// Alerts carry a `notification` block, which the SDK may display on its own; a
// dismiss is data-only and reaches us here. Either way we key notifications by
// "<server_id>/<pane_id>" so a later message about the same agent REPLACES the
// earlier one rather than stacking, and a dismiss can close exactly that one.
const tagFor = (d) => `${d.server_id || ""}/${d.agent || ""}`;

messaging.onBackgroundMessage(async (payload) => {
  const d = payload.data || {};

  if (d.type === "dismiss") {
    const open = await self.registration.getNotifications({ tag: tagFor(d) });
    open.forEach((n) => n.close());
    return;
  }

  self.registration.showNotification(d.title || "gothalo", {
    body: d.body || "",
    tag: tagFor(d),
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
