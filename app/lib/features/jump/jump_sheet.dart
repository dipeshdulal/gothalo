import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../data/bridge/bridge_providers.dart';
import '../../data/bridge/models/snapshot.dart';
import '../approvals/approve_action.dart';
import '../inbox/inbox_providers.dart';
import '../inbox/widgets/agent_avatar.dart';

/// Whether a Jump also focuses the pane on the **host** (`pane.focus`) in
/// addition to navigating the phone. Off by default — jumping is a phone-native
/// navigation, host-follow is opt-in. Remembered for the session.
class JumpFollowHost extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

final jumpFollowHostProvider =
    NotifierProvider<JumpFollowHost, bool>(JumpFollowHost.new);

/// The scopes of the Jump switcher's segmented control.
enum _JumpScope { all, needsMe, working }

/// Open the **Jump** quick-switcher — a search-first command palette over every
/// agent across all Herdr sessions. Type to fuzzy-filter (name, title, cwd,
/// workspace/tab), tap to navigate the phone straight to that agent's chat;
/// optionally follow on the host too. [currentPane] marks the agent you're
/// already viewing (its row reads "Current" and just closes the sheet).
Future<void> showJumpSheet(BuildContext context, {String? currentPane}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (_) => _JumpSheet(currentPane: currentPane, navContext: context),
  );
}

class _JumpSheet extends ConsumerStatefulWidget {
  const _JumpSheet({required this.navContext, this.currentPane});

  /// The context of the screen that opened the sheet — used to navigate after
  /// the sheet pops (its own context is defunct by then).
  final BuildContext navContext;
  final String? currentPane;

  @override
  ConsumerState<_JumpSheet> createState() => _JumpSheetState();
}

class _JumpSheetState extends ConsumerState<_JumpSheet> {
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  _JumpScope _scope = _JumpScope.all;
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// Navigate the phone to an agent (and optionally focus it on the host).
  /// Tapping the row you're already on just closes the sheet.
  Future<void> _jumpTo(_JumpItem item) async {
    final a = item.agent;
    if (a.paneId == widget.currentPane) {
      Navigator.of(context).pop();
      return;
    }
    if (ref.read(jumpFollowHostProvider)) {
      final client = ref.read(bridgeClientProvider);
      if (client != null) {
        // Best-effort host focus — never blocks or fails the navigation.
        unawaited(
          client.herdrCommand('pane.focus', {'pane_id': a.paneId}).then(
            (_) {},
            onError: (_) {},
          ),
        );
      }
    }
    Navigator.of(context).pop();
    widget.navContext.push('/transcript/${Uri.encodeComponent(a.paneId)}');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final snap = ref.watch(snapshotControllerProvider).asData?.value;
    final agents = snap?.agents ?? const <Agent>[];

    final wsById = {for (final w in snap?.workspaces ?? const []) w.workspaceId: w};
    final tabById = {for (final t in snap?.tabs ?? const []) t.tabId: t};

    final items = [
      for (final a in agents)
        _JumpItem.from(a, wsById[a.workspaceId], tabById[a.tabId]),
    ];
    final waiting =
        agents.where((a) => a.agentStatus == AgentStatus.blocked).length;

    final scoped = switch (_scope) {
      _JumpScope.all => items,
      _JumpScope.needsMe =>
        items.where((i) => i.agent.agentStatus == AgentStatus.blocked),
      _JumpScope.working =>
        items.where((i) => i.agent.agentStatus == AgentStatus.working),
    };

    final q = _query.trim();
    final results = <_JumpItem>[];
    for (final i in scoped) {
      if (q.isEmpty) {
        i.score = 0;
        results.add(i);
        continue;
      }
      final s = _scoreQuery(q, i.haystack);
      if (s != null) {
        i.score = s;
        results.add(i);
      }
    }
    results.sort((a, b) {
      if (q.isNotEmpty) {
        final c = a.score.compareTo(b.score);
        if (c != 0) return c;
      }
      // The same order the Flock list uses: attention first, then recency —
      // both the bridge's. Jumping is how you get back to the agent you were
      // just in, so the unqueried sheet is exactly the list that ordering is
      // for. It replaces a local `state_change_seq` tiebreak, which stood in
      // for recency before the bridge ranked it: a counter of transitions,
      // where the question is when the agent last did something.
      final r = Agent.byAttentionThenRecency(a.agent, b.agent);
      if (r != 0) return r;
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: FractionallySizedBox(
        heightFactor: 0.92,
        child: Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            _header(scheme, waiting),
            _searchField(scheme),
            _scopeBar(scheme),
            _followRow(scheme),
            const Divider(height: 1),
            Expanded(
              child: results.isEmpty
                  ? _empty(scheme, q)
                  : ListView.separated(
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: results.length,
                      separatorBuilder: (_, _) =>
                          const Divider(height: 1, indent: 64),
                      itemBuilder: (_, i) => _row(results[i]),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(ColorScheme scheme, int waiting) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
      child: Row(
        children: [
          Text('Jump', style: Theme.of(context).textTheme.titleLarge),
          if (waiting > 0) ...[
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: scheme.errorContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '$waiting waiting',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: scheme.error,
                ),
              ),
            ),
          ],
          const Spacer(),
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  /// The opt-in "also focus this pane on the host" toggle, on its own line so a
  /// long label can never crowd the header on a narrow phone.
  Widget _followRow(ColorScheme scheme) {
    final follow = ref.watch(jumpFollowHostProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          const Spacer(),
          FilterChip(
            selected: follow,
            showCheckmark: false,
            visualDensity: VisualDensity.compact,
            avatar: Icon(
              Icons.desktop_windows_outlined,
              size: 16,
              color:
                  follow ? scheme.onSecondaryContainer : scheme.onSurfaceVariant,
            ),
            label: const Text('Follow on host'),
            labelStyle: const TextStyle(fontSize: 12),
            onSelected: (v) => ref.read(jumpFollowHostProvider.notifier).set(v),
          ),
        ],
      ),
    );
  }

  Widget _searchField(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: TextField(
        controller: _search,
        focusNode: _searchFocus,
        autofocus: true,
        textInputAction: TextInputAction.search,
        onChanged: (v) => setState(() => _query = v),
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: scheme.surfaceContainerHighest,
          hintText: 'Search agents, files, workspaces…',
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () {
                    _search.clear();
                    setState(() => _query = '');
                    _searchFocus.requestFocus();
                  },
                ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  Widget _scopeBar(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: SizedBox(
        width: double.infinity,
        child: SegmentedButton<_JumpScope>(
          showSelectedIcon: false,
          style: const ButtonStyle(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          segments: const [
            ButtonSegment(value: _JumpScope.all, label: Text('All')),
            ButtonSegment(value: _JumpScope.needsMe, label: Text('Needs me')),
            ButtonSegment(value: _JumpScope.working, label: Text('Working')),
          ],
          selected: {_scope},
          onSelectionChanged: (s) => setState(() => _scope = s.first),
        ),
      ),
    );
  }

  Widget _row(_JumpItem item) {
    final scheme = Theme.of(context).colorScheme;
    final a = item.agent;
    final isCurrent = a.paneId == widget.currentPane;

    return InkWell(
      onTap: () => _jumpTo(item),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            _AvatarWithDot(agent: a.agent, status: a.agentStatus),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14.5,
                    ),
                  ),
                  if (item.contextLine.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      item.contextLine,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                        fontFamily: AppTheme.monoFamily,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            _trailing(item, isCurrent, scheme),
          ],
        ),
      ),
    );
  }

  Widget _trailing(_JumpItem item, bool isCurrent, ColorScheme scheme) {
    if (isCurrent) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.my_location, size: 13, color: scheme.onPrimaryContainer),
            const SizedBox(width: 4),
            Text(
              'Current',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: scheme.onPrimaryContainer,
              ),
            ),
          ],
        ),
      );
    }
    if (item.agent.agentStatus == AgentStatus.blocked) {
      // Quick-approve without leaving the sheet.
      return FilledButton.tonal(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          minimumSize: const Size(0, 34),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onPressed: () => approveAgent(context, ref, item.agent),
        child: const Text('Approve'),
      );
    }
    return Icon(Icons.chevron_right, color: scheme.onSurfaceVariant);
  }

  Widget _empty(ColorScheme scheme, String q) {
    final (icon, msg) = switch (_scope) {
      _ when q.isNotEmpty => (Icons.search_off, 'No agents match "$q"'),
      _JumpScope.needsMe => (Icons.check_circle_outline, 'Nothing needs you'),
      _JumpScope.working => (Icons.bedtime_outlined, 'No agents working'),
      _JumpScope.all => (Icons.inbox_outlined, 'No agents right now'),
    };
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 44, color: scheme.onSurfaceVariant),
          const SizedBox(height: 10),
          Text(msg, style: TextStyle(color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

/// A precomputed searchable view of one agent: its display title, a compact
/// context line (project · branch · tab · session), and the flattened haystack
/// the fuzzy filter runs over.
class _JumpItem {
  _JumpItem({
    required this.agent,
    required this.title,
    required this.contextLine,
    required this.haystack,
  });

  final Agent agent;
  final String title;
  final String contextLine;
  final String haystack;
  int score = 0;

  factory _JumpItem.from(Agent a, WorkspaceInfo? ws, TabInfo? tab) {
    final git = a.gitContext;
    final wsLabel = ws?.label ?? '';
    final tabLabel = tab?.label ?? '';

    final parts = <String>[];
    if (git.project.isNotEmpty) parts.add(git.project);
    final branch = a.branchName;
    if (branch != null && branch.isNotEmpty) parts.add(branch);
    if (tabLabel.isNotEmpty) {
      parts.add(tabLabel);
    } else if (tab != null && tab.number > 0) {
      parts.add('tab ${tab.number}');
    }
    if (!a.isDefaultSession) parts.add(a.sessionName);

    final hay = [
      a.displayTitle,
      a.agent,
      brandFor(a.agent).label,
      a.cwd,
      git.project,
      git.worktree ?? '',
      wsLabel,
      tabLabel,
      a.paneId,
      a.sessionName,
    ].where((s) => s.isNotEmpty).join(' ');

    return _JumpItem(
      agent: a,
      title: a.displayTitle,
      contextLine: parts.join('  ·  '),
      haystack: hay,
    );
  }
}

/// Score a whitespace-tokenised query against a haystack. Every token must
/// match (substring or in-order subsequence); the summed score ranks results
/// (lower is better). Returns null when any token fails to match.
int? _scoreQuery(String query, String hay) {
  final h = hay.toLowerCase();
  var total = 0;
  for (final tok in query.toLowerCase().split(RegExp(r'\s+'))) {
    if (tok.isEmpty) continue;
    final s = _fuzzyScore(tok, h);
    if (s == null) return null;
    total += s;
  }
  return total;
}

/// Fuzzy score of [q] (already lowercased) within [t] (already lowercased): a
/// substring match scores by position (earlier = better); otherwise an in-order
/// subsequence scores worse, by the total gap it spanned. Null = no match.
int? _fuzzyScore(String q, String t) {
  final idx = t.indexOf(q);
  if (idx >= 0) return idx;
  var ti = 0, gap = 0;
  for (var qi = 0; qi < q.length; qi++) {
    final ch = q.codeUnitAt(qi);
    var found = -1;
    for (var k = ti; k < t.length; k++) {
      if (t.codeUnitAt(k) == ch) {
        found = k;
        break;
      }
    }
    if (found < 0) return null;
    gap += found - ti;
    ti = found + 1;
  }
  return 1000 + gap;
}

/// The agent avatar with a live status dot in the corner — the dot's colour is
/// driven by the snapshot (which is live off `WS /events`), so it updates as the
/// agent's state changes.
class _AvatarWithDot extends StatelessWidget {
  const _AvatarWithDot({required this.agent, required this.status});

  final String agent;
  final AgentStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dot = status.colors(scheme).fg;
    return SizedBox(
      width: 40,
      height: 40,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          AgentAvatar(agent: agent, radius: 18),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: dot,
                shape: BoxShape.circle,
                border: Border.all(color: scheme.surface, width: 2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
