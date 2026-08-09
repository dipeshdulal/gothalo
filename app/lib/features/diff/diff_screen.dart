import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../core/widgets/pane_title.dart';
import '../../data/bridge/bridge_client.dart';
import '../../data/bridge/bridge_providers.dart';
import 'diff_model.dart';
import 'diff_palette.dart';
import 'diff_tree.dart';

/// The "Changes" screen — an agent pane's working-tree diff (`GET /diff`),
/// reviewed from the phone instead of dropping to the raw terminal and running
/// `git diff` by hand.
///
/// Two things shape everything below.
///
/// **One lazy list, not nested scrollers.** A real agent diff is hundreds of
/// files and thousands of lines. Every visible thing on this screen — tree
/// rows, diff lines, collapsed-region rows — is flattened into a single
/// `List<_Row>` and fed to one `ListView.builder`, so an expanded 4000-line
/// file costs one cheap descriptor per line and builds only the ~40 rows on
/// screen. A file's diff is also parsed the first time it's opened, never on
/// load, so arriving at a 300-file diff parses nothing at all.
///
/// **Lines wrap; they do not scroll sideways.** The obvious alternative — a
/// horizontally scrollable code block per file, which is what this screen used
/// to do — forces every line of that file to be laid out to measure the widest
/// one, which is exactly the thing that must not happen at this size. Wrapping
/// into the fixed-width gutter reads fine on a phone and keeps the whole screen
/// lazy. See the PR for why side-by-side lost outright.
class DiffScreen extends ConsumerStatefulWidget {
  const DiffScreen({super.key, required this.pane});

  final String pane;

  @override
  ConsumerState<DiffScreen> createState() => _DiffScreenState();
}

/// How many lines one tap on a collapsed region reveals, and the size below
/// which a region is revealed whole instead. A gap smaller than the threshold
/// is almost always the few lines between two edits in the same function —
/// making that two taps would be silly.
const _gapChunk = 25;
const _gapWholeThreshold = 60;

class _DiffScreenState extends ConsumerState<DiffScreen> {
  DiffResult? _result;
  String? _error;
  bool _loading = true;

  DiffTreeNode? _tree;

  /// Directory paths the user has folded shut. Everything starts open: the
  /// tree's job is to show the shape of the change at a glance, and a tree you
  /// have to unfold to read shows nothing.
  final Set<String> _collapsedDirs = {};

  /// File paths whose diff is showing. Files start closed — the list IS the
  /// overview; you open the ones you want to read.
  final Set<String> _openFiles = {};

  /// Parsed diffs, keyed by path. Populated on first open and kept, so
  /// re-opening a file is free.
  final Map<String, FileDiff> _parsed = {};

  /// Extra context lines pulled from `/diff/expand`, per file.
  final Map<String, _FileContext> _context = {};

  bool _treeMode = true;

  /// The flattened render list — rebuilt on every state change, read by the
  /// builder.
  List<_Row> _rows = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final client = ref.read(bridgeClientProvider);
    if (client == null) {
      setState(() {
        _loading = false;
        _error = 'No bridge connection.';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await client.getDiff(widget.pane);
      if (!mounted) return;
      setState(() {
        _result = result;
        _tree = buildDiffTree(result.files);
        _loading = false;
        // A refresh mid-review must not silently show stale hunks, but it also
        // must not throw away where you were: keep which files are open, drop
        // everything derived from the old diff text.
        _parsed.clear();
        _context.clear();
        final paths = result.files.map((f) => f.path).toSet();
        _openFiles.retainAll(paths);
        if (result.files.length == 1) _openFiles.add(result.files.first.path);
      });
      _rebuild();
    } on BridgeException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  /// Rebuilds [_rows] from the current expansion state. O(visible rows) and
  /// nothing else — the expensive work (parsing a diff) happens once per file,
  /// behind [_diffFor].
  void _rebuild() {
    final result = _result;
    if (result == null) {
      setState(() => _rows = const []);
      return;
    }
    final rows = <_Row>[];
    if (_treeMode) {
      for (final child in _tree?.children ?? const <DiffTreeNode>[]) {
        _appendNode(rows, child, 0);
      }
    } else {
      for (final f in result.files) {
        _appendFile(rows, f, 0, showDirectory: true);
      }
    }
    setState(() => _rows = rows);
  }

  void _appendNode(List<_Row> rows, DiffTreeNode node, int depth) {
    if (node.isFile) {
      _appendFile(rows, node.file!, depth, showDirectory: false);
      return;
    }
    final open = !_collapsedDirs.contains(node.path);
    rows.add(_DirRow(node: node, depth: depth, expanded: open));
    if (!open) return;
    for (final child in node.children) {
      _appendNode(rows, child, depth + 1);
    }
  }

  void _appendFile(
    List<_Row> rows,
    DiffFile file,
    int depth, {
    required bool showDirectory,
  }) {
    final open = _openFiles.contains(file.path);
    rows.add(
      _FileRow(
        file: file,
        depth: depth,
        expanded: open,
        showDirectory: showDirectory,
      ),
    );
    if (!open) return;

    final diff = _diffFor(file);
    if (diff.note.isNotEmpty) {
      rows.add(_NoteRow(diff.note));
      return;
    }
    if (diff.isEmpty) {
      rows.add(const _NoteRow('No diff to show.'));
      return;
    }

    final ctx = _context[file.path];
    // Gaps are only offerable where there is a working-tree file to read them
    // out of: a deleted file's content lives in HEAD alone, and an untracked
    // file's synthetic diff already contains the whole file. `unavailable` is
    // the same verdict reached the hard way — see [_FileContext].
    final expandable =
        file.status != 'deleted' &&
        file.status != 'untracked' &&
        !(ctx?.unavailable ?? false);

    var cursor = 1;
    for (final hunk in diff.hunks) {
      if (expandable) {
        _appendGap(
          rows,
          file,
          ctx,
          from: cursor,
          to: hunk.newFirst - 1,
          section: hunk.section,
        );
      }
      for (final line in hunk.lines) {
        rows.add(_LineRow(line));
      }
      cursor = hunk.newLast + 1;
    }
    if (expandable) {
      _appendGap(rows, file, ctx, from: cursor, to: ctx?.total, section: '');
    }
  }

  /// Emits one unchanged region: whatever of it has already been fetched, then
  /// a tappable row for the rest.
  ///
  /// Expansion always proceeds downward from the top of a region, which is what
  /// makes this simple: the fetched lines of any region are always a contiguous
  /// prefix of it, so there is never a hole in the middle to stitch around. It
  /// also matches how you read on a phone — you scroll down, and each tap
  /// continues from where you are.
  void _appendGap(
    List<_Row> rows,
    DiffFile file,
    _FileContext? ctx, {
    required int from,
    required int? to,
    required String section,
  }) {
    var i = from;
    while ((to == null || i <= to) && (ctx?.lines.containsKey(i) ?? false)) {
      rows.add(
        _LineRow(
          DiffLine(
            kind: DiffLineKind.context,
            text: ctx!.lines[i]!,
            oldLine: null,
            newLine: i,
          ),
        ),
      );
      i++;
    }
    if (to != null && i > to) return;
    // `to == null` is the region below the last hunk of a file whose length we
    // haven't learned yet; once any expansion lands, `ctx.total` fills it in.
    if (to == null && (ctx?.eofReached ?? false)) return;
    rows.add(
      _GapRow(
        file: file,
        start: i,
        end: to,
        section: section,
        loading: ctx?.pending.contains(i) ?? false,
      ),
    );
  }

  FileDiff _diffFor(DiffFile file) =>
      _parsed[file.path] ??= FileDiff.parse(file.diff);

  void _toggleDir(String path) {
    if (!_collapsedDirs.remove(path)) _collapsedDirs.add(path);
    _rebuild();
  }

  void _toggleFile(String path) {
    if (!_openFiles.remove(path)) _openFiles.add(path);
    _rebuild();
  }

  /// Folds everything shut, or opens every directory back up. Only ever
  /// collapses open FILES on the way in — "expand all" deliberately does not
  /// open every file's diff, because on a 300-file change that would parse
  /// every diff at once for a view nobody asked for.
  void _toggleAll() {
    final anyOpen = _openFiles.isNotEmpty || _hasExpandedDir();
    setState(() {
      _collapsedDirs.clear();
      if (anyOpen) {
        _openFiles.clear();
        _collectDirPaths(_tree, _collapsedDirs);
      }
    });
    _rebuild();
  }

  bool _hasExpandedDir() {
    final all = <String>{};
    _collectDirPaths(_tree, all);
    return all.any((p) => !_collapsedDirs.contains(p));
  }

  void _collectDirPaths(DiffTreeNode? node, Set<String> out) {
    if (node == null) return;
    for (final child in node.children) {
      if (child.isFile) continue;
      out.add(child.path);
      _collectDirPaths(child, out);
    }
  }

  Future<void> _expandGap(DiffFile file, int start, int? end) async {
    final client = ref.read(bridgeClientProvider);
    if (client == null) return;
    final ctx = _context.putIfAbsent(file.path, _FileContext.new);
    if (!ctx.pending.add(start)) return;
    _rebuild();

    final remaining = end == null ? _gapChunk : end - start + 1;
    final count = remaining <= _gapWholeThreshold ? remaining : _gapChunk;
    try {
      final got = await client.getDiffContext(
        widget.pane,
        path: file.path,
        start: start,
        count: count,
      );
      if (!mounted) return;
      for (var i = 0; i < got.lines.length; i++) {
        ctx.lines[got.start + i] = got.lines[i];
      }
      if (got.total > 0) ctx.total = got.total;
      if (got.eof) ctx.eofReached = true;
    } on BridgeException catch (e) {
      if (!mounted) return;
      // 404 covers every "there is nothing here to expand" answer at once — a
      // bridge too old to have the endpoint, a file that vanished under us, a
      // pane whose agent is gone. Retire the affordance for this file rather
      // than raising an error the user cannot act on: the honest fallback is
      // the three lines of context git gave us, which is what this screen
      // showed before /diff/expand existed. Anything else is a real failure and
      // says so.
      if (e.statusCode == 404) {
        ctx.unavailable = true;
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      ctx.pending.remove(start);
      if (mounted) _rebuild();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final result = _result;
    final subtitle = result != null && result.branch.isNotEmpty
        ? result.branch
        : widget.pane;

    return Scaffold(
      backgroundColor: AppTheme.scaffoldBase(Theme.of(context).brightness),
      appBar: AppBar(
        title: PaneTitle(
          title: 'Changes',
          subtitle: subtitle,
          connLabel: _loading
              ? 'Loading…'
              : (_error != null ? 'Error' : 'Live'),
          connColor: _error != null ? scheme.error : scheme.primary,
        ),
        actions: [
          if ((result?.files.length ?? 0) > 1) ...[
            IconButton(
              tooltip: _treeMode ? 'Flat list' : 'Folder tree',
              icon: Icon(
                _treeMode ? Icons.segment : Icons.account_tree_outlined,
                size: 21,
              ),
              onPressed: () {
                setState(() => _treeMode = !_treeMode);
                _rebuild();
              },
            ),
            IconButton(
              tooltip: 'Collapse / expand all',
              icon: const Icon(Icons.unfold_less, size: 21),
              onPressed: _toggleAll,
            ),
          ],
        ],
      ),
      body: _buildBody(scheme),
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    if (_loading && _result == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _result == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 32, color: scheme.error),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.tonal(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    final files = _result?.files ?? const <DiffFile>[];
    if (files.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(height: MediaQuery.sizeOf(context).height * 0.3),
            Icon(
              Icons.check_circle_outline,
              size: 40,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Center(
              child: Text(
                'No changes',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      );
    }

    final palette = DiffPalette.of(scheme);
    return Column(
      children: [
        _SummaryBar(tree: _tree, palette: palette),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 32),
              itemCount: _rows.length,
              itemBuilder: (context, i) => _buildRow(_rows[i], palette, scheme),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRow(_Row row, DiffPalette palette, ColorScheme scheme) {
    return switch (row) {
      _DirRow r => _DirTile(
        node: r.node,
        depth: r.depth,
        expanded: r.expanded,
        palette: palette,
        onTap: () => _toggleDir(r.node.path),
      ),
      _FileRow r => _FileTile(
        file: r.file,
        depth: r.depth,
        expanded: r.expanded,
        showDirectory: r.showDirectory,
        palette: palette,
        onTap: () => _toggleFile(r.file.path),
      ),
      _LineRow r => _DiffLineTile(line: r.line, palette: palette),
      _GapRow r => _GapTile(
        start: r.start,
        end: r.end,
        section: r.section,
        loading: r.loading,
        palette: palette,
        onTap: () => _expandGap(r.file, r.start, r.end),
      ),
      _NoteRow r => Container(
        color: palette.surface,
        padding: const EdgeInsets.fromLTRB(20, 4, 16, 6),
        child: Text(
          r.text,
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5),
        ),
      ),
    };
  }
}

/// Per-file expansion state for the collapsed unchanged regions.
class _FileContext {
  /// New-side line number -> content, for every line pulled from
  /// `/diff/expand`.
  final Map<int, String> lines = {};

  /// The file's length, learned from the first expansion — until then the
  /// region below the last hunk has no number to show.
  int? total;

  /// Set once an expansion has run off the end of the file, which is what
  /// retires the trailing "show more" row for a file we never learned the
  /// length of.
  bool eofReached = false;

  /// Region starts with a request in flight, so a double-tap doesn't fire two.
  final Set<int> pending = {};

  /// The bridge answered 404 — no `/diff/expand` on this bridge, or nothing at
  /// that path any more. Stop offering the expand rows for this file instead of
  /// letting every one of them fail the same way.
  bool unavailable = false;
}

// ---------------------------------------------------------------------------
// Flattened row descriptors. Cheap value objects: the whole screen is one list
// of these, rebuilt on every expansion change.
// ---------------------------------------------------------------------------

sealed class _Row {
  const _Row();
}

class _DirRow extends _Row {
  const _DirRow({
    required this.node,
    required this.depth,
    required this.expanded,
  });
  final DiffTreeNode node;
  final int depth;
  final bool expanded;
}

class _FileRow extends _Row {
  const _FileRow({
    required this.file,
    required this.depth,
    required this.expanded,
    required this.showDirectory,
  });
  final DiffFile file;
  final int depth;
  final bool expanded;

  /// Flat-list mode shows the directory part of the path, dimmed, ahead of the
  /// filename; the tree doesn't need to (that's what the rows above it say).
  final bool showDirectory;
}

class _LineRow extends _Row {
  const _LineRow(this.line);
  final DiffLine line;
}

class _GapRow extends _Row {
  const _GapRow({
    required this.file,
    required this.start,
    required this.end,
    required this.section,
    required this.loading,
  });
  final DiffFile file;
  final int start;

  /// null for the region below the last hunk before the file's length is known.
  final int? end;
  final String section;
  final bool loading;
}

class _NoteRow extends _Row {
  const _NoteRow(this.text);
  final String text;
}

// ---------------------------------------------------------------------------
// Row widgets
// ---------------------------------------------------------------------------

/// Indentation per tree level. 14px is about as tight as a nested row can get
/// and still read as nested; the chain-collapsing in [buildDiffTree] is what
/// keeps the depth low enough for that to be enough. Capped so a deep tree
/// can't eat the filename.
double _indentFor(int depth) => 12 + 14.0 * (depth > 4 ? 4 : depth);

/// A directory row: fold arrow, name, how many files under it, and the rolled
/// up +/− for the whole subtree.
class _DirTile extends StatelessWidget {
  const _DirTile({
    required this.node,
    required this.depth,
    required this.expanded,
    required this.palette,
    required this.onTap,
  });

  final DiffTreeNode node;
  final int depth;
  final bool expanded;
  final DiffPalette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.fromLTRB(_indentFor(depth), 0, 12, 0),
        child: SizedBox(
          height: 32,
          child: Row(
            children: [
              Icon(
                expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right,
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Icon(
                expanded ? Icons.folder_open_outlined : Icons.folder_outlined,
                size: 16,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _shortenChain(node.name),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.1,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              // The file count only when the directory is shut. Open, the files
              // are right there to be counted, and the row is better spent on
              // the name.
              if (!expanded) ...[
                const SizedBox(width: 8),
                Text(
                  '${node.fileCount} file${node.fileCount == 1 ? '' : 's'}',
                  style: TextStyle(
                    fontSize: 10.5,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.85),
                  ),
                ),
              ],
              const SizedBox(width: 8),
              _CountBadge(
                additions: node.additions,
                deletions: node.deletions,
                palette: palette,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Trims a collapsed directory chain from the FRONT when it's long. The tail
/// (`…/features/diff`) is the part that identifies the directory; end-clipping
/// a chain leaves you reading `app/lib/featur…`, which identifies nothing.
String _shortenChain(String name) {
  if (name.length <= 30) return name;
  final parts = name.split('/');
  if (parts.length <= 2) return name;
  return '…/${parts.sublist(parts.length - 2).join('/')}';
}

/// A file row: status icon, name (with the directory dimmed in flat mode), its
/// +/− counts, and a fold arrow for the diff below it.
class _FileTile extends StatelessWidget {
  const _FileTile({
    required this.file,
    required this.depth,
    required this.expanded,
    required this.showDirectory,
    required this.palette,
    required this.onTap,
  });

  final DiffFile file;
  final int depth;
  final bool expanded;
  final bool showDirectory;
  final DiffPalette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color) = DiffPalette.statusVisual(file.status, scheme);
    final slash = file.path.lastIndexOf('/');
    final dir = showDirectory && slash > 0
        ? _elideDirectory(file.path.substring(0, slash + 1))
        : '';
    final name = file.path.substring(slash + 1);

    return InkWell(
      onTap: onTap,
      child: Container(
        color: expanded
            ? scheme.onSurface.withValues(alpha: 0.04)
            : Colors.transparent,
        padding: EdgeInsets.fromLTRB(_indentFor(depth), 0, 12, 0),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 36),
          child: Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      TextSpan(
                        children: [
                          if (dir.isNotEmpty)
                            TextSpan(
                              text: dir,
                              style: TextStyle(
                                color: scheme.onSurfaceVariant.withValues(
                                  alpha: 0.75,
                                ),
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                          TextSpan(text: name),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: AppTheme.monoFamily,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        color: scheme.onSurface,
                      ),
                    ),
                    if (file.oldPath != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Text(
                          'from ${file.oldPath}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: AppTheme.monoFamily,
                            fontSize: 10.5,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _CountBadge(
                additions: file.additions,
                deletions: file.deletions,
                palette: palette,
              ),
              const SizedBox(width: 2),
              Icon(
                expanded ? Icons.expand_less : Icons.expand_more,
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Squeezes a long directory prefix in the flat list so the FILENAME survives.
/// End-ellipsis would eat the name instead — `app/lib/features/diff/diff_scre…`
/// tells you nothing, `app/…/diff/diff_screen.dart` tells you everything that
/// fits.
String _elideDirectory(String dir) {
  if (dir.length <= 18) return dir;
  final parts = dir.split('/').where((p) => p.isNotEmpty).toList();
  if (parts.length <= 2) return dir;
  return '${parts.first}/…/${parts.last}/';
}

/// `+12 −3`, in the diff palette's greens/reds so the counts match the lines
/// they're counting.
class _CountBadge extends StatelessWidget {
  const _CountBadge({
    required this.additions,
    required this.deletions,
    required this.palette,
  });

  final int additions;
  final int deletions;
  final DiffPalette palette;

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
      fontSize: 11.5,
      fontWeight: FontWeight.w600,
      fontFeatures: [FontFeature.tabularFigures()],
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (additions > 0)
          Text('+$additions', style: style.copyWith(color: palette.addFg)),
        if (additions > 0 && deletions > 0) const SizedBox(width: 5),
        if (deletions > 0)
          // A true minus sign, not a hyphen: at 11.5px a hyphen next to a "+"
          // reads as a dash rather than as the other half of a pair.
          Text('−$deletions', style: style.copyWith(color: palette.delFg)),
      ],
    );
  }
}

/// One line of a diff.
///
/// Wrapped in [ExcludeSemantics] on purpose: a screenful of code is thousands
/// of semantics nodes carrying nothing a screen reader can use, and this same
/// screen has a history of a Flutter semantics assertion
/// (`!semantics.parentDataDirty`) blanking itself over the diff body. The
/// interactive parts of the screen — every tree row and every expand row — keep
/// their semantics.
class _DiffLineTile extends StatelessWidget {
  const _DiffLineTile({required this.line, required this.palette});

  final DiffLine line;
  final DiffPalette palette;

  @override
  Widget build(BuildContext context) {
    final (bg, wordBg, sign, signColor) = switch (line.kind) {
      DiffLineKind.addition => (
        palette.addBg,
        palette.addWordBg,
        '+',
        palette.addFg,
      ),
      DiffLineKind.deletion => (
        palette.delBg,
        palette.delWordBg,
        '−',
        palette.delFg,
      ),
      DiffLineKind.context => (
        Colors.transparent,
        Colors.transparent,
        ' ',
        palette.gutterFg,
      ),
    };
    final number = line.kind == DiffLineKind.deletion
        ? line.oldLine
        : line.newLine;

    const code = TextStyle(
      fontFamily: AppTheme.monoFamily,
      fontSize: 11.5,
      height: 1.35,
    );

    return ExcludeSemantics(
      child: Container(
        color: palette.surface,
        child: Container(
          color: bg,
          padding: EdgeInsets.zero,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 38,
                child: Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Text(
                    number?.toString() ?? '',
                    textAlign: TextAlign.right,
                    style: code.copyWith(
                      fontSize: 10,
                      color: palette.gutterFg,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: 11,
                child: Text(
                  sign,
                  style: code.copyWith(
                    color: signColor,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Text.rich(
                    _content(wordBg),
                    style: code.copyWith(color: palette.codeFg),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The line's text, with the intra-line changed runs given the stronger fill.
  /// A line with no word diff (unpaired, or too dissimilar for the highlight to
  /// mean anything) renders as one plain span.
  InlineSpan _content(Color wordBg) {
    final spans = line.spans;
    if (spans == null || spans.isEmpty) {
      return TextSpan(text: _expandTabs(line.text));
    }
    return TextSpan(
      children: [
        for (final s in spans)
          TextSpan(
            text: _expandTabs(s.text),
            style: s.changed ? TextStyle(backgroundColor: wordBg) : null,
          ),
      ],
    );
  }
}

/// Tabs render as a zero-ish-width box in Flutter's text layout, which turns
/// tab-indented code (i.e. all of the Go in this repo) into a left-aligned
/// mush. Two spaces per tab, because indentation depth still has to be visible
/// at 45 columns.
String _expandTabs(String s) => s.contains('\t') ? s.replaceAll('\t', '  ') : s;

/// A collapsed unchanged region: how many lines are hidden, where in the file
/// you are, and one tap to pull them in.
class _GapTile extends StatelessWidget {
  const _GapTile({
    required this.start,
    required this.end,
    required this.section,
    required this.loading,
    required this.palette,
    required this.onTap,
  });

  final int start;
  final int? end;
  final String section;
  final bool loading;
  final DiffPalette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final remaining = end == null ? null : end! - start + 1;
    final label = switch (remaining) {
      null => 'Show more lines',
      final n when n <= _gapWholeThreshold =>
        'Show $n unchanged line${n == 1 ? '' : 's'}',
      final n => 'Show $_gapChunk of $n unchanged lines',
    };

    return Container(
      color: palette.surface,
      child: InkWell(
        onTap: loading ? null : onTap,
        child: Container(
          color: palette.gapBg,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
          child: SizedBox(
            height: 32,
            child: Row(
              children: [
                SizedBox(
                  width: 20,
                  child: loading
                      ? const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 1.6),
                        )
                      : Icon(
                          Icons.unfold_more,
                          size: 15,
                          color: palette.gapFg,
                        ),
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    color: palette.gapFg,
                  ),
                ),
                if (section.isNotEmpty) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      section,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontFamily: AppTheme.monoFamily,
                        fontSize: 10.5,
                        color: palette.gapFg.withValues(alpha: 0.75),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The one-line "what am I looking at" bar above the tree: how many files, the
/// totals, and a proportional bar so the balance of the change registers before
/// you've read either number.
class _SummaryBar extends StatelessWidget {
  const _SummaryBar({required this.tree, required this.palette});

  final DiffTreeNode? tree;
  final DiffPalette palette;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final files = tree?.fileCount ?? 0;
    final adds = tree?.additions ?? 0;
    final dels = tree?.deletions ?? 0;
    final total = adds + dels;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
      ),
      child: Row(
        children: [
          Text(
            '$files file${files == 1 ? '' : 's'}',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 10),
          if (total > 0)
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: SizedBox(
                  height: 4,
                  child: Row(
                    // Without this the bars are laid out with a loose vertical
                    // constraint and a childless ColoredBox collapses to zero
                    // height — a bar that is present in the tree and invisible
                    // on screen.
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        flex: adds == 0 ? 0 : adds,
                        child: ColoredBox(color: palette.addFg),
                      ),
                      Expanded(
                        flex: dels == 0 ? 0 : dels,
                        child: ColoredBox(color: palette.delFg),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else
            const Spacer(),
          const SizedBox(width: 10),
          _CountBadge(additions: adds, deletions: dels, palette: palette),
        ],
      ),
    );
  }
}
