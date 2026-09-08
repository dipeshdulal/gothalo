import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../core/tokens.dart';
import '../../core/widgets/action_chip.dart';
import '../../data/bridge/bridge_client.dart';
import '../../data/bridge/bridge_providers.dart';
import 'agent_kind_picker.dart';
import 'agent_lifecycle_providers.dart';
import '../inbox/inbox_providers.dart';
import '../overview/overview_screen.dart' show spaceCwdOf;
import '../recents/recent_providers.dart';
import '../recents/record_open.dart';

/// Where a new agent should be put. The bridge accepts three targeting forms
/// and this is the app's name for them, so the sheet renders the right fields
/// (an existing pane keeps its own directory and must not be offered one).
enum StartAgentPlacement {
  /// A new tab in a workspace — the "start a task in this project" case.
  newTab,

  /// A new pane split off an existing one, staying in the same tab.
  splitPane,

  /// An existing idle shell pane, reused in place.
  existingPane,
}

/// The launch site handed to [showStartAgentSheet].
class StartAgentTarget {
  const StartAgentTarget({
    required this.placement,
    required this.id,
    required this.where,
    this.defaultCwd = '',
  });

  final StartAgentPlacement placement;

  /// The workspace id for [StartAgentPlacement.newTab], the pane id otherwise.
  final String id;

  /// Human "where this lands", shown so a launch is never a blind action.
  final String where;

  /// Pre-filled working directory. Ignored for [StartAgentPlacement.existingPane],
  /// which inherits its pane's shell directory.
  final String defaultCwd;

  bool get takesCwd => placement != StartAgentPlacement.existingPane;
}

/// Ask for an agent kind, a working directory and an optional opening prompt,
/// then start it and navigate to the new agent's chat.
///
/// The kind list is fetched from the bridge, never assembled here — a kind that
/// isn't installed on that host cannot be offered, because picking it would
/// produce a 30-second startup timeout and an empty pane. A host with nothing
/// installed gets an explanation rather than an empty picker.
Future<void> showStartAgentSheet(
  BuildContext context,
  WidgetRef ref, {
  required StartAgentTarget target,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => Padding(
      // Lift the sheet clear of the keyboard: both text fields are near the
      // bottom and the prompt field is multi-line.
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: _StartAgentSheet(target: target),
    ),
  );
}

class _StartAgentSheet extends ConsumerStatefulWidget {
  const _StartAgentSheet({required this.target});

  final StartAgentTarget target;

  @override
  ConsumerState<_StartAgentSheet> createState() => _StartAgentSheetState();
}

class _StartAgentSheetState extends ConsumerState<_StartAgentSheet> {
  late final TextEditingController _cwd =
      TextEditingController(text: widget.target.defaultCwd);
  late final TextEditingController _prompt = TextEditingController();

  String? _kind;
  bool _starting = false;

  /// Enough to cover "somewhere I was just working" without turning a launch
  /// sheet into a directory browser; Open a project already exists for that.
  static const _recentDirLimit = 6;

  @override
  void dispose() {
    _cwd.dispose();
    _prompt.dispose();
    super.dispose();
  }

  /// Directories of the projects this device was recently in, on the server
  /// being launched against, most recent first.
  ///
  /// Recents span every server; a path only means anything on the host that has
  /// it. Undatable or duplicate paths are dropped rather than shown twice — two
  /// workspaces open on one checkout is ordinary.
  List<String> _recentDirs() {
    final snap = ref.watch(snapshotControllerProvider).asData?.value;
    if (snap == null) return const [];
    final out = <String>[];
    for (final hit in ref.watch(recentSpaceHitsProvider)) {
      if (!hit.server.isActive) continue;
      final panes =
          snap.panes.where((p) => p.workspaceId == hit.workspaceId).toList();
      final cwd = spaceCwdOf(hit.workspace, panes);
      if (cwd.isEmpty || out.contains(cwd)) continue;
      out.add(cwd);
      if (out.length == _recentDirLimit) break;
    }
    return out;
  }

  void _useDir(String dir) => _cwd.value = TextEditingValue(
        text: dir,
        selection: TextSelection.collapsed(offset: dir.length),
      );

  /// The last path segment, which is what tells these apart at a glance. The
  /// whole path is still one tap away in the field above, and in the tooltip.
  static String _dirLabel(String dir) {
    final parts = dir.split('/').where((p) => p.isNotEmpty).toList();
    return parts.isEmpty ? dir : parts.last;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final agents = ref.watch(availableAgentsProvider);
    // What the picker opens on: what you last started, else the first agent
    // this server has. Never nothing while a launchable agent exists — an empty
    // picker makes every launch start with a tap that carries no information.
    // The memory only counts if this server still has that kind; the installed
    // list stays the only thing that may be offered.
    final remembered = ref.watch(lastAgentKindProvider).value;
    final installed = agents.value ?? const <AvailableAgent>[];
    final selected =
        _kind ??
        (installed.any((a) => a.kind == remembered) ? remembered : null) ??
        installed.firstOrNull?.kind;

    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.rocket_launch_outlined, color: scheme.primary),
                const SizedBox(width: 10),
                Text('Start an agent',
                    style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              widget.target.where,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 18),

            Text('Agent', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            AgentKindField(
              agents: agents,
              selected: selected,
              onSelect: (k) => setState(() => _kind = k),
            ),
            const SizedBox(height: 18),

            if (widget.target.takesCwd) ...[
              TextField(
                controller: _cwd,
                enabled: !_starting,
                decoration: const InputDecoration(
                  labelText: 'Working directory',
                  hintText: '/Users/you/projects/app',
                  helperText: 'Absolute path on the server. Checked before '
                      'anything is started.',
                  helperMaxLines: 2,
                ),
                style: const TextStyle(
                    fontFamily: AppTheme.monoFamily, fontSize: 13),
              ),
              // Typing an absolute path on a phone is the slowest thing in this
              // sheet, and the answer is nearly always a project you were just
              // in. Rebuilt off the controller so the current directory reads
              // as selected however it was set — tapped here, or arrived with.
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _cwd,
                builder: (context, value, _) {
                  final dirs = _recentDirs();
                  if (dirs.isEmpty) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: SizedBox(
                      height: 36,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: dirs.length,
                        separatorBuilder: (_, _) =>
                            const SizedBox(width: Space.sm),
                        itemBuilder: (_, i) => Center(
                          child: AppActionChip(
                            icon: Icons.folder_outlined,
                            label: _dirLabel(dirs[i]),
                            tooltip: dirs[i],
                            active: value.text.trim() == dirs[i],
                            onTap: _starting ? () {} : () => _useDir(dirs[i]),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ] else
              SheetNotice(
                icon: Icons.folder_outlined,
                text: widget.target.defaultCwd.isEmpty
                    ? "Runs in this terminal's current directory."
                    : 'Runs in ${widget.target.defaultCwd} — this terminal '
                        'is already there.',
              ),
            const SizedBox(height: 16),

            TextField(
              controller: _prompt,
              enabled: !_starting,
              minLines: 2,
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'First message (optional)',
                hintText: 'What should it work on?',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 20),

            Row(
              children: [
                TextButton(
                  onPressed:
                      _starting ? null : () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: selected == null || _starting
                      ? null
                      : () => _start(selected),
                  icon: _starting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow_rounded),
                  label: Text(_starting ? 'Starting…' : 'Start'),
                ),
              ],
            ),
            if (_starting) ...[
              const SizedBox(height: 10),
              Text(
                'The server waits until the agent is really up — this can take '
                'a few seconds.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _start(String kind) async {
    final client = ref.read(bridgeClientProvider);
    final messenger = ScaffoldMessenger.of(context);
    // Captured before the await: on success the sheet is popped first, and
    // navigating from an already-defunct sheet context would throw.
    final router = GoRouter.of(context);
    final navigator = Navigator.of(context);
    if (client == null) {
      messenger.showSnackBar(
          const SnackBar(content: Text('No bridge connection.')));
      return;
    }
    final cwd = _cwd.text.trim();
    // A cheap client-side check on the one field the operator types freehand.
    // The bridge is still the authority (it also checks the path exists and is
    // a directory); this only saves an obviously-doomed round trip.
    if (widget.target.takesCwd && cwd.isNotEmpty && !cwd.startsWith('/')) {
      messenger.showSnackBar(const SnackBar(
          content: Text('Working directory must be an absolute path.')));
      return;
    }

    setState(() => _starting = true);
    try {
      final result = await client.startAgent(
        kind: kind,
        paneId: widget.target.placement == StartAgentPlacement.existingPane
            ? widget.target.id
            : null,
        splitFrom: widget.target.placement == StartAgentPlacement.splitPane
            ? widget.target.id
            : null,
        workspaceId: widget.target.placement == StartAgentPlacement.newTab
            ? widget.target.id
            : null,
        cwd: widget.target.takesCwd ? cwd : null,
        prompt: _prompt.text.trim(),
      );
      if (!mounted) return;
      await ref.read(lastAgentKindProvider.notifier).record(result.kind);
      // Herdr returns the new pane before the next snapshot necessarily
      // contains it. Record the direct navigation now, rather than relying
      // on TranscriptScreen to discover an agent that is not visible yet.
      await recordRecentOpenForPane(
        ref,
        paneId: result.paneId,
        view: OpenedView.transcript,
      );
      navigator.pop();
      // A dropped opening prompt is the failure that looks like success: the
      // agent is up, so the launch "worked", and the instruction it was started
      // to carry is simply gone. The bridge sends the reason back precisely so
      // it can be said, and it is held longer than a routine confirmation
      // because it means retyping the message.
      final failed = result.promptError;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            failed != null && failed.isNotEmpty
                ? failed
                : result.promptSent
                    ? '${result.kind} started and sent your message'
                    : '${result.kind} started',
          ),
          duration: Duration(
            seconds: failed != null && failed.isNotEmpty ? 6 : 2,
          ),
        ),
      );
      // Straight to the new agent's chat — the pane id came back
      // session-qualified precisely so no lookup is needed in between.
      router.push('/transcript/${Uri.encodeComponent(result.paneId)}');
    } on BridgeException catch (e) {
      if (!mounted) return;
      // The sheet deliberately stays open: the common failures (bad path, busy
      // pane) are ones the operator fixes in the field they are already looking
      // at.
      setState(() => _starting = false);
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}
