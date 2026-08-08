import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/data/bridge/bridge_client.dart';

/// The `GET /suggestions` payload as the bridge actually writes it — see
/// `docs/CONTRACT-suggestions.md`.
Map<String, dynamic> json({
  String kind = 'git_dirty',
  String performer = 'app',
  String label = 'Review changes',
  String detail = '3 files changed',
  String action = 'open_diff',
  Map<String, dynamic>? params,
  int rank = 20,
}) => {
  'kind': kind,
  'performer': performer,
  'label': label,
  'detail': detail,
  'action': action,
  'params': params ?? {'pane': 'acme/w1:p2'},
  'rank': rank,
};

void main() {
  group('PaneSuggestion.fromJson', () {
    test('reads the contract shape', () {
      final s = PaneSuggestion.fromJson(json());
      expect(s.kind, 'git_dirty');
      expect(s.label, 'Review changes');
      expect(s.detail, '3 files changed');
      expect(s.action, 'open_diff');
      expect(s.rank, 20);
      // The pane must survive verbatim, session prefix and all — it is what
      // the diff route and the start-agent sheet are addressed with.
      expect(s.pane, 'acme/w1:p2');
    });

    // Every field except the envelope is optional in principle; a suggestion
    // that arrives half-formed must degrade to "not actionable" rather than
    // throw in the middle of a list rebuild.
    test('survives a payload with everything missing', () {
      final s = PaneSuggestion.fromJson(const {});
      expect(s.label, '');
      expect(s.pane, '');
      expect(s.isActionable, isFalse);
    });
  });

  group('isActionable', () {
    // The forward-compatibility rule: a newer bridge may offer actions this
    // build has no screen for, and rendering one would be a dead button.
    test('drops an action this build does not implement', () {
      expect(
        PaneSuggestion.fromJson(json(action: 'rerun_tests')).isActionable,
        isFalse,
      );
    });

    test('accepts the actions this build implements', () {
      expect(PaneSuggestion.fromJson(json(action: 'open_diff')).isActionable, isTrue);
      expect(
        PaneSuggestion.fromJson(
          json(action: 'start_agent', kind: 'shell_idle'),
        ).isActionable,
        isTrue,
      );
    });

    // The dev-server half of the merged mechanism. `open_url` is the action the
    // old /ports preview chip used to be; it now arrives in the same row as the
    // rest, and carries its target in params.
    test('accepts a dev server with a url', () {
      final s = PaneSuggestion.fromJson(
        json(
          kind: 'dev_server',
          label: 'Open :5173',
          detail: 'node · serving',
          action: 'open_url',
          params: {'pane': 'w1:p2', 'url': 'http://100.84.12.3:5173'},
        ),
      );
      expect(s.isActionable, isTrue);
      expect(s.url, 'http://100.84.12.3:5173');
    });

    // A loopback server has no url by construction — the bridge omits it rather
    // than hand over one that cannot connect. As an `open_url` that is a dead
    // button, so it must be dropped; the bridge sends it as `show_note`.
    test('drops an open_url with no url', () {
      final s = PaneSuggestion.fromJson(
        json(kind: 'dev_server', action: 'open_url', params: {'pane': 'w1:p2'}),
      );
      expect(s.isActionable, isFalse);
    });

    // A relayed loopback server: it is a link now, and it still carries the
    // explanation for a long press. Both must survive the parse.
    test('accepts a relayed localhost server carrying url AND note', () {
      final s = PaneSuggestion.fromJson(
        json(
          kind: 'dev_server_local',
          label: 'Open :8124',
          detail: 'node · via the bridge',
          action: 'open_url',
          params: {
            'pane': 'w1:p2',
            'url': 'http://host.ts.net:54321/?gothalo_preview=abc',
            'note': 'bound to 127.0.0.1 — the bridge is relaying it; use --host to skip the hop',
          },
        ),
      );
      expect(s.isActionable, isTrue);
      expect(s.url, contains('54321'));
      // The long press keys off this being non-empty on a non-show_note chip.
      expect(s.note, contains('--host'));
    });

    test('accepts a localhost-only server as a note', () {
      final s = PaneSuggestion.fromJson(
        json(
          kind: 'dev_server_local',
          label: ':5174 is local-only',
          action: 'show_note',
          params: {'pane': 'w1:p2', 'note': 'bound to 127.0.0.1 — use --host'},
        ),
      );
      expect(s.isActionable, isTrue);
      expect(s.note, contains('--host'));
    });

    test('drops a show_note with nothing to say', () {
      final s = PaneSuggestion.fromJson(
        json(action: 'show_note', params: {'pane': 'w1:p2'}),
      );
      expect(s.isActionable, isFalse);
    });

    // The agent-performed action. Its payload is the prompt, and without one
    // there is nothing to put in front of the user to edit.
    test('accepts a prompt_agent carrying a prompt', () {
      final s = PaneSuggestion.fromJson(
        json(
          kind: 'create_pr',
          performer: 'agent',
          label: 'Create PR',
          detail: 'feat/x → main · 2 commits ahead',
          action: 'prompt_agent',
          params: {'pane': 'w1:p2', 'prompt': 'Open a pull request for…'},
        ),
      );
      expect(s.isActionable, isTrue);
      expect(s.byAgent, isTrue);
      expect(s.prompt, 'Open a pull request for…');
    });

    test('drops a prompt_agent with no prompt', () {
      final s = PaneSuggestion.fromJson(
        json(action: 'prompt_agent', performer: 'agent', params: {'pane': 'w1:p2'}),
      );
      expect(s.isActionable, isFalse);
    });
  });

  group('performer', () {
    // The distinction the app branches on: an agent action needs its text
    // confirmed before anything leaves the phone, an app action does not.
    test('defaults to app for a bridge that predates the field', () {
      final j = json()..remove('performer');
      final s = PaneSuggestion.fromJson(j);
      expect(s.performer, 'app');
      expect(s.byAgent, isFalse);
    });

    test('an unrecognised performer is not treated as the agent', () {
      // Fail closed: whatever "server" would mean, it must not cause a prompt
      // to be sent into someone\'s pane.
      final s = PaneSuggestion.fromJson(json(performer: 'server'));
      expect(s.byAgent, isFalse);
    });

    // Every action operates on a pane, so one without a pane cannot be run —
    // regardless of how well-formed the rest of it looks.
    test('drops a suggestion with no pane in its params', () {
      expect(
        PaneSuggestion.fromJson(json(params: const {})).isActionable,
        isFalse,
      );
    });

    // An unrecognised KIND is fine: kind only picks the icon, so a bridge that
    // grows a new reason for an action we already handle still works.
    test('keeps a known action under an unknown kind', () {
      final s = PaneSuggestion.fromJson(json(kind: 'stash_pending'));
      expect(s.isActionable, isTrue);
    });
  });
}
