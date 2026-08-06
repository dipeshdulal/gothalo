import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/data/bridge/models/snapshot.dart';
import 'package:gothalo/features/home_widget/fleet_counts.dart';

Agent _agent(
  String title,
  AgentStatus status, {
  int? rank,
  int? activeAt,
}) => Agent(
  paneId: title,
  title: title,
  agentStatus: status,
  attentionRank: rank,
  lastActivityTs: activeAt,
);

void main() {
  group('ServerCounts.fromAgents', () {
    test('counts each status the widget draws, and nothing else', () {
      final counts = ServerCounts.fromAgents('Mac Studio', [
        _agent('a', AgentStatus.blocked),
        _agent('b', AgentStatus.blocked),
        _agent('c', AgentStatus.working),
        _agent('d', AgentStatus.done),
        _agent('e', AgentStatus.idle),
        _agent('f', AgentStatus.unknown),
      ], 1000);

      expect(counts.needsYou, 2); // blocked only — done is its own number
      expect(counts.working, 1);
      expect(counts.done, 1);
      expect(counts.total, 6);
      expect(counts.updatedAt, 1000);
    });

    test('lines are the attention-worthy agents, most urgent first', () {
      final counts = ServerCounts.fromAgents('Mac Studio', [
        _agent('finished', AgentStatus.done, rank: 1),
        _agent('waiting', AgentStatus.blocked, rank: 0),
        _agent('busy', AgentStatus.working, rank: 2),
        _agent('parked', AgentStatus.idle, rank: 3),
      ], 1000);

      expect(counts.lines, ['waiting', 'finished']);
    });

    test('within a rank, lines follow the shared recency tiebreak', () {
      // The widget's rows are the head of the list its own tap opens, so it
      // must sort on Agent.byAttentionThenRecency rather than on attention
      // alone — otherwise the home screen and Priority disagree about which
      // blocked agent is first.
      final counts = ServerCounts.fromAgents('Mac Studio', [
        _agent('stale', AgentStatus.blocked, rank: 0, activeAt: 1000),
        _agent('undated', AgentStatus.blocked, rank: 0),
        _agent('fresh', AgentStatus.blocked, rank: 0, activeAt: 9000),
      ], 1000);

      // Most recent first; an agent with no timestamp sorts last, never first.
      expect(counts.lines, ['fresh', 'stale', 'undated']);
    });

    test('lines never exceed what the smallest cell can draw', () {
      final counts = ServerCounts.fromAgents('Mac Studio', [
        for (var i = 0; i < 10; i++) _agent('agent $i', AgentStatus.blocked),
      ], 1000);

      expect(counts.lines, hasLength(kFleetWidgetRows));
    });
  });

  group('ServerCounts.sameNumbers', () {
    test('ignores the timestamp, so an unchanged fleet is not republished', () {
      final agents = [
        _agent('waiting', AgentStatus.blocked),
        _agent('busy', AgentStatus.working),
      ];
      final a = ServerCounts.fromAgents('Mac Studio', agents, 1000);
      final b = ServerCounts.fromAgents('Mac Studio', agents, 9999);
      expect(a.sameNumbers(b), isTrue);
    });

    test('a changed title is a change, even at identical counts', () {
      final a = ServerCounts.fromAgents('Mac Studio', [
        _agent('waiting on rm', AgentStatus.blocked),
      ], 1000);
      final b = ServerCounts.fromAgents('Mac Studio', [
        _agent('waiting on push', AgentStatus.blocked),
      ], 1000);
      expect(a.sameNumbers(b), isFalse);
    });

    test('a renamed server is a change; nothing matches a missing bucket', () {
      final agents = [_agent('waiting', AgentStatus.blocked)];
      expect(
        ServerCounts.fromAgents('Mac Studio', agents, 1000)
            .sameNumbers(ServerCounts.fromAgents('Studio', agents, 1000)),
        isFalse,
      );
      expect(
        ServerCounts.fromAgents('Mac Studio', agents, 1000).sameNumbers(null),
        isFalse,
      );
    });
  });

  group('FleetCounts.merge', () {
    test('sums every server and takes the freshest timestamp', () {
      final fleet = FleetCounts.merge({
        's1': ServerCounts.fromAgents('Mac Studio', [
          _agent('a', AgentStatus.blocked),
          _agent('b', AgentStatus.working),
        ], 1000),
        's2': ServerCounts.fromAgents('Linux box', [
          _agent('c', AgentStatus.working),
          _agent('d', AgentStatus.done),
        ], 2000),
      });

      expect(fleet.needsYou, 1);
      expect(fleet.working, 2);
      expect(fleet.done, 1);
      expect(fleet.total, 4);
      expect(fleet.servers, 2);
      expect(fleet.updatedAt, 2000);
    });

    test('server-qualifies lines only when more than one server contributes', () {
      final one = FleetCounts.merge({
        's1': ServerCounts.fromAgents('Mac Studio', [
          _agent('fix auth', AgentStatus.blocked),
        ], 1000),
      });
      expect(one.lines, ['fix auth']);

      final two = FleetCounts.merge({
        's1': ServerCounts.fromAgents('Mac Studio', [
          _agent('fix auth', AgentStatus.blocked),
        ], 1000),
        's2': ServerCounts.fromAgents('Linux box', [
          _agent('run tests', AgentStatus.blocked),
        ], 1000),
      });
      expect(two.lines, ['fix auth  ·  Mac Studio', 'run tests  ·  Linux box']);
    });

    test('interleaves servers so one busy machine cannot fill every row', () {
      final fleet = FleetCounts.merge({
        's1': ServerCounts.fromAgents('A', [
          _agent('a1', AgentStatus.blocked),
          _agent('a2', AgentStatus.blocked),
          _agent('a3', AgentStatus.blocked),
        ], 1000),
        's2': ServerCounts.fromAgents('B', [
          _agent('b1', AgentStatus.blocked),
        ], 1000),
      });

      expect(fleet.lines, hasLength(kFleetWidgetRows));
      expect(fleet.lines[0], startsWith('a1'));
      expect(fleet.lines[1], startsWith('b1'));
      expect(fleet.lines[2], startsWith('a2'));
    });

    test('no servers is an empty fleet, not a zeroed one', () {
      expect(FleetCounts.merge({}).servers, 0);
      expect(FleetCounts.merge({}).updatedAt, 0);
    });
  });

  group('bucket storage', () {
    test('round-trips through the widget store encoding', () {
      final buckets = {
        's1': ServerCounts.fromAgents('Mac Studio', [
          _agent('fix auth', AgentStatus.blocked),
          _agent('build', AgentStatus.working),
        ], 4242),
      };

      final back = decodeBuckets(encodeBuckets(buckets));
      expect(back.keys, ['s1']);
      expect(back['s1']!.serverName, 'Mac Studio');
      expect(back['s1']!.needsYou, 1);
      expect(back['s1']!.working, 1);
      expect(back['s1']!.lines, ['fix auth']);
      expect(back['s1']!.updatedAt, 4242);
    });

    test('a corrupt or missing store costs the numbers, never a throw', () {
      expect(decodeBuckets(null), isEmpty);
      expect(decodeBuckets(''), isEmpty);
      expect(decodeBuckets('not json'), isEmpty);
      expect(decodeBuckets('{"s1":"wrong shape"}'), isEmpty);
    });
  });
}
