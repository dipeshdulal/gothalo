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
}
