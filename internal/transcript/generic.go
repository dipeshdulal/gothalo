package transcript

import (
	"encoding/json"
	"strings"
)

// genericReader is the fallback for any agent kind without a dedicated transcript
// reader. It makes no assumptions about the file format: it best-effort extracts a
// little text from a JSON line (a `text`/`content`/`message` field, if present)
// and always reports Parsed=false, so the app knows the entry is a raw passthrough
// rather than a normalized one. This keeps the endpoint unknown-safe — a brand-new
// agent kind streams renderable rows instead of failing.
//
// It is also what ReaderFor returns for an unregistered kind, and the base the
// per-kind readers' own fallbacks conceptually mirror (emit, never drop).
type genericReader struct{}

func (genericReader) Kind() string { return "" } // not registered; used as fallback

func (genericReader) Normalize(line []byte) []Entry {
	var m map[string]any
	if err := json.Unmarshal(line, &m); err != nil {
		return []Entry{{Role: RoleSystem, Kind: KindMessage, Parsed: false}}
	}
	e := Entry{Role: RoleSystem, Kind: KindMessage, Parsed: false}
	if id, ok := m["uuid"].(string); ok {
		e.ID = id
	}
	if p, ok := m["parentUuid"].(string); ok {
		e.ParentID = p
	}
	if ts, ok := m["timestamp"].(string); ok {
		e.TS = ts
	}
	// Best-effort text from the most common carrier fields.
	for _, k := range []string{"text", "content", "message"} {
		if s, ok := m[k].(string); ok {
			if t := strings.TrimSpace(s); t != "" {
				e.Text, _ = truncateRunes(t, maxInlineTextRunes)
				break
			}
		}
	}
	return []Entry{e}
}
