import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/data/bridge/models/snapshot.dart';

void main() {
  group('Snapshot parsing', () {
    test('parses the bridge agent shape and maps status', () {
      final agent = Agent.fromJson({
        'agent': 'claude',
        'agent_session': {'value': 'abc-123'},
        'agent_status': 'blocked',
        'pane_id': 'w1:p2',
        'terminal_title_stripped': 'fix the parser',
        'cwd': '/home/dev/proj',
        'focused': false,
        'workspace_id': 'w1',
      });

      expect(agent.agent, 'claude');
      expect(agent.agentStatus, AgentStatus.blocked);
      expect(agent.paneId, 'w1:p2');
      expect(agent.title, 'fix the parser');
      expect(agent.workspaceId, 'w1');
      expect(agent.session?.value, 'abc-123');
      expect(agent.agentStatus.needsAttention, isTrue);
    });

    test('an unrecognized status falls back to unknown, never throws', () {
      final agent = Agent.fromJson({'agent': 'codex', 'agent_status': 'wat'});
      expect(agent.agentStatus, AgentStatus.unknown);
    });

    test('missing fields fall back to safe defaults', () {
      final agent = Agent.fromJson({'agent': 'gemini'});
      expect(agent.agentStatus, AgentStatus.unknown);
      expect(agent.paneId, '');
      expect(agent.displayTitle, 'gemini'); // falls back to agent name
    });
  });

  group('Git context (derived from cwd)', () {
    test('herdr worktree path -> project + worktree (branch-like) name', () {
      const a = Agent(
        cwd: '/Users/alex/.herdr/worktrees/acme-app/validation-reset',
      );
      expect(a.gitContext.project, 'acme-app');
      expect(a.gitContext.worktree, 'validation-reset');
      expect(a.gitLabel, 'validation-reset');
      expect(a.isWorktree, isTrue);
    });

    test('worktree name with slashes is preserved', () {
      const a = Agent(
        cwd: '/Users/alex/.herdr/worktrees/proj/feat/vendor-sync',
      );
      expect(a.gitContext.project, 'proj');
      expect(a.gitContext.worktree, 'feat/vendor-sync');
    });

    test('plain checkout -> project dir, no worktree', () {
      const a = Agent(cwd: '/Users/alex/projects/acme/storefront-frontend');
      expect(a.gitContext.project, 'storefront-frontend');
      expect(a.gitContext.worktree, isNull);
      expect(a.gitLabel, 'storefront-frontend');
      expect(a.isWorktree, isFalse);
    });

    test('empty cwd is safe', () {
      const a = Agent(cwd: '');
      expect(a.gitContext.project, '');
      expect(a.gitContext.worktree, isNull);
      expect(a.isWorktree, isFalse);
    });
  });

  group('Authoritative branch (from the bridge)', () {
    test('a plain checkout uses the reported branch, not the folder name', () {
      // The bridge runs git in the pane cwd — path inference could never see
      // this branch (the dir is not a .herdr worktree).
      final a = Agent.fromJson({
        'agent': 'claude',
        'pane_id': 'w8:p1',
        'cwd': '/Users/alex/projects/acme/storefront-frontend',
        'foreground_cwd': '/Users/alex/projects/acme/storefront-frontend',
        'branch': 'main',
      });
      expect(a.branchName, 'main');
      expect(a.hasBranch, isTrue);
      expect(a.gitLabel, 'main'); // branch wins over the "frontend" folder
    });

    test('a repo subdir resolves to the repo branch', () {
      final a = Agent.fromJson({
        'pane_id': 'w5:p1C',
        'foreground_cwd': '/Users/alex/projects/acme/acme-app/backend',
        'branch': 'develop',
      });
      expect(a.branchName, 'develop');
      expect(a.gitLabel, 'develop'); // not "backend", the leaf dir
    });

    test('a non-git dir reports empty branch -> no branch shown', () {
      final a = Agent.fromJson({
        'pane_id': 'w4:p1',
        'cwd': '/Users/alex',
        'foreground_cwd': '/Users/alex',
        'branch': '', // bridge: not a git work tree
      });
      expect(a.branchName, isNull);
      expect(a.hasBranch, isFalse);
      expect(a.gitLabel, 'alex'); // falls back to the folder label
    });

    test('git context prefers foreground_cwd over the launch cwd', () {
      final a = Agent.fromJson({
        'cwd': '/Users/alex', // launch dir
        'foreground_cwd': '/Users/alex/projects/gothalo', // shell cd'd here
      });
      expect(a.gitContext.project, 'gothalo');
    });

    test('older bridge (no branch field) still infers from a worktree path', () {
      // Forward-compatibility: absent `branch` -> unchanged behavior.
      final a = Agent.fromJson({
        'cwd': '/Users/alex/.herdr/worktrees/gothalo/feat/agent-state',
      });
      expect(a.branch, ''); // default
      expect(a.branchName, 'feat/agent-state'); // via path inference
      expect(a.hasBranch, isTrue);
      expect(a.gitLabel, 'feat/agent-state');
    });
  });

  group('Grouping', () {
    test('groups by workspace, floating attention-needing workspaces up', () {
      final snap = Snapshot(agents: [
        const Agent(agent: 'a', workspaceId: 'w2', agentStatus: AgentStatus.idle, paneId: 'w2:p1'),
        const Agent(agent: 'b', workspaceId: 'w1', agentStatus: AgentStatus.working, paneId: 'w1:p1'),
        const Agent(agent: 'c', workspaceId: 'w1', agentStatus: AgentStatus.blocked, paneId: 'w1:p2'),
      ]);

      final groups = snap.byWorkspace;
      // w1 has a blocked agent → it sorts before w2.
      expect(groups.first.key, 'w1');
      // Within w1, the blocked agent comes first.
      expect(groups.first.value.first.agentStatus, AgentStatus.blocked);
      expect(groups.length, 2);
    });
  });

  group('Authoritative attention order (from the bridge)', () {
    test('parses attention_rank and sorts the flat list on it', () {
      final snap = Snapshot(agents: [
        Agent.fromJson({
          'agent': 'idle-one',
          'pane_id': 'w1:p1',
          'agent_status': 'idle',
          'attention_rank': 3,
        }),
        Agent.fromJson({
          'agent': 'blocked-one',
          'pane_id': 'w1:p2',
          'agent_status': 'blocked',
          'attention_rank': 0,
        }),
        Agent.fromJson({
          'agent': 'working-one',
          'pane_id': 'w2:p1',
          'agent_status': 'working',
          'attention_rank': 2,
        }),
      ]);

      expect(snap.agents[0].attentionRank, 3);
      expect(
        snap.agentsSorted.map((a) => a.agent),
        ['blocked-one', 'working-one', 'idle-one'],
      );
    });

    test("the bridge's rank wins over the locally derived one", () {
      // The bridge is authoritative: if it ever ranks a status differently than
      // the local table, the list must follow the bridge, not re-derive.
      final snap = Snapshot(agents: [
        Agent.fromJson({
          'agent': 'demoted',
          'agent_status': 'blocked', // local rank 0…
          'attention_rank': 9, // …but the bridge says last
        }),
        Agent.fromJson({
          'agent': 'promoted',
          'agent_status': 'idle', // local rank 3…
          'attention_rank': 0, // …but the bridge says first
        }),
      ]);

      expect(snap.agentsSorted.map((a) => a.agent), ['promoted', 'demoted']);
    });

    test('older bridge (no attention_rank) falls back to the local rank', () {
      final snap = Snapshot(agents: [
        Agent.fromJson({'agent': 'idle-one', 'agent_status': 'idle'}),
        Agent.fromJson({'agent': 'done-one', 'agent_status': 'done'}),
        Agent.fromJson({'agent': 'blocked-one', 'agent_status': 'blocked'}),
      ]);

      expect(snap.agents.first.attentionRank, isNull);
      expect(snap.agents.first.attention, AgentStatus.idle.rank);
      expect(
        snap.agentsSorted.map((a) => a.agent),
        ['blocked-one', 'done-one', 'idle-one'],
      );
    });
  });
}
