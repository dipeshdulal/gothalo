import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/core/connection/connection_providers.dart';
import 'package:gothalo/data/bridge/models/snapshot.dart';
import 'package:gothalo/features/priority/priority_providers.dart';
import 'package:gothalo/features/recents/recent_providers.dart';

ServerSummary _server(String id) =>
    ServerSummary(id: id, name: id, baseUrl: 'http://$id', isActive: false);

final _snapshot = Snapshot(
  workspaces: const [
    WorkspaceInfo(
      workspaceId: 'w1',
      worktree: WorktreeInfo(
        checkoutPath: '/Users/d/projects/gothalo',
        repoName: 'gothalo',
      ),
    ),
    WorkspaceInfo(
      workspaceId: 'w2',
      worktree: WorktreeInfo(
        checkoutPath: '/Users/d/.herdr/worktrees/gothalo/feat-mobile',
        repoName: 'gothalo',
        isLinkedWorktree: true,
      ),
    ),
  ],
  panes: const [
    Pane(paneId: 'w1:p1', workspaceId: 'w1', cwd: '/Users/d/projects/gothalo'),
    Pane(
      paneId: 'w1:p2',
      workspaceId: 'w1',
      cwd: '/Users/d/projects/gothalo/app',
      title: 'npm run dev',
    ),
    Pane(
      paneId: 'w2:p1',
      workspaceId: 'w2',
      cwd: '/Users/d/.herdr/worktrees/gothalo/feat-mobile',
    ),
  ],
  agents: const [
    Agent(
      agent: 'gemini',
      paneId: 'w1:p1',
      workspaceId: 'w1',
      title: 'Project work',
    ),
  ],
);

void main() {
  test(
    'recent projects resolve against live spaces, including terminal-only ones',
    () {
      final rows = resolveRecentSpaces(
        [
          const RecentSpaceOpen(serverId: 's1', workspaceId: 'w2', openedAt: 3),
          const RecentSpaceOpen(serverId: 's1', workspaceId: 'w1', openedAt: 2),
          const RecentSpaceOpen(
            serverId: 's1',
            workspaceId: 'gone',
            openedAt: 1,
          ),
        ],
        [
          ServerAgents(
            server: _server('s1'),
            agents: _snapshot.agents,
            snapshot: _snapshot,
          ),
        ],
      );

      expect(rows.map((r) => r.workspaceId), ['w2', 'w1']);
      expect(rows.first.project, 'gothalo');
      expect(rows.first.branch, 'feat-mobile');
      expect(rows.first.agentCount, 0);
      expect(rows.first.terminalCount, 1);
      expect(rows.first.route, '/overview/w2');
      expect(rows.last.agentCount, 1);
      expect(rows.last.terminalCount, 1);
    },
  );

  test('space history is bounded after the visible cap', () {
    final hits = [
      for (var i = 0; i < kRecentSpaceStoreLimit + 3; i++)
        RecentSpaceHit(
          server: _server('s1'),
          workspaceId: 'w$i',
          workspace: null,
          project: 'project-$i',
          branch: null,
          agentCount: 0,
          terminalCount: 1,
          needsAttention: false,
        ),
    ];

    expect(recentSpaceRows(hits).length, kRecentSpaceVisibleRows);
    expect(kRecentSpaceStoreLimit, greaterThan(kRecentSpaceVisibleRows));
  });

  test('the same project is listed once, a different worktree is not', () {
    RecentSpaceHit hit(
      String workspaceId,
      String project, {
      String? branch,
    }) => RecentSpaceHit(
      server: _server('s1'),
      workspaceId: workspaceId,
      workspace: null,
      project: project,
      branch: branch,
      agentCount: 0,
      terminalCount: 1,
      needsAttention: false,
    );

    final rows = recentSpaceRows([
      // Two spaces on one checkout: same project, same branch. The newest
      // workspace wins and the older one is dropped.
      hit('w2', 'gothalo'),
      hit('w1', 'gothalo'),
      // A worktree of the same repo is a different destination and survives.
      hit('w3', 'gothalo', branch: 'feat-mobile'),
      // Another project entirely.
      hit('w4', 'storefront'),
    ]);

    expect(rows.map((r) => r.workspaceId), ['w2', 'w3', 'w4']);
  });

  test('space history round-trips and ignores malformed entries', () {
    final raw = encodeRecentSpaces([
      const RecentSpaceOpen(serverId: 's1', workspaceId: 'w1', openedAt: 9),
    ]);
    final decoded = decodeRecentSpaces(
      raw.replaceFirst('[', '[{"server_id":"s1"},'),
    );

    expect(decoded.single.workspaceId, 'w1');
    expect(decoded.single.openedAt, 9);
    expect(decodeRecentSpaces('{not json'), isEmpty);
  });
}
