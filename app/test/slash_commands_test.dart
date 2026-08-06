import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/data/bridge/bridge_client.dart';
import 'package:gothalo/features/transcript/slash_commands.dart';

SlashCommand cmd(
  String name, {
  String source = 'builtin',
  String scope = '',
  String argumentHint = '',
}) =>
    SlashCommand(
      name: name,
      source: source,
      scope: scope,
      argumentHint: argumentHint,
    );

void main() {
  // applySlashCommand fires selection haptics, which needs a platform channel.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SlashQuery.parse', () {
    test('opens on a bare slash and captures what follows', () {
      expect(SlashQuery.parse('/', 1)?.query, '');
      expect(SlashQuery.parse('/comp', 5)?.query, 'comp');
    });

    test('lowercases the query so matching is case-insensitive', () {
      expect(SlashQuery.parse('/COMP', 5)?.query, 'comp');
    });

    // A space means the command has been chosen and arguments are being typed.
    // The list must get out of the way rather than keep filtering on a token
    // that is no longer the whole message.
    test('closes once whitespace is typed', () {
      expect(SlashQuery.parse('/compact ', 9), isNull);
      expect(SlashQuery.parse('/compact keep the tests', 23), isNull);
    });

    // Agents only accept a slash command as the entire message, so a slash mid
    // sentence is prose. Offering a typeahead there would teach a gesture that
    // then fails when sent.
    test('does not open on a slash that is not at the start', () {
      expect(SlashQuery.parse('see /foo', 8), isNull);
      expect(SlashQuery.parse('a/b', 3), isNull);
    });

    test('plain prose never opens it', () {
      expect(SlashQuery.parse('hello', 5), isNull);
      expect(SlashQuery.parse('', 0), isNull);
    });

    // A caret parked outside the token (dragged to position 0, or a stale
    // offset of -1 while the field has no selection) means the user is not
    // editing the command.
    test('closes when the caret is not inside the token', () {
      expect(SlashQuery.parse('/comp', 0), isNull);
      expect(SlashQuery.parse('/comp', -1), isNull);
      expect(SlashQuery.parse('/comp', 99), isNull);
    });
  });

  group('rankSlashCommands', () {
    test('an empty query keeps the bridge order untouched', () {
      final all = [cmd('migrations'), cmd('clear'), cmd('agents')];
      expect(rankSlashCommands(all, '').map((c) => c.name),
          ['migrations', 'clear', 'agents']);
    });

    test('prefix matches beat namespace-segment beat substring', () {
      final all = [
        cmd('recompile'), // substring
        cmd('git:compare'), // namespace segment
        cmd('compact'), // prefix
      ];
      expect(
        rankSlashCommands(all, 'comp').map((c) => c.name),
        ['compact', 'git:compare', 'recompile'],
      );
    });

    test('drops everything that does not match', () {
      final all = [cmd('compact'), cmd('clear'), cmd('model')];
      expect(rankSlashCommands(all, 'comp').map((c) => c.name), ['compact']);
      expect(rankSlashCommands(all, 'zzz'), isEmpty);
    });

    // Descriptions run to several sentences (they are written for an agent's
    // dispatcher), so matching them would turn a two-letter query into a list of
    // near-everything.
    test('does not match on the description', () {
      final all = [
        const SlashCommand(
          name: 'clear',
          source: 'builtin',
          description: 'Compact and clear the conversation history',
        ),
      ];
      expect(rankSlashCommands(all, 'compact'), isEmpty);
    });

    test('within a tier the bridge ordering survives', () {
      final all = [
        cmd('co-project', source: 'command', scope: 'project'),
        cmd('co-user', source: 'command', scope: 'user'),
        cmd('co-builtin'),
      ];
      expect(
        rankSlashCommands(all, 'co-').map((c) => c.name),
        ['co-project', 'co-user', 'co-builtin'],
      );
    });
  });

  group('applySlashCommand', () {
    test('replaces the token and parks the caret at the end', () {
      final c = TextEditingController(text: '/comp');
      applySlashCommand(c, cmd('compact'));
      expect(c.text, '/compact');
      expect(c.selection.baseOffset, '/compact'.length);
    });

    // A command that takes an argument gets a trailing space so the user types
    // straight into it; one that does not is already a complete message, and a
    // stray trailing space would be sent verbatim.
    test('adds a trailing space only when the command wants an argument', () {
      final withArg = TextEditingController(text: '/rev');
      applySlashCommand(withArg, cmd('review', argumentHint: '[pr]'));
      expect(withArg.text, '/review ');

      final without = TextEditingController(text: '/cle');
      applySlashCommand(without, cmd('clear'));
      expect(without.text, '/clear');
    });
  });

  group('SlashCommand', () {
    // The badge is how a user tells a verified-on-disk command from a built-in
    // list that can drift. See CONTRACT-commands.md.
    test('badges by source and scope', () {
      expect(cmd('clear').badge, 'built-in');
      expect(cmd('migrations', source: 'skill', scope: 'project').badge,
          'project skill');
      expect(cmd('herdr', source: 'skill', scope: 'user').badge, 'skill');
      expect(cmd('ship', source: 'command', scope: 'project').badge, 'project');
      expect(cmd('ship', source: 'command', scope: 'user').badge, 'user');
    });

    test('parses the wire shape, tolerating absent optional fields', () {
      final c = SlashCommand.fromJson({
        'name': 'compact',
        'description': 'Summarize the conversation',
        'argument_hint': '[instructions]',
        'source': 'builtin',
      });
      expect(c.name, 'compact');
      expect(c.argumentHint, '[instructions]');
      expect(c.isBuiltin, isTrue);
      expect(c.scope, '');

      final bare = SlashCommand.fromJson({'name': 'x', 'source': 'command'});
      expect(bare.description, '');
      expect(bare.isBuiltin, isFalse);
    });
  });
}
