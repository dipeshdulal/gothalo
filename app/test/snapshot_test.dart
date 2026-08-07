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

  group('Authoritative recency order (from the bridge)', () {
    // The list this exists for: a dozen-plus agents across every status, some
    // the bridge could date and some it could not. Two agents never showed the
    // problem — needing to scroll to the end for the one you were just in is
    // something only a long list does.
    const now = 1785677600000;
    const minute = 60000;

    /// One snapshot agent as the bridge stamps it: a `recency_rank` on every
    /// agent, and a `last_activity_ts` only on the ones it could date.
    /// [minutesAgo] of null is an agent with no transcript to read.
    Map<String, dynamic> mk(
      String name,
      String status,
      int rank, {
      int? minutesAgo,
    }) => {
      'agent': name,
      'pane_id': 'w1:$name',
      'agent_status': status,
      'attention_rank': const {
        'blocked': 0,
        'done': 1,
        'working': 2,
        'idle': 3,
      }[status]!,
      'recency_rank': rank,
      if (minutesAgo != null) 'last_activity_ts': now - minutesAgo * minute,
    };

    // Ranks are the bridge's: newest first across the whole list, undated
    // agents after every dated one.
    List<Map<String, dynamic>> fleet() => [
      mk('idle-3d', 'idle', 12, minutesAgo: 4320),
      mk('blocked-55m', 'blocked', 8, minutesAgo: 55),
      mk('done-2m', 'done', 1, minutesAgo: 2),
      mk('idle-undated-a', 'idle', 13),
      mk('working-1m', 'working', 0, minutesAgo: 1),
      mk('idle-15m', 'idle', 4, minutesAgo: 15),
      mk('done-40m', 'done', 7, minutesAgo: 40),
      mk('blocked-6m', 'blocked', 2, minutesAgo: 6),
      mk('idle-20h', 'idle', 11, minutesAgo: 1200),
      mk('done-11m', 'done', 3, minutesAgo: 11),
      mk('idle-90m', 'idle', 9, minutesAgo: 90),
      mk('working-undated', 'working', 14),
      mk('idle-8h', 'idle', 10, minutesAgo: 480),
      mk('done-30m', 'done', 6, minutesAgo: 30),
      mk('idle-20m', 'idle', 5, minutesAgo: 20),
      mk('idle-undated-b', 'idle', 15),
    ];

    test('attention still wins; recency only orders within a rank', () {
      final snap = Snapshot(agents: fleet().map(Agent.fromJson).toList());

      expect(snap.agentsSorted.map((a) => a.agent), [
        // blocked — 55m still outranks every done/idle agent, however fresh.
        'blocked-6m', 'blocked-55m',
        'done-2m', 'done-11m', 'done-30m', 'done-40m',
        'working-1m', 'working-undated',
        'idle-15m', 'idle-20m', 'idle-90m', 'idle-8h', 'idle-20h', 'idle-3d',
        // Undated agents land at the bottom of their own rank, never the top.
        'idle-undated-a', 'idle-undated-b',
      ]);
    });

    test('the agent you were just in is at the top of its rank', () {
      // The whole complaint: with the old order ("whatever the snapshot
      // produced, then title") an idle agent you touched a minute ago sat
      // wherever herdr listed it — here, last but one alphabetically.
      final agents = fleet()..add(mk('zz-just-used', 'idle', 4, minutesAgo: 1));
      final sorted = Snapshot(
        agents: agents.map(Agent.fromJson).toList(),
      ).agentsSorted;

      final idle = sorted.where((a) => a.agentStatus == AgentStatus.idle);
      expect(idle.first.agent, 'zz-just-used');
    });

    test('the order does not depend on the snapshot\'s own order', () {
      // The failure worth guarding is not a wrong order but a moving one: a
      // list that reshuffles under a thumb between two reads of the same state.
      final forward = Snapshot(
        agents: fleet().map(Agent.fromJson).toList(),
      ).agentsSorted.map((a) => a.agent).toList();
      final reversed = Snapshot(
        agents: fleet().reversed.map(Agent.fromJson).toList(),
      ).agentsSorted.map((a) => a.agent).toList();

      expect(reversed, forward);
    });

    test('undated agents keep the bridge\'s order among themselves', () {
      // Nothing dates them, so the bridge ranked them by their last herdr
      // transition — which is what keeps a just-started agent (no transcript
      // yet) out of the basement. The app must not re-sort them by title.
      final snap = Snapshot(
        agents: [
          mk('aaa-stale', 'idle', 9),
          mk('zzz-just-started', 'idle', 7),
        ].map(Agent.fromJson).toList(),
      );

      expect(snap.agentsSorted.map((a) => a.agent), [
        'zzz-just-started',
        'aaa-stale',
      ]);
    });

    test('a bridge that dates agents but does not rank them still orders', () {
      // An older bridge sends last_activity_ts and no recency_rank. Recency is
      // still recoverable from the timestamp; only the undated agents lose
      // their relative order, and they still sort last.
      final snap = Snapshot(
        agents:
            [
              {
                'agent': 'stale',
                'agent_status': 'idle',
                'last_activity_ts': now - 600 * minute,
              },
              {'agent': 'undated', 'agent_status': 'idle'},
              {
                'agent': 'fresh',
                'agent_status': 'idle',
                'last_activity_ts': now - 2 * minute,
              },
            ].map(Agent.fromJson).toList(),
      );

      expect(snap.agents.first.recencyRank, isNull);
      expect(snap.agentsSorted.map((a) => a.agent), [
        'fresh',
        'stale',
        'undated',
      ]);
    });

    test('a bridge with neither field falls back to title, as before', () {
      final snap = Snapshot(
        agents: [
          {'agent': 'b-one', 'agent_status': 'idle'},
          {'agent': 'a-one', 'agent_status': 'idle'},
        ].map(Agent.fromJson).toList(),
      );

      expect(snap.agentsSorted.map((a) => a.agent), ['a-one', 'b-one']);
    });

    test('across servers the clock decides, not the rank', () {
      // Priority mixes agents from several bridges. `recency_rank` is an index
      // into ONE bridge's snapshot, so rank 0 on server A and rank 0 on server
      // B say nothing about each other — the comparison has to reach the
      // timestamp, which is a real clock on both.
      final fromA = Agent.fromJson({
        'agent': 'server-a-stale',
        'agent_status': 'blocked',
        'attention_rank': 0,
        'recency_rank': 0, // top of A's list…
        'last_activity_ts': now - 300 * minute, // …but five hours old
      });
      final fromB = Agent.fromJson({
        'agent': 'server-b-fresh',
        'agent_status': 'blocked',
        'attention_rank': 0,
        'recency_rank': 9, // buried in B's list…
        'last_activity_ts': now - 2 * minute, // …but two minutes old
      });

      final mixed = [fromA, fromB]..sort(Agent.byAttentionThenRecency);
      expect(mixed.map((a) => a.agent), ['server-b-fresh', 'server-a-stale']);
    });
  });
}
