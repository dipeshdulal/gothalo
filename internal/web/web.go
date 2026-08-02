// Package web embeds the static web-push receiver page so the bridge serves it
// from its own origin (no external file path, works after `go install`).
package web

import (
	"embed"
	"io/fs"
)

//go:embed assets
var files embed.FS

// FS returns the receiver-page assets rooted so that "/" serves index.html.
func FS() fs.FS {
	sub, err := fs.Sub(files, "assets")
	if err != nil {
		panic(err) // embed layout is fixed at build time
	}
	return sub
}
