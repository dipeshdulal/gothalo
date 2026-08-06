package server

import (
	"reflect"
	"testing"
)

func TestSplitPaneInput(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name string
		in   string
		want []paneChunk
	}{
		{
			name: "plain text stays one send-text",
			in:   "git status",
			want: []paneChunk{{text: "git status"}},
		},
		{
			name: "the arrow pad's four keys",
			in:   "\x1b[A\x1b[B\x1b[C\x1b[D",
			want: []paneChunk{{key: "up"}, {key: "down"}, {key: "right"}, {key: "left"}},
		},
		{
			name: "application cursor mode arrows",
			in:   "\x1bOA\x1bOD",
			want: []paneChunk{{key: "up"}, {key: "left"}},
		},
		{
			name: "a quick command: text then submit",
			in:   "git status\r",
			want: []paneChunk{{text: "git status"}, {key: "enter"}},
		},
		{
			name: "CRLF is one Enter, not two",
			in:   "ls\r\n",
			want: []paneChunk{{text: "ls"}, {key: "enter"}},
		},
		{
			name: "order is preserved around text",
			in:   "ab\x1b[Bcd\x03",
			want: []paneChunk{
				{text: "ab"}, {key: "down"}, {text: "cd"}, {key: "ctrl+c"},
			},
		},
		{
			name: "a lone ESC is Esc, not the start of a sequence",
			in:   "\x1b",
			want: []paneChunk{{key: "esc"}},
		},
		{
			name: "ESC followed by ordinary text stays Esc plus text",
			in:   "\x1bfoo",
			want: []paneChunk{{key: "esc"}, {text: "foo"}},
		},
		{
			name: "accessory row: Tab, Shift-Tab, Ctrl-C, Ctrl-D",
			in:   "\t\x1b[Z\x03\x04",
			want: []paneChunk{
				{key: "tab"}, {key: "shift+tab"}, {key: "ctrl+c"}, {key: "ctrl+d"},
			},
		},
		{
			name: "both backspace encodings",
			in:   "\x7f\x08",
			want: []paneChunk{{key: "backspace"}, {key: "backspace"}},
		},
		{
			name: "sticky-Ctrl output becomes a ctrl+letter press",
			in:   "\x12", // Ctrl-R
			want: []paneChunk{{key: "ctrl+r"}},
		},
		{
			name: "a multi-line paste submits each line",
			in:   "one\ntwo\n",
			want: []paneChunk{
				{text: "one"}, {key: "enter"}, {text: "two"}, {key: "enter"},
			},
		},
		{
			name: "unsupported sequences are left as text, not dropped",
			in:   "\x1b[5~",
			want: []paneChunk{{key: "esc"}, {text: "[5~"}},
		},
		{
			name: "empty input produces nothing to send",
			in:   "",
			want: nil,
		},
		{
			name: "multi-byte UTF-8 survives intact",
			in:   "héllo→\r",
			want: []paneChunk{{text: "héllo→"}, {key: "enter"}},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got := splitPaneInput(tc.in)
			if !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("splitPaneInput(%q)\n got %#v\nwant %#v", tc.in, got, tc.want)
			}
		})
	}
}

// Every sequence in the table must be reachable: one longer than the lookahead
// would never match, and the bug would only show up as a dead key on a phone.
func TestPaneKeySeqWithinLookahead(t *testing.T) {
	t.Parallel()
	for seq, key := range paneKeySeq {
		if len(seq) > longestPaneKeySeq {
			t.Errorf("sequence %q (%s) is longer than longestPaneKeySeq=%d", seq, key, longestPaneKeySeq)
		}
	}
}
