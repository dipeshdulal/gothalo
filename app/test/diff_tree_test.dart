import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/data/bridge/bridge_client.dart';
import 'package:gothalo/features/diff/diff_tree.dart';

DiffFile file(String path, {int add = 1, int del = 0, String status = 'modified'}) =>
    DiffFile(
      path: path,
      status: status,
      additions: add,
      deletions: del,
      diff: '',
    );

/// The tree as `name(+a −d, n)` lines, indented by depth — compact enough to
/// assert a whole shape in one expect.
List<String> render(DiffTreeNode root) {
  final out = <String>[];
  void walk(DiffTreeNode n, int depth) {
    for (final c in n.children) {
      out.add(
        '${'  ' * depth}${c.name}${c.isFile ? '' : '/'}'
        ' +${c.additions} -${c.deletions} n${c.fileCount}',
      );
      walk(c, depth + 1);
    }
  }

  walk(root, 0);
  return out;
}

void main() {
  test('groups by directory and rolls counts up', () {
    final tree = buildDiffTree([
      file('internal/server/diff.go', add: 5, del: 1),
      file('internal/server/pane.go', add: 2, del: 3),
      file('README.md', add: 7),
    ]);

    expect(render(tree), [
      'internal/server/ +7 -4 n2',
      '  diff.go +5 -1 n1',
      '  pane.go +2 -3 n1',
      'README.md +7 -0 n1',
    ]);
    expect(tree.fileCount, 3);
    expect(tree.additions, 14);
  });

  // The whole point on a phone: `a/b/c/file.dart` must not cost three taps or
  // three levels of indent.
  test('collapses a single-child directory chain into one row', () {
    final tree = buildDiffTree([file('app/lib/features/diff/diff_screen.dart')]);

    expect(render(tree), [
      'app/lib/features/diff/ +1 -0 n1',
      '  diff_screen.dart +1 -0 n1',
    ]);
    // The row's path is still the real directory, so expansion state keys off
    // something stable.
    expect(tree.children.single.path, 'app/lib/features/diff');
  });

  test('stops collapsing where the tree actually branches', () {
    final tree = buildDiffTree([
      file('a/b/c/one.dart'),
      file('a/b/d/two.dart'),
    ]);

    expect(render(tree), [
      'a/b/ +2 -0 n2',
      '  c/ +1 -0 n1',
      '    one.dart +1 -0 n1',
      '  d/ +1 -0 n1',
      '    two.dart +1 -0 n1',
    ]);
  });

  // A directory holding exactly one FILE keeps its own row — that file's row is
  // where the diff opens, so folding it away would leave nothing to tap.
  test('a directory with one file is not folded into the file', () {
    final tree = buildDiffTree([file('docs/API.md')]);
    expect(render(tree), ['docs/ +1 -0 n1', '  API.md +1 -0 n1']);
  });

  test('directories sort before files, each case-insensitively', () {
    final tree = buildDiffTree([
      file('zeta.md'),
      file('Alpha.md'),
      file('src/x.dart'),
      file('Docs/y.md'),
    ]);

    expect(render(tree).where((l) => !l.startsWith('  ')).toList(), [
      'Docs/ +1 -0 n1',
      'src/ +1 -0 n1',
      'Alpha.md +1 -0 n1',
      'zeta.md +1 -0 n1',
    ]);
  });

  test('an empty change list gives an empty tree, not a crash', () {
    final tree = buildDiffTree(const []);
    expect(tree.children, isEmpty);
    expect(tree.fileCount, 0);
  });
}
