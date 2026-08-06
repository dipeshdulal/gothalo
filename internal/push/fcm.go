// Package push is a minimal FCM v1 sender using only the Go stdlib (no
// firebase-admin dependency).
//
// Flow: resolve credentials -> mint an OAuth access token -> POST to the FCM
// messages:send API. Access tokens are cached until ~1 min before expiry.
//
// Credentials come in two shapes — a downloaded service-account key, or the
// user credentials `gcloud auth application-default login` leaves behind — and
// they are found by following Google's Application Default Credentials search
// order. See creds.go, which is also where the reasoning for supporting both
// lives.
//
// Every message carries explicit per-platform blocks (android / apns / webpush).
// That is not decoration: the FCM defaults are what make a notification quietly
// fail to arrive — a data message defaults to NORMAL priority and gets batched by
// Doze, and an iOS push with no apns-push-type is dropped outright. See
// [Client.build].
package push

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"sync"
	"time"
)

// Client sends FCM messages for one Firebase project.
type Client struct {
	creds *credentials

	mu       sync.Mutex
	token    string
	tokenExp time.Time
}

// Resolve finds credentials by the ADC search order and returns a ready Client.
//
// explicitPath is gothalo's configured service-account path and is tried first;
// projectID (config push.project_id) overrides whatever the credentials imply,
// and is REQUIRED for user credentials, which name a person rather than a
// project.
func Resolve(explicitPath, projectID string) (*Client, error) {
	creds, err := resolveCredentials(explicitPath)
	if err != nil {
		return nil, err
	}
	if projectID != "" {
		creds.projectID = projectID
	}
	if creds.projectID == "" {
		return nil, fmt.Errorf("%w: credentials from %s name no project — set push.project_id in config (or GOTHALO_FCM_PROJECT)",
			ErrNoProjectID, creds.source)
	}
	return &Client{creds: creds}, nil
}

// LoadFile reads a credential JSON file (either shape) and returns a Client.
func LoadFile(path string) (*Client, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return Load(b)
}

// Load parses credential JSON (either shape) into a Client. A user credential
// carries no project id, so callers on that path want [Resolve] instead.
func Load(jsonBytes []byte) (*Client, error) {
	creds, err := parseCredentials(jsonBytes, "credentials")
	if err != nil {
		return nil, err
	}
	if creds.projectID == "" {
		return nil, fmt.Errorf("%w: credentials name no project", ErrNoProjectID)
	}
	return &Client{creds: creds}, nil
}

// ProjectID returns the Firebase project id the client sends to.
func (c *Client) ProjectID() string {
	if c.creds == nil {
		return ""
	}
	return c.creds.projectID
}

// Source describes where the credentials came from, for logs and `push status`.
// Two plausible credential files on one machine is otherwise an invisible
// mixup.
func (c *Client) Source() string {
	if c.creds == nil {
		return ""
	}
	return c.creds.source
}

// Kind reports the credential shape ("service_account", "authorized_user",
// "metadata").
func (c *Client) Kind() string {
	if c.creds == nil {
		return ""
	}
	return c.creds.kind
}

// Identity best-effort names who the client authenticates as. Empty is a normal
// answer for user credentials without the email scope, not an error.
func (c *Client) Identity() string {
	at, err := c.accessToken()
	if err != nil {
		return ""
	}
	return c.creds.identity(at)
}

// accessToken returns a cached OAuth token or mints a fresh one by whichever
// grant this credential shape uses.
func (c *Client) accessToken() (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.token != "" && time.Now().Before(c.tokenExp.Add(-60*time.Second)) {
		return c.token, nil
	}
	token, expiresIn, err := c.creds.mintToken()
	if err != nil {
		return "", err
	}
	c.token = token
	c.tokenExp = time.Now().Add(expiresIn)
	return c.token, nil
}

// Kind selects how a message is delivered.
type Kind string

const (
	// KindDisplay carries a `notification` block, so ANDROID renders it — with no
	// app process involved. This is the only shape that survives the app being
	// swiped away, frozen by an OEM battery manager, or killed.
	//
	// The cost is that Android does NOT invoke the app's message handler for a
	// notification-bearing message while the app is backgrounded, so the client
	// cannot enrich it: no action buttons, no grouping. See KindData.
	KindDisplay Kind = "display"

	// KindData is data-only, which is what makes the app's handler run. The
	// client uses it both to ACT on a payload (dismissing a notification that is
	// no longer true) and to redraw a KindDisplay notification as a richer,
	// action-bearing one — same Tag, so it replaces rather than duplicates.
	//
	// It is best-effort by nature: a frozen or dead process never sees it.
	KindData Kind = "data"
)

// Message is one push to one device. Tag is the identity of the *subject* (a
// pane on a server), not of the message: reusing it lets a later message replace
// an earlier one for the same agent instead of stacking a duplicate, on both
// platforms and in the client's own notification.
type Message struct {
	Token string
	Kind  Kind

	Title string
	Body  string

	// Tag collapses/replaces earlier notifications about the same subject.
	Tag string
	// ChannelID is the Android notification channel; it decides importance,
	// sound and whether the alert may interrupt.
	ChannelID string
	// HighPriority asks for immediate, Doze-exempt delivery.
	HighPriority bool

	Data map[string]string
}

// ErrTokenInvalid marks a device token FCM has rejected as unregistered or
// malformed. It is permanent: the caller should drop the token rather than
// retry it forever.
var ErrTokenInvalid = errors.New("fcm token invalid")

// maxTagBytes bounds the notification tag / collapse key. FCM caps a
// collapse_key well above this; the limit exists so an unusually long
// session-qualified pane id can't bloat every payload.
const maxTagBytes = 64

// sendAttempts is how many times a transient failure (network, 5xx, 429) is
// retried before the message is dropped.
const sendAttempts = 3

// httpClient bounds every FCM call. Without a timeout one unreachable device
// token could wedge a notification fan-out indefinitely.
var httpClient = &http.Client{Timeout: 15 * time.Second}

// Send delivers a plain data-only message. Retained for callers that want the
// old shape (the web test page); everything notification-shaped uses
// [Client.SendMessage].
func (c *Client) Send(deviceToken, title, body string, data map[string]string) error {
	return c.SendMessage(Message{
		Token: deviceToken, Kind: KindDisplay, Title: title, Body: body,
		HighPriority: true, Data: data,
	})
}

// SendMessage renders m into an FCM v1 payload and delivers it, retrying
// transient failures. A token FCM rejects as unregistered returns
// [ErrTokenInvalid] so the caller can prune it.
func (c *Client) SendMessage(m Message) error {
	payload, err := json.Marshal(map[string]any{"message": c.build(m)})
	if err != nil {
		return fmt.Errorf("marshal fcm message: %w", err)
	}
	endpoint := c.endpoint()

	var last error
	for attempt := range sendAttempts {
		if attempt > 0 {
			// 250ms, 500ms — short enough that a blocked agent still gets a timely
			// alert, long enough to ride out a blip.
			time.Sleep(time.Duration(250*(1<<(attempt-1))) * time.Millisecond)
		}
		retryable, err := c.post(endpoint, payload)
		if err == nil {
			return nil
		}
		last = err
		if !retryable {
			return err
		}
	}
	return last
}

// fcmBaseURL is the FCM v1 API root. A var so tests can point it at a stub.
var fcmBaseURL = "https://fcm.googleapis.com/v1"

func (c *Client) endpoint() string {
	return fcmBaseURL + "/projects/" + c.ProjectID() + "/messages:send"
}

// Verify checks that these credentials can actually send to this project,
// WITHOUT delivering anything: FCM's validate_only flag runs the whole
// authorize-and-validate path and stops short of delivery.
//
// The point is to turn the two failure modes that look identical at 2am into
// distinct, actionable answers. A credential that authenticates but was never
// granted access returns PERMISSION_DENIED — on the gcloud path that means
// "nobody added you to the project yet", which no amount of re-running login
// will fix. So it is reported as [ErrPermissionDenied] rather than a generic
// send failure.
//
// The device token below is a deliberate placeholder: with a valid credential
// FCM rejects it as INVALID_ARGUMENT, and reaching that rejection is itself the
// proof that auth and project access are fine.
func (c *Client) Verify() error {
	at, err := c.accessToken()
	if err != nil {
		return fmt.Errorf("could not mint an access token: %w", err)
	}
	payload, _ := json.Marshal(map[string]any{
		"validate_only": true,
		"message":       map[string]any{"token": "gothalo-verify-placeholder"},
	})
	req, err := http.NewRequest("POST", c.endpoint(), bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+at)
	req.Header.Set("Content-Type", "application/json")

	resp, err := httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("fcm request: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	return classifyVerify(resp.StatusCode, body)
}

// classifyVerify maps a validate_only response to a verdict. Split out from
// [Client.Verify] so the mapping is testable without a network.
func classifyVerify(status int, body []byte) error {
	switch {
	// 200 (accepted) and a rejection of the placeholder token both prove the
	// credential authenticated and may send to this project.
	//
	// This deliberately does NOT reuse isUnregistered: that treats a bare 404
	// NOT_FOUND as a dead token, and a 404 here far more likely means the
	// PROJECT does not exist. Requiring an explicit token-level error code keeps
	// a wrong project_id from being reported as a healthy setup.
	case status/100 == 2, tokenRejected(body):
		return nil
	case status == http.StatusUnauthorized:
		return fmt.Errorf("credentials rejected (401) — run `gothalo push login` again: %s", body)
	case status == http.StatusForbidden:
		return fmt.Errorf("%w (403) — the credential is valid but has no permission to send. "+
			"Ask the project owner to grant it Firebase Cloud Messaging access, "+
			"or a custom role with cloudmessaging.messages.create: %s", ErrPermissionDenied, body)
	case status == http.StatusNotFound:
		return fmt.Errorf("project not found (404) — check push.project_id, and that the "+
			"Firebase Cloud Messaging API is enabled for it: %s", body)
	default:
		return fmt.Errorf("fcm %d: %s", status, body)
	}
}

// post performs one delivery attempt. It reports whether the failure is worth
// retrying (network error, 429, 5xx); everything else — including an invalid
// token — is permanent.
func (c *Client) post(endpoint string, payload []byte) (retryable bool, err error) {
	at, err := c.accessToken()
	if err != nil {
		return true, err
	}
	req, err := http.NewRequest("POST", endpoint, bytes.NewReader(payload))
	if err != nil {
		return false, err
	}
	req.Header.Set("Authorization", "Bearer "+at)
	req.Header.Set("Content-Type", "application/json")

	resp, err := httpClient.Do(req)
	if err != nil {
		return true, fmt.Errorf("fcm request: %w", err)
	}
	defer resp.Body.Close()
	rb, _ := io.ReadAll(resp.Body)
	switch {
	case resp.StatusCode/100 == 2:
		return false, nil
	case isUnregistered(resp.StatusCode, rb):
		return false, fmt.Errorf("%w: fcm %d: %s", ErrTokenInvalid, resp.StatusCode, rb)
	case resp.StatusCode == http.StatusTooManyRequests || resp.StatusCode/100 == 5:
		return true, fmt.Errorf("fcm %d: %s", resp.StatusCode, rb)
	default:
		return false, fmt.Errorf("fcm %d: %s", resp.StatusCode, rb)
	}
}

// tokenRejected reports whether FCM's complaint is specifically about the
// device token, evidenced by an explicit error code rather than the status
// alone. Used by [classifyVerify], where "it got as far as disliking the token"
// is the success signal.
func tokenRejected(body []byte) bool {
	var e struct {
		Error struct {
			Details []struct {
				ErrorCode string `json:"errorCode"`
			} `json:"details"`
		} `json:"error"`
	}
	if json.Unmarshal(body, &e) != nil {
		return false
	}
	for _, d := range e.Error.Details {
		if d.ErrorCode == "UNREGISTERED" || d.ErrorCode == "INVALID_ARGUMENT" {
			return true
		}
	}
	return false
}

// isUnregistered reports whether FCM is telling us this token is dead. FCM v1
// signals it as 404 UNREGISTERED (the app was uninstalled or the token expired)
// or 400 INVALID_ARGUMENT on the token field (a malformed registration).
func isUnregistered(status int, body []byte) bool {
	if status != http.StatusNotFound && status != http.StatusBadRequest {
		return false
	}
	var e struct {
		Error struct {
			Status  string `json:"status"`
			Details []struct {
				ErrorCode string `json:"errorCode"`
			} `json:"details"`
		} `json:"error"`
	}
	if json.Unmarshal(body, &e) != nil {
		return false
	}
	for _, d := range e.Error.Details {
		if d.ErrorCode == "UNREGISTERED" || d.ErrorCode == "INVALID_ARGUMENT" {
			return true
		}
	}
	return status == http.StatusNotFound && e.Error.Status == "NOT_FOUND"
}

// build renders a Message as the FCM v1 `message` object.
//
// Two settings here are the difference between a notification arriving and
// quietly not arriving, and both are non-default:
//
//   - android.priority "high". A data message defaults to NORMAL, which Doze is
//     free to batch until the next maintenance window — precisely the "it never
//     showed up while the app was away" symptom.
//   - an `android.notification` block on alerts. A data-only message can only be
//     drawn by the app's own code, so a swiped-away or OEM-killed process shows
//     nothing at all. With this block the system tray renders it with no app
//     process involved; the client then replaces it in place (same tag) with a
//     richer, action-bearing notification whenever it does get to run.
//
// Silent messages deliberately carry no notification block: they exist to make
// the client dismiss something, and must never draw anything themselves.
func (c *Client) build(m Message) map[string]any {
	tag := m.Tag
	if len(tag) > maxTagBytes {
		tag = tag[:maxTagBytes]
	}
	prio := "normal"
	if m.HighPriority {
		prio = "high"
	}

	android := map[string]any{"priority": prio}
	if tag != "" {
		android["collapse_key"] = tag
	}
	msg := map[string]any{"token": m.Token, "data": m.Data}

	if m.Kind == KindDisplay {
		msg["notification"] = map[string]any{"title": m.Title, "body": m.Body}

		an := map[string]any{
			"notification_priority": "PRIORITY_HIGH",
			"default_sound":         true,
		}
		if tag != "" {
			an["tag"] = tag // replace-in-place instead of stacking duplicates
		}
		if m.ChannelID != "" {
			an["channel_id"] = m.ChannelID
		}
		android["notification"] = an
	}

	msg["android"] = android
	msg["webpush"] = map[string]any{
		"headers": map[string]string{"Urgency": "high", "TTL": "3600"},
	}
	return msg
}
