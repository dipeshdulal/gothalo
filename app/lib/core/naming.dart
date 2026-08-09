/// The words the app says out loud, as opposed to the words Herdr uses on the
/// wire.
///
/// Herdr's model is a multiplexer's: sessions hold workspaces, workspaces hold
/// tabs, tabs hold panes, and a pane may or may not have a coding agent in it.
/// That model is correct and the app still navigates by it — `pane_id` is the
/// address we type into, `workspace_id` is what a worktree is removed by. It is
/// simply not the model the person holding the phone has. Theirs is: my
/// projects, my agents, and the terminals I left open.
///
/// So the ids stay, and the vocabulary changes:
///
/// | Herdr            | here                            |
/// |------------------|---------------------------------|
/// | workspace/space  | **project** — repo + branch      |
/// | pane with agent  | **the agent**                   |
/// | pane without one | **a terminal**, in some project |
/// | tab              | nothing; a grouping detail      |
/// | `w1N:p3`         | never shown                     |
///
/// Everything in this file is a pure string derivation, so the naming can be
/// pinned by tests without a bridge — the failure mode being guarded against is
/// one screen quietly going back to showing a pane id.
library;

import '../data/bridge/models/snapshot.dart';

/// A project's name as one line: the repo, then the branch when it is on one.
///
/// The separator is the same middle dot the rest of the app uses for
/// "and also", so `gothalo · feat/ui-foundation` reads as one label rather than
/// two facts. An empty branch collapses to the repo alone rather than leaving a
/// dangling dot.
String projectLabel(String project, [String? branch]) {
  final p = project.trim();
  final b = branch?.trim() ?? '';
  if (p.isEmpty) return b;
  if (b.isEmpty) return p;
  return '$p · $b';
}

/// What to call a **terminal** — a pane with no agent in it.
///
/// `w1N:p3` is not a name. What actually distinguishes one terminal from
/// another is what is running in it and which project it is running in, which
/// is exactly what this says: `npm run dev · gothalo`, or `shell · gothalo` for
/// one sitting at its prompt.
///
/// [Pane.command] already knows the difference between a shell prompt and a
/// foreground process, so an idle shell is named for what it is rather than
/// having its `user@host:path` prompt shown as if it were a title.
String terminalTitle(Pane pane) {
  final what = pane.command ?? 'shell';
  final project = gitContextForCwd(pane.where).project;
  return project.isEmpty ? what : '$what · $project';
}

/// The project an agent is working in, as `repo · branch`.
extension AgentNaming on Agent {
  /// `gothalo · feat/ui-foundation`, or just `gothalo` off a plain checkout
  /// whose branch nothing has reported.
  ///
  /// This is the line that replaces the space label on every agent row. It is
  /// deliberately built from [gitContext] and [branchName] rather than from
  /// `workspace_id`: a project's main checkout and its worktrees are separate
  /// Herdr workspaces but one project, and `w5`/`w8` says neither.
  String get projectLine => projectLabel(gitContext.project, branchName);

  /// The repo alone — for the rows that show the branch separately.
  String get projectName => gitContext.project;
}

/// The project a pane belongs to, derived the same way an agent's is.
extension PaneNaming on Pane {
  /// The repo folder this terminal is sitting in, or empty when its cwd is not
  /// under one.
  String get projectName => gitContextForCwd(where).project;
}

/// Where a project lives — the directory a new agent started in it should
/// default to.
///
/// The workspace's own checkout path is the only authoritative answer. A pane's
/// cwd is only a fallback for a plain, non-git space, and the shallowest pane
/// wins so the result is not an arbitrary subdirectory from the snapshot.
String spaceCwdFor(WorkspaceInfo? workspace, List<Pane> panes) {
  final checkout = workspace?.worktree?.checkoutPath ?? '';
  if (checkout.isNotEmpty) return checkout;
  if (panes.isEmpty) return '';

  var shallowest = panes.first.cwd;
  for (final p in panes) {
    if (p.cwd.isEmpty) continue;
    if (shallowest.isEmpty ||
        '/'.allMatches(p.cwd).length < '/'.allMatches(shallowest).length) {
      shallowest = p.cwd;
    }
  }
  return shallowest;
}

/// What to call a **project** — one Herdr workspace, named for its checkout.
///
/// Prefers the repo name Herdr reports for the workspace's own checkout, since
/// that is authoritative; falls back to inferring it from [cwd] (which is all
/// an older bridge gives us), and only then to the workspace's own label. The
/// last resort is deliberately the label and never the `workspace_id`: a
/// nameless space is better shown as "Untitled" than as `w8`.
({String project, String? branch}) projectOf(
  WorkspaceInfo? workspace,
  String cwd,
) {
  final git = gitContextForCwd(cwd);
  final repo = workspace?.worktree?.repoName ?? '';
  final project = repo.isNotEmpty
      ? repo
      : (git.project.isNotEmpty
            ? git.project
            : (workspace?.label ?? '').trim());
  return (
    project: project.isEmpty ? 'Untitled' : project,
    branch: git.worktree,
  );
}
