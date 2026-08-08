/// The changed-file tree for the Changes screen — pure Dart, built from the
/// `files[]` the bridge already returns, so no contract change and no second
/// source of truth about what changed.
///
/// A flat list of paths is fine on a laptop and hostile on a phone: forty rows
/// of `app/lib/features/diff/…` all truncate to the same visible prefix. The
/// tree groups by directory and rolls the +/- counts up, so the top of the
/// screen answers "which parts of the repo did the agent touch" before you read
/// a single line of diff.
library;

import '../../data/bridge/bridge_client.dart';

/// One node of the changed-file tree: a directory (with [children]) or a file
/// (with [file] set).
class DiffTreeNode {
  DiffTreeNode({
    required this.name,
    required this.path,
    required this.children,
    this.file,
    required this.additions,
    required this.deletions,
    required this.fileCount,
  });

  /// What the row shows. For a collapsed chain this is the whole run —
  /// `internal/server`, not `internal` — which is the point: see below.
  final String name;

  /// Full repo-relative path, and the stable key for expansion state.
  final String path;

  final List<DiffTreeNode> children;

  /// Set on a file node only.
  final DiffFile? file;

  /// Rolled up over the subtree (the file's own counts on a file node).
  final int additions;
  final int deletions;
  final int fileCount;

  bool get isFile => file != null;
}

/// Builds the tree for [files]. The root is a synthetic node that is never
/// rendered — its [children] are the top level.
///
/// Directories sort before files and each group sorts case-insensitively by
/// name; the flat list keeps git's own order, this one needs to be stable
/// across refreshes so rows don't jump under your thumb while an agent works.
DiffTreeNode buildDiffTree(List<DiffFile> files) {
  final root = _Dir();
  for (final f in files) {
    final parts = f.path.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) continue;
    var dir = root;
    for (var i = 0; i < parts.length - 1; i++) {
      dir = dir.dirs.putIfAbsent(parts[i], _Dir.new);
    }
    dir.files.add(f);
  }
  final children = _childrenOf(root, '');
  return DiffTreeNode(
    name: '',
    path: '',
    children: children,
    additions: children.fold(0, (s, c) => s + c.additions),
    deletions: children.fold(0, (s, c) => s + c.deletions),
    fileCount: children.fold(0, (s, c) => s + c.fileCount),
  );
}

/// A mutable trie node, only alive while building.
class _Dir {
  final Map<String, _Dir> dirs = {};
  final List<DiffFile> files = [];
}

List<DiffTreeNode> _childrenOf(_Dir dir, String prefix) {
  final out = <DiffTreeNode>[];

  final names = dir.dirs.keys.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  for (final name in names) {
    out.add(_collapse(_dirNode(dir.dirs[name]!, name, _join(prefix, name))));
  }

  final files = [...dir.files]
    ..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
  for (final f in files) {
    out.add(
      DiffTreeNode(
        name: f.path.split('/').last,
        path: f.path,
        children: const [],
        file: f,
        additions: f.additions,
        deletions: f.deletions,
        fileCount: 1,
      ),
    );
  }
  return out;
}

DiffTreeNode _dirNode(_Dir dir, String name, String path) {
  final children = _childrenOf(dir, path);
  return DiffTreeNode(
    name: name,
    path: path,
    children: children,
    additions: children.fold(0, (s, c) => s + c.additions),
    deletions: children.fold(0, (s, c) => s + c.deletions),
    fileCount: children.fold(0, (s, c) => s + c.fileCount),
  );
}

/// Folds a single-child directory chain into one row: `a/b/c/file.dart` costs
/// one tap on `a/b/c`, not three on `a`, `b`, `c`.
///
/// It also buys back indentation, which is the scarcest thing on a phone —
/// every level skipped is ~14px of width that goes to the filename instead.
/// The chain is only folded while each directory has exactly one child AND that
/// child is itself a directory: a directory holding one file still gets its own
/// row, because that file's row is where the diff opens.
DiffTreeNode _collapse(DiffTreeNode node) {
  var current = node;
  var name = node.name;
  while (current.children.length == 1 && !current.children.first.isFile) {
    final only = current.children.first;
    name = '$name/${only.name}';
    current = only;
  }
  if (identical(current, node)) return node;
  return DiffTreeNode(
    name: name,
    path: current.path,
    children: current.children,
    additions: current.additions,
    deletions: current.deletions,
    fileCount: current.fileCount,
  );
}

String _join(String prefix, String name) =>
    prefix.isEmpty ? name : '$prefix/$name';
