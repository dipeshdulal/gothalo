import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/features/transcript/transcript_models.dart';

void main() {
  group('session_changed (protocol 4)', () {
    test('parses from/to so a rotation can be announced against its hello', () {
      final frame = TranscriptFrame.fromJson({
        'type': 'session_changed',
        'pane': 'w1:p2',
        'from': 'b0651a43-38fc-4f8b-8b03-c8611cdb9237',
        'to': '7d2c19f0-1111-2222-3333-444455556666',
      });

      expect(frame.type, TranscriptFrameType.sessionChanged);
      expect(frame.fromSessionId, 'b0651a43-38fc-4f8b-8b03-c8611cdb9237');
      expect(frame.toSessionId, '7d2c19f0-1111-2222-3333-444455556666');
    });

    test('missing ids degrade to empty strings rather than throwing', () {
      final frame = TranscriptFrame.fromJson({'type': 'session_changed'});
      expect(frame.type, TranscriptFrameType.sessionChanged);
      expect(frame.fromSessionId, '');
      expect(frame.toSessionId, '');
    });

    test('a hello still carries the session id the reset keys off', () {
      final frame = TranscriptFrame.fromJson({
        'type': 'hello',
        'protocol': 4,
        'pane': 'w1:p2',
        'agent_kind': 'claude',
        'session_id': '7d2c19f0-1111-2222-3333-444455556666',
        'backlog_count': 2,
        'total': 2,
        'oldest_loaded_seq': 1,
        'has_older': false,
      });

      expect(frame.type, TranscriptFrameType.hello);
      expect(frame.hello?.protocol, 4);
      expect(frame.hello?.sessionId, '7d2c19f0-1111-2222-3333-444455556666');
      expect(frame.hello?.oldestLoadedSeq, 1);
    });
  });
}
