import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/data/bridge/bridge_client.dart';
import 'package:gothalo/features/worktrees/new_worktree_sheet.dart';

/// Creating a worktree and launching an agent into it is two calls with a
/// half-done state between them. The two things worth pinning down are
/// therefore: which ids the launch uses (they come out of the create response —
/// a guess would start an agent with full tool access in the wrong checkout),
/// and what the operator is told when only the first half worked.

/// The real `worktree.create` result, trimmed to the keys this reads. Captured
/// against the live socket — see docs/CONTRACT-herdr-proxy.md.
Map<String, dynamic> createResult() => {
      'type': 'worktree_created',
      'workspace': {
        'workspace_id': 'wZ',
        'label': 'feat/thing',
        'worktree': {
          'repo_name': 'gothalo',
          'checkout_path': '/Users/d/.herdr/worktrees/gothalo/feat-thing',
        },
      },
      'tab': {'tab_id': 'wZ:t1', 'workspace_id': 'wZ'},
      'root_pane': {
        'pane_id': 'wZ:p1',
        'workspace_id': 'wZ',
        'tab_id': 'wZ:t1',
        'cwd': '/Users/d/.herdr/worktrees/gothalo/feat-thing',
      },
      'worktree': {
        'path': '/Users/d/.herdr/worktrees/gothalo/feat-thing',
        'branch': 'feat/thing',
        'open_workspace_id': 'wZ',
      },
    };

StartAgentResult started({bool promptSent = false, String? promptError}) =>
    StartAgentResult(
      paneId: 'wZ:p1',
      kind: 'claude',
      name: 'claude-wz-p1',
      promptSent: promptSent,
      promptError: promptError,
    );

void main() {
  group('CreatedWorktree.fromResult', () {
    test('takes the ids Herdr just handed back, not a lookup', () {
      final c = CreatedWorktree.fromResult(createResult());
      expect(c.workspaceId, 'wZ');
      expect(c.rootPaneId, 'wZ:p1');
      expect(c.checkoutPath, '/Users/d/.herdr/worktrees/gothalo/feat-thing');
    });

    test('a session-qualified result keeps its prefix', () {
      // The proxy re-qualifies ids on a non-default session, and the pane id
      // goes straight to /agent/start, which addresses panes that way.
      final raw = createResult();
      raw['root_pane'] = {'pane_id': 'acme/wZ:p1'};
      raw['workspace'] = {'workspace_id': 'acme/wZ'};
      final c = CreatedWorktree.fromResult(raw);
      expect(c.rootPaneId, 'acme/wZ:p1');
      expect(c.workspaceId, 'acme/wZ');
    });

    test('no root pane yields empty rather than a substitute', () {
      // The sheet turns this into "there was nowhere to start it". Falling back
      // to any other pane would launch an agent in someone else's checkout.
      final raw = createResult()..remove('root_pane');
      expect(CreatedWorktree.fromResult(raw).rootPaneId, '');
    });

    test('the checkout path falls back to the workspace worktree block', () {
      final raw = createResult()..remove('worktree');
      expect(CreatedWorktree.fromResult(raw).checkoutPath,
          '/Users/d/.herdr/worktrees/gothalo/feat-thing');
    });

    test('an unrecognised result parses empty instead of throwing', () {
      expect(CreatedWorktree.fromResult(const {}).rootPaneId, '');
      expect(
        CreatedWorktree.fromResult(const {'workspace': 'not-an-object'})
            .workspaceId,
        '',
      );
    });
  });

  group('worktreeLaunchSummary', () {
    test('no prompt asked for says only what happened', () {
      expect(
        worktreeLaunchSummary(
            branch: 'feat/thing', agent: started(), promptAsked: false),
        'feat/thing created — claude started',
      );
    });

    test('a delivered prompt is reported as delivered', () {
      expect(
        worktreeLaunchSummary(
          branch: 'feat/thing',
          agent: started(promptSent: true),
          promptAsked: true,
        ),
        'feat/thing created — claude started and given your message',
      );
    });

    test('an undelivered prompt is not reported as delivered', () {
      // The bridge returns 200 with prompt_sent:false when the agent came up
      // but the opening message did not land. Claiming otherwise leaves the
      // operator waiting on an agent that was never told anything.
      final summary = worktreeLaunchSummary(
        branch: 'feat/thing',
        agent: started(promptError: 'agent_not_ready'),
        promptAsked: true,
      );
      expect(summary, contains('claude started'));
      expect(summary, contains('not delivered'));
    });
  });

  group('worktreeAgentFailure', () {
    test('names both halves and keeps the bridge’s own words', () {
      final message = worktreeAgentFailure(
        branch: 'feat/thing',
        kind: 'claude',
        error: 'pane wZ:p1 is busy running zsh — an agent can only start at an '
            'idle shell prompt',
      );
      // What succeeded…
      expect(message, contains('"feat/thing" worktree was created'));
      // …what did not…
      expect(message, contains('claude did not start'));
      // …and why, verbatim, because that sentence is the whole diagnosis.
      expect(message, contains('is busy running zsh'));
    });
  });

  test('StartAgentResult carries prompt_error when the prompt was dropped', () {
    final r = StartAgentResult.fromJson(const {
      'pane_id': 'wZ:p1',
      'kind': 'claude',
      'name': 'claude-wz-p1',
      'prompt_sent': false,
      'prompt_error':
          'the agent started but your opening prompt was not delivered: '
              'agent_not_ready',
    });
    expect(r.promptSent, isFalse);
    expect(r.promptError, contains('not delivered'));
  });

  test('no prompt_error when none was asked for', () {
    final r = StartAgentResult.fromJson(const {
      'pane_id': 'wZ:p1',
      'kind': 'claude',
      'prompt_sent': false,
    });
    expect(r.promptError, isNull);
  });
}
