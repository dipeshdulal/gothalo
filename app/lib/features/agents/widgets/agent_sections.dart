import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme.dart';
import '../../../core/tokens.dart';
import '../../../core/widgets/panel_row.dart';
import '../agent_groups.dart';
import 'agent_row.dart';

/// The agent list, as rows under state headings — **the** agent list.
///
/// Home and the Flock screen show the same agents; before this they showed them
/// two different ways, so the same agent looked like a different thing
/// depending on which screen you had reached it from. This is the one
/// implementation of that list: the headings, their order, the idle compaction
/// and its cap, and the row itself all live here and in [groupAgents].
///
/// It returns a `List<Widget>` rather than a scrollable so each screen can
/// splice it into its own list — home puts Priority, Recent and Servers around
/// it; the Flock tab is nothing but this. Sharing a scrollable would have meant
/// nested scroll views or a common screen neither of them wants.
///
/// [showServer] is false wherever the server is implied — inside one server's
/// flock, and on a home screen with a single bridge paired — so the row does
/// not repeat the same word down the page.
///
/// [selectedKey] marks the row whose pane is open in the desktop shell's detail
/// column, so the master list shows where you are. Null everywhere on a phone.
///
/// [capSections] keeps the phone's row caps and their expanders. Pass false on
/// a surface with the vertical room to show every agent — the desktop list
/// panel — so it never renders a "show N more" for rows it could have shown.
List<Widget> buildAgentSections(
  BuildContext context,
  WidgetRef ref, {
  required List<AgentGroup> groups,
  required bool showServer,
  required void Function(ServerAgentHit hit) onOpen,
  void Function(ServerAgentHit hit)? onApprove,
  bool showActivity = false,
  String? selectedKey,
  bool capSections = true,
}) {
  final scheme = Theme.of(context).colorScheme;
  final expanded = ref.watch(sectionExpandedProvider);
  final sections = ref.read(sectionExpandedProvider.notifier);
  final out = <Widget>[];

  for (final group in groups) {
    // The cap exists to keep a phone section from pushing the next one off the
    // bottom. A surface with the room to spare passes `capSections: false` and
    // shows every row instead — no "show N more", and no "show less" either,
    // because a control that is never hiding anything is just a label taking up
    // space. Cap-to-fit rather than cap-by-count means the split is the full
    // list, which is exactly what `SectionCap` reports as having no overflow.
    final split = capSections
        ? SectionCap.of(
            group.agents,
            expanded: expanded.contains(group.label),
            cap: group.cap,
          )
        : SectionCap.of(
            group.agents,
            expanded: false,
            cap: group.agents.length,
          );
    final isOpen = expanded.contains(group.label);

    out.add(
      SectionLabel(
        group.label,
        color: group.emphasize ? scheme.error : null,
        trailing: _Count(group.agents.length, emphasize: group.emphasize),
      ),
    );

    final expander = split.hasOverflow
        ? SectionExpander(
            hidden: split.hidden,
            expanded: isOpen,
            onToggle: () => sections.toggle(group.label),
          )
        : null;

    if (group.compact) {
      // Idle: dense lines in one shared panel, with the expander drawn inside
      // it. Everything about it says "secondary" — which is the honest
      // description of an agent that wants nothing from you.
      // The idle section is the one that grows and shrinks when its
      // "show more/show less" control is used. Animate the panel's height so
      // the rows below move out of the way instead of jumping, while keeping
      // the content itself dense and otherwise unchanged.
      out.add(
        AnimatedSize(
          duration: Motion.medium,
          reverseDuration: Motion.medium,
          curve: Motion.curve,
          alignment: Alignment.topCenter,
          clipBehavior: Clip.hardEdge,
          child: CompactAgentPanel(
            rows: [
              for (final hit in split.visible)
                AgentRow.compact(
                  agent: hit.agent,
                  serverName: showServer ? hit.server.name : null,
                  onTap: () => onOpen(hit),
                ),
            ],
          ),
        ),
      );
      // Keep the expander outside the idle panel, like Needs you and
      // Working. The list remains one shared panel, while the control has
      // one consistent standalone treatment on every state section.
      if (expander != null) out.add(expander);
      continue;
    }

    for (final hit in split.visible) {
      out.add(
        AgentRow(
          agent: hit.agent,
          serverName: showServer ? hit.server.name : null,
          showActivity: showActivity,
          selected: selectedKey != null && hit.key == selectedKey,
          onApprove: onApprove == null ? null : () => onApprove(hit),
          onTap: () => onOpen(hit),
        ),
      );
    }
    if (expander != null) out.add(expander);
  }

  return out;
}

/// A section header's count, in mono like every other number on the screen.
class _Count extends StatelessWidget {
  const _Count(this.value, {this.emphasize = false});

  final int value;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Text(
      '$value',
      style: TextStyle(
        fontSize: 10.5,
        color: emphasize ? scheme.error : scheme.onSurfaceVariant,
      ).mono,
    );
  }
}
