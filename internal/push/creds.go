package push

// Credential resolution for FCM.
//
// There are two credential SHAPES, and the difference is not cosmetic — each
// mints an access token by a different OAuth grant:
//
//   - service_account: a downloaded private key. We build an RS256-signed JWT
//     and exchange it (the jwt-bearer grant). Anyone holding the file *is* that
//     service account, so a team sharing one file shares one unrevocable,
//     unattributable identity.
//   - authorized_user: what `gcloud auth application-default login` leaves
//     behind — a refresh token for a *person's* Google account. There is no key
//     to sign with; the refresh_token grant trades it for an access token. Each
//     teammate authenticates as themselves, so access is granted and revoked per
//     person in IAM and the audit log names who sent what.
//
// Scopes are fixed at authorization time for the refresh grant — they cannot be
// requested later. That is why `gothalo push login` passes --scopes explicitly:
// gcloud's default scope set does not include firebase.messaging, and a token
// minted without it fails at send time with a confusing 403.
//
// We also follow Google's Application Default Credentials search order, so the
// same binary works from a laptop (gcloud login) and from Cloud Run (the
// instance's attached identity, no file anywhere).

import (
	"context"
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
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

// Scope is the OAuth scope required to send a message through the FCM v1 API.
const Scope = "https://www.googleapis.com/auth/firebase.messaging"

// LoginScopes is what `gothalo push login` asks gcloud to authorize. The
// identity scopes are not needed to send; they exist so `push status` can report
// WHO is authenticated instead of an anonymous "some user credential", which is
// the difference between a useful status line and a puzzle.
var LoginScopes = []string{Scope, "openid", "email"}

const defaultTokenURI = "https://oauth2.googleapis.com/token"

// metadataHost is the GCE/Cloud Run metadata server. Overridable via
// GCE_METADATA_HOST, which is also how test doubles are pointed at.
const metadataHost = "metadata.google.internal"

// metadataProbe bounds the metadata-server check. It runs only when no
// credential file was found anywhere, and off GCP the host does not resolve —
// so this is the ceiling on how long a laptop with no credentials waits before
// `serve` reports FCM disabled.
const metadataProbe = 400 * time.Millisecond

// Credential shape identifiers, as written in the JSON's "type" field.
const (
	kindServiceAccount = "service_account"
	kindAuthorizedUser = "authorized_user"
	kindMetadata       = "metadata" // synthesized; never appears in a file
)

// ErrNoCredentials means nothing was found anywhere in the search order. It is
// the expected state for a fresh install and must stay distinguishable from a
// credential that was found but is broken.
var ErrNoCredentials = errors.New("no FCM credentials found")

// ErrNoProjectID means credentials resolved but we do not know which Firebase
// project to send to. A user credential carries no project (it identifies a
// person, not a project), so this is the normal gap on the gcloud path.
var ErrNoProjectID = errors.New("no Firebase project id")

// ErrPermissionDenied means the credentials are valid but lack permission to
// send. On the gcloud path this is the "you were never added to the project"
// case, and it is worth its own error so the CLI can say so in words.
var ErrPermissionDenied = errors.New("permission denied")

// credentials is one resolved credential of either shape, plus where it came
// from (shown by `push status`; a wrong-file mixup is otherwise invisible).
type credentials struct {
	kind   string
	source string

	projectID string

	// service_account
	clientEmail string
	key         *rsa.PrivateKey
	tokenURI    string

	// authorized_user
	clientID     string
	clientSecret string
	refreshToken string
}

// credentialFile is the union of both on-disk shapes. Google writes them to the
// same well-known path, discriminated only by "type".
type credentialFile struct {
	Type string `json:"type"`

	// service_account
	ClientEmail string `json:"client_email"`
	PrivateKey  string `json:"private_key"`
	ProjectID   string `json:"project_id"`
	TokenURI    string `json:"token_uri"`

	// authorized_user
	ClientID     string `json:"client_id"`
	ClientSecret string `json:"client_secret"`
	RefreshToken string `json:"refresh_token"`
	// QuotaProjectID is the closest thing a user credential has to a project,
	// and gcloud usually sets it. Used only as a fallback guess.
	QuotaProjectID string `json:"quota_project_id"`
}

// parseCredentials reads either credential shape.
func parseCredentials(b []byte, source string) (*credentials, error) {
	var f credentialFile
	if err := json.Unmarshal(b, &f); err != nil {
		return nil, fmt.Errorf("parse credentials from %s: %w", source, err)
	}

	kind := f.Type
	if kind == "" {
		// Tolerate a service-account file with no "type" rather than failing
		// with a confusing "unknown credential type: ".
		if f.PrivateKey != "" {
			kind = kindServiceAccount
		} else if f.RefreshToken != "" {
			kind = kindAuthorizedUser
		}
	}

	switch kind {
	case kindServiceAccount:
		if f.ClientEmail == "" || f.PrivateKey == "" || f.ProjectID == "" {
			return nil, fmt.Errorf("%s: service account missing client_email/private_key/project_id", source)
		}
		key, err := parseRSAKey(f.PrivateKey)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", source, err)
		}
		tokenURI := f.TokenURI
		if tokenURI == "" {
			tokenURI = defaultTokenURI
		}
		return &credentials{
			kind: kindServiceAccount, source: source,
			projectID:   f.ProjectID,
			clientEmail: f.ClientEmail, key: key, tokenURI: tokenURI,
		}, nil

	case kindAuthorizedUser:
		if f.ClientID == "" || f.ClientSecret == "" || f.RefreshToken == "" {
			return nil, fmt.Errorf("%s: user credentials missing client_id/client_secret/refresh_token", source)
		}
		tokenURI := f.TokenURI
		if tokenURI == "" {
			tokenURI = defaultTokenURI
		}
		return &credentials{
			kind: kindAuthorizedUser, source: source,
			// A user credential identifies a person, not a project. quota_project_id
			// is a hint only; config.push.project_id overrides it.
			projectID:    f.QuotaProjectID,
			clientID:     f.ClientID,
			clientSecret: f.ClientSecret,
			refreshToken: f.RefreshToken,
			tokenURI:     tokenURI,
		}, nil

	default:
		return nil, fmt.Errorf("%s: unknown credential type %q", source, f.Type)
	}
}

func b64url(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

func parseRSAKey(pemKey string) (*rsa.PrivateKey, error) {
	block, _ := pem.Decode([]byte(pemKey))
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
	return key, nil
}

// adcFilePath returns gcloud's well-known Application Default Credentials path
// — where `gcloud auth application-default login` writes.
func adcFilePath() string {
	if dir := os.Getenv("CLOUDSDK_CONFIG"); dir != "" {
		return filepath.Join(dir, "application_default_credentials.json")
	}
	if runtime.GOOS == "windows" {
		if appData := os.Getenv("APPDATA"); appData != "" {
			return filepath.Join(appData, "gcloud", "application_default_credentials.json")
		}
		return ""
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".config", "gcloud", "application_default_credentials.json")
}

// resolveCredentials walks the search order and returns the first credential
// found. The order mirrors Google's ADC convention, with gothalo's own
// configured path ahead of it so an explicit setting always wins:
//
//  1. explicitPath (config push.service_account_path)
//  2. $GOOGLE_APPLICATION_CREDENTIALS
//  3. gcloud's application_default_credentials.json
//  4. the GCE/Cloud Run metadata server (no file at all)
//
// A path that exists but fails to parse is a hard error: silently falling
// through to the next source would make a typo'd key look like "no credentials"
// and send the operator hunting in the wrong place.
func resolveCredentials(explicitPath string) (*credentials, error) {
	type candidate struct{ path, label string }
	var candidates []candidate

	if explicitPath != "" {
		candidates = append(candidates, candidate{explicitPath, explicitPath})
	}
	if p := os.Getenv("GOOGLE_APPLICATION_CREDENTIALS"); p != "" {
		candidates = append(candidates, candidate{p, p + " (GOOGLE_APPLICATION_CREDENTIALS)"})
	}
	if p := adcFilePath(); p != "" {
		candidates = append(candidates, candidate{p, p + " (gcloud)"})
	}

	for _, c := range candidates {
		b, err := os.ReadFile(c.path)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return nil, err
		}
		return parseCredentials(b, c.label)
	}

	if creds := metadataCredentials(); creds != nil {
		return creds, nil
	}
	return nil, ErrNoCredentials
}

// metadataCredentials detects an attached instance identity (GCE, Cloud Run,
// GKE). On that path there is no key material anywhere — the platform mints
// tokens for the instance — which is the strongest form of the property this
// whole file is about, and it is what a hosted relay would run on.
func metadataCredentials() *credentials {
	host := os.Getenv("GCE_METADATA_HOST")
	if host == "" {
		host = metadataHost
	}
	ctx, cancel := context.WithTimeout(context.Background(), metadataProbe)
	defer cancel()

	project, err := metadataGet(ctx, host, "project/project-id")
	if err != nil {
		return nil
	}
	return &credentials{
		kind:      kindMetadata,
		source:    "GCE metadata server (attached instance identity)",
		projectID: project,
		tokenURI:  "http://" + host + "/computeMetadata/v1/instance/service-accounts/default/token",
	}
}

func metadataGet(ctx context.Context, host, path string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", "http://"+host+"/computeMetadata/v1/"+path, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("Metadata-Flavor", "Google")
	resp, err := httpClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}
	if resp.StatusCode/100 != 2 {
		return "", fmt.Errorf("metadata %s: %d", path, resp.StatusCode)
	}
	return strings.TrimSpace(string(b)), nil
}

// mintToken exchanges the credential for a fresh access token. Each shape uses
// a different grant; see the package comment at the top of this file.
func (c *credentials) mintToken() (token string, expiresIn time.Duration, err error) {
	switch c.kind {
	case kindServiceAccount:
		return c.mintFromJWT()
	case kindAuthorizedUser:
		return c.mintFromRefreshToken()
	case kindMetadata:
		return c.mintFromMetadata()
	default:
		return "", 0, fmt.Errorf("unknown credential type %q", c.kind)
	}
}

// mintFromJWT is the jwt-bearer grant: sign our own assertion with the service
// account's private key and trade it for an access token.
func (c *credentials) mintFromJWT() (string, time.Duration, error) {
	now := time.Now()
	header := b64url([]byte(`{"alg":"RS256","typ":"JWT"}`))
	claims, _ := json.Marshal(map[string]any{
		"iss":   c.clientEmail,
		"scope": Scope,
		"aud":   c.tokenURI,
		"iat":   now.Unix(),
		"exp":   now.Add(time.Hour).Unix(),
	})
	signingInput := header + "." + b64url(claims)
	digest := sha256.Sum256([]byte(signingInput))
	sig, err := rsa.SignPKCS1v15(rand.Reader, c.key, crypto.SHA256, digest[:])
	if err != nil {
		return "", 0, fmt.Errorf("sign jwt: %w", err)
	}

	return postTokenForm(c.tokenURI, url.Values{
		"grant_type": {"urn:ietf:params:oauth:grant-type:jwt-bearer"},
		"assertion":  {signingInput + "." + b64url(sig)},
	})
}

// mintFromRefreshToken is the refresh_token grant used by gcloud user
// credentials. Note the absence of a "scope" parameter: the scopes were bound
// when the user consented at login and cannot be widened here.
func (c *credentials) mintFromRefreshToken() (string, time.Duration, error) {
	return postTokenForm(c.tokenURI, url.Values{
		"grant_type":    {"refresh_token"},
		"client_id":     {c.clientID},
		"client_secret": {c.clientSecret},
		"refresh_token": {c.refreshToken},
	})
}

// mintFromMetadata asks the platform for a token minted for the attached
// identity. No grant, no key — just an authenticated-by-position GET.
func (c *credentials) mintFromMetadata() (string, time.Duration, error) {
	req, err := http.NewRequest("GET", c.tokenURI+"?scopes="+url.QueryEscape(Scope), nil)
	if err != nil {
		return "", 0, err
	}
	req.Header.Set("Metadata-Flavor", "Google")
	resp, err := httpClient.Do(req)
	if err != nil {
		return "", 0, fmt.Errorf("metadata token: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode/100 != 2 {
		return "", 0, fmt.Errorf("metadata token %d: %s", resp.StatusCode, body)
	}
	return parseTokenResponse(body)
}

func postTokenForm(tokenURI string, form url.Values) (string, time.Duration, error) {
	resp, err := httpClient.PostForm(tokenURI, form)
	if err != nil {
		return "", 0, fmt.Errorf("token request: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode/100 != 2 {
		return "", 0, fmt.Errorf("token endpoint %d: %s", resp.StatusCode, body)
	}
	return parseTokenResponse(body)
}

func parseTokenResponse(body []byte) (string, time.Duration, error) {
	var tok struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if err := json.Unmarshal(body, &tok); err != nil || tok.AccessToken == "" {
		return "", 0, fmt.Errorf("bad token response: %s", body)
	}
	return tok.AccessToken, time.Duration(tok.ExpiresIn) * time.Second, nil
}

// tokeninfoURL is where an opaque access token is exchanged for what it says
// about itself. Overridable so tests need no network.
var tokeninfoURL = "https://oauth2.googleapis.com/tokeninfo"

// identity best-effort names who these credentials authenticate as. For a
// service account the file already says. For a user credential it takes a round
// trip, and it only answers if the email scope was granted — so an empty result
// is normal and must never be treated as a failure.
func (c *credentials) identity(accessToken string) string {
	if c.kind == kindServiceAccount {
		return c.clientEmail
	}
	resp, err := httpClient.Get(tokeninfoURL + "?access_token=" + url.QueryEscape(accessToken))
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return ""
	}
	var info struct {
		Email string `json:"email"`
	}
	body, _ := io.ReadAll(resp.Body)
	if json.Unmarshal(body, &info) != nil {
		return ""
	}
	return info.Email
}
