package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"testing"

	"github.com/dipeshdulal/gothalo/internal/browse"
	"github.com/dipeshdulal/gothalo/internal/config"
	"github.com/dipeshdulal/gothalo/internal/herdr"
	"github.com/dipeshdulal/gothalo/internal/store"
)

// fakeSpaces stands in for the session Manager so the roots the handler builds
// are the test's own directories rather than whatever the machine running the
// tests happens to have open in Herdr.
type fakeSpaces []herdr.OpenSpace

func (f fakeSpaces) OpenSpaces() []herdr.OpenSpace { return f }

// browseFixture lays out a home directory with one open space in it and a
// second tree that nothing points at:
//
//	<tmp>/home/projects/gothalo   (open as workspace wN)
//	<tmp>/home/projects/other
//	<tmp>/elsewhere/private
//
// HOME is pointed at <tmp>/home for the duration of the test, since that is
// where the handler's first root comes from.
func browseFixture(t *testing.T) (home, elsewhere string) {
	t.Helper()
	base, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	home = filepath.Join(base, "home")
	elsewhere = filepath.Join(base, "elsewhere")
	for _, d := range []string{
		filepath.Join(home, "projects", "gothalo", ".git"),
		filepath.Join(home, "projects", "other"),
		filepath.Join(elsewhere, "private"),
	} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("HOME", home)
	return home, elsewhere
}

func newBrowseServer(t *testing.T, spaces spaceLister) *Server {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "devices.json"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	return &Server{
		cfg:    &config.Config{AdminToken: "admintok"},
		store:  st,
		spaces: spaces,
	}
}

func browseRequest(t *testing.T, srv *Server, bearer, path string, hidden bool) *httptest.ResponseRecorder {
	t.Helper()
	q := url.Values{}
	if path != "" {
		q.Set("path", path)
	}
	if hidden {
		q.Set("hidden", "1")
	}
	req := httptest.NewRequest(http.MethodGet, "/browse?"+q.Encode(), nil)
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	rec := httptest.NewRecorder()
	srv.handleBrowse(rec, req)
	return rec
}

func decodeListing(t *testing.T, rec *httptest.ResponseRecorder) browse.Listing {
	t.Helper()
	var l browse.Listing
	if err := json.Unmarshal(rec.Body.Bytes(), &l); err != nil {
		t.Fatalf("decode listing: %v (body: %s)", err, rec.Body.String())
	}
	return l
}

func TestBrowseRequiresAuth(t *testing.T) {
	browseFixture(t)
	srv := newBrowseServer(t, fakeSpaces{})
	if rec := browseRequest(t, srv, "", "", false); rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", rec.Code)
	}
	if rec := browseRequest(t, srv, "wrong", "", false); rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", rec.Code)
	}
}

// The empty-session case the whole feature exists for: no open spaces at all,
// and the phone still gets somewhere to start from.
func TestBrowseDefaultsToHomeWithNoSpacesOpen(t *testing.T) {
	home, _ := browseFixture(t)
	srv := newBrowseServer(t, fakeSpaces{})

	rec := browseRequest(t, srv, "admintok", "", false)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}
	got := decodeListing(t, rec)
	if got.Path != home {
		t.Errorf("path = %q, want home %q", got.Path, home)
	}
	if got.Parent != "" {
		t.Errorf("parent = %q, want \"\" — home is a root", got.Parent)
	}
	if len(got.Roots) != 1 || got.Roots[0].Kind != "home" {
		t.Fatalf("roots = %+v, want just home", got.Roots)
	}
	if len(got.Entries) != 1 || got.Entries[0].Name != "projects" {
		t.Fatalf("entries = %+v, want [projects]", got.Entries)
	}
}

func TestBrowseListsDirectoriesAndMarksOpenSpaces(t *testing.T) {
	home, _ := browseFixture(t)
	gothalo := filepath.Join(home, "projects", "gothalo")
	srv := newBrowseServer(t, fakeSpaces{{WorkspaceID: "wN", Dir: gothalo, RepoRoot: gothalo}})

	rec := browseRequest(t, srv, "admintok", filepath.Join(home, "projects"), false)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}
	got := decodeListing(t, rec)
	if len(got.Entries) != 2 {
		t.Fatalf("entries = %+v, want gothalo + other", got.Entries)
	}
	if got.Entries[0].Name != "gothalo" || !got.Entries[0].IsRepo {
		t.Errorf("first entry = %+v, want gothalo marked as a repo", got.Entries[0])
	}
	if got.Entries[0].OpenWorkspaceID != "wN" {
		t.Errorf("open_workspace_id = %q, want wN", got.Entries[0].OpenWorkspaceID)
	}
	if got.Entries[1].OpenWorkspaceID != "" {
		t.Errorf("other is not open, got %q", got.Entries[1].OpenWorkspaceID)
	}
	if got.Parent != home {
		t.Errorf("parent = %q, want %q", got.Parent, home)
	}
	if got.Limit != browse.MaxEntries || got.Truncated {
		t.Errorf("limit/truncated = %d/%v, want %d/false", got.Limit, got.Truncated, browse.MaxEntries)
	}
}

// An open space outside home widens the roots by exactly its parent — and by
// nothing more. This is the rule that decides how much of the host the phone
// can see, so it is asserted from the handler, not just the package.
func TestBrowseRootsFollowOpenSpacesOutsideHome(t *testing.T) {
	home, elsewhere := browseFixture(t)
	private := filepath.Join(elsewhere, "private")
	srv := newBrowseServer(t, fakeSpaces{{WorkspaceID: "acme/w3", Dir: private}})

	rec := browseRequest(t, srv, "admintok", "", false)
	got := decodeListing(t, rec)
	if len(got.Roots) != 2 {
		t.Fatalf("roots = %+v, want home + the out-of-home space's parent", got.Roots)
	}
	if got.Roots[0].Path != home || got.Roots[1].Path != elsewhere {
		t.Fatalf("roots = %+v, want [%q %q]", got.Roots, home, elsewhere)
	}
	// The new root is browsable...
	if rec := browseRequest(t, srv, "admintok", elsewhere, false); rec.Code != http.StatusOK {
		t.Errorf("listing the new root: status = %d, want 200 (%s)", rec.Code, rec.Body.String())
	}
	// ...and its parent, which is the shared tmp dir, still is not.
	if rec := browseRequest(t, srv, "admintok", filepath.Dir(elsewhere), false); rec.Code != http.StatusForbidden {
		t.Errorf("listing above the new root: status = %d, want 403", rec.Code)
	}
}

func TestBrowseRejectsTraversalAndRelativePaths(t *testing.T) {
	home, elsewhere := browseFixture(t)
	srv := newBrowseServer(t, fakeSpaces{})

	// ".." spelled out, as it would arrive in a query string.
	for _, p := range []string{
		home + "/..",
		home + "/projects/../../elsewhere/private",
		elsewhere,
		"/etc",
	} {
		if rec := browseRequest(t, srv, "admintok", p, false); rec.Code != http.StatusForbidden {
			t.Errorf("path=%q: status = %d, want 403", p, rec.Code)
		}
	}
	for _, p := range []string{".", "..", "projects", "~/projects"} {
		if rec := browseRequest(t, srv, "admintok", p, false); rec.Code != http.StatusBadRequest {
			t.Errorf("path=%q: status = %d, want 400", p, rec.Code)
		}
	}
}

// Missing-and-outside must look exactly like present-and-outside, or the
// endpoint becomes a probe for what exists on the host.
func TestBrowseDoesNotDistinguishMissingFromForbidden(t *testing.T) {
	home, elsewhere := browseFixture(t)
	srv := newBrowseServer(t, fakeSpaces{})

	outsideMissing := browseRequest(t, srv, "admintok", filepath.Join(elsewhere, "nope"), false)
	outsidePresent := browseRequest(t, srv, "admintok", filepath.Join(elsewhere, "private"), false)
	if outsideMissing.Code != http.StatusForbidden || outsidePresent.Code != http.StatusForbidden {
		t.Fatalf("statuses = %d / %d, want 403 / 403", outsideMissing.Code, outsidePresent.Code)
	}
	if outsideMissing.Body.String() != outsidePresent.Body.String() {
		t.Errorf("bodies differ (%q vs %q) — that difference IS the disclosure",
			outsideMissing.Body.String(), outsidePresent.Body.String())
	}
	// Inside the roots, missing is allowed to say so.
	if rec := browseRequest(t, srv, "admintok", filepath.Join(home, "nope"), false); rec.Code != http.StatusNotFound {
		t.Errorf("missing path inside home: status = %d, want 404", rec.Code)
	}
}

func TestBrowseRefusesAFileAndNonGET(t *testing.T) {
	home, _ := browseFixture(t)
	file := filepath.Join(home, "projects", "notes.txt")
	if err := os.WriteFile(file, []byte("secret"), 0o600); err != nil {
		t.Fatal(err)
	}
	srv := newBrowseServer(t, fakeSpaces{})

	rec := browseRequest(t, srv, "admintok", file, false)
	if rec.Code != http.StatusNotFound {
		t.Errorf("status = %d, want 404 — a file is not browsable", rec.Code)
	}
	// And the listing of its directory never mentions it.
	got := decodeListing(t, browseRequest(t, srv, "admintok", filepath.Join(home, "projects"), false))
	for _, e := range got.Entries {
		if e.Name == "notes.txt" {
			t.Fatal("a file leaked into the listing")
		}
	}

	req := httptest.NewRequest(http.MethodPost, "/browse", nil)
	req.Header.Set("Authorization", "Bearer admintok")
	post := httptest.NewRecorder()
	srv.handleBrowse(post, req)
	if post.Code != http.StatusMethodNotAllowed {
		t.Errorf("POST status = %d, want 405", post.Code)
	}
}

func TestBrowseHidesDotDirectoriesUnlessAsked(t *testing.T) {
	home, _ := browseFixture(t)
	if err := os.MkdirAll(filepath.Join(home, ".config"), 0o755); err != nil {
		t.Fatal(err)
	}
	srv := newBrowseServer(t, fakeSpaces{})

	plain := decodeListing(t, browseRequest(t, srv, "admintok", home, false))
	if len(plain.Entries) != 1 || plain.Entries[0].Name != "projects" {
		t.Fatalf("entries = %+v, want [projects]", plain.Entries)
	}
	hidden := decodeListing(t, browseRequest(t, srv, "admintok", home, true))
	if len(hidden.Entries) != 2 || hidden.Entries[0].Name != ".config" {
		t.Fatalf("entries with hidden=1 = %+v, want [.config projects]", hidden.Entries)
	}
}
