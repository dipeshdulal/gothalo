import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/core/widgets/agent_age.dart';
import 'package:gothalo/data/bridge/models/snapshot.dart';

/// The age is the number that decides whether you act on a row. Two properties
/// matter more than the formatting: unknown must stay unknown, and the short end
/// must keep its resolution.

void main() {
  group('formatAgentAge', () {
    test('keeps resolution where the decision is', () {
      // 30s vs 30m is the difference between ignoring a row and opening it.
      expect(formatAgentAge(const Duration(seconds: 5)), '5s');
      expect(formatAgentAge(const Duration(seconds: 59)), '59s');
      expect(formatAgentAge(const Duration(minutes: 1)), '1m');
      expect(formatAgentAge(const Duration(minutes: 50)), '50m');
    });

    test('drops precision once it stops mattering', () {
      // Nobody chooses differently at 3h14m than at 3h.
      expect(formatAgentAge(const Duration(hours: 3, minutes: 14)), '3h');
      expect(formatAgentAge(const Duration(hours: 23)), '23h');
      expect(formatAgentAge(const Duration(days: 2, hours: 5)), '2d');
    });

    test('a real zero renders as zero, not as nothing', () {
      expect(formatAgentAge(Duration.zero), '0s');
    });
  });

  group('Agent.sinceLastActivity', () {
    test('null when the bridge could not date the agent', () {
      // Absent must never become "just now" — that is backwards for an agent
      // parked for hours, and it is exactly the row you would then ignore.
      expect(const Agent().sinceLastActivity, isNull);
      expect(const Agent(lastActivityTs: 0).sinceLastActivity, isNull);
    });

    test('measures back from the reported timestamp', () {
      final tenMinutesAgo = DateTime.now()
          .subtract(const Duration(minutes: 10))
          .millisecondsSinceEpoch;
      final d = Agent(lastActivityTs: tenMinutesAgo).sinceLastActivity;
      expect(d, isNotNull);
      expect(d!.inMinutes, 10);
    });

    test('a clock skewed into the future clamps to zero, never negative', () {
      final ahead = DateTime.now()
          .add(const Duration(minutes: 5))
          .millisecondsSinceEpoch;
      expect(Agent(lastActivityTs: ahead).sinceLastActivity, Duration.zero);
    });

    test('survives the snapshot round-trip', () {
      final a = Agent.fromJson(const {
        'pane_id': 'w1:p1',
        'agent': 'claude',
        'last_activity_ts': 1785991520989,
      });
      expect(a.lastActivityTs, 1785991520989);
    });

    test('an older bridge that omits the field parses to null', () {
      final a = Agent.fromJson(const {'pane_id': 'w1:p1', 'agent': 'claude'});
      expect(a.lastActivityTs, isNull);
      expect(a.sinceLastActivity, isNull);
    });
  });
}
