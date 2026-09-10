package imagedrop

import (
	"archive/zip"
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// pdfBytes is the smallest sequence http.DetectContentType calls a PDF — the
// magic is all the sniffer reads, so a full document would test nothing extra.
var pdfBytes = append([]byte("%PDF-1.7\n"), bytes.Repeat([]byte{0}, 32)...)

// ooxml builds a minimal Office Open XML container: a zip whose first entries
// are the ones a real .docx / .pptx carries. Classification reads entry names,
// so the entry bodies can stay empty.
func ooxml(t *testing.T, partDir string) []byte {
	t.Helper()
	var buf bytes.Buffer
	w := zip.NewWriter(&buf)
	for _, name := range []string{"[Content_Types].xml", partDir} {
		if _, err := w.Create(name); err != nil {
			t.Fatal(err)
		}
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

// plainZip is a well-formed zip that is not an Office document — the case the
// zip sniff alone cannot reject.
func plainZip(t *testing.T) []byte {
	t.Helper()
	var buf bytes.Buffer
	w := zip.NewWriter(&buf)
	if _, err := w.Create("archive/readme.txt"); err != nil {
		t.Fatal(err)
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

// TestDetectDocumentAllowsOnlyDocuments pins the allowlist and that the
// extension follows from the container's CONTENTS — a zip is a .docx or a
// .pptx because of what is inside it, never because of what it was named.
func TestDetectDocumentAllowsOnlyDocuments(t *testing.T) {
	cases := []struct {
		name string
		data []byte
		ct   string
		ext  string
	}{
		{"pdf", pdfBytes, "application/pdf", ".pdf"},
		{
			"docx", ooxml(t, "word/document.xml"),
			"application/vnd.openxmlformats-officedocument.wordprocessingml.document", ".docx",
		},
		{
			"pptx", ooxml(t, "ppt/presentation.xml"),
			"application/vnd.openxmlformats-officedocument.presentationml.presentation", ".pptx",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			ct, ext, err := DetectDocument(c.data)
			if err != nil {
				t.Fatalf("DetectDocument: %v", err)
			}
			if ct != c.ct || ext != c.ext {
				t.Errorf("got (%q, %q), want (%q, %q)", ct, ext, c.ct, c.ext)
			}
		})
	}
}

// TestDetectDocumentRejects covers every refusal: junk, images (which belong to
// POST /image), zips that aren't Office documents, an xlsx (a real OOXML type
// deliberately off the allowlist), and truncated zip garbage.
func TestDetectDocumentRejects(t *testing.T) {
	cases := []struct {
		name string
		data []byte
		want error
	}{
		{"empty", nil, ErrEmpty},
		{"too-large", append([]byte("%PDF-1.7\n"), bytes.Repeat([]byte{0}, MaxDocumentBytes)...), ErrDocumentTooLarge},
		{"plain-text", []byte("#!/bin/sh\nrm -rf /\n"), ErrUnsupportedDocument},
		{"png", pngBytes, ErrUnsupportedDocument},
		{"plain-zip", plainZip(t), ErrUnsupportedDocument},
		{"xlsx", ooxml(t, "xl/workbook.xml"), ErrUnsupportedDocument},
		// PK magic satisfies the sniffer but the archive is unreadable.
		{"corrupt-zip", append([]byte("PK\x03\x04"), bytes.Repeat([]byte{0x41}, 32)...), ErrUnsupportedDocument},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if _, _, err := DetectDocument(c.data); !errors.Is(err, c.want) {
				t.Errorf("err = %v, want %v", err, c.want)
			}
		})
	}
}

// TestDetectDocumentAcceptsExactlyMaxBytes asserts the document cap is
// inclusive, same as the image cap.
func TestDetectDocumentAcceptsExactlyMaxBytes(t *testing.T) {
	data := append([]byte("%PDF-1.7\n"), bytes.Repeat([]byte{0}, MaxDocumentBytes-9)...)
	if len(data) != MaxDocumentBytes {
		t.Fatalf("fixture is %d bytes, want %d", len(data), MaxDocumentBytes)
	}
	if _, _, err := DetectDocument(data); err != nil {
		t.Errorf("DetectDocument at the cap: %v", err)
	}
}

// TestSaveDocumentWritesUnderCwd is the core contract, mirrored from images:
// the file lands in the pane's tree under .gothalo/files, and the returned
// path is absolute and readable.
func TestSaveDocumentWritesUnderCwd(t *testing.T) {
	cwd := t.TempDir()
	res, err := SaveDocument(cwd, pdfBytes, fixedClock)
	if err != nil {
		t.Fatalf("SaveDocument: %v", err)
	}
	if !filepath.IsAbs(res.Path) {
		t.Errorf("path %q is not absolute", res.Path)
	}
	wantDir := filepath.Join(cwd, ".gothalo", "files")
	if filepath.Dir(res.Path) != wantDir {
		t.Errorf("dir = %q, want %q", filepath.Dir(res.Path), wantDir)
	}
	if res.RelativePath != ".gothalo/files/"+filepath.Base(res.Path) {
		t.Errorf("relative_path = %q", res.RelativePath)
	}
	if res.ContentType != "application/pdf" || res.Bytes != len(pdfBytes) {
		t.Errorf("got (%q, %d)", res.ContentType, res.Bytes)
	}
	got, err := os.ReadFile(res.Path)
	if err != nil {
		t.Fatalf("read back: %v", err)
	}
	if !bytes.Equal(got, pdfBytes) {
		t.Error("written bytes differ from the upload")
	}
	body, err := os.ReadFile(filepath.Join(cwd, ".gothalo", ".gitignore"))
	if err != nil {
		t.Fatalf("read .gitignore: %v", err)
	}
	if string(bytes.TrimSpace(body)) != "*" {
		t.Errorf(".gitignore = %q, want \"*\"", body)
	}
}

// TestSaveDocumentExtensionFollowsContents asserts a .docx lands as .docx and
// a .pptx as .pptx with no filename ever crossing the wire.
func TestSaveDocumentExtensionFollowsContents(t *testing.T) {
	cwd := t.TempDir()
	docx, err := SaveDocument(cwd, ooxml(t, "word/document.xml"), fixedClock)
	if err != nil {
		t.Fatalf("SaveDocument docx: %v", err)
	}
	if filepath.Ext(docx.Path) != ".docx" {
		t.Errorf("docx landed as %q", filepath.Base(docx.Path))
	}
	pptx, err := SaveDocument(cwd, ooxml(t, "ppt/presentation.xml"), fixedClock)
	if err != nil {
		t.Fatalf("SaveDocument pptx: %v", err)
	}
	if filepath.Ext(pptx.Path) != ".pptx" {
		t.Errorf("pptx landed as %q", filepath.Base(pptx.Path))
	}
}

// TestSaveDocumentRejectsRelativeCwd mirrors the image guard: a pane with no
// absolute working directory must not send writes anywhere.
func TestSaveDocumentRejectsRelativeCwd(t *testing.T) {
	for _, cwd := range []string{"", "relative/dir", "../up"} {
		if _, err := SaveDocument(cwd, pdfBytes, fixedClock); err == nil {
			t.Errorf("SaveDocument(%q) succeeded, want an error", cwd)
		}
	}
}

// TestPruneSweepsDocuments asserts retention treats the files directory
// exactly like the images one: our stale names go, foreign names stay.
func TestPruneSweepsDocuments(t *testing.T) {
	cwd := t.TempDir()
	old, err := SaveDocument(cwd, pdfBytes, fixedClock.Add(-retainAge-time.Hour))
	if err != nil {
		t.Fatalf("SaveDocument old: %v", err)
	}
	foreign := filepath.Join(filepath.Dir(old.Path), "keep-me.pdf")
	if err := os.WriteFile(foreign, pdfBytes, 0o644); err != nil {
		t.Fatal(err)
	}
	fresh, err := SaveDocument(cwd, ooxml(t, "word/document.xml"), fixedClock)
	if err != nil {
		t.Fatalf("SaveDocument fresh: %v", err)
	}
	if _, err := os.Stat(old.Path); !os.IsNotExist(err) {
		t.Errorf("stale document survived the sweep: %v", err)
	}
	if _, err := os.Stat(fresh.Path); err != nil {
		t.Errorf("fresh document was swept: %v", err)
	}
	if _, err := os.Stat(foreign); err != nil {
		t.Errorf("foreign file was deleted: %v", err)
	}
}
