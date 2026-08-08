import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../data/bridge/bridge_client.dart';
import '../../data/bridge/bridge_providers.dart';
import '../inbox/inbox_providers.dart';

/// Open a project on the host as a new Herdr space, picked from the phone.
///
/// This is the one flow that has to work when the server has **nothing** open:
/// with no workspaces there is no pane to split and no cwd to inherit, so the
/// directory has to be named outright. The bridge's `GET /browse` is what makes
/// that possible without the app knowing anything about the host's filesystem —
/// it hands back roots to start from and the directories under them, and
/// nothing else (see `docs/CONTRACT-browse.md`).
///
/// A bridge that doesn't have the endpoint 404s; the sheet says so plainly
/// rather than showing an empty picker, which is the same gating rule the
/// slash-command typeahead and the agent launcher use.
Future<void> showOpenSpaceSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (_) => _OpenSpaceSheet(navContext: context),
  );
}

class _OpenSpaceSheet extends ConsumerStatefulWidget {
  const _OpenSpaceSheet({required this.navContext});

  /// The context of the screen that opened the sheet — used to navigate after
  /// the sheet pops, when its own context is defunct.
  final BuildContext navContext;

  @override
  ConsumerState<_OpenSpaceSheet> createState() => _OpenSpaceSheetState();
}

class _OpenSpaceSheetState extends ConsumerState<_OpenSpaceSheet> {
  BrowseListing? _listing;
  Object? _error;
  bool _loading = true;
  bool _showHidden = false;
  bool _opening = false;

  /// Which Herdr session the new space lands in. Only ever shown when the
  /// server actually runs more than one (D14) — with a single session there is
  /// no decision to put in front of anyone.
  String? _session;

  @override
  void initState() {
    super.initState();
    _load(null);
  }

  List<String> get _sessions =>
      ref.read(snapshotControllerProvider).asData?.value.sessionNames ??
      const ['default'];

  Future<void> _load(String? path) async {
    final client = ref.read(bridgeClientProvider);
    if (client == null) {
      setState(() {
        _loading = false;
        _error = BridgeException('No bridge connection.');
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final listing = await client.browse(path: path, showHidden: _showHidden);
      if (!mounted) return;
      setState(() {
        _listing = listing;
        _loading = false;
      });
    } on BridgeException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        // A 403 means the path left the allowed roots — only reachable if the
        // listing we navigated from was stale. Keep the old listing on screen
        // so there is still somewhere to go back to.
        _error = e;
      });
    }
  }

  /// Open [path] as a space and navigate to it.
  ///
  /// Two Herdr methods, picked by whether the directory is a git checkout:
  ///
  /// - `worktree.open` for a repo. It attaches the repo metadata Herdr uses to
  ///   group a project with its worktrees (which is what puts the space under
  ///   the right heading in the Spaces list), and it is **idempotent** — asked
  ///   twice it returns the existing workspace with `already_open`, instead of
  ///   opening a second space on the same tree.
  /// - `workspace.create` for anything else. It takes any directory, which is
  ///   the whole point: a project that isn't a repo yet still needs a space.
  ///
  /// `worktree.open` needs `cwd` as well as `path` — without it Herdr answers
  /// `not_git_worktree` even for a valid checkout, since `cwd` is what it
  /// resolves the repository from.
  Future<void> _open(String path, {required bool isRepo, String? label}) async {
    final client = ref.read(bridgeClientProvider);
    final messenger = ScaffoldMessenger.of(context);
    // All captured before the await: on success the sheet pops first, and
    // reaching for its context — or for `ref` — after that is reaching into a
    // disposed widget.
    final router = GoRouter.of(widget.navContext);
    final navigator = Navigator.of(context);
    final snapshots = ref.read(snapshotControllerProvider.notifier);
    if (client == null) {
      messenger.showSnackBar(const SnackBar(content: Text('No bridge connection.')));
      return;
    }

    setState(() => _opening = true);
    try {
      final result = await client.herdrCommand(
        isRepo ? 'worktree.open' : 'workspace.create',
        {
          'cwd': path,
          if (isRepo) 'path': path,
          if (!isRepo && label != null && label.isNotEmpty) 'label': label,
        },
        _session,
      );
      final workspace = result['workspace'];
      final workspaceId =
          workspace is Map ? (workspace['workspace_id'] as String?) ?? '' : '';
      final alreadyOpen = result['already_open'] == true;
      if (!mounted) return;
      navigator.pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text(alreadyOpen
              ? '${_leaf(path)} was already open'
              : 'Opened ${_leaf(path)}'),
          duration: const Duration(seconds: 2),
        ),
      );
      // Pull the snapshot forward rather than waiting for the next poll — the
      // space we are about to navigate to has to exist in it.
      unawaited(snapshots.refresh());
      if (workspaceId.isNotEmpty) {
        router.push('/overview/${Uri.encodeComponent(workspaceId)}');
      }
    } on BridgeException catch (e) {
      if (!mounted) return;
      setState(() => _opening = false);
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final listing = _listing;
    final sessions = _sessions;

    return SafeArea(
      top: false,
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.82,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
              child: Row(
                children: [
                  Icon(Icons.create_new_folder_outlined, color: scheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Open a project',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: _showHidden ? 'Hide dot folders' : 'Show dot folders',
                    icon: Icon(
                      _showHidden ? Icons.visibility : Icons.visibility_off_outlined,
                      size: 20,
                    ),
                    onPressed: _opening
                        ? null
                        : () {
                            setState(() => _showHidden = !_showHidden);
                            _load(listing?.path);
                          },
                  ),
                ],
              ),
            ),
            if (sessions.length > 1)
              _SessionPicker(
                sessions: sessions,
                selected: _session ?? sessions.first,
                enabled: !_opening,
                onSelect: (s) => setState(() => _session = s),
              ),
            if (listing != null) _Breadcrumb(listing: listing),
            const Divider(height: 1),
            Expanded(child: _body(listing)),
            if (listing != null && !_loading && _error == null)
              _OpenHereBar(
                listing: listing,
                busy: _opening,
                onOpen: listing.isOpen
                    ? () {
                        Navigator.of(context).pop();
                        widget.navContext.push(
                          '/overview/${Uri.encodeComponent(listing.openWorkspaceId)}',
                        );
                      }
                    : () => _open(
                          listing.path,
                          isRepo: listing.isRepo,
                          label: _leaf(listing.path),
                        ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _body(BrowseListing? listing) {
    if (_loading && listing == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && listing == null) {
      return _BrowseError(error: _error!, onRetry: () => _load(null));
    }
    if (listing == null) return const SizedBox.shrink();

    return Stack(
      children: [
        ListView(
          padding: const EdgeInsets.only(bottom: 12),
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Text(
                  _error is BridgeException
                      ? (_error as BridgeException).message
                      : '$_error',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Theme.of(context).colorScheme.error),
                ),
              ),
            // Roots first, but only when there is more than one place to start:
            // with a single root (the usual case) the header would be a list of
            // one naming the directory already on screen.
            if (listing.roots.length > 1)
              for (final r in listing.roots)
                ListTile(
                  dense: true,
                  leading: Icon(
                    r.kind == 'home' ? Icons.home_outlined : Icons.folder_special_outlined,
                    size: 20,
                  ),
                  title: Text(r.label),
                  subtitle: Text(
                    r.path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontFamily: AppTheme.monoFamily, fontSize: 11),
                  ),
                  selected: r.path == listing.path,
                  onTap: _opening ? null : () => _load(r.path),
                ),
            if (listing.roots.length > 1) const Divider(height: 1),
            if (listing.canGoUp)
              ListTile(
                leading: const Icon(Icons.drive_folder_upload_outlined),
                title: Text(_leaf(listing.parent)),
                subtitle: const Text('Up one level'),
                onTap: _opening ? null : () => _load(listing.parent),
              ),
            for (final e in listing.entries)
              _EntryTile(
                entry: e,
                enabled: !_opening,
                onOpenDir: () => _load(e.path),
                onOpenSpace: () => _open(e.path, isRepo: e.isRepo, label: e.name),
                onGoToSpace: () {
                  Navigator.of(context).pop();
                  widget.navContext.push(
                    '/overview/${Uri.encodeComponent(e.openWorkspaceId)}',
                  );
                },
              ),
            if (listing.entries.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 32, 20, 0),
                child: Text(
                  _showHidden
                      ? 'Nothing in here.'
                      : 'No folders here. Dot folders are hidden — use the eye '
                          'button if the project you want starts with a dot.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
            if (listing.truncated)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                child: Text(
                  'Showing the first ${listing.limit} folders — this directory '
                  'has more. Open a folder closer to the project you want.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
          ],
        ),
        if (_loading)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(minHeight: 2),
          ),
      ],
    );
  }
}

/// One directory row. Tapping navigates into it; the trailing action opens it
/// as a space — two different things, so they are two different targets rather
/// than a tap that guesses.
class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.entry,
    required this.enabled,
    required this.onOpenDir,
    required this.onOpenSpace,
    required this.onGoToSpace,
  });

  final BrowseEntry entry;
  final bool enabled;
  final VoidCallback onOpenDir;
  final VoidCallback onOpenSpace;
  final VoidCallback onGoToSpace;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      onTap: enabled ? onOpenDir : null,
      leading: Icon(
        entry.isRepo ? Icons.source_outlined : Icons.folder_outlined,
        color: entry.isRepo ? scheme.primary : scheme.onSurfaceVariant,
      ),
      title: Text(
        entry.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 15),
      ),
      subtitle: entry.isOpen
          ? Text(
              'Already open',
              style: TextStyle(fontSize: 12, color: scheme.primary),
            )
          : (entry.isSymlink
              ? Text(
                  'Link',
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                )
              : null),
      trailing: entry.isOpen
          ? TextButton(
              onPressed: enabled ? onGoToSpace : null,
              child: const Text('Go to'),
            )
          : FilledButton.tonal(
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                minimumSize: const Size(0, 34),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: enabled ? onOpenSpace : null,
              child: const Text('Open'),
            ),
    );
  }
}

/// The path you are looking at, mono and ellipsized from the left so the tail —
/// the part that identifies the directory — is what survives truncation.
class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({required this.listing});

  final BrowseListing listing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
      child: Text(
        listing.path,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textDirection: TextDirection.rtl,
        style: TextStyle(
          fontFamily: AppTheme.monoFamily,
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// "Open this directory itself", for a project you have navigated *into*. Kept
/// as a bar rather than a row in the list because it acts on the current
/// location, not on any of the things listed under it.
class _OpenHereBar extends StatelessWidget {
  const _OpenHereBar({
    required this.listing,
    required this.busy,
    required this.onOpen,
  });

  final BrowseListing listing;
  final bool busy;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 12, 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                listing.isOpen
                    ? '${_leaf(listing.path)} is already open'
                    : 'Open ${_leaf(listing.path)} itself',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: busy ? null : onOpen,
              child: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(listing.isOpen ? 'Go to it' : 'Open here'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Which Herdr session the new space lands in. One bridge can front several
/// (D14) and a space has to go in exactly one of them, so on a multi-session
/// server this is a required choice rather than a silent default.
class _SessionPicker extends StatelessWidget {
  const _SessionPicker({
    required this.sessions,
    required this.selected,
    required this.enabled,
    required this.onSelect,
  });

  final List<String> sessions;
  final String selected;
  final bool enabled;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Row(
        children: [
          Icon(
            Icons.layers_outlined,
            size: 16,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Wrap(
              spacing: 8,
              children: [
                for (final s in sessions)
                  ChoiceChip(
                    selected: s == selected,
                    onSelected: enabled ? (_) => onSelect(s) : null,
                    label: Text(s),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BrowseError extends StatelessWidget {
  const _BrowseError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bridgeErr = error is BridgeException ? error as BridgeException : null;
    // A 404 here is not "directory missing", it is "this bridge has no /browse"
    // — the picker's own capability check.
    final unsupported = bridgeErr?.statusCode == 404;
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            unsupported ? Icons.update_disabled : Icons.error_outline,
            size: 44,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(height: 14),
          Text(
            unsupported ? 'This server is too old' : "Couldn't read the host",
            style: Theme.of(context).textTheme.titleSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            unsupported
                ? 'Browsing for a project needs a newer gothalo bridge on the '
                    'host. Update it, or open the project in Herdr on the desktop.'
                : (bridgeErr?.message ?? '$error'),
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          if (!unsupported) ...[
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ],
      ),
    );
  }
}

/// Last path segment, for labels. Falls back to the whole path (a root like
/// "/" has no leaf).
String _leaf(String path) {
  final parts = path.split('/').where((s) => s.isNotEmpty).toList();
  return parts.isEmpty ? path : parts.last;
}
