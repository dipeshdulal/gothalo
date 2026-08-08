package ports

import (
	"context"
	"net"
	"net/http"
	"os"
	"os/exec"
	"testing"
	"time"
)

// TestCollectFindsARealServer is the end-to-end half the fixtures cannot cover:
// lsof's real output shape on this host, the probe, and the two filters that
// decide what reaches the app. It stands up an actual HTTP server plus a bare
// TCP listener that never speaks HTTP, and asserts the scan keeps the first and
// drops the second — the distinction the whole chip list rests on.
func TestCollectFindsARealServer(t *testing.T) {
	if _, err := exec.LookPath("lsof"); err != nil {
		t.Skip("lsof not available")
	}

	srv := &http.Server{Handler: http.NotFoundHandler()}
	httpLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer srv.Close()
	go srv.Serve(httpLn)
	httpPort := httpLn.Addr().(*net.TCPAddr).Port

	// A listener that accepts and says nothing — the stand-in for Postgres.
	muteLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer muteLn.Close()
	go func() {
		for {
			c, err := muteLn.Accept()
			if err != nil {
				return
			}
			// Hold it open past the probe deadline, then drop it: a socket that
			// accepts but never writes is exactly what the probe must reject.
			go func() { time.Sleep(2 * probeTimeout); c.Close() }()
		}
	}()
	mutePort := muteLn.Addr().(*net.TCPAddr).Port

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	found, err := Collect(ctx, map[int]PaneRef{})
	if err != nil {
		t.Fatalf("Collect: %v", err)
	}

	var gotHTTP, gotMute bool
	for _, l := range found {
		switch l.Port {
		case httpPort:
			gotHTTP = true
			if l.PID != os.Getpid() {
				t.Errorf("http listener pid = %d, want this process %d", l.PID, os.Getpid())
			}
			if !l.Loopback {
				t.Errorf("127.0.0.1 listener on :%d did not read as loopback", l.Port)
			}
		case mutePort:
			gotMute = true
		}
	}
	if !gotHTTP {
		t.Errorf("scan missed the HTTP server on :%d; found %+v", httpPort, found)
	}
	if gotMute {
		t.Errorf("scan kept the non-HTTP listener on :%d", mutePort)
	}
}
