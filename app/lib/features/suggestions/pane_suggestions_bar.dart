import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/tokens.dart';
import '../../data/bridge/bridge_client.dart';
import '../../data/bridge/models/snapshot.dart';
import '../agents/start_agent_sheet.dart';
import '../inbox/inbox_providers.dart';
import '../pr/create_pr.dart';
import 'suggestions_providers.dart';

/// A single row of context chips for one pane — "Open :5173", "Resolve",
/// "Review changes", "Create PR", "Start an agent" — from `GET /suggestions`.
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
///
/// Chips come in two kinds and the row does not hide the difference: most are
/// things the app does (open a screen, open a URL), but a `performer: "agent"`
/// chip asks the agent in the pane to do something and always opens an editable
/// prompt first. Those carry a trailing "…" so a tap is never mistaken for the
/// action itself.
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
            // A chip that carries BOTH an action and a note has something to
            // explain beyond what it does — today that is a relayed dev server,
            // where the link works but rebinding the server is still the better
            // fix. Long press rather than a second chip: the row must not grow
            // a column of asterisks.
            onLongPress: suggestions[i].note.isNotEmpty &&
                    suggestions[i].action != 'show_note'
                ? () => showSuggestionNote(context, suggestions[i])
                : null,
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
    case 'open_url':
      // Straight to the system browser rather than an in-app WebView. Over a
      // tailnet the phone reaches the dev server directly, so a WebView would
      // add nothing and take away the address bar, devtools, and the tab you
      // want to keep open while you go back to the terminal.
      final opened = await launchUrl(
        Uri.parse(suggestion.url),
        mode: LaunchMode.externalApplication,
      );
      if (!opened && context.mounted) {
        // The URL came from the bridge's own scan, so a refusal here is the
        // phone's (no browser registered for http, an enterprise policy) — say
        // so rather than leaving a tap that visibly did nothing.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open ${suggestion.url}')),
        );
      }
    case 'prompt_agent':
      // The agent-performed branch. Never sends on the tap alone: the sheet
      // shows the bridge-composed text, lets it be edited, and only then puts
      // it in the pane. "Create PR" additionally re-reads the pane's git
      // situation first — it is the one action here that reaches outside the
      // host, so a chip that has gone stale must explain itself rather than
      // push a branch nobody asked for.
      await showAgentPromptSheet(
        context,
        ref,
        suggestion: suggestion,
        agentKind: _agentKind(ref, suggestion.pane),
        preflight: suggestion.kind == 'create_pr'
            ? () => prPreflight(ref, suggestion.pane)
            : null,
      );
    case 'show_note':
      await showSuggestionNote(context, suggestion);
    // No default: an unknown action never reaches here (the client drops it),
    // and if one ever did, doing nothing beats guessing.
  }
}

/// Show a suggestion's [PaneSuggestion.note].
///
/// Reached two ways, which is why it is a function rather than a case: as the
/// whole action of a `show_note` chip, and as the long press on a chip that
/// also does something — a relayed dev server opens, and explains what the
/// relay is doing and how to stop needing it.
Future<void> showSuggestionNote(
  BuildContext context,
  PaneSuggestion suggestion,
) => showDialog<void>(
  context: context,
  builder: (ctx) => AlertDialog(
    title: Text(suggestion.label),
    content: SingleChildScrollView(child: Text(suggestion.note)),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(ctx).pop(),
        child: const Text('OK'),
      ),
    ],
  ),
);

/// The agent kind running in [pane] ("claude"), for a sheet that says who will
/// carry the instruction out. Falls back to the generic word rather than
/// guessing a vendor.
String _agentKind(WidgetRef ref, String pane) {
  final snap = ref.read(snapshotControllerProvider).asData?.value;
  for (final a in snap?.agents ?? const <Agent>[]) {
    if (a.paneId == pane && a.agent.isNotEmpty) return a.agent;
  }
  return 'the agent';
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
  const _SuggestionChip({
    required this.suggestion,
    required this.onTap,
    this.onLongPress,
  });

  final PaneSuggestion suggestion;
  final VoidCallback onTap;

  /// Set when the chip has something to say beyond what it does. Null leaves
  /// the long press unhandled rather than showing an empty dialog.
  final VoidCallback? onLongPress;

  /// Icons are keyed off the KIND, not the action: `git_conflict` and
  /// `git_dirty` both open the diff, and drawing them identically would throw
  /// away the one glance that tells you which of the two you are looking at.
  IconData get _icon => switch (suggestion.kind) {
    'git_conflict' => Icons.merge_type,
    'git_dirty' => Icons.difference_outlined,
    'shell_idle' => Icons.play_arrow_outlined,
    'dev_server' => Icons.open_in_new,
    // Not an error icon: the server is up and working. The only thing wrong
    // with it is where it is bound, and the chip is dimmed rather than red for
    // exactly that reason.
    'dev_server_local' => Icons.lan_outlined,
    'create_pr' => Icons.merge_type,
    _ => Icons.bolt,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // A conflict is the one state where a person is actually needed, so it is
    // the one chip allowed to use the error colour. Everything else stays
    // neutral — a row where every chip shouts is a row you stop reading.
    final urgent = suggestion.kind == 'git_conflict';
    // A localhost-bound dev server is dimmed whether or not the bridge is
    // relaying it. Relayed, the link works but goes through an extra hop and
    // rebinding is still the better fix; unrelayed, it cannot take you anywhere
    // at all. Either way it should not compete with a server the phone reaches
    // directly. Always tappable — the tap either opens it or explains it.
    final dimmed = suggestion.kind == 'dev_server_local';
    final fg = urgent
        ? scheme.error
        : (dimmed ? scheme.onSurfaceVariant : null);
    final chip = InkWell(
      borderRadius: Radii.smAll,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: scheme.panelFill,
          borderRadius: Radii.smAll,
          border: Border.all(color: scheme.hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_icon, size: 15, color: fg),
            const SizedBox(width: 6),
            // The ellipsis marks an agent-performed chip: tapping it opens an
            // editable prompt rather than doing the thing. Cheaper than a second
            // icon, and it reads the way an ellipsis always has on a menu item.
            Text(
              suggestion.byAgent ? '${suggestion.label}…' : suggestion.label,
              style: TextStyle(
                color: fg,
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
              ),
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
      ),
    );
    if (onLongPress == null) return chip;
    // GestureDetector rather than a Chip parameter: wrapping keeps the tap on
    // the chip itself so the ink splash still reads as one control.
    return GestureDetector(onLongPress: onLongPress, child: chip);
  }
}
