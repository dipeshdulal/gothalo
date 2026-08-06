import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/data/bridge/bridge_client.dart';

/// The `GET /suggestions` payload as the bridge actually writes it — see
/// `docs/CONTRACT-suggestions.md`.
Map<String, dynamic> json({
  String kind = 'git_dirty',
  String label = 'Review changes',
  String detail = '3 files changed',
  String action = 'open_diff',
  Map<String, dynamic>? params,
  int rank = 20,
}) => {
  'kind': kind,
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
