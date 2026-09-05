import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/features/transcript/transcript_models.dart';

void main() {
  group('hello.subagents (protocol 4)', () {
    test('parses the roster the contract documents', () {
      final frame = TranscriptFrame.fromJson({
        'type': 'hello',
        'protocol': 4,
        'pane': 'wN:p1',
        'agent_kind': 'claude',
        'session_id': 'b0651a43-38fc-4f8b-8b03-c8611cdb9237',
        'backlog_count': 150,
        'total': 1025,
        'has_more': true,
        'oldest_loaded_seq': 876,
        'has_older': true,
        'subagents': [
          {
            'agent_id': 'aa4832e5ce82b16f0',
            'tool_use_id': 'toolu_01F9bssr6JjRZXjvEumqMwuR',
            'agent_type': 'general-purpose',
            'description': 'Build recent-activity timeline',
            'spawn_depth': 1,
          },
          {
            'agent_id': 'a9adcab7329a772ac',
            'tool_use_id': 'toolu_013gpQcoGTMVRYdciecEq7rZ',
            'agent_type': 'Explore',
            'description': 'Explore Flutter app conventions',
            'spawn_depth': 2,
          },
        ],
      });

      final roster = frame.hello!.subagents;
      expect(roster, hasLength(2));
      expect(roster.first.agentId, 'aa4832e5ce82b16f0');
      expect(roster.first.toolUseId, 'toolu_01F9bssr6JjRZXjvEumqMwuR');
      expect(roster.first.agentType, 'general-purpose');
      expect(roster.first.description, 'Build recent-activity timeline');
      expect(roster.first.spawnDepth, 1);
      expect(roster.last.spawnDepth, 2);
    });

    /// The key is omitted for a session that delegated nothing — the norm.
    test('an absent roster is empty, not null', () {
      final frame = TranscriptFrame.fromJson({
        'type': 'hello',
        'protocol': 4,
        'pane': 'wN:p1',
        'agent_kind': 'claude',
        'session_id': 'b0651a43',
        'backlog_count': 0,
        'total': 0,
      });

      expect(frame.hello!.subagents, isEmpty);
    });

    test('echoes the subagent being streamed so a reconnect knows where it is',
        () {
      final frame = TranscriptFrame.fromJson({
        'type': 'hello',
        'protocol': 4,
        'pane': 'wN:p1',
        'agent_kind': 'claude',
        'session_id': 'b0651a43',
        'backlog_count': 0,
        'total': 0,
        'subagent': 'aa4832e5ce82b16f0',
      });

      expect(frame.hello!.subagent, 'aa4832e5ce82b16f0');
    });
  });

  group('SubagentRoster', () {
    final roster = SubagentRoster([
      const Subagent(
        agentId: 'aa4832e5ce82b16f0',
        toolUseId: 'toolu_parent',
        agentType: 'general-purpose',
        description: 'Build recent-activity timeline',
        spawnDepth: 1,
      ),
      const Subagent(
        agentId: 'a9adcab7329a772ac',
        toolUseId: 'toolu_child',
        agentType: 'Explore',
        description: 'Explore Flutter app conventions',
        spawnDepth: 2,
      ),
    ]);

    test('finds the subagent a tool call spawned', () {
      expect(roster.forToolUse('toolu_parent')?.agentId, 'aa4832e5ce82b16f0');
    });

    /// The roster is flat and covers every depth, so a depth-2 entry is found
    /// by the same lookup when its parent subagent's transcript is on screen.
    test('finds a deeper subagent by the same lookup', () {
      expect(roster.forToolUse('toolu_child')?.agentType, 'Explore');
    });

    test('a tool call that spawned nothing has no entry', () {
      expect(roster.forToolUse('toolu_bash'), isNull);
    });
  });
}
