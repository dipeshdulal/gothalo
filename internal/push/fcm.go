// Package push is a minimal FCM v1 sender using only the Go stdlib (no
// firebase-admin dependency).
//
// Flow: read the service-account JSON -> build & RS256-sign a JWT -> exchange
// it for an OAuth access token -> POST to the FCM messages:send API. Access
// tokens are cached until ~1 min before expiry.
//
// Every message carries explicit per-platform blocks (android / apns / webpush).
// That is not decoration: the FCM defaults are what make a notification quietly
// fail to arrive — a data message defaults to NORMAL priority and gets batched by
// Doze, and an iOS push with no apns-push-type is dropped outright. See
// [Client.build].
package push

import (
	"bytes"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"sync"
	"time"
)

const scope = "https://www.googleapis.com/auth/firebase.messaging"

type serviceAccount struct {
	ClientEmail string `json:"client_email"`
	PrivateKey  string `json:"private_key"`
	TokenURI    string `json:"token_uri"`
	ProjectID   string `json:"project_id"`
}

// Client sends FCM messages for one Firebase project.
type Client struct {
	sa  serviceAccount
	key *rsa.PrivateKey

	mu       sync.Mutex
	token    string
	tokenExp time.Time
}

func b64url(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

// LoadFile reads a Firebase service-account JSON file and returns a Client.
func LoadFile(path string) (*Client, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return Load(b)
}

// Load parses service-account JSON (and its RSA key) into a Client.
func Load(jsonBytes []byte) (*Client, error) {
	var sa serviceAccount
	if err := json.Unmarshal(jsonBytes, &sa); err != nil {
		return nil, fmt.Errorf("parse service account: %w", err)
	}
	if sa.ClientEmail == "" || sa.PrivateKey == "" || sa.ProjectID == "" {
		return nil, fmt.Errorf("service account missing client_email/private_key/project_id")
	}
	if sa.TokenURI == "" {
		sa.TokenURI = "https://oauth2.googleapis.com/token"
	}
	block, _ := pem.Decode([]byte(sa.PrivateKey))
	if block == nil {
		return nil, fmt.Errorf("private_key has no PEM block")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("parse private key: %w", err)
	}
	key, ok := parsed.(*rsa.PrivateKey)
	if !ok {
		return nil, fmt.Errorf("private key is not RSA")
	}
	return &Client{sa: sa, key: key}, nil
}

// ProjectID returns the Firebase project id the client sends to.
func (c *Client) ProjectID() string { return c.sa.ProjectID }

// accessToken returns a cached OAuth token or mints a fresh one via the
// JWT-bearer grant.
func (c *Client) accessToken() (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.token != "" && time.Now().Before(c.tokenExp.Add(-60*time.Second)) {
		return c.token, nil
	}

	now := time.Now()
	header := b64url([]byte(`{"alg":"RS256","typ":"JWT"}`))
	claims, _ := json.Marshal(map[string]any{
		"iss":   c.sa.ClientEmail,
		"scope": scope,
		"aud":   c.sa.TokenURI,
		"iat":   now.Unix(),
		"exp":   now.Add(time.Hour).Unix(),
	})
	signingInput := header + "." + b64url(claims)
	digest := sha256.Sum256([]byte(signingInput))
	sig, err := rsa.SignPKCS1v15(rand.Reader, c.key, crypto.SHA256, digest[:])
	if err != nil {
		return "", fmt.Errorf("sign jwt: %w", err)
	}
	assertion := signingInput + "." + b64url(sig)

	resp, err := http.PostForm(c.sa.TokenURI, url.Values{
		"grant_type": {"urn:ietf:params:oauth:grant-type:jwt-bearer"},
		"assertion":  {assertion},
	})
	if err != nil {
		return "", fmt.Errorf("token request: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode/100 != 2 {
		return "", fmt.Errorf("token endpoint %d: %s", resp.StatusCode, body)
	}
	var tok struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if err := json.Unmarshal(body, &tok); err != nil || tok.AccessToken == "" {
		return "", fmt.Errorf("bad token response: %s", body)
	}
	c.token = tok.AccessToken
	c.tokenExp = now.Add(time.Duration(tok.ExpiresIn) * time.Second)
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
	endpoint := "https://fcm.googleapis.com/v1/projects/" + c.sa.ProjectID + "/messages:send"

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
