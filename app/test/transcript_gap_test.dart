import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/features/transcript/transcript_models.dart';

/// A transcript hides where time went: once rendered, a turn that took four
/// minutes looks exactly like one that took a second. The gap label restores
/// that — but only for pauses the AGENT is responsible for. The pause before
/// YOUR message is you being away, and labelling it would litter every
/// overnight session with hours-long "gaps".

TranscriptEntry entry({
  required int seq,
  required String role,
  String? ts,
  String kind = 'message',
}) => TranscriptEntry(
  id: 'e$seq',
  seq: seq,
  ts: ts,
  roleRaw: role,
  kindRaw: kind,
  parsed: true,
);

void main() {
  group('TranscriptEntry.at', () {
    test('parses the ISO timestamp the bridge sends', () {
      final e = entry(seq: 1, role: 'assistant', ts: '2026-08-06T05:32:43.666Z');
      expect(e.at, isNotNull);
      expect(e.at!.toUtc(), DateTime.utc(2026, 8, 6, 5, 32, 43, 666));
    });

    test('null when the source line carried none', () {
      expect(entry(seq: 1, role: 'assistant').at, isNull);
      expect(entry(seq: 1, role: 'assistant', ts: '').at, isNull);
      expect(entry(seq: 1, role: 'assistant', ts: 'not a date').at, isNull);
    });
  });

  group('which pauses are the agent thinking', () {
    // The rule the screen applies: a gap counts when the entry AFTER it is the
    // assistant. These assert the rule's inputs rather than the widget tree, so
    // they stay honest if the rendering changes.
    test('assistant follows user — that pause is the agent working', () {
      final user = entry(
        seq: 1,
        role: 'user',
        ts: '2026-08-06T05:00:00.000Z',
      );
      final assistant = entry(
        seq: 2,
        role: 'assistant',
        ts: '2026-08-06T05:00:45.000Z',
      );
      expect(assistant.role, EntryRole.assistant);
      expect(assistant.at!.difference(user.at!), const Duration(seconds: 45));
    });

    test('user follows assistant — that pause is the human, not the agent', () {
      final assistant = entry(
        seq: 1,
        role: 'assistant',
        ts: '2026-08-06T05:00:00.000Z',
      );
      final user = entry(
        seq: 2,
        role: 'user',
        ts: '2026-08-06T13:00:00.000Z',
      );
      // Eight hours. Labelling this would claim the agent "thought" overnight.
      expect(user.role, EntryRole.user);
      expect(user.at!.difference(assistant.at!), const Duration(hours: 8));
    });

    test('a tool call is assistant-side, so its pause counts too', () {
      final e = entry(
        seq: 1,
        role: 'assistant',
        kind: 'tool_call',
        ts: '2026-08-06T05:00:00.000Z',
      );
      expect(e.role, EntryRole.assistant);
      expect(e.kind, EntryKind.toolCall);
    });
  });
}
