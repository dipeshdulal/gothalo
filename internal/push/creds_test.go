package push

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"testing"
)

// noMetadataServer points the metadata probe at a closed port. Without it a
// test with no credentials would try to reach the real metadata host, making
// the result depend on where the test runs.
func noMetadataServer(t *testing.T) {
	t.Helper()
	t.Setenv("GCE_METADATA_HOST", "127.0.0.1:1")
}

// isolateCredentialEnv removes every ambient credential source, so a developer
// who happens to be logged into gcloud does not get different results than CI.
func isolateCredentialEnv(t *testing.T) {
	t.Helper()
	noMetadataServer(t)
	t.Setenv("GOOGLE_APPLICATION_CREDENTIALS", "")
	t.Setenv("CLOUDSDK_CONFIG", t.TempDir())
}

func serviceAccountJSON(t *testing.T, project string) []byte {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatalf("marshal key: %v", err)
	}
	pemKey := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
	b, _ := json.Marshal(map[string]string{
		"type":         "service_account",
		"project_id":   project,
		"client_email": "bot@" + project + ".iam.gserviceaccount.com",
		"private_key":  string(pemKey),
	})
	return b
}

func userCredentialJSON(quotaProject string) []byte {
	m := map[string]string{
		"type":          "authorized_user",
		"client_id":     "client-id.apps.googleusercontent.com",
		"client_secret": "client-secret",
		"refresh_token": "refresh-token",
	}
	if quotaProject != "" {
		m["quota_project_id"] = quotaProject
	}
	b, _ := json.Marshal(m)
	return b
}

func writeFile(t *testing.T, dir, name string, b []byte) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, b, 0o600); err != nil {
		t.Fatalf("write %s: %v", p, err)
	}
	return p
}

// TestParseServiceAccount: the pre-existing shape must keep working unchanged.
func TestParseServiceAccount(t *testing.T) {
	creds, err := parseCredentials(serviceAccountJSON(t, "proj-a"), "test")
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if creds.kind != kindServiceAccount {
		t.Errorf("kind = %q, want %q", creds.kind, kindServiceAccount)
	}
	if creds.projectID != "proj-a" {
		t.Errorf("projectID = %q, want proj-a", creds.projectID)
	}
	if creds.key == nil {
		t.Error("private key was not parsed")
	}
	if creds.tokenURI != defaultTokenURI {
		t.Errorf("tokenURI = %q, want the default", creds.tokenURI)
	}
}

// TestParseAuthorizedUser is the new shape — the whole point of this change.
func TestParseAuthorizedUser(t *testing.T) {
	creds, err := parseCredentials(userCredentialJSON("proj-b"), "test")
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if creds.kind != kindAuthorizedUser {
		t.Errorf("kind = %q, want %q", creds.kind, kindAuthorizedUser)
	}
	if creds.refreshToken != "refresh-token" {
		t.Errorf("refreshToken = %q", creds.refreshToken)
	}
	if creds.key != nil {
		t.Error("user credentials carry no signing key")
	}
	// quota_project_id is the only project hint a user credential has.
	if creds.projectID != "proj-b" {
		t.Errorf("projectID = %q, want the quota project as a fallback", creds.projectID)
	}
}

// TestParseAuthorizedUserWithoutProject: the normal case, since gcloud does not
// always set a quota project. It must parse — the project comes from config.
func TestParseAuthorizedUserWithoutProject(t *testing.T) {
	creds, err := parseCredentials(userCredentialJSON(""), "test")
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if creds.projectID != "" {
		t.Errorf("projectID = %q, want empty", creds.projectID)
	}
}

func TestParseCredentialsRejects(t *testing.T) {
	cases := []struct {
		name string
		body string
	}{
		{"not json", `{`},
		{"unknown type", `{"type":"magic"}`},
		{"service account missing project", `{"type":"service_account","client_email":"a@b","private_key":"x"}`},
		{"user missing refresh token", `{"type":"authorized_user","client_id":"a","client_secret":"b"}`},
		{"service account bad pem", `{"type":"service_account","client_email":"a@b","project_id":"p","private_key":"not-a-pem"}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := parseCredentials([]byte(tc.body), "test"); err == nil {
				t.Error("want an error, got nil")
			}
		})
	}
}

// TestResolveOrder: an explicitly configured path wins over everything else, so
// a stale gcloud login can never silently shadow the operator's choice.
func TestResolveOrder(t *testing.T) {
	isolateCredentialEnv(t)
	dir := t.TempDir()

	explicit := writeFile(t, dir, "explicit.json", serviceAccountJSON(t, "from-explicit"))
	envPath := writeFile(t, dir, "env.json", serviceAccountJSON(t, "from-env"))
	t.Setenv("GOOGLE_APPLICATION_CREDENTIALS", envPath)

	gcloudDir := t.TempDir()
	writeFile(t, gcloudDir, "application_default_credentials.json", userCredentialJSON("from-gcloud"))
	t.Setenv("CLOUDSDK_CONFIG", gcloudDir)

	creds, err := resolveCredentials(explicit)
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if creds.projectID != "from-explicit" {
		t.Errorf("projectID = %q, want from-explicit", creds.projectID)
	}

	// With no explicit path, the env var is next.
	creds, err = resolveCredentials("")
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if creds.projectID != "from-env" {
		t.Errorf("projectID = %q, want from-env", creds.projectID)
	}

	// With neither, gcloud's well-known file is the fallback — this is the path
	// `gothalo push login` sets up.
	t.Setenv("GOOGLE_APPLICATION_CREDENTIALS", "")
	creds, err = resolveCredentials("")
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if creds.kind != kindAuthorizedUser {
		t.Errorf("kind = %q, want the gcloud user credential", creds.kind)
	}
}

// TestResolveSkipsMissingConfiguredPath: the configured service-account path
// has a DEFAULT, so on a fresh install it points at a file that does not exist.
// If that shadowed the rest of the search order, `push login` could never work.
func TestResolveSkipsMissingConfiguredPath(t *testing.T) {
	isolateCredentialEnv(t)
	gcloudDir := t.TempDir()
	writeFile(t, gcloudDir, "application_default_credentials.json", userCredentialJSON("p"))
	t.Setenv("CLOUDSDK_CONFIG", gcloudDir)

	creds, err := resolveCredentials(filepath.Join(t.TempDir(), "does-not-exist.json"))
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if creds.kind != kindAuthorizedUser {
		t.Errorf("kind = %q, want fall-through to the gcloud credential", creds.kind)
	}
}

// TestResolveMalformedIsFatal: a file that EXISTS but is broken must not fall
// through — that would report "no credentials" and send the operator looking in
// the wrong place for a typo they made in a file they know about.
func TestResolveMalformedIsFatal(t *testing.T) {
	isolateCredentialEnv(t)
	gcloudDir := t.TempDir()
	writeFile(t, gcloudDir, "application_default_credentials.json", userCredentialJSON("p"))
	t.Setenv("CLOUDSDK_CONFIG", gcloudDir)

	bad := writeFile(t, t.TempDir(), "bad.json", []byte(`{"type":"service_account"}`))
	if _, err := resolveCredentials(bad); err == nil {
		t.Fatal("want an error for a malformed configured credential, got nil")
	}
}

func TestResolveNothingFound(t *testing.T) {
	isolateCredentialEnv(t)
	_, err := resolveCredentials("")
	if !errors.Is(err, ErrNoCredentials) {
		t.Errorf("err = %v, want ErrNoCredentials", err)
	}
}

// TestResolveRequiresProjectForUserCredentials: a user credential names a
// person, so without a configured project there is nothing to address a send
// to. The error has to be specific enough for the CLI to explain the fix.
func TestResolveRequiresProjectForUserCredentials(t *testing.T) {
	isolateCredentialEnv(t)
	gcloudDir := t.TempDir()
	writeFile(t, gcloudDir, "application_default_credentials.json", userCredentialJSON(""))
	t.Setenv("CLOUDSDK_CONFIG", gcloudDir)

	if _, err := Resolve("", ""); !errors.Is(err, ErrNoProjectID) {
		t.Errorf("err = %v, want ErrNoProjectID", err)
	}

	c, err := Resolve("", "configured-project")
	if err != nil {
		t.Fatalf("resolve with project: %v", err)
	}
	if c.ProjectID() != "configured-project" {
		t.Errorf("ProjectID = %q, want configured-project", c.ProjectID())
	}
}

// TestConfiguredProjectOverridesFile: pointing an existing service-account key
// at a different project must not silently keep sending to the file's project.
func TestConfiguredProjectOverridesFile(t *testing.T) {
	isolateCredentialEnv(t)
	p := writeFile(t, t.TempDir(), "sa.json", serviceAccountJSON(t, "file-project"))
	c, err := Resolve(p, "override-project")
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if c.ProjectID() != "override-project" {
		t.Errorf("ProjectID = %q, want override-project", c.ProjectID())
	}
}

// TestRefreshTokenGrant pins the wire format of the new grant. It differs from
// the service-account flow in kind, not detail: no assertion, and deliberately
// no scope parameter (scopes are fixed when the user consents at login).
func TestRefreshTokenGrant(t *testing.T) {
	var got url.Values
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseForm(); err != nil {
			t.Errorf("parse form: %v", err)
		}
		got = r.PostForm
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"access_token":"at-123","expires_in":3600}`))
	}))
	defer srv.Close()

	creds := &credentials{
		kind: kindAuthorizedUser, tokenURI: srv.URL,
		clientID: "cid", clientSecret: "csecret", refreshToken: "rtoken",
	}
	token, expires, err := creds.mintToken()
	if err != nil {
		t.Fatalf("mint: %v", err)
	}
	if token != "at-123" {
		t.Errorf("token = %q, want at-123", token)
	}
	if expires.Seconds() != 3600 {
		t.Errorf("expires = %v, want 1h", expires)
	}
	if g := got.Get("grant_type"); g != "refresh_token" {
		t.Errorf("grant_type = %q, want refresh_token", g)
	}
	if got.Get("refresh_token") != "rtoken" || got.Get("client_id") != "cid" || got.Get("client_secret") != "csecret" {
		t.Errorf("form = %v, want the client id/secret/refresh token", got)
	}
	if got.Has("scope") {
		t.Error("refresh grant sent a scope parameter; scopes are bound at consent time")
	}
	if got.Has("assertion") {
		t.Error("refresh grant sent a signed assertion; that is the service-account flow")
	}
}

// TestTokenCaching: a token is reused until near expiry, so a burst of pushes
// does not mint one token per message.
func TestTokenCaching(t *testing.T) {
	var calls int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		_, _ = w.Write([]byte(`{"access_token":"at","expires_in":3600}`))
	}))
	defer srv.Close()

	c := &Client{creds: &credentials{
		kind: kindAuthorizedUser, tokenURI: srv.URL,
		clientID: "cid", clientSecret: "cs", refreshToken: "rt",
	}}
	for range 3 {
		if _, err := c.accessToken(); err != nil {
			t.Fatalf("accessToken: %v", err)
		}
	}
	if calls != 1 {
		t.Errorf("token endpoint called %d times, want 1", calls)
	}
}

// TestIdentityIsBestEffort: a user credential without the email scope returns
// no identity, and that must read as "unknown", never as a failure.
func TestIdentityIsBestEffort(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusForbidden)
	}))
	defer srv.Close()
	old := tokeninfoURL
	tokeninfoURL = srv.URL
	defer func() { tokeninfoURL = old }()

	creds := &credentials{kind: kindAuthorizedUser}
	if got := creds.identity("at"); got != "" {
		t.Errorf("identity = %q, want empty", got)
	}

	sa := &credentials{kind: kindServiceAccount, clientEmail: "bot@p.iam.gserviceaccount.com"}
	if got := sa.identity(""); got != "bot@p.iam.gserviceaccount.com" {
		t.Errorf("identity = %q, want the service account email", got)
	}
}
