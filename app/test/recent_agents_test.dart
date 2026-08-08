import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/core/connection/connection_providers.dart';
import 'package:gothalo/data/bridge/models/snapshot.dart';
import 'package:gothalo/features/priority/priority_providers.dart';
import 'package:gothalo/features/recents/recent_providers.dart';

/// The Recent section is this device's own navigation history, and every part
/// of it is the kind of thing that rots silently: a cap that stops capping, a
/// dedupe that starts double-listing, a dead row that survives its pane, a
/// history that quietly stops surviving a restart. None of those announce
/// themselves in the UI — the section just gets subtly wrong. So each is
/// pinned here.

/// A stand-in keystore. Subclassing rather than mocking the channel keeps the
/// notifier's real read/write path under test, which is the half that has to
/// survive an app restart.
class _MemoryStorage extends FlutterSecureStorage {
  _MemoryStorage([Map<String, String>? seed]) : store = {...?seed};

  final Map<String, String> store;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => store[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      store.remove(key);
    } else {
      store[key] = value;
    }
  }
}

ServerSummary _server(String id) =>
    ServerSummary(id: id, name: id, baseUrl: 'http://$id', isActive: false);

Agent _agent(String paneId, {AgentStatus status = AgentStatus.idle}) =>
    Agent(agent: 'claude', paneId: paneId, agentStatus: status, title: paneId);

ServerAgents _live(String serverId, List<String> paneIds) =>
    ServerAgents(server: _server(serverId), agents: [for (final p in paneIds) _agent(p)]);

RecentOpen _open(
  String serverId,
  String paneId, {
  OpenedView view = OpenedView.transcript,
  int at = 0,
}) => RecentOpen(
  serverId: serverId,
  paneId: paneId,
  view: view,
  openedAt: at,
);

RecentHit _hit(String serverId, String paneId) =>
    RecentHit(server: _server(serverId), agent: _agent(paneId), view: OpenedView.transcript);

void main() {
  group('the cap', () {
    test('shows at most four, and they are the four most recent', () {
      // Stored newest-first, which is the order the notifier writes.
      final hits = [for (var i = 0; i < 9; i++) _hit('s1', 'w1:p$i')];

      final rows = recentRows(hits);

      expect(rows.length, kRecentVisibleRows);
      expect(rows.map((r) => r.agent.paneId), [
        'w1:p0',
        'w1:p1',
        'w1:p2',
        'w1:p3',
      ]);
    });

    test('a short history is shown whole, not padded', () {
      expect(recentRows([_hit('s1', 'a'), _hit('s1', 'b')]).length, 2);
    });

    test('the stored history is deeper than the visible cap', () {
      // Rows drop out when their pane dies, so a history exactly as long as the
      // cap would show three rows after one worktree was removed.
      expect(kRecentStoreLimit, greaterThan(kRecentVisibleRows));
    });
  });

  group('the dedupe against Priority', () {
    test('an agent already in Priority is not repeated as recent', () {
      final hits = [_hit('s1', 'a'), _hit('s1', 'b'), _hit('s1', 'c')];

      final rows = recentRows(hits, exclude: {recentKey('s1', 'b')});

      expect(rows.map((r) => r.agent.paneId), ['a', 'c']);
    });

    test('the same pane id on another server is a different agent', () {
      final hits = [_hit('s1', 'w1:p1'), _hit('s2', 'w1:p1')];

      // Excluding s1's copy must not take s2's with it — pane ids repeat across
      // bridges, which is why the key carries the server.
      final rows = recentRows(hits, exclude: {recentKey('s1', 'w1:p1')});

      expect(rows.length, 1);
      expect(rows.single.server.id, 's2');
    });

    test('a deduped entry is backfilled, not left as a gap', () {
      final hits = [for (var i = 0; i < 6; i++) _hit('s1', 'p$i')];

      final rows = recentRows(hits, exclude: {recentKey('s1', 'p1')});

      // Still four rows: the cap applies after the exclusion.
      expect(rows.length, kRecentVisibleRows);
      expect(rows.map((r) => r.agent.paneId), ['p0', 'p2', 'p3', 'p4']);
    });
  });

  group('entries whose pane is gone', () {
    test('drop out silently, and the rest keep their order', () {
      final opens = [
        _open('s1', 'gone'),
        _open('s1', 'alive'),
        _open('s1', 'also-gone'),
      ];

      final rows = resolveRecents(opens, [_live('s1', ['alive'])]);

      expect(rows.map((r) => r.agent.paneId), ['alive']);
    });

    test('an unreachable server contributes nothing rather than an error', () {
      final asleep = ServerAgents(server: _server('s1'), error: 'timeout');

      expect(resolveRecents([_open('s1', 'p1')], [asleep]), isEmpty);
    });

    test('an unpaired server contributes nothing', () {
      expect(resolveRecents([_open('deleted', 'p1')], [_live('s1', ['p1'])]), isEmpty);
    });

    test('a server coming back restores its rows', () {
      final opens = [_open('s1', 'p1')];

      expect(resolveRecents(opens, [ServerAgents(server: _server('s1'), error: 'x')]), isEmpty);
      expect(resolveRecents(opens, [_live('s1', ['p1'])]).length, 1);
    });

    test('the live agent is used, not a cached copy of it', () {
      final opens = [_open('s1', 'p1')];
      final servers = [
        ServerAgents(
          server: _server('s1'),
          agents: [_agent('p1', status: AgentStatus.blocked)],
        ),
      ];

      // Nothing about the agent is stored, so a row can never disagree with the
      // same agent's row elsewhere on the screen.
      expect(resolveRecents(opens, servers).single.agent.agentStatus,
          AgentStatus.blocked);
    });

    test('the view you left it in is what the row reopens', () {
      final rows = resolveRecents(
        [_open('s1', 'p1', view: OpenedView.terminal)],
        [_live('s1', ['p1'])],
      );

      expect(rows.single.route, '/terminal/${Uri.encodeComponent('p1')}');
    });

    test('a session-qualified pane id survives the round trip to a route', () {
      final rows = resolveRecents(
        [_open('s1', 'acme/w1:p2', view: OpenedView.transcript)],
        [_live('s1', ['acme/w1:p2'])],
      );

      // The slash in a session-qualified id has to be escaped or the router
      // reads it as another path segment.
      expect(rows.single.route, '/transcript/acme%2Fw1%3Ap2');
    });
  });

  group('persistence', () {
    ProviderContainer container(FlutterSecureStorage storage) =>
        ProviderContainer(
          overrides: [secureStorageProvider.overrideWithValue(storage)],
        );

    test('survives a restart, newest first, with the view intact', () async {
      final keystore = _MemoryStorage();

      final before = container(keystore);
      await before.read(recentOpensProvider.future);
      final opens = before.read(recentOpensProvider.notifier);
      await opens.record(
        serverId: 's1',
        paneId: 'w1:p1',
        view: OpenedView.transcript,
      );
      await opens.record(
        serverId: 's1',
        paneId: 'w1:p2',
        view: OpenedView.terminal,
      );
      before.dispose();

      // A cold start: a brand-new container reading the same keystore.
      final after = container(keystore);
      final restored = await after.read(recentOpensProvider.future);
      after.dispose();

      expect(restored.map((e) => e.paneId), ['w1:p2', 'w1:p1']);
      expect(restored.first.view, OpenedView.terminal);
    });

    test('reopening an agent moves it up rather than duplicating it', () async {
      final keystore = _MemoryStorage();
      final c = container(keystore);
      await c.read(recentOpensProvider.future);
      final opens = c.read(recentOpensProvider.notifier);

      await opens.record(serverId: 's1', paneId: 'a', view: OpenedView.transcript);
      await opens.record(serverId: 's1', paneId: 'b', view: OpenedView.transcript);
      await opens.record(serverId: 's1', paneId: 'a', view: OpenedView.terminal);
      c.dispose();

      final after = container(keystore);
      final restored = await after.read(recentOpensProvider.future);
      after.dispose();

      expect(restored.map((e) => e.paneId), ['a', 'b']);
      // The cap counts agents, not taps — and the view is refreshed to the one
      // you were most recently in.
      expect(restored.first.view, OpenedView.terminal);
    });

    test('the stored history is bounded', () async {
      final keystore = _MemoryStorage();
      final c = container(keystore);
      await c.read(recentOpensProvider.future);
      final opens = c.read(recentOpensProvider.notifier);

      for (var i = 0; i < kRecentStoreLimit + 6; i++) {
        await opens.record(
          serverId: 's1',
          paneId: 'p$i',
          view: OpenedView.transcript,
        );
      }
      c.dispose();

      final after = container(keystore);
      final restored = await after.read(recentOpensProvider.future);
      after.dispose();

      expect(restored.length, kRecentStoreLimit);
      expect(restored.first.paneId, 'p${kRecentStoreLimit + 5}');
    });

    test('recording before the store has loaded keeps the history', () async {
      // A cold start: home mounts, the keystore read is still in flight, and
      // the user taps straight into an agent. Reading the not-yet-loaded state
      // here would write a one-entry history over everything remembered.
      final keystore = _MemoryStorage({
        'gothalo.recent_agents': encodeRecents([_open('s1', 'from-last-time')]),
      });

      final c = container(keystore);
      // Deliberately NOT awaiting the provider's future first.
      await c
          .read(recentOpensProvider.notifier)
          .record(serverId: 's1', paneId: 'just-opened', view: OpenedView.transcript);
      final now = await c.read(recentOpensProvider.future);
      c.dispose();

      expect(now.map((e) => e.paneId), ['just-opened', 'from-last-time']);
    });

    test('a corrupt blob costs the history, not the screen', () async {
      final keystore = _MemoryStorage({'gothalo.recent_agents': '{not json'});

      final c = container(keystore);
      final restored = await c.read(recentOpensProvider.future);
      c.dispose();

      expect(restored, isEmpty);
    });

    test('an unreadable row is dropped, the readable ones are kept', () {
      final raw = encodeRecents([_open('s1', 'good', at: 5)]);
      // Splice in a row that is missing its pane id, as a partial write would.
      final withJunk = raw.replaceFirst('[', '[{"server_id":"s1"},');

      final decoded = decodeRecents(withJunk);

      expect(decoded.map((e) => e.paneId), ['good']);
    });

    test('an unknown view falls back to the chat rather than throwing', () {
      final decoded = decodeRecents(
        '[{"server_id":"s1","pane_id":"p","view":"hologram","opened_at":1}]',
      );

      expect(decoded.single.view, OpenedView.transcript);
    });

    test('nothing stored is an empty history, not an error', () {
      expect(decodeRecents(null), isEmpty);
      expect(decodeRecents(''), isEmpty);
    });
  });
}
