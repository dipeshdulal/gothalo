import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/features/diff/diff_model.dart';

/// Reassembles a line's spans, marking the changed runs, so an assertion can
/// state exactly which characters the word diff picked out.
String marked(List<DiffSpan>? spans) =>
    spans == null ? '<none>' : spans.map((s) => s.toString()).join();

void main() {
  group('FileDiff.parse', () {
    const modified = '''
diff --git a/internal/server/server.go b/internal/server/server.go
index 36dd2cd..4c341f8 100644
--- a/internal/server/server.go
+++ b/internal/server/server.go
@@ -78,6 +78,7 @@ func (s *Server) Handler() http.Handler {
 	mux.HandleFunc("/send", s.handleSend)
 	mux.HandleFunc("/approve", s.handleApprove)
 	mux.HandleFunc("/agent-state", s.handleAgentState)
+	mux.HandleFunc("/diff", s.handleDiff)
 	mux.HandleFunc("/agent-mode/cycle", s.handleAgentModeCycle)''';

    test('skips the preamble and numbers both sides of a hunk', () {
      final d = FileDiff.parse(modified);
      expect(d.hunks, hasLength(1));

      final h = d.hunks.single;
      expect(h.oldStart, 78);
      expect(h.newStart, 78);
      expect(h.section, 'func (s *Server) Handler() http.Handler {');
      expect(h.lines, hasLength(5));

      // The added line sits on the new side only, at 81.
      final added = h.lines.firstWhere(
        (l) => l.kind == DiffLineKind.addition,
      );
      expect(added.newLine, 81);
      expect(added.oldLine, isNull);
      expect(added.text.trim(), 'mux.HandleFunc("/diff", s.handleDiff)');

      // Context after it keeps counting on both sides.
      final last = h.lines.last;
      expect(last.kind, DiffLineKind.context);
      // The added line advanced the new side only, so the two sides are now
      // one apart — the whole reason both numbers are tracked separately.
      expect(last.oldLine, 81);
      expect(last.newLine, 82);
    });

    test('an untracked file\'s synthetic diff opens an implicit hunk', () {
      // No `@@` header at all — see CONTRACT-diff.md.
      final d = FileDiff.parse('--- /dev/null\n+++ b/new.go\n+package main\n+\n+func main() {}');
      expect(d.hunks, hasLength(1));

      final h = d.hunks.single;
      expect(h.lines.every((l) => l.kind == DiffLineKind.addition), isTrue);
      expect(h.lines.first.newLine, 1);
      expect(h.lines.last.newLine, 3);
      // Recovered from the parsed lines, so the region below it starts at 4.
      expect(h.newLast, 3);
    });

    test('a binary placeholder becomes a note, not lines', () {
      final d = FileDiff.parse('Binary file, not shown.');
      expect(d.hunks, isEmpty);
      expect(d.note, 'Binary file, not shown.');
    });

    test('an empty diff parses to nothing rather than throwing', () {
      expect(FileDiff.parse('').isEmpty, isTrue);
      expect(FileDiff.parse('   \n').isEmpty, isTrue);
    });

    test('"\\ No newline at end of file" is not a diff line', () {
      final d = FileDiff.parse(
        '@@ -1 +1 @@\n-a\n\\ No newline at end of file\n+b',
      );
      expect(d.hunks.single.lines, hasLength(2));
    });

    // A deletion-only hunk has newCount 0, and git then points newStart at the
    // line BEFORE the removal. Both ends have to step around that or the gaps
    // either side come out one line off.
    test('a deletion-only hunk resolves its new-side bounds', () {
      final d = FileDiff.parse('@@ -5,2 +4,0 @@\n-gone one\n-gone two');
      final h = d.hunks.single;
      expect(h.newCount, 0);
      expect(h.newFirst, 5); // the region above it ends at 4
      expect(h.newLast, 4); // the region below it starts at 5
    });

    test('multiple hunks each keep their own section header', () {
      final d = FileDiff.parse(
        '@@ -1,1 +1,1 @@ func a()\n-x\n+y\n@@ -50,1 +50,1 @@ func b()\n-p\n+q',
      );
      expect(d.hunks.map((h) => h.section), ['func a()', 'func b()']);
      expect(d.hunks.last.newStart, 50);
    });
  });

  group('word diff', () {
    test('a one-token edit highlights only that token', () {
      final d = FileDiff.parse(
        '@@ -1 +1 @@\n-  final timeout = 30 * time.Second\n+  final timeout = 45 * time.Second',
      );
      final lines = d.hunks.single.lines;

      expect(marked(lines[0].spans), '  final timeout = [30] * time.Second');
      expect(marked(lines[1].spans), '  final timeout = [45] * time.Second');
    });

    test('a single changed character does not mark the whole line', () {
      final d = FileDiff.parse('@@ -1 +1 @@\n-count += 1;\n+count -= 1;');
      final lines = d.hunks.single.lines;

      expect(marked(lines[0].spans), 'count [+]= 1;');
      expect(marked(lines[1].spans), 'count [-]= 1;');
    });

    test('two unrelated lines are left uniform', () {
      final d = FileDiff.parse(
        '@@ -1 +1 @@\n-import "os"\n+return fmt.Errorf("nope: %w", err)',
      );
      for (final l in d.hunks.single.lines) {
        expect(l.spans, isNull, reason: 'no pairing should survive here');
      }
    });

    test('a block pairs positionally and leaves the surplus uniform', () {
      final d = FileDiff.parse(
        '@@ -1,2 +1,3 @@\n-alpha one\n-beta two\n+alpha ONE\n+beta TWO\n+gamma three',
      );
      final lines = d.hunks.single.lines;

      expect(marked(lines[0].spans), 'alpha [one]');
      expect(marked(lines[2].spans), 'alpha [ONE]');
      expect(marked(lines[1].spans), 'beta [two]');
      expect(marked(lines[3].spans), 'beta [TWO]');
      // The unpaired third addition has nothing to be a diff OF.
      expect(lines[4].spans, isNull);
    });

    test('unpaired additions and deletions get no spans', () {
      final d = FileDiff.parse('@@ -1,1 +1,2 @@\n context\n+brand new line');
      expect(d.hunks.single.lines.last.spans, isNull);
    });

    test('identical text yields no word diff', () {
      expect(wordDiff('same', 'same'), isNull);
    });

    test('a pure insertion inside a line marks only the insertion', () {
      final r = wordDiff('foo(a, b)', 'foo(a, extra, b)')!;
      expect(marked(r.oldSpans), 'foo(a, b)');
      expect(marked(r.newSpans), 'foo(a, [extra, ]b)');
      expect(r.similarity, greaterThan(0.5));
    });

    test('a very long line skips the word diff rather than pay for it', () {
      final long = 'x' * 2000;
      expect(wordDiff(long, '${long}y'), isNull);
    });
  });
}
