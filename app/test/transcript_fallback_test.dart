import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/features/transcript/transcript_screen.dart';

void main() {
  group('transcriptVerdictFor', () {
    test('404 sends the user to the terminal rather than to a notice', () {
      // The bridge resolves the pane, its kind and its session before it
      // upgrades, so a 404 means "this pane has no readable conversation" —
      // not "the pane is missing". Its PTY is still attachable.
      expect(transcriptVerdictFor(404), TranscriptVerdict.useTerminal);
    });

    test('a rejected token is explained, never bounced', () {
      // The terminal authenticates with the same bearer, so dropping to it
      // would fail identically and read as the app losing the transcript.
      expect(transcriptVerdictFor(401), TranscriptVerdict.explain);
      expect(transcriptVerdictFor(403), TranscriptVerdict.explain);
    });

    test('a server-side read failure is explained, not buried', () {
      // 500 is a bug someone should see. Silently landing in the terminal
      // would hide it behind a screen that happens to work.
      expect(transcriptVerdictFor(500), TranscriptVerdict.explain);
    });

    test('a bridge that is down stays retryable', () {
      // 502/503 is the daemon not running yet — transient by construction, and
      // the reconnect loop is what recovers from it.
      expect(transcriptVerdictFor(502), TranscriptVerdict.retry);
      expect(transcriptVerdictFor(503), TranscriptVerdict.retry);
    });

    test('an unrecognised status retries rather than stranding the screen', () {
      // Never upgrade an unknown answer into a permanent verdict: retrying
      // costs a reconnect, guessing costs the user their transcript.
      expect(transcriptVerdictFor(0), TranscriptVerdict.retry);
      expect(transcriptVerdictFor(200), TranscriptVerdict.retry);
      expect(transcriptVerdictFor(418), TranscriptVerdict.retry);
    });
  });

  group('transcriptFailureMessage', () {
    test('every verdict-bearing status has something to say', () {
      for (final status in [401, 403, 404, 500]) {
        expect(transcriptFailureMessage(status), isNotEmpty);
      }
    });

    test('an unknown status still yields a sentence, not an empty screen', () {
      expect(transcriptFailureMessage(418), isNotEmpty);
    });
  });
}
