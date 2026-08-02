package transcript

import (
	"fmt"
	"strings"
)

// structuredPatchHunk is one hunk of Claude Code's `toolUseResult.structuredPatch`
// — the applied edit, already split into context/removed/added lines. Its lines
// are pre-prefixed with " ", "-", or "+" exactly like a unified diff body, so we
// only add the "@@" hunk headers to reconstruct a standard unified diff.
type structuredPatchHunk struct {
	OldStart int      `json:"oldStart"`
	OldLines int      `json:"oldLines"`
	NewStart int      `json:"newStart"`
	NewLines int      `json:"newLines"`
	Lines    []string `json:"lines"`
}

// diffFromStructuredPatch renders a unified diff from structuredPatch hunks. It
// caps output at maxDiffLines/maxDiffRunes and reports whether it truncated, so a
// whole-file edit can't produce an unbounded frame.
func diffFromStructuredPatch(hunks []structuredPatchHunk) (diff string, truncated bool) {
	if len(hunks) == 0 {
		return "", false
	}
	var b strings.Builder
	lineCount := 0
	for _, h := range hunks {
		if lineCount >= maxDiffLines {
			truncated = true
			break
		}
		fmt.Fprintf(&b, "@@ -%d,%d +%d,%d @@\n", h.OldStart, h.OldLines, h.NewStart, h.NewLines)
		for _, l := range h.Lines {
			if lineCount >= maxDiffLines {
				truncated = true
				break
			}
			b.WriteString(l)
			b.WriteByte('\n')
			lineCount++
		}
	}
	out, cut := truncateRunes(strings.TrimRight(b.String(), "\n"), maxDiffRunes)
	return out, truncated || cut
}

// diffAllAdded renders a diff for a freshly-written file (Write): every line of
// content as an added ("+") line. Caps like the other diff builders.
func diffAllAdded(content string) (diff string, truncated bool) {
	if content == "" {
		return "", false
	}
	lines := strings.Split(content, "\n")
	var b strings.Builder
	fmt.Fprintf(&b, "@@ -0,0 +1,%d @@\n", len(lines))
	for i, l := range lines {
		if i >= maxDiffLines {
			truncated = true
			break
		}
		b.WriteByte('+')
		b.WriteString(l)
		b.WriteByte('\n')
	}
	out, cut := truncateRunes(strings.TrimRight(b.String(), "\n"), maxDiffRunes)
	return out, truncated || cut
}

// diffFromEditInput builds a unified diff from an Edit tool's raw old/new strings
// (available on the tool_call before the applied result arrives). It trims the
// common leading/trailing context lines so the hunk shows only what changed, then
// renders removed ("-") and added ("+") lines. This is a best-effort preview; the
// authoritative applied diff rides on the paired tool_result. Caps like
// diffFromStructuredPatch.
func diffFromEditInput(oldStr, newStr string) (diff string, truncated bool) {
	if oldStr == "" && newStr == "" {
		return "", false
	}
	oldLines := strings.Split(oldStr, "\n")
	newLines := strings.Split(newStr, "\n")

	// Trim identical leading lines (kept as a little context, capped at 3).
	pre := 0
	for pre < len(oldLines) && pre < len(newLines) && oldLines[pre] == newLines[pre] {
		pre++
	}
	// Trim identical trailing lines.
	suf := 0
	for suf < len(oldLines)-pre && suf < len(newLines)-pre &&
		oldLines[len(oldLines)-1-suf] == newLines[len(newLines)-1-suf] {
		suf++
	}
	ctx := 3
	lead := pre
	if lead > ctx {
		lead = ctx
	}
	trail := suf
	if trail > ctx {
		trail = ctx
	}

	changedOld := oldLines[pre-lead : len(oldLines)-suf+trail]
	changedNew := newLines[pre-lead : len(newLines)-suf+trail]

	var b strings.Builder
	fmt.Fprintf(&b, "@@ -%d +%d @@\n", pre-lead+1, pre-lead+1)
	lineCount := 0
	emit := func(prefix string, lines []string, skipContext bool) bool {
		for i, l := range lines {
			// Leading/trailing context lines are shared; emit them once (as context)
			// only for the old side to avoid duplication.
			isLead := i < lead
			isTrail := i >= len(lines)-trail
			if (isLead || isTrail) && skipContext {
				continue
			}
			if lineCount >= maxDiffLines {
				truncated = true
				return false
			}
			p := prefix
			if isLead || isTrail {
				p = " "
			}
			b.WriteString(p)
			b.WriteString(l)
			b.WriteByte('\n')
			lineCount++
		}
		return true
	}
	// Old side: context lines + removed lines.
	if emit("-", changedOld, false) {
		// New side: only the added lines (context already emitted from the old side).
		emit("+", changedNew, true)
	}
	out, cut := truncateRunes(strings.TrimRight(b.String(), "\n"), maxDiffRunes)
	return out, truncated || cut
}
