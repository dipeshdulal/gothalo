import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../core/widgets/pane_title.dart';
import '../../data/bridge/bridge_client.dart';
import '../../data/bridge/bridge_providers.dart';

/// The "Changes" screen — an agent pane's working-tree diff (`GET /diff`),
/// reviewed from the phone instead of dropping to the raw terminal and
/// running `git diff` by hand. The #1-ranked idea from the app's feature
/// research (docs/RESEARCH-feature-ideas.md): every comparable app (Moshi,
/// Omnara, Orca) makes "review what the agent changed" a headline feature;
/// gothalo only ever showed tool-call diffs inline in the transcript.
class DiffScreen extends ConsumerStatefulWidget {
  const DiffScreen({super.key, required this.pane});

  final String pane;

  @override
  ConsumerState<DiffScreen> createState() => _DiffScreenState();
}

class _DiffScreenState extends ConsumerState<DiffScreen> {
  DiffResult? _result;
  String? _error;
  bool _loading = true;

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
        _loading = false;
      });
    } on BridgeException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
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
      appBar: AppBar(
        titleSpacing: 12,
        title: PaneTitle(
          title: 'Changes',
          subtitle: subtitle,
          connLabel: _loading ? 'Loading…' : (_error != null ? 'Error' : 'Live'),
          connColor: _error != null ? scheme.error : scheme.primary,
        ),
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
    final files = _result?.files ?? const [];
    if (files.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(height: MediaQuery.sizeOf(context).height * 0.3),
            Icon(Icons.check_circle_outline, size: 40, color: scheme.onSurfaceVariant),
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
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: files.length,
        itemBuilder: (context, i) => _FileSection(file: files[i]),
      ),
    );
  }
}

/// One changed file: a summary row (status, path, +/- counts) that expands to
/// its unified diff. Collapsed by default — a tree with a dozen files
/// shouldn't dump every diff on screen at once.
class _FileSection extends StatelessWidget {
  const _FileSection({required this.file});
  final DiffFile file;

  (IconData, Color) _statusVisual(ColorScheme scheme) => switch (file.status) {
        'added' => (Icons.add_circle_outline, const Color(0xFF00C853)),
        'deleted' => (Icons.remove_circle_outline, scheme.error),
        'renamed' => (Icons.drive_file_rename_outline, scheme.primary),
        'untracked' => (Icons.fiber_new_outlined, scheme.primary),
        _ => (Icons.edit_outlined, const Color(0xFF448AFF)),
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color) = _statusVisual(scheme);
    final subtitle = file.oldPath != null ? 'from ${file.oldPath}' : null;

    return Theme(
      // Kill the divider ExpansionTile draws by default — the outer
      // ListView's own spacing is enough.
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        leading: Icon(icon, size: 20, color: color),
        title: Text(
          file.path,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontFamily: AppTheme.monoFamily,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
        subtitle: subtitle != null
            ? Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: AppTheme.monoFamily,
                  fontSize: 11,
                  color: scheme.onSurfaceVariant,
                ),
              )
            : null,
        trailing: _CountBadge(additions: file.additions, deletions: file.deletions),
        children: [
          if (file.diff.isNotEmpty)
            _DiffBody(diff: file.diff)
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                'No diff to show.',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5),
              ),
            ),
        ],
      ),
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.additions, required this.deletions});
  final int additions;
  final int deletions;

  @override
  Widget build(BuildContext context) {
    const green = Color(0xFF00C853);
    final red = Theme.of(context).colorScheme.error;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (additions > 0)
          Text('+$additions',
              style: const TextStyle(
                  color: green, fontSize: 12, fontWeight: FontWeight.w600)),
        if (additions > 0 && deletions > 0) const SizedBox(width: 4),
        if (deletions > 0)
          Text('-$deletions',
              style: TextStyle(
                  color: red, fontSize: 12, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

/// The unified diff itself — one line per row, colored by prefix, in a
/// horizontally scrollable monospace block so long source lines don't wrap
/// into an unreadable staircase.
class _DiffBody extends StatelessWidget {
  const _DiffBody({required this.diff});
  final String diff;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lines = diff.split('\n');
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final line in lines) _DiffLine(line: line),
          ],
        ),
      ),
    );
  }
}

class _DiffLine extends StatelessWidget {
  const _DiffLine({required this.line});
  final String line;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const green = Color(0xFF00C853);
    final (Color? bg, Color fg) = switch (line) {
      _ when line.startsWith('+++') || line.startsWith('---') =>
        (null, scheme.onSurfaceVariant),
      _ when line.startsWith('+') =>
        (green.withValues(alpha: 0.12), green),
      _ when line.startsWith('-') =>
        (scheme.error.withValues(alpha: 0.12), scheme.error),
      _ when line.startsWith('@@') =>
        (scheme.primary.withValues(alpha: 0.1), scheme.primary),
      _ when line.startsWith('diff --git') ||
          line.startsWith('index ') ||
          line.startsWith('similarity index') ||
          line.startsWith('rename ') =>
        (null, scheme.onSurfaceVariant),
      _ => (null, scheme.onSurface),
    };
    return Container(
      width: double.infinity,
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
      child: Text(
        line.isEmpty ? ' ' : line,
        style: TextStyle(
          fontFamily: AppTheme.monoFamily,
          fontSize: 12,
          height: 1.4,
          color: fg,
        ),
      ),
    );
  }
}
