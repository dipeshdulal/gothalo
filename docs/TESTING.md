# Testing ladder — validate the backend with NO mobile app

Each rung is proven with `curl` or a browser tab. You only build the Flutter app
after the last rung (a real push landing on a device) is green.

## ① Bridge serves state — ✅ done
```bash
cd bridge && go build -o gothalo-bridge .
BRIDGE_ADDR=127.0.0.1:8787 BRIDGE_TOKEN=test123 ./gothalo-bridge &

curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8787/snapshot   # -> 401
curl -s -H "Authorization: Bearer test123" http://127.0.0.1:8787/snapshot # -> agents JSON
```
Confirmed: real agents + statuses returned, auth enforced.

## ② Reach it from the phone (proves the tailnet path) — no app
```bash
# on the Herdr host:
BRIDGE_ADDR=$(tailscale ip -4):8787 BRIDGE_TOKEN=realtoken ./gothalo-bridge
```
On the phone **browser** (or a REST client that can set headers), open
`http://<tailscale-ip>:8787/snapshot`. JSON over cellular = transport proven.

## ③ Typing works (proves control) — no app
```bash
curl -X POST -H "Authorization: Bearer test123" \
  -d '{"pane":"wM:p1","text":"echo hi\n"}' http://<ip>:8787/send
```
Watch it land in that Herdr pane.

## ④ Notify trigger fires (proves detection) — no app, no Firebase
The bridge already runs a watcher. Make an agent block (run something that needs
approval in a pane) and watch the bridge log:
```
NOTIFY  agent=wM:p2  status=blocked  title="…"
```
This proves detection → trigger with zero push setup.

## ⑤ A real push lands on a device (proves the whole chain) — still no app
Trick: **FCM web push.** A ~30-line static HTML page using the Firebase JS SDK
registers for a token and receives notifications in a **browser tab** (desktop or
phone) — no Flutter, no Apple Developer account.

1. Create a Firebase project (free); enable Cloud Messaging.
2. Static page requests a web push token, prints it.
3. Point the bridge's `notify()` at FCM `messages:send` with that token.
4. Block a live agent → a real notification pops in the browser tab.

Green here = the entire pipeline (`agent blocks → wait → FCM → device`) is proven.
Only now start Phase 3 (the Flutter app).

## Milestone gate
> Do not write app code until rung ⑤ is green.
The app is then pure UI over endpoints you already trust.
