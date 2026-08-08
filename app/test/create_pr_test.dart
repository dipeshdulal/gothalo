import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/data/bridge/bridge_client.dart';
import 'package:gothalo/features/pr/create_pr.dart';

/// A pane sitting on a feature branch with somewhere to push and something to
/// push — the state the "Create PR" action exists for. Every test below varies
/// one field off this baseline.
GitContext ctx({
  bool repo = true,
  String branch = 'feat/x',
  String defaultBranch = 'main',
  String defaultRef = 'refs/remotes/origin/main',
  String remote = 'origin',
  String upstream = 'origin/feat/x',
  int ahead = 2,
  int behind = 0,
  bool dirty = false,
}) => GitContext(
  repo: repo,
  branch: branch,
  defaultBranch: defaultBranch,
  defaultRef: defaultRef,
  remote: remote,
  upstream: upstream,
  ahead: ahead,
  behind: behind,
  dirty: dirty,
);

void main() {
  group('GitContext.fromJson', () {
    test('reads the bridge\'s git object', () {
      final g = GitContext.fromJson(const {
        'repo': true,
        'branch': 'feat/one-tap-pr',
        'default_branch': 'main',
        'default_ref': 'refs/remotes/origin/main',
        'remote': 'origin',
        'upstream': 'origin/main',
        'ahead': 3,
        'behind': 1,
        'dirty': true,
      });
      expect(g.repo, isTrue);
      expect(g.branch, 'feat/one-tap-pr');
      expect(g.defaultBranch, 'main');
      expect(g.ahead, 3);
      expect(g.behind, 1);
      expect(g.dirty, isTrue);
      expect(g.onDefaultBranch, isFalse);
      expect(g.hasWork, isTrue);
    });

    test('a bridge too old to send `git` decodes as unknown, not as a repo', () {
      final r = DiffResult.fromJson(const {'branch': 'feat/x', 'files': []});
      expect(r.git.repo, isFalse);
      expect(r.branch, 'feat/x');
      // The gate must read "can't tell" as "don't offer the action".
      expect(prBlockReason(r.git), isNotNull);
    });

    test('carries the git object through the full diff payload', () {
      final r = DiffResult.fromJson(const {
        'branch': 'feat/x',
        'git': {'repo': true, 'branch': 'feat/x', 'default_branch': 'main'},
        'files': [],
      });
      expect(r.git.repo, isTrue);
      expect(r.git.defaultBranch, 'main');
    });
  });

  group('prBlockReason', () {
    test('passes a feature branch with commits ahead', () {
      expect(prBlockReason(ctx()), isNull);
    });

    test('passes a branch with no commits but uncommitted work', () {
      // Committing IS step one of what the agent is asked to do, so a dirty
      // tree with nothing committed yet is a perfectly good PR to open.
      expect(prBlockReason(ctx(ahead: 0, dirty: true)), isNull);
    });

    test('blocks a non-repo', () {
      expect(prBlockReason(ctx(repo: false)), contains('git repository'));
    });

    test('blocks a detached HEAD', () {
      expect(prBlockReason(ctx(branch: '')), contains('detached HEAD'));
    });

    test('blocks a repo with no remote', () {
      expect(prBlockReason(ctx(remote: '')), contains('no git remote'));
    });

    test('blocks the default branch itself', () {
      final reason = prBlockReason(ctx(branch: 'main'));
      expect(reason, contains('default branch'));
      expect(reason, contains('feature branch'));
    });

    test('blocks a clean branch with nothing ahead', () {
      expect(
        prBlockReason(ctx(ahead: 0, dirty: false)),
        contains('no commits ahead of main'),
      );
    });

    test('names the first problem, not a downstream symptom', () {
      // No repo at all: every later check would also fail, but "not a git
      // repository" is the only one worth saying.
      expect(
        prBlockReason(ctx(repo: false, branch: '', remote: '', ahead: 0)),
        contains('git repository'),
      );
    });
  });

  // The prompt itself, and the one-line summary, are composed on the BRIDGE
  // now (internal/suggest.prPrompt / prSummary) and arrive in the suggestion's
  // params — one wording, reviewable in one place, identical on every client.
  // They are tested in internal/suggest/createpr_test.go, including the
  // single-line constraint that keeps /send from submitting half a message.
}
