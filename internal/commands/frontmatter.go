package commands

import (
	"bufio"
	"io"
	"os"
	"strings"
)

// frontmatterLimit bounds how much of a file the frontmatter scanner reads
// before giving up. Frontmatter lives at the very top; anything past this is the
// command's prompt body, which this package has no interest in. Keeps a large
// SKILL.md from being read into memory just to learn its one-line description.
const frontmatterLimit = 16 << 10 // 16 KiB

// readFrontmatter returns the leading YAML frontmatter of a markdown file as
// key -> value.
//
// This is NOT a YAML parser and deliberately does not pull one in. Command and
// skill frontmatter in the wild is a flat block of `key: value` lines, and the
// only two keys this package wants — `description` and `argument-hint` — are
// always scalars. So the scanner handles exactly that, plus surrounding quotes,
// and IGNORES anything structured (nested maps, block scalars, lists). A key it
// cannot read is simply absent, which degrades to a command with no description
// rather than a command that fails to list.
//
// Verified against real files on 2026-08-06: an official plugin command
// (`description:` alone, and `allowed-tools:` + `description:`) and a skill
// (`name:` + a long double-quoted `description:`) all parse with this.
//
// A file with no frontmatter yields an empty map and no error — plenty of
// perfectly good commands are a bare prompt.
func readFrontmatter(path string) (map[string]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	out := map[string]string{}
	sc := bufio.NewScanner(io.LimitReader(f, frontmatterLimit))
	sc.Buffer(make([]byte, 0, 4096), frontmatterLimit)

	// The block must open with --- on the first non-empty line, or there is no
	// frontmatter at all.
	opened := false
	for sc.Scan() {
		line := sc.Text()
		if !opened {
			if strings.TrimSpace(line) == "" {
				continue
			}
			if strings.TrimSpace(line) != "---" {
				return out, nil // no frontmatter; not an error
			}
			opened = true
			continue
		}
		if strings.TrimSpace(line) == "---" {
			break // end of block
		}
		// An indented line is nested under a structured key (a map entry, a list
		// item), not a top-level scalar. Checked on the RAW line, before any
		// trimming, or every nested key would read as top-level.
		if line != strings.TrimLeft(line, " \t") {
			continue
		}
		key, val, ok := strings.Cut(line, ":")
		if !ok {
			continue // continuation of a structured value we do not read
		}
		key = strings.TrimSpace(key)
		if key == "" || strings.HasPrefix(key, "#") {
			continue
		}
		if v := unquote(strings.TrimSpace(val)); v != "" {
			out[strings.ToLower(key)] = v
		}
	}
	// A scan error mid-frontmatter still returns what was read: a truncated
	// description beats dropping the command.
	return out, nil
}

// unquote strips one layer of matching single or double quotes and collapses
// interior whitespace, so a description reads as one line in a chip.
func unquote(s string) string {
	if len(s) >= 2 {
		if (s[0] == '"' && s[len(s)-1] == '"') || (s[0] == '\'' && s[len(s)-1] == '\'') {
			s = s[1 : len(s)-1]
		}
	}
	return strings.Join(strings.Fields(s), " ")
}
