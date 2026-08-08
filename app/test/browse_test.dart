import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/data/bridge/bridge_client.dart';
import 'package:gothalo/data/bridge/models/snapshot.dart';

/// The open-a-project flow reads two things off the wire that decide what it
/// does next: whether a directory is a git checkout (which Herdr method opens
/// it) and which Herdr sessions exist (where the space lands). Both have to
/// survive an older bridge that omits the field.

void main() {
  group('BrowseListing', () {
    test('parses a listing and its navigation context', () {
      final l = BrowseListing.fromJson({
        'path': '/Users/d/projects',
        'parent': '/Users/d',
        'roots': [
          {'path': '/Users/d', 'label': 'Home', 'kind': 'home'},
        ],
        'entries': [
          {
            'name': 'gothalo',
            'path': '/Users/d/projects/gothalo',
            'is_repo': true,
            'is_symlink': false,
            'open_workspace_id': 'wN',
          },
          {'name': 'scratch', 'path': '/Users/d/projects/scratch'},
        ],
        'truncated': false,
        'limit': 500,
      });

      expect(l.path, '/Users/d/projects');
      expect(l.canGoUp, isTrue);
      expect(l.isRepo, isFalse);
      expect(l.isOpen, isFalse);
      expect(l.roots.single.kind, 'home');
      expect(l.entries.first.isRepo, isTrue);
      expect(l.entries.first.isOpen, isTrue);
      expect(l.entries.first.openWorkspaceId, 'wN');
      // Absent flags are false, never null: the picker branches on isRepo to
      // choose worktree.open vs workspace.create, and a null there would be a
      // crash rather than a wrong-but-working default.
      expect(l.entries.last.isRepo, isFalse);
      expect(l.entries.last.isSymlink, isFalse);
      expect(l.entries.last.isOpen, isFalse);
    });

    // "Open here" has to pick the same Herdr method as the Open button on the
    // row you descended through — worktree.open for a checkout — so the
    // listing describes itself, not only its children.
    test('describes the directory it is listing, not only its children', () {
      final l = BrowseListing.fromJson({
        'path': '/Users/d/projects/gothalo',
        'parent': '/Users/d/projects',
        'is_repo': true,
        'open_workspace_id': 'acme/w3',
        'entries': const [],
      });
      expect(l.isRepo, isTrue);
      expect(l.isOpen, isTrue);
      expect(l.openWorkspaceId, 'acme/w3');
    });

    test('a root listing has no way up', () {
      final l = BrowseListing.fromJson({
        'path': '/Users/d',
        'parent': '',
        'entries': const [],
      });
      expect(l.canGoUp, isFalse);
      expect(l.entries, isEmpty);
      expect(l.roots, isEmpty);
    });

    test('an empty body parses rather than throwing', () {
      final l = BrowseListing.fromJson(const {});
      expect(l.path, '');
      expect(l.canGoUp, isFalse);
      expect(l.truncated, isFalse);
    });
  });

  group('Snapshot.sessionNames', () {
    test('prefers the bridge list, default first', () {
      const snap = Snapshot(sessions: ['default', 'acme']);
      expect(snap.sessionNames, ['default', 'acme']);
    });

    // The case the field exists for: a session with nothing in it has no pane
    // or workspace id to be inferred from, and that is exactly the session
    // someone would want to open a first space into.
    test('reports an empty session the ids could never name', () {
      const snap = Snapshot(sessions: ['default', 'spare']);
      expect(snap.sessionNames, contains('spare'));
    });

    test('falls back to id prefixes on a bridge that sends no list', () {
      const snap = Snapshot(
        panes: [Pane(paneId: 'acme/w1:p2'), Pane(paneId: 'w4:p1')],
      );
      expect(snap.sessionNames, ['default', 'acme']);
    });

    test('is never empty, so a target always exists', () {
      expect(const Snapshot().sessionNames, ['default']);
    });
  });
}
