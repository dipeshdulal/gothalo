package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"
)

// daemonClient talks to a locally running `gothalo serve` over its admin API.
type daemonClient struct {
	base  string
	token string
}

func newDaemonClient(addr, token string) *daemonClient {
	return &daemonClient{base: "http://" + addr, token: token}
}

// do issues an admin request and decodes a JSON response into out (may be nil).
func (c *daemonClient) do(method, path string, reqBody, out any) error {
	var r io.Reader
	if reqBody != nil {
		b, _ := json.Marshal(reqBody)
		r = bytes.NewReader(b)
	}
	u := c.base + path + "?token=" + url.QueryEscape(c.token)
	req, err := http.NewRequest(method, u, r)
	if err != nil {
		return err
	}
	if reqBody != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	req.Header.Set("Authorization", "Bearer "+c.token)

	resp, err := (&http.Client{Timeout: 10 * time.Second}).Do(req)
	if err != nil {
		return fmt.Errorf("cannot reach the daemon at %s — is `gothalo serve` running? (%w)", c.base, err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("daemon returned %d: %s", resp.StatusCode, bytes.TrimSpace(body))
	}
	if out != nil {
		return json.Unmarshal(body, out)
	}
	return nil
}
