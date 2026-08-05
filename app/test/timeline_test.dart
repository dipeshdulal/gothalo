import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/core/theme.dart'; // AgentStatusUi.label
import 'package:gothalo/data/bridge/bridge_client.dart';
import 'package:gothalo/features/timeline/timeline_screen.dart';

void main() {
  group('TimelineEntry parsing', () {
    test('parses a full transition from the bridge shape', () {
      final e = TimelineEntry.fromJson({
        'ts': 1785681000000,
        'pane': 'acme/w1:p3',
        'agent': 'codex',
        'session': 'acme',
        'workspace': 'acme/w1',
        'from': 'blocked',
        'to': 'working',
        'prev_ms': 3012000,
      });

      expect(e.at.millisecondsSinceEpoch, 1785681000000);
      expect(e.pane, 'acme/w1:p3');
      expect(e.agent, 'codex');
      expect(e.session, 'acme');
      expect(e.workspace, 'acme/w1');
      expect(e.from, 'blocked');
      expect(e.to, 'working');
      expect(e.previous, const Duration(milliseconds: 3012000));
      expect(e.isGone, isFalse);
    });

    // A first sighting: the bridge omits `from` because it had never seen the
    // pane, which is NOT a transition out of an unnamed state.
    test('a first sighting has no from and no duration', () {
      final e = TimelineEntry.fromJson({
        'ts': 1785679000000,
        'pane': 'w4:p2',
        'agent': 'claude',
        'to': 'working',
      });

      expect(e.from, isNull);
      expect(e.previous, isNull);
      expect(e.session, isNull);
      expect(e.workspace, isNull);
    });

    // The distinction the whole endpoint hinges on: absent means "the bridge
    // could not see where the span began", zero means "it flipped instantly".
    // Conflating them would print "0s" for a duration nobody knows.
    test('prev_ms 0 is a real duration, absent is not', () {
      final instant = TimelineEntry.fromJson({
        'ts': 1,
        'pane': 'w1:p1',
        'to': 'idle',
        'from': 'working',
        'prev_ms': 0,
      });
      final unknown = TimelineEntry.fromJson({
        'ts': 1,
        'pane': 'w1:p1',
        'to': 'idle',
        'from': 'working',
      });

      expect(instant.previous, Duration.zero);
      expect(unknown.previous, isNull);
    });

    test('a closed pane is flagged, not special-cased by the caller', () {
      final e = TimelineEntry.fromJson({
        'ts': 1,
        'pane': 'w2:p9',
        'from': 'done',
        'to': 'gone',
      });
      expect(e.isGone, isTrue);
    });

    // A bridge field that is missing, null, or empty must never throw or leave a
    // half-built row — the same tolerance every other model in the app applies.
    test('an empty or absent payload degrades instead of throwing', () {
      final e = TimelineEntry.fromJson(const {});
      expect(e.pane, '');
      expect(e.agent, '');
      expect(e.to, '');
      expect(e.from, isNull);
      expect(e.previous, isNull);
      expect(e.at.millisecondsSinceEpoch, 0);

      // Empty strings are normalized to null so a renderer has one "nothing to
      // show" check rather than two.
      final blanks = TimelineEntry.fromJson({
        'ts': 1,
        'pane': 'w1:p1',
        'to': 'idle',
        'from': '',
        'session': '',
        'workspace': '',
      });
      expect(blanks.from, isNull);
      expect(blanks.session, isNull);
      expect(blanks.workspace, isNull);
    });
  });

  group('statusFromWire', () {
    test('maps every status the bridge can send', () {
      expect(statusFromWire('blocked').label, 'Blocked');
      expect(statusFromWire('working').label, 'Working');
      expect(statusFromWire('idle').label, 'Idle');
      expect(statusFromWire('done').label, 'Done');
    });

    // A status herdr adds later, or the bridge's synthetic `gone`, must degrade
    // rather than throw — the same rule Agent.agentStatus follows.
    test('an unrecognized status falls back to unknown', () {
      expect(statusFromWire('gone').label, 'Unknown');
      expect(statusFromWire('wat').label, 'Unknown');
      expect(statusFromWire('').label, 'Unknown');
    });
  });

  group('formatDuration', () {
    // Two units at most: the number exists for a snap judgement ("that block
    // cost me an hour"), and "1h 40m 12s" reads slower while saying no more.
    test('renders at most two units', () {
      expect(formatDuration(const Duration(seconds: 8)), '8s');
      expect(formatDuration(const Duration(seconds: 59)), '59s');
      expect(formatDuration(const Duration(minutes: 12)), '12m');
      expect(formatDuration(const Duration(minutes: 59)), '59m');
      expect(formatDuration(const Duration(hours: 1, minutes: 40)), '1h 40m');
      expect(formatDuration(const Duration(hours: 3)), '3h');
      expect(formatDuration(const Duration(days: 2, hours: 5)), '2d 5h');
      expect(formatDuration(const Duration(days: 2)), '2d');
    });

    test('zero and a backwards clock both render as 0s, never negative', () {
      expect(formatDuration(Duration.zero), '0s');
      expect(formatDuration(const Duration(seconds: -30)), '0s');
    });
  });

  group('dayLabel', () {
    final now = DateTime(2026, 8, 5, 14, 30);

    test('names today and yesterday, dates anything older', () {
      expect(dayLabel(DateTime(2026, 8, 5, 2), now: now), 'Today');
      expect(dayLabel(DateTime(2026, 8, 4, 23), now: now), 'Yesterday');
      expect(dayLabel(DateTime(2026, 8, 3, 9), now: now), '3 Aug');
    });

    // The window is 72h, so a header can legitimately cross a month or a year.
    test('crosses a month boundary correctly', () {
      final newYear = DateTime(2027, 1, 1, 0, 30);
      expect(dayLabel(DateTime(2026, 12, 31, 23), now: newYear), 'Yesterday');
      expect(dayLabel(DateTime(2026, 12, 30, 23), now: newYear), '30 Dec');
    });
  });
}
