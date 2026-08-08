import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../core/tokens.dart';
import '../../core/widgets/action_chip.dart';
import '../agents/widgets/agent_row.dart';
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
    // No shape override: the theme's bottomSheetTheme owns the radius, and the
    // literal 18 that was here disagreed with it.
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
            _controls(scheme),
            const SizedBox(height: Space.sm),
            Expanded(
              child: results.isEmpty
                  ? _empty(scheme, q)
                  : ListView.builder(
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: const EdgeInsets.symmetric(vertical: Space.sm),
                      itemCount: results.length,
                      // No separators: each row is a panel held by its own
                      // hairline, like every other agent list in the app.
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

  /// The filters, plus the opt-in "also focus this pane on the host" toggle —
  /// one scrollable line of the app's own chips.
  ///
  /// The filters were a Material `SegmentedButton` (an outlined pill with a
  /// filled selection) and Follow was an outlined `FilterChip`: two Material
  /// components in a sheet where everything else is a flat hairline-edged chip.
  /// They are the shared [AppActionChip] now, selection marked by an accent
  /// edge rather than a fill, so colour stays on status. Follow sits after the
  /// filters and reads as what it is — a mode, not a fourth filter — because it
  /// keeps its own glyph.
  Widget _controls(ColorScheme scheme) {
    final follow = ref.watch(jumpFollowHostProvider);
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Space.xl),
        children: [
          for (final (scope, label) in const [
            (_JumpScope.all, 'All'),
            (_JumpScope.needsMe, 'Needs me'),
            (_JumpScope.working, 'Working'),
          ]) ...[
            Center(
              child: _SelectableChip(
                label: label,
                selected: _scope == scope,
                onTap: () => setState(() => _scope = scope),
              ),
            ),
            const SizedBox(width: Space.sm),
          ],
          const SizedBox(width: Space.md),
          Center(
            child: _SelectableChip(
              icon: Icons.desktop_windows_outlined,
              label: 'Follow on host',
              selected: follow,
              onTap: () =>
                  ref.read(jumpFollowHostProvider.notifier).set(!follow),
            ),
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
        // **Not autofocused.** Opening the sheet used to raise the keyboard
        // immediately, which covers about half the screen and left three and a
        // half results visible. Jump is mostly for *scanning* — you open it to
        // see what is there and tap one — so it opens with the list at full
        // height. Tapping the field is how you get the keyboard.
        autofocus: false,
        textInputAction: TextInputAction.search,
        onChanged: (v) => setState(() => _query = v),
        style: const TextStyle(fontSize: 14),
        // The composer's treatment: a flat panel fill inside a hairline, the
        // accent only on focus. It was a heavy mint-accented rounded box, which
        // is the one input style in the app that had not been converted.
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: scheme.panelFill,
          hintText: 'Search agents, files, projects…',
          hintStyle: TextStyle(color: scheme.onSurfaceVariant, fontSize: 14),
          prefixIcon: Icon(
            Icons.search,
            size: 18,
            color: scheme.onSurfaceVariant,
          ),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear, size: 16),
                  onPressed: () {
                    _search.clear();
                    setState(() => _query = '');
                  },
                ),
          border: OutlineInputBorder(
            borderRadius: Radii.mdAll,
            borderSide: BorderSide(color: scheme.hairline),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: Radii.mdAll,
            borderSide: BorderSide(color: scheme.hairline),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: Radii.mdAll,
            borderSide: BorderSide(color: scheme.primary),
          ),
        ),
      ),
    );
  }

  /// One result — the shared [AgentRow], not a fifth agent row.
  ///
  /// This was the last screen carrying its own: an avatar with an overlaid
  /// status dot, a trailing chevron, no status mark, and a context line that
  /// truncated to a bare "· 1". Jump's own additions ride as flags: the
  /// [AgentRow.trailing] slot marks the agent you are already in, and a blocked
  /// agent keeps the quick-approve it always had.
  Widget _row(_JumpItem item) {
    final a = item.agent;
    final isCurrent = a.paneId == widget.currentPane;
    return AgentRow(
      agent: a,
      onTap: () => _jumpTo(item),
      trailing: isCurrent ? const _CurrentMark() : null,
      onApprove: isCurrent ? null : () => approveAgent(context, ref, a),
    );
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
    // A tab the user has *named* is a name they chose, so it earns a place on
    // the context line. An unnamed one used to fall back to "tab 3", which named
    // Herdr's container rather than anything about the agent — dropped, not
    // renamed: there is nothing to say there.
    if (tabLabel.isNotEmpty) parts.add(tabLabel);
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



/// "You are already here" — the marker on the row for [_JumpSheet.currentPane].
///
/// A small mono tag in the [AgentRow.trailing] slot rather than a filled
/// primary-container pill, which was the last stadium shape in this sheet.
class _CurrentMark extends StatelessWidget {
  const _CurrentMark();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.my_location, size: 12, color: scheme.primary),
        const SizedBox(width: 4),
        Text(
          'HERE',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
            color: scheme.primary,
          ).mono,
        ),
      ],
    );
  }
}

/// A chip that is on or off, for Jump's filters and its host-follow toggle.
///
/// [AppActionChip] with a selected state: the accent goes on the edge and the
/// label, never the fill, so colour still means status everywhere else.
class _SelectableChip extends StatelessWidget {
  const _SelectableChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (!selected) {
      return AppActionChip(
        icon: icon ?? Icons.filter_list,
        label: label,
        onTap: onTap,
      );
    }
    return Material(
      type: MaterialType.transparency,
      borderRadius: Radii.smAll,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 32),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: scheme.panelFillRaised,
            borderRadius: Radii.smAll,
            border: Border.all(color: scheme.primary),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon ?? Icons.check, size: 15, color: scheme.primary),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: scheme.primary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
