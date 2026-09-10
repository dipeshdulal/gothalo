# CONTRACT — `POST /file` (attach a document to a prompt)

`POST /image`, for documents: the spec PDF someone sent you, the requirements
docx, the slide deck from the design review — handed to the agent the same way
a screenshot is, as a path inside the pane's own tree that the app inserts
where the user is typing. Everything structural is inherited from
[`CONTRACT-image.md`](CONTRACT-image.md) — the path-is-the-attachment trick,
the raw-bytes wire format, the no-filename rule, the drop-directory hygiene —
and is not restated here. This contract covers only what differs.

**The app does not send**, same as images: uploading a document is not, by
itself, a message.

---

## Request

```
POST /file?pane=<pane_id>
Authorization: Bearer <bearer>
Content-Type: application/octet-stream

<raw document bytes>
```

Raw bytes, not multipart, for the reason CONTRACT-image.md spells out: a
filename is the one thing this endpoint must never accept. `?name=`,
`?filename=` and `Content-Disposition` are not read.

## What is accepted

| Type | How it is recognised | Stored as |
|---|---|---|
| PDF | `http.DetectContentType` (`%PDF` magic) | `.pdf` |
| Word | zip container holding `word/…` parts | `.docx` |
| PowerPoint | zip container holding `ppt/…` parts | `.pptx` |

The OOXML pair is the one place document sniffing needs a second step: every
`.docx` and `.pptx` is a plain zip to the sniffer, so the bridge opens the
container (`archive/zip`) and classifies it by the package parts inside. A zip
is stored as `.docx` because it *contains Word's document parts* — never
because of what the client called it. A plain archive, an `.xlsx` (off the
allowlist until someone needs it), or a zip too corrupt to open are all `415`.

**Legacy `.doc` / `.ppt` are deliberately excluded.** They share one OLE
container magic between Word, Excel and PowerPoint, and telling them apart
means parsing OLE directory streams — real complexity for formats a phone
rarely holds. The `415` message says to convert first.

## Size

Capped at **25 MiB** inclusive (`imagedrop.MaxDocumentBytes`) — documents run
larger than screenshots, but the handler still buffers the whole body, so the
cap stays a real per-request memory bound. Same two-tier refusal as images: a
declared `Content-Length` over the cap is refused without reading the body;
a chunked body is read through a limit reader and refused past it.

## Where it lands

`<pane cwd>/.gothalo/files/` — a sibling of `.gothalo/images/`, under the same
self-gitignored root, with the same name scheme
(`<timestamp>-<content hash>.<ext>`) and the same retention (7 days / 40
files, swept on every write, names this bridge did not write are never
touched). Pane resolution — agent cwd when the pane hosts one, the pane's own
cwd when it doesn't, session-qualified ids accepted — is identical to
`/image`.

## Response

`200` with the same shape as `/image`:

```json
{ "path": "/Users/dipesh/projects/gothalo/.gothalo/files/20260910-142530-9f86d081.pdf",
  "relative_path": ".gothalo/files/20260910-142530-9f86d081.pdf",
  "content_type": "application/pdf",
  "bytes": 1843200 }
```

For the OOXML pair, `content_type` is the real Office type
(`application/vnd.openxmlformats-officedocument.wordprocessingml.document` /
`…presentationml.presentation`), not `application/zip` — the classification
the bridge actually made.

## Errors

Identical to `/image`, with the document cap and allowlist behind them:
`400` missing `pane` or empty body · `401` bad bearer · `404` unknown pane, or
one Herdr reports no cwd for · `405` non-POST · `413` over 25 MiB · `415` not
a pdf/docx/pptx · `500` the drop directory couldn't be written · `502` herdr
command failed. A `404` seen by the app also means "this bridge predates the
endpoint" — the client words it that way.

## What agents do with it

A path is text; what the agent does with it is the agent's business. Claude
Code reads PDFs natively; for `.docx`/`.pptx` agents typically shell out to a
converter — either way the bridge's contract ends at "the bytes are inside
your tree, here is the path", exactly as it does for images.
