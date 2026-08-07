import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/bridge/bridge_client.dart';
import '../inbox/widgets/agent_avatar.dart';

/// The "which agent" control, shared by every surface that launches one — the
/// start-agent sheet and the new-worktree sheet.
///
/// It is one widget rather than a copy per sheet because the rules around this
/// list are the interesting part and must not drift: the kinds come from the
/// bridge (`GET /agents/available`), never from a list written here, and a kind
/// Herdr cannot classify carries a warning. A second, hand-copied picker is
/// exactly where a hardcoded fallback list or a dropped warning would appear.

/// The kind picker plus the three non-answers the bridge can give — still
/// loading, could not be asked, and "this host has none installed" — each of
/// which is a different sentence to the operator.
class AgentKindField extends StatelessWidget {
  const AgentKindField({
    super.key,
    required this.agents,
    required this.selected,
    required this.onSelect,
  });

  /// `availableAgentsProvider`'s value, passed in so the caller owns the watch.
  final AsyncValue<List<AvailableAgent>> agents;
  final String? selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return agents.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: LinearProgressIndicator(),
      ),
      error: (err, _) => SheetNotice(
        icon: Icons.error_outline,
        text: err is BridgeException
            ? err.message
            : 'Could not ask the server which agents it has.',
      ),
      data: (list) => list.isEmpty
          ? const SheetNotice(
              icon: Icons.info_outline,
              text: 'This server reports no installed agents. Install one on '
                  "the host (or make sure it is on the bridge daemon's PATH) "
                  'and pull to refresh.',
            )
          : AgentKindPicker(
              agents: list,
              selected: selected,
              onSelect: onSelect,
            ),
    );
  }
}

/// The installed agents as selectable chips, in the order the bridge reported
/// them (Herdr's own order), so the picker doesn't reshuffle between opens.
class AgentKindPicker extends StatelessWidget {
  const AgentKindPicker({
    super.key,
    required this.agents,
    required this.selected,
    required this.onSelect,
  });

  final List<AvailableAgent> agents;
  final String? selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final chosen = agents.where((a) => a.kind == selected).firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final a in agents)
              ChoiceChip(
                selected: a.kind == selected,
                onSelected: (_) => onSelect(a.kind),
                avatar: AgentAvatar(agent: a.kind, radius: 11),
                label: Text(a.kind),
              ),
          ],
        ),
        // Only surfaced once a kind is chosen, and only when it matters: an
        // agent Herdr has no detection manifest for will run but can never be
        // reported idle/working/blocked, so it will sit at "unknown" forever and
        // never raise an approval push. Better said before the launch.
        if (chosen != null && !chosen.stateReporting) ...[
          const SizedBox(height: 10),
          SheetNotice(
            icon: Icons.warning_amber_rounded,
            color: scheme.error,
            text: '${chosen.kind} runs, but this server cannot read its '
                'status — it will show as unknown and will not notify you when '
                'it needs input.',
          ),
        ],
      ],
    );
  }
}

/// A muted icon+text line for a launch sheet's inline explanations.
class SheetNotice extends StatelessWidget {
  const SheetNotice({
    super.key,
    required this.icon,
    required this.text,
    this.color,
  });

  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = color ?? scheme.onSurfaceVariant;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: tint),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: tint, height: 1.35),
          ),
        ),
      ],
    );
  }
}
