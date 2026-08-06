import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/data/bridge/models/snapshot.dart';
import 'package:gothalo/features/overview/overview_screen.dart';

/// Where a space lives decides where a new agent starts. Getting it wrong
/// launches an agent — with full tool access — in the wrong repository, so the
/// default the start sheet prefills has to come from the space itself rather
/// than from whichever pane happens to be listed first.

Pane pane(String cwd) => Pane(workspaceId: 'wN', cwd: cwd);

void main() {
  test('a space with a checkout uses it, not any pane', () {
    // The real spread from a live session: one space holding the repo root, a
    // subdirectory, and three linked worktrees. Only the first is the answer,
    // and it is NOT the pane the snapshot happens to list first.
    final panes = [
      pane('/Users/d/projects/gothalo/app'),
      pane('/Users/d/.herdr/worktrees/gothalo/feat-image-to-agent'),
      pane('/Users/d/projects/gothalo'),
      pane('/Users/d/.herdr/worktrees/gothalo/feat-activity-timeline'),
    ];
    final ws = WorkspaceInfo(
      workspaceId: 'wN',
      worktree: const WorktreeInfo(checkoutPath: '/Users/d/projects/gothalo'),
    );
    expect(spaceCwdOf(ws, panes), '/Users/d/projects/gothalo');
  });

  test('a linked-worktree space uses ITS checkout, not the main repo', () {
    final ws = WorkspaceInfo(
      workspaceId: 'wR',
      worktree: const WorktreeInfo(
        checkoutPath: '/Users/d/.herdr/worktrees/gothalo/feat-terminal-scroll',
        isLinkedWorktree: true,
      ),
    );
    expect(
      spaceCwdOf(ws, [pane('/Users/d/projects/gothalo')]),
      '/Users/d/.herdr/worktrees/gothalo/feat-terminal-scroll',
    );
  });

  test('no checkout falls back to the shallowest pane cwd', () {
    // A plain `~` space has no repository. The common ancestor is the closest
    // thing the panes can tell us, and beats an incidental deep path.
    final panes = [
      pane('/Users/d/projects/one/deep/nested'),
      pane('/Users/d'),
      pane('/Users/d/projects/two'),
    ];
    expect(spaceCwdOf(null, panes), '/Users/d');
  });

  test('a checkout wins even when panes are shallower', () {
    final ws = WorkspaceInfo(
      workspaceId: 'wN',
      worktree: const WorktreeInfo(checkoutPath: '/Users/d/projects/gothalo'),
    );
    expect(spaceCwdOf(ws, [pane('/Users/d')]), '/Users/d/projects/gothalo');
  });

  test('an empty space yields empty rather than a guess', () {
    expect(spaceCwdOf(null, const []), '');
    expect(spaceCwdOf(WorkspaceInfo(workspaceId: 'wN'), const []), '');
  });

  test('panes with no cwd are skipped, not chosen as shallowest', () {
    expect(
      spaceCwdOf(null, [pane(''), pane('/Users/d/projects/gothalo')]),
      '/Users/d/projects/gothalo',
    );
  });

  test('the workspace worktree survives snapshot parsing', () {
    // Regression for the actual defect: the bridge was already sending this and
    // the model dropped it on the floor, so the correct answer was unreachable.
    final ws = WorkspaceInfo.fromJson(const {
      'workspace_id': 'wN',
      'label': 'gothalo',
      'worktree': {
        'checkout_path': '/Users/d/projects/gothalo',
        'repo_name': 'gothalo',
        'is_linked_worktree': false,
      },
    });
    expect(ws.worktree?.checkoutPath, '/Users/d/projects/gothalo');
    expect(ws.worktree?.repoName, 'gothalo');
    expect(ws.worktree?.isLinkedWorktree, false);
  });

  test('a workspace with no worktree key parses as null, not a crash', () {
    final ws = WorkspaceInfo.fromJson(const {
      'workspace_id': 'w4',
      'label': '~',
    });
    expect(ws.worktree, isNull);
  });
}
