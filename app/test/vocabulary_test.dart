import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/core/connection/connection_providers.dart';
import 'package:gothalo/core/naming.dart';
import 'package:gothalo/data/bridge/models/snapshot.dart';
import 'package:gothalo/features/priority/priority_providers.dart';
import 'package:gothalo/features/servers/servers_screen.dart';

/// The vocabulary rules, as functions.
///
/// The app navigates by Herdr's ids and speaks in the user's nouns, and the way
/// that arrangement fails is always the same: an id leaks into a label. A pane
/// id where a name should be, a `w8` where a project should be. These pin the
/// derivations every screen title and row is built from, so the leak is caught
/// here rather than on someone's phone.

ServerSummary _server(String id, {String? name}) =>
    ServerSummary(id: id, name: name ?? id, baseUrl: 'http://$id', isActive: false);

Agent _agent(
  String paneId, {
  AgentStatus status = AgentStatus.idle,
  String cwd = '',
  String branch = '',
}) => Agent(
  agent: 'claude',
  paneId: paneId,
  agentStatus: status,
  title: paneId,
  cwd: cwd,
  branch: branch,
);

void main() {
  group('a terminal is named for what runs in it and where', () {
    test('an idle shell is a shell in its project', () {
      const pane = Pane(
        paneId: 'w1N:p3',
        // A shell sitting at its prompt sets the terminal title to the prompt.
        title: 'd@mac:~/projects/gothalo',
        cwd: '/Users/d/projects/gothalo',
      );

      expect(terminalTitle(pane), 'shell · gothalo');
      // The thing this replaces.
      expect(terminalTitle(pane), isNot(contains('w1N:p3')));
    });

    test('a running command names itself', () {
      const pane = Pane(
        paneId: 'w1N:p3',
        title: 'npm run dev',
        cwd: '/Users/d/projects/gothalo/app',
      );

      expect(terminalTitle(pane), 'npm run dev · app');
    });

    test('the live foreground directory wins over the launch one', () {
      const pane = Pane(
        paneId: 'w1N:p3',
        title: 'd@mac:~',
        cwd: '/Users/d',
        foregroundCwd: '/Users/d/projects/acme',
      );

      expect(terminalTitle(pane), 'shell · acme');
    });

    test('no project at all still is not a pane id', () {
      const pane = Pane(paneId: 'w1N:p3', title: 'htop');

      expect(terminalTitle(pane), 'htop');
    });
  });

  group('a project is a repo and a branch', () {
    test('joins them with the app\'s separator', () {
      expect(projectLabel('gothalo', 'feat/x'), 'gothalo · feat/x');
    });

    test('a branchless checkout does not trail a dangling separator', () {
      expect(projectLabel('gothalo'), 'gothalo');
      expect(projectLabel('gothalo', ''), 'gothalo');
      expect(projectLabel('gothalo', '   '), 'gothalo');
    });

    test('an agent reports the branch the bridge gave it', () {
      final agent = _agent(
        'w5:p1',
        cwd: '/Users/d/projects/gothalo',
        branch: 'feat/ui-foundation',
      );

      expect(agent.projectLine, 'gothalo · feat/ui-foundation');
      expect(agent.projectName, 'gothalo');
    });

    test('a herdr worktree reveals its branch through the path', () {
      final agent = _agent(
        'w5:p1',
        cwd: '/Users/d/.herdr/worktrees/gothalo/feat-recent-agents',
      );

      // No `branch` from the bridge, but the worktree layout carries it.
      expect(agent.projectLine, 'gothalo · feat-recent-agents');
    });

    test('a workspace prefers the repo name Herdr reports for it', () {
      const ws = WorkspaceInfo(
        workspaceId: 'w8',
        label: 'w8',
        worktree: WorktreeInfo(
          checkoutPath: '/Users/d/projects/gothalo',
          repoName: 'gothalo',
        ),
      );

      final named = projectOf(ws, '/Users/d/projects/gothalo');
      expect(named.project, 'gothalo');
      expect(named.branch, isNull);
    });

    test('a nameless workspace is Untitled, never its id', () {
      const ws = WorkspaceInfo(workspaceId: 'w8');

      expect(projectOf(ws, '').project, 'Untitled');
      expect(projectOf(null, '').project, 'Untitled');
    });
  });

  group('the home screen groups agents by what they are doing', () {
    ServerAgents live(String id, List<Agent> agents) =>
        ServerAgents(server: _server(id), agents: agents);

    test('needs you, then working, then idle — empty groups omitted', () {
      final servers = [
        live('s1', [
          _agent('idle1'),
          _agent('work1', status: AgentStatus.working),
          _agent('block1', status: AgentStatus.blocked),
          _agent('done1', status: AgentStatus.done),
        ]),
      ];

      final groups = groupAgentsByState(servers);

      expect(groups.map((g) => g.label), ['Needs you', 'Working', 'Idle']);
      // Blocked and done both want a human; blocked comes first inside the group.
      expect(groups.first.agents.map((h) => h.agent.paneId), [
        'block1',
        'done1',
      ]);
      expect(groups.first.emphasize, isTrue);
      expect(groups[1].emphasize, isFalse);
    });

    test('an unknown status is grouped with idle, not dropped', () {
      final servers = [
        live('s1', [_agent('mystery', status: AgentStatus.unknown)]),
      ];

      final groups = groupAgentsByState(servers);

      expect(groups.single.label, 'Idle');
    });

    test('it spans every server', () {
      final groups = groupAgentsByState([
        live('s1', [_agent('a', status: AgentStatus.working)]),
        live('s2', [_agent('b', status: AgentStatus.working)]),
      ]);

      expect(groups.single.agents.map((h) => h.server.id), ['s1', 's2']);
    });

    test('an unreachable server contributes nothing', () {
      final groups = groupAgentsByState([
        ServerAgents(server: _server('s1'), error: 'asleep'),
        live('s2', [_agent('b', status: AgentStatus.working)]),
      ]);

      expect(groups.single.agents.length, 1);
    });

    test('what Priority and Recent already show is excluded', () {
      final servers = [
        live('s1', [
          _agent('shown', status: AgentStatus.working),
          _agent('other', status: AgentStatus.working),
        ]),
      ];

      final groups = groupAgentsByState(
        servers,
        exclude: {'s1::shown'},
      );

      // One agent, one row: an agent already on screen above is not repeated.
      expect(groups.single.agents.map((h) => h.agent.paneId), ['other']);
    });

    test('excluding everything leaves no headings behind', () {
      final servers = [
        live('s1', [_agent('a', status: AgentStatus.working)]),
      ];

      expect(groupAgentsByState(servers, exclude: {'s1::a'}), isEmpty);
    });

    test('nothing paired is an empty list, not a crash', () {
      expect(groupAgentsByState(const []), isEmpty);
    });
  });
}
