package push

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// build is a pure function of the Message, so these tests need no credentials.
func buildFor(t *testing.T, m Message) map[string]any {
	t.Helper()
	c := &Client{}
	// Round-trip through JSON so the assertions see exactly what FCM would.
	b, err := json.Marshal(c.build(m))
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var out map[string]any
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	return out
}

// TestAlertCarriesNotificationBlock is the regression test for the bug this
// package existed to have: a data-only message can only be drawn by the app's
// own code, so a killed app showed nothing at all. An alert must carry a
// notification block the system can render unaided.
func TestAlertCarriesNotificationBlock(t *testing.T) {
	msg := buildFor(t, Message{
		Token: "tok", Kind: KindDisplay, Title: "mac · claude", Body: "Needs you",
		Tag: "srv/w1:p2", ChannelID: "gothalo_blocked", HighPriority: true,
		Data: map[string]string{"agent": "w1:p2"},
	})

	n, ok := msg["notification"].(map[string]any)
	if !ok {
		t.Fatal("alert has no notification block: a killed app would show nothing")
	}
	if n["title"] != "mac · claude" || n["body"] != "Needs you" {
		t.Errorf("notification = %v, want the message title/body", n)
	}

	android, _ := msg["android"].(map[string]any)
	if android["priority"] != "high" {
		t.Errorf("android.priority = %v, want high (normal is Doze-batched)", android["priority"])
	}
	an, ok := android["notification"].(map[string]any)
	if !ok {
		t.Fatal("android.notification missing")
	}
	if an["tag"] != "srv/w1:p2" {
		t.Errorf("android.notification.tag = %v, want the message tag", an["tag"])
	}
	if an["channel_id"] != "gothalo_blocked" {
		t.Errorf("channel_id = %v, want gothalo_blocked", an["channel_id"])
	}
	if android["collapse_key"] != "srv/w1:p2" {
		t.Errorf("collapse_key = %v, want the message tag", android["collapse_key"])
	}
}

// TestSilentDrawsNothing: a dismiss must never render a notification of its own.
func TestSilentDrawsNothing(t *testing.T) {
	msg := buildFor(t, Message{
		Token: "tok", Kind: KindData, Tag: "srv/w1:p2", HighPriority: true,
		Data: map[string]string{"type": "dismiss"},
	})
	if _, has := msg["notification"]; has {
		t.Error("silent message carries a notification block; it would display")
	}
	android, _ := msg["android"].(map[string]any)
	if _, has := android["notification"]; has {
		t.Error("silent message carries android.notification; it would display")
	}
	if android["priority"] != "high" {
		t.Errorf("android.priority = %v, want high (a dismiss should not wait on Doze)", android["priority"])
	}
}

// TestNormalPriorityIsExplicit guards the default: a message that does not ask
// for high priority must still say so rather than omit the field.
func TestNormalPriorityIsExplicit(t *testing.T) {
	msg := buildFor(t, Message{Token: "tok", Kind: KindDisplay, Title: "t", Body: "b"})
	android, _ := msg["android"].(map[string]any)
	if android["priority"] != "normal" {
		t.Errorf("android.priority = %v, want normal", android["priority"])
	}
}

// TestTagTruncated: an over-long session-qualified pane id must not bloat the
// payload or be sent verbatim as a collapse key.
func TestTagTruncated(t *testing.T) {
	long := strings.Repeat("x", maxTagBytes+40)
	msg := buildFor(t, Message{Token: "tok", Kind: KindDisplay, Tag: long})
	android, _ := msg["android"].(map[string]any)
	got, _ := android["collapse_key"].(string)
	if len(got) != maxTagBytes {
		t.Errorf("collapse_key length = %d, want %d", len(got), maxTagBytes)
	}
}

// TestClassifyVerify covers the reason Verify exists: the failures that look
// alike from the outside must come back as different, actionable answers.
func TestClassifyVerify(t *testing.T) {
	cases := []struct {
		name    string
		status  int
		body    string
		wantErr bool
		// wantDenied marks the case a user cannot fix alone: authenticated, but
		// never granted access to the project.
		wantDenied bool
	}{
		{
			name:   "accepted",
			status: http.StatusOK,
			body:   `{"name":"projects/p/messages/1"}`,
		},
		{
			// Reaching a rejection of the placeholder token proves auth and
			// project access are fine, which is exactly what we are testing for.
			name:   "placeholder token rejected means auth is fine",
			status: http.StatusBadRequest,
			body:   `{"error":{"status":"INVALID_ARGUMENT","details":[{"errorCode":"INVALID_ARGUMENT"}]}}`,
		},
		{
			name:    "unauthenticated",
			status:  http.StatusUnauthorized,
			body:    `{"error":{"status":"UNAUTHENTICATED"}}`,
			wantErr: true,
		},
		{
			name:       "permission denied",
			status:     http.StatusForbidden,
			body:       `{"error":{"status":"PERMISSION_DENIED"}}`,
			wantErr:    true,
			wantDenied: true,
		},
		{
			name:    "project not found",
			status:  http.StatusNotFound,
			body:    `{"error":{"status":"NOT_FOUND","message":"project not found"}}`,
			wantErr: true,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := classifyVerify(tc.status, []byte(tc.body))
			if (err != nil) != tc.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tc.wantErr)
			}
			if got := errors.Is(err, ErrPermissionDenied); got != tc.wantDenied {
				t.Errorf("ErrPermissionDenied = %v, want %v (err: %v)", got, tc.wantDenied, err)
			}
		})
	}
}

// TestVerifyDoesNotDeliver: Verify must set validate_only, or "check my setup"
// would push a junk notification to somebody's phone.
func TestVerifyDoesNotDeliver(t *testing.T) {
	tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"access_token":"at","expires_in":3600}`))
	}))
	defer tokenSrv.Close()

	var body map[string]any
	fcmSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("Authorization"); got != "Bearer at" {
			t.Errorf("Authorization = %q, want the minted token", got)
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Errorf("decode: %v", err)
		}
		_, _ = w.Write([]byte(`{"name":"projects/p/messages/1"}`))
	}))
	defer fcmSrv.Close()

	old := fcmBaseURL
	fcmBaseURL = fcmSrv.URL
	defer func() { fcmBaseURL = old }()

	c := &Client{creds: &credentials{
		kind: kindAuthorizedUser, projectID: "p", tokenURI: tokenSrv.URL,
		clientID: "cid", clientSecret: "cs", refreshToken: "rt",
	}}
	if err := c.Verify(); err != nil {
		t.Fatalf("Verify: %v", err)
	}
	if body["validate_only"] != true {
		t.Errorf("validate_only = %v, want true — Verify must not deliver a real push", body["validate_only"])
	}
}

// TestIsUnregistered: only FCM's "this token is dead" shapes count, so a
// transient failure never costs a device its registration.
func TestIsUnregistered(t *testing.T) {
	cases := []struct {
		name   string
		status int
		body   string
		want   bool
	}{
		{
			name:   "unregistered detail",
			status: http.StatusNotFound,
			body:   `{"error":{"status":"NOT_FOUND","details":[{"errorCode":"UNREGISTERED"}]}}`,
			want:   true,
		},
		{
			name:   "invalid argument detail",
			status: http.StatusBadRequest,
			body:   `{"error":{"status":"INVALID_ARGUMENT","details":[{"errorCode":"INVALID_ARGUMENT"}]}}`,
			want:   true,
		},
		{
			name:   "plain not found",
			status: http.StatusNotFound,
			body:   `{"error":{"status":"NOT_FOUND"}}`,
			want:   true,
		},
		{
			name:   "quota exceeded is transient",
			status: http.StatusTooManyRequests,
			body:   `{"error":{"status":"RESOURCE_EXHAUSTED"}}`,
			want:   false,
		},
		{
			name:   "server error is transient",
			status: http.StatusInternalServerError,
			body:   `{"error":{"status":"INTERNAL"}}`,
			want:   false,
		},
		{
			name:   "bad request that is not about the token",
			status: http.StatusBadRequest,
			body:   `{"error":{"status":"INVALID_ARGUMENT","details":[{"errorCode":"THIRD_PARTY_AUTH_ERROR"}]}}`,
			want:   false,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := isUnregistered(tc.status, []byte(tc.body)); got != tc.want {
				t.Errorf("isUnregistered = %v, want %v", got, tc.want)
			}
		})
	}
}
