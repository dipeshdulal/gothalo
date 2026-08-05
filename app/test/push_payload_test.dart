import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/features/push/push_payload.dart';

/// A blocked push as the bridge composes it (internal/server/notify.go).
Map<String, dynamic> blockedData({String? options}) => {
  'type': 'alert',
  'agent': 'acme/w1:p2',
  'status': 'blocked',
  'state_change_seq': '7',
  'server_id': 'srv1',
  'server_name': 'Mac Studio',
  'agent_title': 'claude — gothalo',
  'title': 'Mac Studio · claude — gothalo',
  'body': 'Needs you — Run `rm -rf build`? · 1. Yes / 2. No',
  'question': 'Run `rm -rf build`?',
  'category': 'dangerous_command_approval',
  'options': ?options,
};

void main() {
  group('PushPayload', () {
    test('carries the server, the pane and the seq an approve needs', () {
      final p = PushPayload.from(blockedData());

      expect(p.serverId, 'srv1');
      expect(p.serverName, 'Mac Studio');
      expect(p.pane, 'acme/w1:p2');
      expect(p.seq, 7);
      expect(p.isBlocked, isTrue);
      expect(p.isDismiss, isFalse);
      expect(p.question, 'Run `rm -rf build`?');
      expect(p.category, 'dangerous_command_approval');
    });

    test('tag is server-qualified so two machines never collide', () {
      final a = PushPayload.from(blockedData());
      final b = PushPayload.from({...blockedData(), 'server_id': 'srv2'});

      expect(a.tag, 'srv1/acme/w1:p2');
      expect(a.tag, isNot(b.tag));
    });

    test('a missing seq reads as null rather than throwing', () {
      final p = PushPayload.from({
        ...blockedData(),
        'state_change_seq': 'not-a-number',
      });
      expect(p.seq, isNull);
    });

    test('an empty payload degrades instead of throwing', () {
      final p = PushPayload.from(const {});
      expect(p.pane, isEmpty);
      expect(p.type, 'alert');
      expect(p.options, isEmpty);
      expect(p.defaultOption, isNull);
      expect(p.declineOption, isNull);
    });

    test('a dismiss is recognised', () {
      final p = PushPayload.from(const {
        'type': 'dismiss',
        'agent': 'w1:p2',
        'server_id': 'srv1',
      });
      expect(p.isDismiss, isTrue);
    });
  });

  group('choices', () {
    test('the highlighted option is the one Approve accepts', () {
      final p = PushPayload.from(
        blockedData(
          options: jsonEncode([
            {'index': 1, 'label': 'Yes', 'selected': true},
            {'index': 2, 'label': 'No, tell Claude what to do'},
          ]),
        ),
      );

      expect(p.defaultOption?.label, 'Yes');
      expect(p.declineOption?.index, 2);
    });

    test('an esc-only prompt declines by keystroke, not by number', () {
      final p = PushPayload.from(
        blockedData(
          options: jsonEncode([
            {'index': 1, 'label': 'Yes', 'selected': true},
            {'index': 0, 'label': 'Cancel', 'key': 'esc'},
          ]),
        ),
      );

      expect(p.declineOption?.key, 'esc');
      expect(p.declineOption?.index, 0);
    });

    test('a prompt with no way to say no offers no decline', () {
      final p = PushPayload.from(
        blockedData(
          options: jsonEncode([
            {'index': 1, 'label': 'Yes', 'selected': true},
          ]),
        ),
      );
      expect(p.declineOption, isNull);
    });

    test('malformed options are ignored, not fatal', () {
      final p = PushPayload.from(blockedData(options: 'not json'));
      expect(p.options, isEmpty);
    });
  });

  group('DeepLinkTarget', () {
    test('round-trips through the notification payload', () {
      final p = PushPayload.from(
        blockedData(
          options: jsonEncode([
            {'index': 1, 'label': 'Yes', 'selected': true},
            {'index': 0, 'label': 'Cancel', 'key': 'esc'},
          ]),
        ),
      );

      final target = DeepLinkTarget.decode(p.encodeTarget())!;

      expect(target.serverId, 'srv1');
      expect(target.pane, 'acme/w1:p2');
      expect(target.seq, 7);
      // The choices must survive: a tray action fires into a fresh isolate that
      // has nothing but this string to work from.
      expect(target.options.length, 2);
      expect(target.options.last.key, 'esc');
    });

    test('a bare pane id from an older notification still routes', () {
      final target = DeepLinkTarget.decode('w1:p2')!;
      expect(target.pane, 'w1:p2');
      expect(target.serverId, isEmpty);
    });

    test('an empty payload routes nowhere', () {
      expect(DeepLinkTarget.decode(null), isNull);
      expect(DeepLinkTarget.decode(''), isNull);
    });
  });
}
