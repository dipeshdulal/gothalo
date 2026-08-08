/// Unified-diff parsing for the Changes screen — pure Dart, no Flutter import,
/// so all of it is unit-testable without pumping a widget.
///
/// The bridge hands the app one unified diff per file (`docs/CONTRACT-diff.md`)
/// and nothing else. Everything the viewer knows beyond "here is some text" is
/// derived here: hunks, per-line old/new line numbers, and the word-level
/// segmentation that stops a one-character edit from reading as a whole
/// rewritten line. Doing it client-side keeps the contract as it was and means
/// a bridge that never learns about any of this still renders correctly.
///
/// Every parse step falls back to something renderable rather than throwing: a
/// diff shape this doesn't recognize degrades to plain context lines, never to
/// an exception on the review screen.
library;

/// What one row of a diff IS, independent of how it's painted.
enum DiffLineKind { context, addition, deletion }

/// A run of characters within a line, flagged as part of the intra-line change
/// or not. The whole point of the word diff: `changed` spans get a stronger
/// wash so the eye lands on the two characters that actually moved.
class DiffSpan {
  const DiffSpan(this.text, {this.changed = false});

  final String text;
  final bool changed;

  @override
  String toString() => changed ? '[$text]' : text;
}

/// One rendered row of a file's diff.
class DiffLine {
  DiffLine({
    required this.kind,
    required this.text,
    this.oldLine,
    this.newLine,
    this.spans,
  });

  final DiffLineKind kind;

  /// The line's content, with the `+`/`-`/space prefix already stripped — the
  /// marker is drawn as its own gutter column, not as part of the code.
  final String text;

  /// 1-based line numbers on each side; null on the side the line isn't on.
  final int? oldLine;
  final int? newLine;

  /// Word-level segmentation, or null when the line is shown uniformly (an
  /// unpaired add/delete, or a pair too dissimilar for the highlighting to mean
  /// anything). Mutable because it's filled in by [_annotateWordDiffs] straight
  /// after the hunk is parsed, and never touched again.
  List<DiffSpan>? spans;
}

/// One `@@` hunk.
class DiffHunk {
  DiffHunk({
    required this.oldStart,
    required this.oldCount,
    required this.newStart,
    required this.newCount,
    required this.section,
    required this.lines,
  });

  final int oldStart;
  final int oldCount;
  final int newStart;
  final int newCount;

  /// The text git puts after the closing `@@` — the enclosing function or
  /// section. Free context worth showing on a collapsed gap row, since it says
  /// *where* in the file you are without expanding anything.
  final String section;

  final List<DiffLine> lines;

  /// The first/last NEW-side line numbers this hunk occupies.
  ///
  /// A hunk that only deletes has `newCount == 0`, and git then points
  /// `newStart` at the line *before* the removal rather than at a line the hunk
  /// owns — so both ends have to step around it or every gap either side comes
  /// out one line wrong.
  int get newFirst => newCount == 0 ? newStart + 1 : newStart;
  int get newLast => newCount == 0 ? newStart : newStart + newCount - 1;
}

/// A parsed per-file diff.
class FileDiff {
  const FileDiff({required this.hunks, this.note = ''});

  final List<DiffHunk> hunks;

  /// Set when there is nothing to render line-by-line — a binary file, or a
  /// diff the bridge replaced with a message. Shown verbatim in place of the
  /// hunks.
  final String note;

  bool get isEmpty => hunks.isEmpty;

  /// Parses one file's unified diff (`files[].diff` from `GET /diff`).
  static FileDiff parse(String raw) {
    if (raw.trim().isEmpty) return const FileDiff(hunks: []);

    final hunks = <DiffHunk>[];
    var note = '';

    List<DiffLine>? open;
    var oldStart = 0, oldCount = 0, newStart = 0, newCount = 0, section = '';
    var oldNo = 0, newNo = 0;

    void flush() {
      final lines = open;
      if (lines == null) return;
      _annotateWordDiffs(lines);
      hunks.add(
        DiffHunk(
          oldStart: oldStart,
          oldCount: oldCount,
          newStart: newStart,
          newCount: newCount,
          section: section,
          lines: lines,
        ),
      );
      open = null;
    }

    for (final line in raw.split('\n')) {
      final header = _hunkHeader.firstMatch(line);
      if (header != null) {
        flush();
        oldStart = int.tryParse(header.group(1) ?? '') ?? 0;
        oldCount = int.tryParse(header.group(2) ?? '') ?? 1;
        newStart = int.tryParse(header.group(3) ?? '') ?? 0;
        newCount = int.tryParse(header.group(4) ?? '') ?? 1;
        section = (header.group(5) ?? '').trim();
        oldNo = oldStart;
        newNo = newStart;
        open = <DiffLine>[];
        continue;
      }

      if (open == null) {
        // Preamble: `diff --git`, `index`, mode/rename lines, and the
        // `---`/`+++` file headers. Skipped HERE and only here — inside a hunk
        // a line starting `+++` is a genuine added line whose content happens
        // to begin with `++`.
        if (line.startsWith('Binary file') || line.startsWith('Binary files')) {
          note = line;
          continue;
        }
        if (!line.startsWith('+') || line.startsWith('+++')) continue;
        // No `@@` in sight but content already: an untracked file's synthetic
        // "every line added" diff (see CONTRACT-diff.md). Open a hunk covering
        // the whole new file so it renders through the same path as any other.
        oldStart = 0;
        oldCount = 0;
        newStart = 1;
        newCount = 0;
        section = '';
        oldNo = 0;
        newNo = 1;
        open = <DiffLine>[];
      }

      final lines = open!;
      if (line.startsWith('\\')) continue; // "\ No newline at end of file"
      if (line.startsWith('+')) {
        lines.add(
          DiffLine(
            kind: DiffLineKind.addition,
            text: line.substring(1),
            newLine: newNo++,
          ),
        );
      } else if (line.startsWith('-')) {
        lines.add(
          DiffLine(
            kind: DiffLineKind.deletion,
            text: line.substring(1),
            oldLine: oldNo++,
          ),
        );
      } else {
        // A context line is " content"; a truly empty line and the synthetic
        // diff's "… (truncated)" marker both land here too, which is right —
        // they read as unchanged context.
        lines.add(
          DiffLine(
            kind: DiffLineKind.context,
            text: line.isEmpty ? '' : line.substring(1),
            oldLine: oldNo == 0 ? null : oldNo++,
            newLine: newNo++,
          ),
        );
      }
    }
    flush();

    // The synthetic all-added diff has no real header, so its newCount was
    // never stated; recover it from what was actually parsed, otherwise the
    // "lines below this hunk" gap starts in the wrong place.
    for (var i = 0; i < hunks.length; i++) {
      final h = hunks[i];
      if (h.newCount != 0 || h.oldCount != 0 || h.lines.isEmpty) continue;
      final last = h.lines.last.newLine;
      if (last != null) {
        hunks[i] = DiffHunk(
          oldStart: h.oldStart,
          oldCount: h.oldCount,
          newStart: h.newStart,
          newCount: last - h.newStart + 1,
          section: h.section,
          lines: h.lines,
        );
      }
    }

    return FileDiff(hunks: hunks, note: note);
  }
}

final _hunkHeader = RegExp(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@ ?(.*)$');

/// Below this similarity a deleted/added pair is treated as two unrelated
/// lines and shown uniformly. Highlighting "the changed words" of a line that
/// was rewritten wholesale is just noise with extra colours in it.
const _minSimilarity = 0.3;

/// Lines longer than this skip the word diff entirely — a minified bundle on
/// one 40KB line is not something anyone reads word by word, and it's exactly
/// the input that would make the DP below expensive.
const _maxWordDiffChars = 1000;

/// Cap on the LCS table. Past it, the whole differing middle is marked changed
/// (which is what the eye would conclude anyway on a pair that dissimilar).
const _maxDpCells = 40000;

/// Pairs up deletion/addition runs within a hunk and fills in [DiffLine.spans]
/// for each pair that's similar enough to be a genuine edit.
///
/// Pairing is positional within a run — the k-th deletion against the k-th
/// addition — which is what a real edit looks like. A block where the counts
/// differ still pairs its overlap and leaves the surplus lines uniform, so a
/// "3 lines became 4" edit highlights the three that correspond and shows the
/// fourth as a plain addition.
void _annotateWordDiffs(List<DiffLine> lines) {
  var i = 0;
  while (i < lines.length) {
    if (lines[i].kind != DiffLineKind.deletion) {
      i++;
      continue;
    }
    var d = i;
    while (d < lines.length && lines[d].kind == DiffLineKind.deletion) {
      d++;
    }
    var a = d;
    while (a < lines.length && lines[a].kind == DiffLineKind.addition) {
      a++;
    }
    final pairs = (d - i) < (a - d) ? (d - i) : (a - d);
    for (var k = 0; k < pairs; k++) {
      final del = lines[i + k], add = lines[d + k];
      final wd = wordDiff(del.text, add.text);
      if (wd == null || wd.similarity < _minSimilarity) continue;
      del.spans = wd.oldSpans;
      add.spans = wd.newSpans;
    }
    i = a > i ? a : i + 1;
  }
}

/// Both sides of one line's intra-line diff, plus how alike they are.
class WordDiffResult {
  const WordDiffResult({
    required this.oldSpans,
    required this.newSpans,
    required this.similarity,
  });

  final List<DiffSpan> oldSpans;
  final List<DiffSpan> newSpans;

  /// 0..1 — matched characters as a share of both lines' length. Drives the
  /// "is this an edit or two unrelated lines?" call.
  final double similarity;
}

/// Word-level diff of two lines. Returns null when the lines are identical or
/// too long to be worth it — in both cases the caller shows them uniformly.
///
/// Common leading/trailing tokens are stripped before any real work, which is
/// what makes the common case (one token changed in a long line) essentially
/// free; only the differing middle reaches the LCS table.
WordDiffResult? wordDiff(String a, String b) {
  if (a == b) return null;
  if (a.length > _maxWordDiffChars || b.length > _maxWordDiffChars) return null;

  final ta = _tokenize(a), tb = _tokenize(b);
  var prefix = 0;
  while (prefix < ta.length && prefix < tb.length && ta[prefix] == tb[prefix]) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < ta.length - prefix &&
      suffix < tb.length - prefix &&
      ta[ta.length - 1 - suffix] == tb[tb.length - 1 - suffix]) {
    suffix++;
  }

  final midA = ta.sublist(prefix, ta.length - suffix);
  final midB = tb.sublist(prefix, tb.length - suffix);

  final changedA = List<bool>.filled(midA.length, true);
  final changedB = List<bool>.filled(midB.length, true);
  var matched = 0;
  for (var i = 0; i < prefix; i++) {
    matched += ta[i].length;
  }
  for (var i = ta.length - suffix; i < ta.length; i++) {
    matched += ta[i].length;
  }

  if (midA.isNotEmpty &&
      midB.isNotEmpty &&
      midA.length * midB.length <= _maxDpCells) {
    matched += _markLcs(midA, midB, changedA, changedB);
  }

  final total = a.length + b.length;
  final similarity = total == 0 ? 1.0 : (2 * matched) / total;

  return WordDiffResult(
    oldSpans: _spans(ta, prefix, suffix, changedA),
    newSpans: _spans(tb, prefix, suffix, changedB),
    similarity: similarity,
  );
}

/// Marks the tokens NOT on the longest common subsequence as changed, and
/// returns how many characters did match.
int _markLcs(
  List<String> a,
  List<String> b,
  List<bool> changedA,
  List<bool> changedB,
) {
  final w = b.length + 1;
  final table = List<int>.filled((a.length + 1) * w, 0);
  for (var i = a.length - 1; i >= 0; i--) {
    for (var j = b.length - 1; j >= 0; j--) {
      table[i * w + j] = a[i] == b[j]
          ? table[(i + 1) * w + j + 1] + 1
          : (table[(i + 1) * w + j] >= table[i * w + j + 1]
                ? table[(i + 1) * w + j]
                : table[i * w + j + 1]);
    }
  }
  var matched = 0, i = 0, j = 0;
  while (i < a.length && j < b.length) {
    if (a[i] == b[j]) {
      changedA[i] = false;
      changedB[j] = false;
      matched += a[i].length;
      i++;
      j++;
    } else if (table[(i + 1) * w + j] >= table[i * w + j + 1]) {
      i++;
    } else {
      j++;
    }
  }
  return matched;
}

/// Rebuilds a line from its tokens, merging neighbours that share a changed
/// flag so the renderer emits a handful of spans rather than one per token.
List<DiffSpan> _spans(
  List<String> tokens,
  int prefix,
  int suffix,
  List<bool> changedMiddle,
) {
  final out = <DiffSpan>[];
  final buf = StringBuffer();
  bool? mode;

  void emit() {
    if (buf.isEmpty) return;
    out.add(DiffSpan(buf.toString(), changed: mode ?? false));
    buf.clear();
  }

  for (var i = 0; i < tokens.length; i++) {
    final inMiddle = i >= prefix && i < tokens.length - suffix;
    final changed = inMiddle && changedMiddle[i - prefix];
    if (mode != changed) {
      emit();
      mode = changed;
    }
    buf.write(tokens[i]);
  }
  emit();
  return out;
}

/// Splits a line into diff-able tokens: identifier-ish runs, whitespace runs,
/// and every other character on its own.
///
/// Token granularity is what makes the highlight readable — a character-level
/// diff of two lines of code finds spurious matches everywhere (every `e`
/// matches some other `e`) and paints a dotted mess; whole-word tokens with
/// punctuation split out land the highlight on the identifier that changed.
List<String> _tokenize(String s) {
  final out = <String>[];
  var i = 0;
  while (i < s.length) {
    final c = s.codeUnitAt(i);
    if (_isWordChar(c)) {
      final start = i;
      while (i < s.length && _isWordChar(s.codeUnitAt(i))) {
        i++;
      }
      out.add(s.substring(start, i));
    } else if (c == 0x20 || c == 0x09) {
      final start = i;
      while (i < s.length &&
          (s.codeUnitAt(i) == 0x20 || s.codeUnitAt(i) == 0x09)) {
        i++;
      }
      out.add(s.substring(start, i));
    } else {
      out.add(s[i]);
      i++;
    }
  }
  return out;
}

bool _isWordChar(int c) =>
    (c >= 0x61 && c <= 0x7a) || // a-z
    (c >= 0x41 && c <= 0x5a) || // A-Z
    (c >= 0x30 && c <= 0x39) || // 0-9
    c == 0x5f || // _
    c >= 0x80; // anything non-ASCII: one word, not one token per byte
