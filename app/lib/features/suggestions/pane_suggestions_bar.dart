import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/bridge/bridge_client.dart';
import '../../data/bridge/models/snapshot.dart';
import '../agents/start_agent_sheet.dart';
import '../inbox/inbox_providers.dart';
import 'suggestions_providers.dart';

/// A single row of context chips for one pane — "Review changes", "Resolve",
/// "Start an agent" — from `GET /suggestions`.
///
/// Deliberately quiet. It occupies **no height at all** when the bridge has
/// nothing to offer, which is most panes most of the time: this is a shortcut
/// past a couple of taps, not a control surface, and a permanently-present
/// empty strip would cost more screen than it ever saves. For the same reason
/// there is no loading state and no error state — a chip that has not arrived
/// yet is indistinguishable from a pane with nothing to suggest, and that is
/// the correct impression in both cases.
///
/// The bridge decides *what* to offer; this decides only how it looks and what
/// tapping it does. A suggestion carrying an action this build does not
/// implement has already been dropped by [BridgeClient.getSuggestions].
class PaneSuggestionsBar extends ConsumerWidget {
  const PaneSuggestionsBar({super.key, required this.pane});

  final String pane;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final suggestions =
        ref.watch(paneSuggestionsProvider(pane)).asData?.value ?? const [];
    if (suggestions.isEmpty) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surfaceContainerHigh,
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: SizedBox(
        height: 34,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: suggestions.length,
          separatorBuilder: (_, _) => const SizedBox(width: 6),
          itemBuilder: (context, i) => _SuggestionChip(
            suggestion: suggestions[i],
            onTap: () => runSuggestion(context, ref, suggestions[i]),
          ),
        ),
      ),
    );
  }
}

/// Perform a suggestion's action.
///
/// Split out of the chip so the mapping from an `action` string to a screen
/// lives in exactly one place: this is the app's half of the contract, and a
/// second copy is how a new action ends up handled in one surface and silently
/// ignored in another.
Future<void> runSuggestion(
  BuildContext context,
  WidgetRef ref,
  PaneSuggestion suggestion,
) async {
  switch (suggestion.action) {
    case 'open_diff':
      context.push('/diff/${Uri.encodeComponent(suggestion.pane)}');
    case 'start_agent':
      await showStartAgentSheet(
        context,
        ref,
        target: StartAgentTarget(
          // The pane already exists and is at its prompt — that is the whole
          // reason the bridge offered this — so the agent is started IN it
          // rather than in a pane we create. An existing pane also keeps its
          // own directory, which is the one the suggestion was reasoning about.
          placement: StartAgentPlacement.existingPane,
          id: suggestion.pane,
          where: _paneLabel(ref, suggestion.pane),
        ),
      );
    // No default: an unknown action never reaches here (the client drops it),
    // and if one ever did, doing nothing beats guessing.
  }
}

/// A human "where this lands" for the start-agent sheet, so a launch is never a
/// blind action. Falls back to the pane id, which is at least unambiguous.
String _paneLabel(WidgetRef ref, String pane) {
  final snap = ref.read(snapshotControllerProvider).asData?.value;
  for (final p in snap?.panes ?? const <Pane>[]) {
    if (p.paneId == pane) {
      final label = p.locationLabel;
      return label.isNotEmpty ? label : pane;
    }
  }
  return pane;
}

/// One suggestion as a compact chip: an icon for the *kind*, the label, and the
/// detail dimmed beside it.
///
/// The detail is on the same line rather than under it because this row sits
/// directly above the keyboard accessory bar — two-line chips would push the
/// terminal itself around every time an agent finished a turn.
class _SuggestionChip extends StatelessWidget {
  const _SuggestionChip({required this.suggestion, required this.onTap});

  final PaneSuggestion suggestion;
  final VoidCallback onTap;

  /// Icons are keyed off the KIND, not the action: `git_conflict` and
  /// `git_dirty` both open the diff, and drawing them identically would throw
  /// away the one glance that tells you which of the two you are looking at.
  IconData get _icon => switch (suggestion.kind) {
    'git_conflict' => Icons.merge_type,
    'git_dirty' => Icons.difference_outlined,
    'shell_idle' => Icons.play_arrow_outlined,
    _ => Icons.bolt,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // A conflict is the one state where a person is actually needed, so it is
    // the one chip allowed to use the error colour. Everything else stays
    // neutral — a row where every chip shouts is a row you stop reading.
    final urgent = suggestion.kind == 'git_conflict';
    return ActionChip(
      avatar: Icon(_icon, size: 15, color: urgent ? scheme.error : null),
      visualDensity: VisualDensity.compact,
      onPressed: onTap,
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            suggestion.label,
            style: TextStyle(color: urgent ? scheme.error : null),
          ),
          if (suggestion.detail.isNotEmpty) ...[
            const SizedBox(width: 6),
            Text(
              suggestion.detail,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
