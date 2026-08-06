package browse

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// realPath is EvalSymlinks with the test failing rather than the caller
// silently comparing against an unresolved path. It matters on macOS, where
// t.TempDir() hands back /var/... but the kernel walks /private/var/...: a test
// that skipped this would compare resolved output against unresolved
// expectations and fail for the wrong reason.
func realPath(t *testing.T, p string) string {
	t.Helper()
	r, err := filepath.EvalSymlinks(p)
	if err != nil {
		t.Fatalf("EvalSymlinks(%q): %v", p, err)
	}
	return r
}

// sandbox lays out a root with a couple of directories plus an "outside"
// sibling that nothing inside the root may reach.
//
//	<tmp>/root/projects/{alpha,beta}
//	<tmp>/root/projects/alpha/.git      (so alpha reads as a repo)
//	<tmp>/outside/secret
func sandbox(t *testing.T) (root, outside string) {
	t.Helper()
	base := realPath(t, t.TempDir())
	root = filepath.Join(base, "root")
	outside = filepath.Join(base, "outside")
	for _, d := range []string{
		filepath.Join(root, "projects", "alpha", ".git"),
		filepath.Join(root, "projects", "beta"),
		filepath.Join(outside, "secret"),
	} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return root, outside
}

// raw joins path elements WITHOUT cleaning them, which filepath.Join would do.
// The traversal tests need the ".." to still be in the string when Resolve sees
// it — that is what arrives in a `?path=` query — and a Join-built path has
// already had it collapsed lexically, which is the very thing under test.
func raw(parts ...string) string { return strings.Join(parts, string(filepath.Separator)) }

func rootsAt(paths ...string) Roots {
	rs := make(Roots, 0, len(paths))
	for _, p := range paths {
		rs = append(rs, Root{Path: p, Label: filepath.Base(p), Kind: "project"})
	}
	return rs
}

// ---- containment ----

func TestContainsIsSeparatorTerminated(t *testing.T) {
	cases := []struct {
		root, p string
		want    bool
	}{
		{"/srv/app", "/srv/app", true},
		{"/srv/app", "/srv/app/sub", true},
		{"/srv/app", "/srv/appdata", false}, // the bare-prefix bug
		{"/srv/app", "/srv/appdata/x", false},
		{"/srv/app", "/srv", false},
		{"/srv/app", "/", false},
		{"/srv/app/", "/srv/app/sub", true}, // a root with a trailing separator
		{"/", "/anything", true},
	}
	for _, c := range cases {
		if got := Contains(c.root, c.p); got != c.want {
			t.Errorf("Contains(%q, %q) = %v, want %v", c.root, c.p, got, c.want)
		}
	}
}

// ---- traversal ----

func TestResolveRejectsTraversalAboveRoot(t *testing.T) {
	root, outside := sandbox(t)
	rs := rootsAt(root)

	// Every one of these names a real directory outside the root, with the ".."
	// left in the string exactly as a `?path=` query would carry it.
	for _, p := range []string{
		raw(root, ".."),
		raw(root, "..", "outside"),
		raw(root, "projects", "..", "..", "outside", "secret"),
		raw(root, "projects", "alpha", "..", "..", "..", "outside"),
		raw(root, "projects", ".", "..", "..", "outside"),
		outside,
		filepath.Join(outside, "secret"),
	} {
		if got, err := rs.Resolve(p); !errors.Is(err, ErrOutsideRoots) {
			t.Errorf("Resolve(%q) = (%q, %v), want ErrOutsideRoots", p, got, err)
		}
	}
}

func TestResolveAllowsTraversalThatLandsBackInside(t *testing.T) {
	root, _ := sandbox(t)
	rs := rootsAt(root)

	// ".." is not banned, it is *resolved*: these all end up inside the root.
	cases := map[string]string{
		root:                          root,
		raw(root, "projects"):         filepath.Join(root, "projects"),
		raw(root, "projects", ".."):   root,
		raw(root, "projects", "", ""): filepath.Join(root, "projects"),
		raw(root, "projects", "alpha", "..", "beta"): filepath.Join(root, "projects", "beta"),
	}
	for in, want := range cases {
		got, err := rs.Resolve(in)
		if err != nil {
			t.Errorf("Resolve(%q): %v", in, err)
			continue
		}
		if got != want {
			t.Errorf("Resolve(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestResolveFollowsSymlinkOutOfRootAndRejects(t *testing.T) {
	root, outside := sandbox(t)
	rs := rootsAt(root)

	link := filepath.Join(root, "escape")
	if err := os.Symlink(outside, link); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}

	// The link itself, and anything under it, resolve outside the root.
	for _, p := range []string{link, raw(link, "secret")} {
		if got, err := rs.Resolve(p); !errors.Is(err, ErrOutsideRoots) {
			t.Errorf("Resolve(%q) = (%q, %v), want ErrOutsideRoots", p, got, err)
		}
	}
}

// The case a lexical Clean gets wrong: ".." AFTER a symlink pops the link's
// TARGET, not the link's own directory. `<root>/link/..` is `<outside>`, even
// though Clean says `<root>`.
func TestResolveHandlesDotDotAfterSymlink(t *testing.T) {
	root, outside := sandbox(t)
	rs := rootsAt(root)

	link := filepath.Join(root, "to-secret")
	if err := os.Symlink(filepath.Join(outside, "secret"), link); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	p := raw(link, "..")
	if filepath.Clean(p) != root {
		t.Fatalf("precondition: Clean(%q) = %q, want %q", p, filepath.Clean(p), root)
	}
	if got, err := rs.Resolve(p); !errors.Is(err, ErrOutsideRoots) {
		t.Errorf("Resolve(%q) = (%q, %v), want ErrOutsideRoots — Clean() says it is inside the root, the kernel disagrees", p, got, err)
	}
}

func TestResolveRejectsRelativePaths(t *testing.T) {
	root, _ := sandbox(t)
	rs := rootsAt(root)
	for _, p := range []string{"", ".", "..", "projects", "../outside", "~/projects"} {
		if _, err := rs.Resolve(p); !errors.Is(err, ErrNotAbsolute) {
			t.Errorf("Resolve(%q) err = %v, want ErrNotAbsolute", p, err)
		}
	}
}

// A missing path is only ever reported as missing when it is nominally inside a
// root. Outside, the answer is "not allowed" — otherwise this endpoint answers
// "does /etc/shadow exist" for anyone holding a bearer.
func TestResolveDoesNotLeakExistenceOutsideRoots(t *testing.T) {
	root, outside := sandbox(t)
	rs := rootsAt(root)

	if _, err := rs.Resolve(filepath.Join(root, "nope")); !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("missing path inside root: err = %v, want fs.ErrNotExist", err)
	}
	for _, p := range []string{
		filepath.Join(outside, "nope"),
		filepath.Join(outside, "secret"), // exists, but outside
		"/definitely/not/here",
	} {
		if err := errFrom(rs.Resolve(p)); !errors.Is(err, ErrOutsideRoots) {
			t.Errorf("Resolve(%q) err = %v, want ErrOutsideRoots", p, err)
		}
	}
}

func errFrom(_ string, err error) error { return err }

func TestResolveAcrossSeveralRoots(t *testing.T) {
	root, outside := sandbox(t)
	rs := rootsAt(root, outside)
	for _, p := range []string{root, filepath.Join(outside, "secret")} {
		if _, err := rs.Resolve(p); err != nil {
			t.Errorf("Resolve(%q): %v", p, err)
		}
	}
	if _, err := rs.Resolve(filepath.Dir(root)); !errors.Is(err, ErrOutsideRoots) {
		t.Error("the shared parent of two roots must not itself be browsable")
	}
}

// ---- listing ----

func TestListIsDirectoriesOnlyAndHidesDotDirs(t *testing.T) {
	root, _ := sandbox(t)
	if err := os.WriteFile(filepath.Join(root, "projects", "notes.txt"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "projects", ".hidden"), 0o755); err != nil {
		t.Fatal(err)
	}
	rs := rootsAt(root)

	got, err := rs.List(filepath.Join(root, "projects"), false, nil)
	if err != nil {
		t.Fatal(err)
	}
	if names := entryNames(got); len(names) != 2 || names[0] != "alpha" || names[1] != "beta" {
		t.Fatalf("entries = %v, want [alpha beta]", names)
	}
	if !got.Entries[0].IsRepo || got.Entries[1].IsRepo {
		t.Errorf("is_repo = (%v, %v), want (true, false)", got.Entries[0].IsRepo, got.Entries[1].IsRepo)
	}

	withHidden, err := rs.List(filepath.Join(root, "projects"), true, nil)
	if err != nil {
		t.Fatal(err)
	}
	if names := entryNames(withHidden); len(names) != 3 || names[0] != ".hidden" {
		t.Fatalf("entries with hidden = %v, want [.hidden alpha beta]", names)
	}
}

func TestListSkipsSymlinksPointingOutOfRoots(t *testing.T) {
	root, outside := sandbox(t)
	projects := filepath.Join(root, "projects")
	if err := os.Symlink(outside, filepath.Join(projects, "escape")); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	if err := os.Symlink(filepath.Join(projects, "beta"), filepath.Join(projects, "beta-link")); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	rs := rootsAt(root)

	got, err := rs.List(projects, false, nil)
	if err != nil {
		t.Fatal(err)
	}
	names := entryNames(got)
	if len(names) != 3 || names[0] != "alpha" || names[1] != "beta" || names[2] != "beta-link" {
		t.Fatalf("entries = %v, want [alpha beta beta-link] — the outward link must be dropped", names)
	}
	for _, e := range got.Entries {
		if e.Name == "beta-link" && !e.IsSymlink {
			t.Error("an inward link should still be marked is_symlink")
		}
	}
}

func TestListRejectsAPathOutsideTheRoots(t *testing.T) {
	root, outside := sandbox(t)
	rs := rootsAt(root)
	if _, err := rs.List(raw(root, "..", "outside"), false, nil); !errors.Is(err, ErrOutsideRoots) {
		t.Errorf("err = %v, want ErrOutsideRoots", err)
	}
	if _, err := rs.List(outside, false, nil); !errors.Is(err, ErrOutsideRoots) {
		t.Errorf("err = %v, want ErrOutsideRoots", err)
	}
}

func TestListParentStopsAtTheRoot(t *testing.T) {
	root, _ := sandbox(t)
	rs := rootsAt(root)

	atRoot, err := rs.List(root, false, nil)
	if err != nil {
		t.Fatal(err)
	}
	if atRoot.Parent != "" {
		t.Errorf("parent at the root = %q, want \"\" (no way up)", atRoot.Parent)
	}
	inside, err := rs.List(filepath.Join(root, "projects"), false, nil)
	if err != nil {
		t.Fatal(err)
	}
	if inside.Parent != root {
		t.Errorf("parent = %q, want %q", inside.Parent, root)
	}
}

func TestListDefaultsToTheFirstRootAndRefusesAFile(t *testing.T) {
	root, _ := sandbox(t)
	rs := rootsAt(root)

	got, err := rs.List("", false, nil)
	if err != nil {
		t.Fatal(err)
	}
	if got.Path != root {
		t.Errorf("path = %q, want the first root %q", got.Path, root)
	}

	file := filepath.Join(root, "projects", "notes.txt")
	if err := os.WriteFile(file, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := rs.List(file, false, nil); !errors.Is(err, ErrNotDirectory) {
		t.Errorf("listing a file: err = %v, want ErrNotDirectory", err)
	}

	if _, err := (Roots{}).List(root, false, nil); !errors.Is(err, ErrNoRoots) {
		t.Errorf("empty roots: err = %v, want ErrNoRoots", err)
	}
}

func TestListCapsAndReportsTruncation(t *testing.T) {
	base := realPath(t, t.TempDir())
	big := filepath.Join(base, "big")
	for i := range MaxEntries + 5 {
		if err := os.MkdirAll(filepath.Join(big, "d"+pad(i)), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	rs := rootsAt(base)

	got, err := rs.List(big, false, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Entries) != MaxEntries || !got.Truncated {
		t.Fatalf("entries = %d, truncated = %v; want %d and true", len(got.Entries), got.Truncated, MaxEntries)
	}
	if got.Limit != MaxEntries {
		t.Errorf("limit = %d, want %d", got.Limit, MaxEntries)
	}

	// Exactly at the cap is NOT truncated — the flag must mean "there is more",
	// not "you hit the number".
	exact := filepath.Join(base, "exact")
	for i := range MaxEntries {
		if err := os.MkdirAll(filepath.Join(exact, "d"+pad(i)), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	got, err = rs.List(exact, false, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Entries) != MaxEntries || got.Truncated {
		t.Fatalf("entries = %d, truncated = %v; want %d and false", len(got.Entries), got.Truncated, MaxEntries)
	}
}

func TestListMarksAlreadyOpenSpaces(t *testing.T) {
	root, _ := sandbox(t)
	alpha := filepath.Join(root, "projects", "alpha")
	rs := rootsAt(root)

	openBy := map[string]string{alpha: "acme/w3"}
	got, err := rs.List(filepath.Join(root, "projects"), false, openBy)
	if err != nil {
		t.Fatal(err)
	}
	if got.Entries[0].OpenWorkspaceID != "acme/w3" {
		t.Errorf("open_workspace_id = %q, want %q", got.Entries[0].OpenWorkspaceID, "acme/w3")
	}
	if got.Entries[1].OpenWorkspaceID != "" {
		t.Errorf("beta should not be marked open, got %q", got.Entries[1].OpenWorkspaceID)
	}

	// The same two facts about the directory being listed, so "open here" and
	// "open that one" can't disagree about the same tree.
	inside, err := rs.List(alpha, false, openBy)
	if err != nil {
		t.Fatal(err)
	}
	if !inside.IsRepo || inside.OpenWorkspaceID != "acme/w3" {
		t.Errorf("listing alpha itself: is_repo = %v, open = %q; want true, acme/w3",
			inside.IsRepo, inside.OpenWorkspaceID)
	}
	if got.IsRepo || got.OpenWorkspaceID != "" {
		t.Errorf("projects/ is neither a repo nor open, got %v / %q",
			got.IsRepo, got.OpenWorkspaceID)
	}
}

// ---- roots ----

func TestNewRootsUsesSpaceParentsAndCollapses(t *testing.T) {
	base := realPath(t, t.TempDir())
	home := filepath.Join(base, "home", "dev")
	inHome := filepath.Join(home, "projects", "gothalo")
	elsewhere := filepath.Join(base, "srv", "code", "api")
	for _, d := range []string{home, inHome, elsewhere} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}

	rs := NewRoots(home, []string{inHome, elsewhere})
	if len(rs) != 2 {
		t.Fatalf("roots = %v, want home + the out-of-home project parent", rs)
	}
	if rs[0].Path != home || rs[0].Kind != "home" {
		t.Errorf("first root = %+v, want home %q", rs[0], home)
	}
	// ~/projects/gothalo's parent is inside home, so it collapses away.
	if rs[1].Path != filepath.Join(base, "srv", "code") {
		t.Errorf("second root = %q, want %q", rs[1].Path, filepath.Join(base, "srv", "code"))
	}
	if !rs.Allows(inHome) || !rs.Allows(elsewhere) {
		t.Error("both open spaces must be reachable from the roots they produced")
	}
	if rs.Allows(base) {
		t.Errorf("%q is above every root and must not be allowed", base)
	}
}

// A space sitting directly in the home directory would contribute home's own
// parent — /Users, i.e. every account on the machine. It must not.
func TestNewRootsDropsAncestorsOfHome(t *testing.T) {
	base := realPath(t, t.TempDir())
	home := filepath.Join(base, "home", "dev")
	spaceInHome := filepath.Join(home, "notes")
	for _, d := range []string{home, spaceInHome} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}

	rs := NewRoots(home, []string{spaceInHome})
	if len(rs) != 1 || rs[0].Path != home {
		t.Fatalf("roots = %v, want just home %q", rs, home)
	}
	if rs.Allows(filepath.Dir(home)) {
		t.Error("home's parent must not be browsable")
	}
}

func TestNewRootsSkipsUnresolvableAndFilesystemRoot(t *testing.T) {
	base := realPath(t, t.TempDir())
	home := filepath.Join(base, "home")
	if err := os.MkdirAll(home, 0o755); err != nil {
		t.Fatal(err)
	}

	rs := NewRoots(home, []string{filepath.Join(base, "gone"), "/", "relative/path"})
	if len(rs) != 1 || rs[0].Path != home {
		t.Fatalf("roots = %v, want just home %q", rs, home)
	}

	// No home either: nothing to browse, and List says so rather than guessing.
	if got := NewRoots("", []string{"/"}); len(got) != 0 {
		t.Fatalf("roots = %v, want none", got)
	}
}

func entryNames(l Listing) []string {
	names := make([]string, 0, len(l.Entries))
	for _, e := range l.Entries {
		names = append(names, e.Name)
	}
	return names
}

// pad keeps the generated directory names sortable so the cap test's ordering
// is stable regardless of how ReadDir orders them.
func pad(i int) string {
	s := "0000" + itoa(i)
	return s[len(s)-4:]
}

func itoa(i int) string {
	if i == 0 {
		return "0"
	}
	var b []byte
	for i > 0 {
		b = append([]byte{byte('0' + i%10)}, b...)
		i /= 10
	}
	return string(b)
}
