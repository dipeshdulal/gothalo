// Minimal FCM v1 sender using only the Go stdlib (no firebase-admin dependency).
//
// Flow: read the service-account JSON -> build & RS256-sign a JWT ->
// exchange it for an OAuth access token -> POST to the FCM messages:send API.
// Access tokens are cached until ~1 min before expiry.
package main

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
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sync"
	"time"
)

const fcmScope = "https://www.googleapis.com/auth/firebase.messaging"

type serviceAccount struct {
	ClientEmail string `json:"client_email"`
	PrivateKey  string `json:"private_key"`
	TokenURI    string `json:"token_uri"`
	ProjectID   string `json:"project_id"`
}

type fcmClient struct {
	sa  serviceAccount
	key *rsa.PrivateKey

	mu       sync.Mutex
	token    string
	tokenExp time.Time
}

func b64url(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

// loadServiceAccount parses the downloaded Firebase service-account JSON and its
// RSA private key. Returns an error (not a nil client) so callers can log-and-disable.
func loadServiceAccount(jsonBytes []byte) (*fcmClient, error) {
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
	return &fcmClient{sa: sa, key: key}, nil
}

// accessToken returns a cached OAuth token or mints a fresh one via the JWT-bearer grant.
func (c *fcmClient) accessToken() (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.token != "" && time.Now().Before(c.tokenExp.Add(-60*time.Second)) {
		return c.token, nil
	}

	now := time.Now()
	header := b64url([]byte(`{"alg":"RS256","typ":"JWT"}`))
	claims, _ := json.Marshal(map[string]any{
		"iss":   c.sa.ClientEmail,
		"scope": fcmScope,
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

// send delivers a notification to a single device/web token.
func (c *fcmClient) send(deviceToken, title, body string, data map[string]string) error {
	at, err := c.accessToken()
	if err != nil {
		return err
	}
	// Data-only message (no "notification" key): this guarantees the service
	// worker's onBackgroundMessage fires and renders the notification itself,
	// which is what makes it appear on a locked Android screen. title/body ride
	// in data{}. Urgency:high tells the push service to deliver immediately
	// rather than batching while the device is idle (Doze).
	full := map[string]string{"title": title, "body": body}
	for k, v := range data {
		full[k] = v
	}
	payload, _ := json.Marshal(map[string]any{
		"message": map[string]any{
			"token": deviceToken,
			"data":  full,
			"webpush": map[string]any{
				"headers": map[string]string{"Urgency": "high", "TTL": "3600"},
			},
		},
	})
	endpoint := "https://fcm.googleapis.com/v1/projects/" + c.sa.ProjectID + "/messages:send"
	req, _ := http.NewRequest("POST", endpoint, bytes.NewReader(payload))
	req.Header.Set("Authorization", "Bearer "+at)
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("fcm request: %w", err)
	}
	defer resp.Body.Close()
	rb, _ := io.ReadAll(resp.Body)
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("fcm %d: %s", resp.StatusCode, rb)
	}
	return nil
}
