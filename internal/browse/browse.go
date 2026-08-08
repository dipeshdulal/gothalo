// Package browse is the read-only, directories-only view of the host
// filesystem behind `GET /browse` — just enough for the phone to point at a
// directory and open it as a Herdr space.
//
// It is deliberately the narrowest thing that can do that job. A paired device
// gets to see *where* directories are, and nothing else: no file names, no file
// contents, no sizes, and nothing outside an explicit allowlist of [Roots].
// That is not because a paired device is untrusted — it already has `/send`,
// which types into a shell — but because "list me /etc" is a filesystem-layout
// disclosure that survives revoking the device, and there is no reason for this
// endpoint to be the thing that hands it over.
//
// The containment rule is the whole security story, so it is written once here
// and used by every path in and out:
//
//   - a requested path is resolved with [filepath.EvalSymlinks], which expands
//     symlinks AND ".." in the correct order, and is then re-checked against
//     the roots — resolution alone proves nothing;
//   - a path that fails to resolve is only reported as missing when it is
//     lexically inside a root, so a caller cannot probe for the existence of
//     paths it was never allowed to ask about;
//   - a directory entry that is a symlink is followed only if its target is
//     still inside the roots, so a link cannot be an escape hatch;
//   - containment is a separator-terminated prefix, so "/srv/appdata" is not
//     inside "/srv/app".
package browse

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// MaxEntries caps one listing. A home directory with thousands of folders is a
// scrolling problem on a phone, not a browsing one; past this the app should
// have the user narrow down rather than page. Truncation is reported, never
// silent.
const MaxEntries = 500

var (
	// ErrNotAbsolute is a relative or empty path — the endpoint only ever
	// speaks in absolute host paths, so a relative one has no meaning here.
	ErrNotAbsolute = errors.New("path must be absolute")
	// ErrOutsideRoots is a path that resolved outside every allowed root.
	ErrOutsideRoots = errors.New("path is outside the allowed roots")
	// ErrNotDirectory is a path that exists and is inside the roots, but is a
	// file. Files are never listed and never opened.
	ErrNotDirectory = errors.New("path is not a directory")
	// ErrNoRoots means the host offered nothing browsable (no home directory
	// and no open spaces) — a misconfiguration, not a bad request.
	ErrNoRoots = errors.New("no browsable roots")
)

// Root is one directory the phone is allowed to browse, and everything under
// it. Kind is "home" for the operator's home directory and "project" for the
// parent of a space that is already open — the two answers to "where do this
// person's projects live" that the bridge can derive without being told.
type Root struct {
	Path  string `json:"path"`
	Label string `json:"label"`
	Kind  string `json:"kind"`
}

// Entry is one directory inside a listing. There is no entry type for a file:
// files are filtered out before this struct exists.
type Entry struct {
	Name string `json:"name"`
	Path string `json:"path"`
	// IsRepo is whether the directory holds a `.git` (a directory for a normal
	// checkout, a file for a linked worktree). It is a stat, never a read — it
	// tells the app which Herdr method opens this directory (worktree.open for
	// a repo, workspace.create otherwise).
	IsRepo bool `json:"is_repo"`
	// IsSymlink marks an entry that is a link. It is only ever present when the
	// target resolved back inside the roots.
	IsSymlink bool `json:"is_symlink"`
	// OpenWorkspaceID is the Herdr workspace already open at this directory,
	// when there is one, so the app can offer "go there" instead of opening a
	// second space on the same tree. Session-qualified, like every id the
	// bridge hands out.
	OpenWorkspaceID string `json:"open_workspace_id,omitempty"`
}

// Listing is one directory's worth of browsable children, plus the navigation
// context the phone needs to move around without keeping its own model of the
// host's filesystem.
type Listing struct {
	Path string `json:"path"`
	// Parent is the directory above Path, or "" when Path is a root — which is
	// also how the app knows to stop offering "up".
	Parent string `json:"parent"`
	// IsRepo and OpenWorkspaceID describe Path ITSELF, on the same terms as an
	// [Entry]. They are what makes "open the directory I am standing in" answer
	// identically to "open that one in the list" — without them the app would
	// have to remember the entry it descended through, and would get it wrong
	// for a root.
	IsRepo          bool    `json:"is_repo"`
	OpenWorkspaceID string  `json:"open_workspace_id,omitempty"`
	Roots           []Root  `json:"roots"`
	Entries         []Entry `json:"entries"`
	Truncated       bool    `json:"truncated"`
	Limit           int     `json:"limit"`
}

// Roots is the allowlist: a browse request is legal exactly when its resolved
// path is one of these or lives under one.
type Roots []Root

// NewRoots builds the allowlist from the operator's home directory and the
// on-disk locations of the spaces Herdr already has open.
//
// An open space contributes its *parent*, not itself: the point of the flow is
// to open a sibling of something already open ("the other repo in ~/projects"),
// and a root at the space itself could only ever browse into it.
//
// Two rules keep that from quietly widening the boundary. A parent that is an
// ancestor of the home directory is dropped — a space sitting directly in `~`
// would otherwise contribute `/Users`, i.e. every account on the machine — and
// so is the filesystem root. Whatever survives is then collapsed, so a root
// already covered by another (almost everything, once home is in the list) does
// not appear twice.
//
// Paths that do not resolve are skipped rather than trusted: a root is only
// useful as a *resolved* prefix, since that is what every later check compares
// against.
func NewRoots(home string, spaceDirs []string) Roots {
	var rs Roots
	realHome := ""
	if home != "" {
		if r, err := filepath.EvalSymlinks(home); err == nil {
			realHome = r
			rs = append(rs, Root{Path: r, Label: "Home", Kind: "home"})
		}
	}
	for _, d := range spaceDirs {
		real, err := filepath.EvalSymlinks(d)
		if err != nil {
			continue
		}
		parent := filepath.Dir(real)
		if parent == real || parent == string(filepath.Separator) {
			continue // the filesystem root is never a browsing root
		}
		if realHome != "" && parent != realHome && Contains(parent, realHome) {
			continue // an ancestor of home ("/Users") is every account, not a project dir
		}
		rs = append(rs, Root{Path: parent, Label: filepath.Base(parent), Kind: "project"})
	}
	return collapse(rs)
}

// collapse drops roots that are covered by another root and orders the result
// home-first, then by path — the order the app renders them in.
func collapse(rs Roots) Roots {
	// Shortest path first, so a parent is always considered before its children
	// and therefore wins.
	sort.Slice(rs, func(i, j int) bool {
		if len(rs[i].Path) != len(rs[j].Path) {
			return len(rs[i].Path) < len(rs[j].Path)
		}
		return rs[i].Path < rs[j].Path
	})
	out := make(Roots, 0, len(rs))
	for _, r := range rs {
		covered := false
		for _, k := range out {
			if Contains(k.Path, r.Path) {
				covered = true
				break
			}
		}
		if !covered {
			out = append(out, r)
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		if (out[i].Kind == "home") != (out[j].Kind == "home") {
			return out[i].Kind == "home"
		}
		return out[i].Path < out[j].Path
	})
	return out
}

// Contains reports whether p is root itself or lives under it. The separator is
// what makes this a containment test rather than a string test: a bare
// strings.HasPrefix would put "/srv/appdata" inside "/srv/app".
func Contains(root, p string) bool {
	if root == p {
		return true
	}
	if !strings.HasSuffix(root, string(filepath.Separator)) {
		root += string(filepath.Separator)
	}
	return strings.HasPrefix(p, root)
}

// Allows reports whether an ALREADY-RESOLVED path is inside the roots. It is
// deliberately not exported as "check this user input" — callers go through
// [Roots.Resolve], which is the only thing that turns input into a path this
// may be asked about.
func (rs Roots) Allows(resolved string) bool {
	for _, r := range rs {
		if Contains(r.Path, resolved) {
			return true
		}
	}
	return false
}

// Resolve turns a requested path into a real one inside the roots, or an error.
//
// The resolution is [filepath.EvalSymlinks], not [filepath.Clean]: cleaning is
// lexical, so it would resolve ".." against the *link's* own path rather than
// its target, and "/root/link/../.." would be judged as "/root" while the
// kernel walks somewhere else entirely. EvalSymlinks expands links and ".." in
// the order the kernel does, and the result is re-checked against the roots —
// resolving is not a permission check.
//
// A path that fails to resolve gets its error decided by a lexical containment
// check on the cleaned form: only a path that is at least *nominally* inside a
// root is told it does not exist. Otherwise "does /etc/shadow exist" would be
// answerable by anyone holding a bearer, which is the disclosure this package
// exists to avoid.
func (rs Roots) Resolve(p string) (string, error) {
	real, err := Real(p)
	if err != nil {
		if errors.Is(err, ErrNotAbsolute) {
			return "", err
		}
		if !rs.Allows(filepath.Clean(p)) {
			return "", ErrOutsideRoots
		}
		return "", err
	}
	if !rs.Allows(real) {
		return "", ErrOutsideRoots
	}
	return real, nil
}

// Real is the resolution half of [Roots.Resolve] with no containment check: an
// absolute path with every symlink and ".." expanded. Callers that need the two
// halves apart — mapping a directory the bridge already trusts onto the string
// a listing will compare against — use this; callers handling client input
// must not.
func Real(p string) (string, error) {
	if !filepath.IsAbs(p) {
		return "", ErrNotAbsolute
	}
	return filepath.EvalSymlinks(p)
}

// List returns the directories inside path. An empty path means "start here" —
// the first root, which is home when the host has one.
//
// openBy maps a resolved directory to the Herdr workspace already open there;
// it may be nil. showHidden opts into dot-directories, which are excluded by
// default: they are configuration, not projects, and `~` is mostly noise
// without the filter.
func (rs Roots) List(path string, showHidden bool, openBy map[string]string) (Listing, error) {
	if len(rs) == 0 {
		return Listing{}, ErrNoRoots
	}
	if path == "" {
		path = rs[0].Path
	}
	real, err := rs.Resolve(path)
	if err != nil {
		return Listing{}, err
	}
	st, err := os.Stat(real)
	if err != nil {
		return Listing{}, err
	}
	if !st.IsDir() {
		return Listing{}, ErrNotDirectory
	}
	des, err := os.ReadDir(real)
	if err != nil {
		return Listing{}, err
	}

	out := Listing{
		Path:            real,
		IsRepo:          isRepo(real),
		OpenWorkspaceID: openBy[real],
		Roots:           rs,
		Entries:         []Entry{},
		Limit:           MaxEntries,
	}
	// "" for a root, which is how the app knows there is no "up" from here.
	if parent := filepath.Dir(real); parent != real && rs.Allows(parent) {
		out.Parent = parent
	}
	for _, de := range des {
		name := de.Name()
		if !showHidden && strings.HasPrefix(name, ".") {
			continue
		}
		full := filepath.Join(real, name)
		isLink := de.Type()&fs.ModeSymlink != 0
		target := full
		if isLink {
			// A link is followed only back into the roots; one pointing out of
			// them is simply not there as far as this endpoint is concerned.
			t, err := filepath.EvalSymlinks(full)
			if err != nil || !rs.Allows(t) {
				continue
			}
			target = t
		} else if !de.IsDir() {
			continue // files are never listed
		}
		if st, err := os.Stat(target); err != nil || !st.IsDir() {
			continue
		}
		if len(out.Entries) == MaxEntries {
			// We found one more than fits, so there IS more — say so.
			out.Truncated = true
			break
		}
		out.Entries = append(out.Entries, Entry{
			Name:            name,
			Path:            full,
			IsRepo:          isRepo(target),
			IsSymlink:       isLink,
			OpenWorkspaceID: openBy[target],
		})
	}
	return out, nil
}

// isRepo reports whether dir is the top of a git checkout. A normal repository
// has a `.git` directory; a linked worktree has a `.git` file pointing at the
// real one — both count, and neither is read.
func isRepo(dir string) bool {
	_, err := os.Stat(filepath.Join(dir, ".git"))
	return err == nil
}
