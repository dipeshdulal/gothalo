import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import '../../core/connection/connection.dart';
import 'models/snapshot.dart';
import 'models/usage.dart';

/// Outcome of a `POST /approve`. The bridge always returns `200`; [applied]
/// says whether the confirm keystroke was actually sent, and [reason] explains
/// a no-op (stale seq, agent no longer blocked, no such agent). See D8.
class ApproveResult {
  const ApproveResult({required this.applied, this.reason});

  final bool applied;
  final String? reason;
}

/// Identity of a pane created by `POST /pane/new` — enough to immediately
/// `/attach` to it (and later close it).
class NewPaneResult {
  const NewPaneResult({
    required this.paneId,
    required this.tabId,
    required this.workspaceId,
  });

  final String paneId;
  final String tabId;
  final String workspaceId;
}

/// One agent kind this host can actually launch, from `GET /agents/available`.
///
/// The list is discovered on the bridge (Herdr's kind catalog ∩ what resolves on
/// PATH), never assembled here — the app must not offer a kind that isn't
/// installed, and it has no way to know what is.
class AvailableAgent {
  const AvailableAgent({
    required this.kind,
    required this.path,
    required this.stateReporting,
  });

  /// Herdr's kind id — `claude`, `codex`, `opencode`… Also the executable name.
  final String kind;

  /// Where the executable was found on the host. Shown as the reassurance that
  /// "installed" is a fact about that machine, not a guess.
  final String path;

  /// Whether Herdr can classify this kind's state. False means it will run but
  /// never leave `unknown` — no idle/working/blocked, so no push, no approval
  /// bar. Worth warning about before launch, not after.
  final bool stateReporting;

  factory AvailableAgent.fromJson(Map<String, dynamic> j) => AvailableAgent(
        kind: (j['kind'] as String?) ?? '',
        path: (j['path'] as String?) ?? '',
        stateReporting: j['state_reporting'] == true,
      );
}

/// What a `worktree.create` proxy call brought into existence.
///
/// Herdr answers that call with the whole tree it just made — the workspace,
/// its first tab, that tab's root pane, and the git worktree — so a client that
/// wants to do something *in* the new checkout already has the ids and must not
/// go re-listing workspaces to find one it can only identify by guessing at the
/// label. See `docs/CONTRACT-herdr-proxy.md` for the captured response.
class CreatedWorktree {
  const CreatedWorktree({
    required this.workspaceId,
    required this.rootPaneId,
    required this.checkoutPath,
  });

  /// Session-qualified by the proxy, so it addresses `worktree.remove` and the
  /// overview route directly.
  final String workspaceId;

  /// The workspace's first pane — a plain shell sitting in [checkoutPath], and
  /// therefore the place an agent for this worktree belongs. Empty if Herdr
  /// reported none, which a caller must treat as "nothing to launch into"
  /// rather than substituting a pane of its own choosing.
  final String rootPaneId;

  /// Where the checkout landed on the host. Shown to the operator, since a
  /// worktree path is derived by Herdr and is not something they typed.
  final String checkoutPath;

  factory CreatedWorktree.fromResult(Map<String, dynamic> result) {
    Map<String, dynamic> obj(dynamic v) =>
        v is Map ? Map<String, dynamic>.from(v) : const {};
    final workspace = obj(result['workspace']);
    final worktree = obj(result['worktree']);
    return CreatedWorktree(
      workspaceId: (workspace['workspace_id'] as String?) ?? '',
      rootPaneId: (obj(result['root_pane'])['pane_id'] as String?) ?? '',
      // Herdr reports the path twice — on the git worktree and on the
      // workspace's own worktree block. They agree; prefer the former and fall
      // back rather than showing nothing if one is absent.
      checkoutPath: (worktree['path'] as String?) ??
          (obj(workspace['worktree'])['checkout_path'] as String?) ??
          '',
    );
  }
}

/// The outcome of `POST /agent/start` — enough to navigate straight to the new
/// agent without re-reading the snapshot first.
class StartAgentResult {
  const StartAgentResult({
    required this.paneId,
    required this.kind,
    required this.name,
    required this.promptSent,
    this.promptError,
  });

  /// Session-qualified, so it addresses `/transcript`, `/attach` and `/send`
  /// directly.
  final String paneId;
  final String kind;

  /// The agent's Herdr name, minted by the bridge when the caller gave none.
  final String name;

  /// False when no opening prompt was asked for — and also when one was asked
  /// for but didn't land. The agent is up either way; the prompt is not.
  final bool promptSent;

  /// Why the opening prompt did not land, in the bridge's words. Present ONLY
  /// when one was asked for and failed, which is what tells those two
  /// [promptSent]-false cases apart — "started, carrying your instruction"
  /// versus "started, sitting there empty".
  final String? promptError;

  factory StartAgentResult.fromJson(Map<String, dynamic> j) => StartAgentResult(
        paneId: (j['pane_id'] as String?) ?? '',
        kind: (j['kind'] as String?) ?? '',
        name: (j['name'] as String?) ?? '',
        promptSent: j['prompt_sent'] == true,
        promptError: j['prompt_error'] as String?,
      );
}

/// One changed file from `GET /diff` — a unified diff for this file alone,
/// plus enough metadata to render a file-list row without parsing the diff.
class DiffFile {
  const DiffFile({
    required this.path,
    required this.status,
    required this.additions,
    required this.deletions,
    required this.diff,
    this.oldPath,
  });

  final String path;

  /// Set only for a rename/copy — the path it moved from.
  final String? oldPath;

  /// `"modified"` | `"added"` | `"deleted"` | `"renamed"` | `"untracked"`.
  final String status;
  final int additions;
  final int deletions;

  /// A unified diff for this file alone. For an untracked file this is a
  /// synthetic "every line added" diff (see CONTRACT-diff.md) — the app
  /// renders every entry the same way regardless of status.
  final String diff;

  factory DiffFile.fromJson(Map<String, dynamic> j) => DiffFile(
        path: (j['path'] as String?) ?? '',
        oldPath: j['old_path'] as String?,
        status: (j['status'] as String?) ?? 'modified',
        additions: (j['additions'] as num?)?.toInt() ?? 0,
        deletions: (j['deletions'] as num?)?.toInt() ?? 0,
        diff: (j['diff'] as String?) ?? '',
      );
}

/// The pane's git *situation*, from the `git` object on `GET /diff` — which
/// branch, where it sits relative to the default branch, whether there is a
/// remote to push to. See CONTRACT-diff.md.
///
/// This is what decides whether offering "Create PR" for a pane makes any
/// sense, and it is read from the host rather than inferred from the cwd path:
/// a directory named `feat/x` is not evidence of a repository, let alone of a
/// branch with commits on it.
///
/// A bridge older than the `git` object sends nothing, which decodes to
/// [unknown] — [repo] false, so every gate reads it as "can't tell" and hides
/// the action rather than offering one that would fail.
class GitContext {
  const GitContext({
    required this.repo,
    required this.branch,
    required this.defaultBranch,
    required this.defaultRef,
    required this.remote,
    required this.upstream,
    required this.ahead,
    required this.behind,
    required this.dirty,
  });

  /// What an absent `git` object (an older bridge) means: nothing is known.
  static const unknown = GitContext(
    repo: false,
    branch: '',
    defaultBranch: '',
    defaultRef: '',
    remote: '',
    upstream: '',
    ahead: 0,
    behind: 0,
    dirty: false,
  );

  /// The pane's cwd is inside a git work tree. False makes every other field
  /// meaningless.
  final bool repo;

  /// The checked-out branch; "" on a detached HEAD.
  final String branch;

  /// The repo's trunk — what a PR would target. "" when git couldn't name one.
  final String defaultBranch;

  /// The ref [ahead]/[behind] were counted against, e.g.
  /// `refs/remotes/origin/main`. Display/diagnostic only.
  final String defaultRef;

  /// The remote a push would go to ("origin"); "" when the repo has none.
  final String remote;

  /// The branch's tracking ref, "" when it has never been pushed. Not
  /// disqualifying — `git push -u` is part of what the agent is asked to do.
  final String upstream;

  /// Commits on this branch that [defaultBranch] doesn't have — the work a PR
  /// would contain.
  final int ahead;

  /// Commits on [defaultBranch] that this branch doesn't have.
  final int behind;

  /// The working tree has uncommitted changes (untracked files included).
  final bool dirty;

  /// True when the pane sits on the trunk itself — you don't open a PR from
  /// `main` to `main`.
  bool get onDefaultBranch =>
      branch.isNotEmpty && defaultBranch.isNotEmpty && branch == defaultBranch;

  /// There is something to turn into a pull request: commits the default
  /// branch doesn't have, or uncommitted work that would become one.
  bool get hasWork => ahead > 0 || dirty;

  factory GitContext.fromJson(Map<String, dynamic> j) => GitContext(
        repo: j['repo'] == true,
        branch: (j['branch'] as String?) ?? '',
        defaultBranch: (j['default_branch'] as String?) ?? '',
        defaultRef: (j['default_ref'] as String?) ?? '',
        remote: (j['remote'] as String?) ?? '',
        upstream: (j['upstream'] as String?) ?? '',
        ahead: (j['ahead'] as num?)?.toInt() ?? 0,
        behind: (j['behind'] as num?)?.toInt() ?? 0,
        dirty: j['dirty'] == true,
      );
}

/// The full `GET /diff` payload — an agent pane's working-tree changes, plus
/// the [git] context they sit in.
class DiffResult {
  const DiffResult({
    required this.branch,
    required this.files,
    this.git = GitContext.unknown,
  });

  /// Best-effort; "" on a detached HEAD or if git couldn't resolve one. Same
  /// value as `git.branch`, kept because the app read it before `git` existed.
  final String branch;

  /// The pane's git situation. [GitContext.unknown] on a bridge too old to
  /// send it.
  final GitContext git;
  final List<DiffFile> files;

  factory DiffResult.fromJson(Map<String, dynamic> j) {
    final files = j['files'];
    final git = j['git'];
    return DiffResult(
      branch: (j['branch'] as String?) ?? '',
      git: git is Map
          ? GitContext.fromJson(Map<String, dynamic>.from(git))
          : GitContext.unknown,
      files: files is List
          ? files
              .whereType<Map>()
              .map((f) => DiffFile.fromJson(Map<String, dynamic>.from(f)))
              .toList()
          : const [],
    );
  }
}

/// `GET /branch-info` — what removing a worktree would leave behind, and
/// whether the branch can go with it. See `docs/CONTRACT-branch-delete.md`.
///
/// Every field is the bridge's answer, not a guess made here: [branch] and
/// [repoRoot] come from Herdr's own worktree record for the space, and the
/// merge/checkout facts come from git on the host. The app reconstructs none of
/// it from paths — a Herdr worktree directory is named after the branch it was
/// *created* for, which stops being true the moment anyone switches branches
/// inside it.
class BranchInfo {
  const BranchInfo({
    required this.repoRoot,
    required this.branch,
    required this.defaultBranch,
    required this.isDefault,
    required this.checkedOutElsewhere,
    required this.merged,
    required this.mergedInto,
    required this.unmergedCommits,
    required this.upstream,
    required this.deletable,
    required this.blockedReason,
  });

  /// The repository's main checkout — echoed back to [BridgeClient.deleteBranch]
  /// after the worktree is gone, when the workspace id no longer resolves.
  final String repoRoot;

  /// The branch the worktree is on. Empty when the space has none to offer
  /// (not a worktree, detached HEAD, …), in which case [deletable] is false.
  final String branch;

  /// The repo's default branch, resolved on the host rather than assumed to be
  /// `main`. Empty when it could not be determined — which is itself a reason
  /// not to offer the delete.
  final String defaultBranch;
  final bool isDefault;

  /// Other worktrees still holding this branch. Non-empty means removing this
  /// one does not free the branch, so it cannot be deleted.
  final List<String> checkedOutElsewhere;

  /// Merged into [defaultBranch] — i.e. deleting loses nothing. False means the
  /// delete needs the deliberate second confirm.
  final bool merged;

  /// Which ref proved it: `main`, or `origin/main` for the very common case of
  /// a PR merged on the forge but not yet pulled locally. Empty when unmerged.
  final String mergedInto;

  /// Commits on the branch that are not in the default branch — what would be
  /// lost. Zero when [merged].
  final int unmergedCommits;

  /// The tracking ref (`origin/feat/x`), empty when there is none. Deleting the
  /// local branch does NOT delete this, and the UI has to say so.
  final String upstream;

  /// Whether the branch could be deleted once the worktree is removed —
  /// including the unmerged case, which is possible but costs an extra confirm.
  final bool deletable;

  /// Why not, when [deletable] is false. Empty otherwise.
  final String blockedReason;

  bool get hasUpstream => upstream.isNotEmpty;

  factory BranchInfo.fromJson(Map<String, dynamic> j) => BranchInfo(
        repoRoot: (j['repo_root'] as String?) ?? '',
        branch: (j['branch'] as String?) ?? '',
        defaultBranch: (j['default_branch'] as String?) ?? '',
        isDefault: (j['is_default'] as bool?) ?? false,
        checkedOutElsewhere:
            (j['checked_out_elsewhere'] as List?)?.whereType<String>().toList() ??
                const [],
        merged: (j['merged'] as bool?) ?? false,
        mergedInto: (j['merged_into'] as String?) ?? '',
        unmergedCommits: (j['unmerged_commits'] as num?)?.toInt() ?? 0,
        upstream: (j['upstream'] as String?) ?? '',
        deletable: (j['deletable'] as bool?) ?? false,
        blockedReason: (j['blocked_reason'] as String?) ?? '',
      );
}

/// `POST /branch-delete` — what the delete actually did.
///
/// [forced] is the command git ran, not what was asked for: forcing an
/// already-merged branch still deletes with `-d`, and the app must not claim
/// commits were dropped when none were.
class BranchDeleteResult {
  const BranchDeleteResult({
    required this.branch,
    required this.deleted,
    required this.forced,
    required this.merged,
    required this.sha,
    required this.upstream,
    required this.remoteDeleted,
  });

  final String branch;
  final bool deleted;
  final bool forced;
  final bool merged;

  /// The commit the branch pointed at, read before the delete — the only
  /// handle left for `git branch <name> <sha>` afterwards.
  final String sha;
  final String upstream;

  /// Always false: the bridge never pushes. Carried so the app states it
  /// rather than leaving the user to assume either way.
  final bool remoteDeleted;

  factory BranchDeleteResult.fromJson(Map<String, dynamic> j) =>
      BranchDeleteResult(
        branch: (j['branch'] as String?) ?? '',
        deleted: (j['deleted'] as bool?) ?? false,
        forced: (j['forced'] as bool?) ?? false,
        merged: (j['merged'] as bool?) ?? false,
        sha: (j['sha'] as String?) ?? '',
        upstream: (j['upstream'] as String?) ?? '',
        remoteDeleted: (j['remote_deleted'] as bool?) ?? false,
      );
}

/// A slice of a file's current content from `GET /diff/expand` — the lines
/// behind one "show the unchanged region" tap in the diff viewer.
class DiffContext {
  const DiffContext({
    required this.path,
    required this.start,
    required this.lines,
    required this.eof,
    required this.total,
  });

  final String path;

  /// 1-based NEW-side line number of [lines] `[0]`.
  final int start;
  final List<String> lines;

  /// [lines] runs to the end of the file — nothing further down to reveal.
  final bool eof;

  /// The file's whole line count, which is what lets the viewer put an exact
  /// number on the gap below the last hunk.
  final int total;

  factory DiffContext.fromJson(Map<String, dynamic> j) => DiffContext(
    path: (j['path'] as String?) ?? '',
    start: (j['start'] as num?)?.toInt() ?? 1,
    lines: (j['lines'] as List?)?.map((l) => l?.toString() ?? '').toList() ??
        const [],
    eof: j['eof'] == true,
    total: (j['total'] as num?)?.toInt() ?? 0,
  );
}

/// One slash command the pane's agent will accept, from `GET /commands` — the
/// composer typeahead's unit. See `docs/CONTRACT-commands.md`.
class SlashCommand {
  const SlashCommand({
    required this.name,
    required this.source,
    this.description = '',
    this.argumentHint = '',
    this.scope = '',
  });

  /// The invocation WITHOUT the leading slash — "compact", "frontend:component".
  final String name;

  /// One-line summary. May be empty; a command with no description is still
  /// perfectly invocable, so this must never gate whether the row renders.
  final String description;

  /// e.g. "[pr-number]" — shown dimmed after the name when the command wants an
  /// argument, which is the hint that stops a bare `/review` doing nothing.
  final String argumentHint;

  /// `builtin` | `command` | `skill`.
  final String source;

  /// `user` | `project`, empty for a built-in.
  final String scope;

  /// True for a command compiled into the agent rather than read off disk. The
  /// only entries that can drift from what the agent really accepts, so the UI
  /// badges them honestly instead of implying they were discovered.
  bool get isBuiltin => source == 'builtin';

  /// What the typeahead row shows as its badge.
  String get badge => switch (source) {
        'builtin' => 'built-in',
        'skill' => scope == 'project' ? 'project skill' : 'skill',
        _ => scope == 'project' ? 'project' : 'user',
      };

  factory SlashCommand.fromJson(Map<String, dynamic> j) => SlashCommand(
        name: (j['name'] as String?) ?? '',
        description: (j['description'] as String?) ?? '',
        argumentHint: (j['argument_hint'] as String?) ?? '',
        source: (j['source'] as String?) ?? '',
        scope: (j['scope'] as String?) ?? '',
      );
}

/// One offered action for a pane, from `GET /suggestions` — see
/// `docs/CONTRACT-suggestions.md`.
///
/// The bridge decides *what* is worth offering (it is the only side that can
/// see the pane's processes, working tree and listeners); the app decides how to
/// render it and which [action] values it knows how to perform. Anything else is
/// dropped on the floor — see [isActionable] — which is what lets a newer bridge
/// add a suggestion kind without breaking an app that predates it.
class PaneSuggestion {
  const PaneSuggestion({
    required this.kind,
    required this.label,
    required this.action,
    this.performer = 'app',
    this.detail = '',
    this.params = const {},
    this.rank = 0,
  });

  /// Why it was offered: `git_conflict` | `git_dirty` | `shell_idle`. Only
  /// drives the icon — never whether the chip renders, so an unrecognised kind
  /// with a known action still works.
  final String kind;

  /// The chip text, already short enough for a phone. Rendered verbatim: the
  /// bridge is what knows whether the tree has one file changed or forty.
  final String label;

  /// One line of justification under the label. May be empty.
  final String detail;

  /// What to do on tap: `open_diff` | `start_agent` | `open_url` | `show_note`
  /// | `prompt_agent`.
  final String action;

  /// Who carries it out: `app` or `agent` — see [byAgent]. Defaults to `app`
  /// for a bridge that predates the field, which is the safe reading: an app
  /// suggestion is never sent anywhere.
  final String performer;

  /// The action's arguments. Always carries `pane` (session-qualified).
  final Map<String, String> params;

  /// Usefulness, highest first. The bridge has already sorted; this is kept so
  /// a caller merging in suggestions from elsewhere can interleave them.
  final int rank;

  /// The pane this acts on — the same id `/attach`, `/diff` and `/send` take.
  String get pane => params['pane'] ?? '';

  /// The dev server to open, for `open_url`. Empty for every other action.
  String get url => params['url'] ?? '';

  /// What a `show_note` tap displays. Empty for every other action.
  String get note => params['note'] ?? '';

  /// The text a `prompt_agent` tap puts in front of the user. Empty otherwise.
  ///
  /// This is a *starting* text, never a message to send on its own: an agent
  /// action commits, pushes and reaches outside the machine, so it is shown and
  /// editable before anything leaves the phone.
  String get prompt => params['prompt'] ?? '';

  /// Whether this asks the AGENT in the pane to do something rather than the
  /// app. The distinction is load-bearing, not cosmetic: an agent action needs
  /// its text confirmed first, and it lands in the transcript where it can be
  /// watched and interrupted.
  bool get byAgent => performer == 'agent';

  /// Whether THIS build knows how to perform the action, *and* was given what
  /// that action needs. A chip that cannot do anything is worse than a missing
  /// chip, so both an unknown action and a known one with a missing argument
  /// are dropped rather than rendered as a dead button.
  bool get isActionable => switch (action) {
        'open_diff' || 'start_agent' => pane.isNotEmpty,
        'open_url' => url.isNotEmpty,
        'show_note' => note.isNotEmpty,
        // Needs both: something to say, and an agent to say it to.
        'prompt_agent' => prompt.isNotEmpty && pane.isNotEmpty,
        _ => false,
      };

  factory PaneSuggestion.fromJson(Map<String, dynamic> j) => PaneSuggestion(
        kind: (j['kind'] as String?) ?? '',
        performer: (j['performer'] as String?) ?? 'app',
        label: (j['label'] as String?) ?? '',
        detail: (j['detail'] as String?) ?? '',
        action: (j['action'] as String?) ?? '',
        params: switch (j['params']) {
          final Map<dynamic, dynamic> p => {
              for (final e in p.entries)
                e.key.toString(): e.value?.toString() ?? '',
            },
          _ => const <String, String>{},
        },
        rank: (j['rank'] as num?)?.toInt() ?? 0,
      );
}

/// One recorded agent status transition from `GET /timeline` — see
/// `docs/CONTRACT-timeline.md`.
///
/// Every other bridge read describes the PRESENT. This is the only one that
/// describes the past, and [previous] is the reason it exists: a status alone
/// cannot distinguish an agent that blocked fifty minutes ago from one that
/// blocked ten seconds ago, and that difference is the whole question you have
/// when you pick the phone up.
class TimelineEntry {
  const TimelineEntry({
    required this.at,
    required this.pane,
    required this.agent,
    required this.to,
    this.from,
    this.session,
    this.workspace,
    this.previous,
    this.title,
  });

  /// When the bridge observed the transition.
  final DateTime at;

  /// Session-qualified pane id — the same id `/attach`, `/send` and
  /// `/transcript` take, so a row can open the agent it describes.
  final String pane;

  /// Agent kind (`claude`, `codex`, …). May be empty for a pane whose kind the
  /// bridge never learned.
  final String agent;

  final String? session;
  final String? workspace;

  /// The pane's human name at the time of the transition ("Fix the failing
  /// parser test").
  ///
  /// This, not [agent], is what identifies a row to a person: [agent] is a KIND,
  /// so a host running a dozen Claudes yields a dozen rows that all read
  /// "Claude". Null for a pane the bridge never learned a title for.
  final String? title;

  /// The status being left. **Null for a first sighting** — a newly detected
  /// agent, not a transition out of an unnamed state.
  final String? from;

  /// The status entered: a Herdr agent status, or `"gone"` when the pane closed
  /// or its process exited.
  final String to;

  /// How long the agent spent in [from].
  ///
  /// **Null means unknown, not zero.** The bridge omits it when it cannot see
  /// where the span began (the first transition after a restart for a pane that
  /// had moved on while the bridge was down). `Duration.zero` is a real value —
  /// an instantaneous flip — so a renderer must not conflate the two.
  final Duration? previous;

  /// The pane stopped existing rather than changing status.
  bool get isGone => to == 'gone';

  factory TimelineEntry.fromJson(Map<String, dynamic> j) {
    final prevMs = (j['prev_ms'] as num?)?.toInt();
    String? nonEmpty(Object? v) {
      final s = v as String?;
      return (s == null || s.isEmpty) ? null : s;
    }

    return TimelineEntry(
      at: DateTime.fromMillisecondsSinceEpoch((j['ts'] as num?)?.toInt() ?? 0),
      pane: (j['pane'] as String?) ?? '',
      agent: (j['agent'] as String?) ?? '',
      session: nonEmpty(j['session']),
      workspace: nonEmpty(j['workspace']),
      title: nonEmpty(j['title']),
      from: nonEmpty(j['from']),
      to: (j['to'] as String?) ?? '',
      previous: prevMs == null ? null : Duration(milliseconds: prevMs),
    );
  }
}

/// One selectable choice on a blocked agent's prompt (from `/agent-state`).
class BlockedOption {
  const BlockedOption({
    required this.index,
    required this.label,
    required this.selected,
    this.key,
  });

  /// The number to type to pick it (1-based); 0 if unnumbered (see [key]).
  final int index;
  final String label;

  /// The highlighted default — the one a bare Enter (`/approve`) accepts.
  final bool selected;

  /// Set instead of a usable [index] for a choice with no menu number, only
  /// reachable via a raw keystroke — e.g. `"esc"` for the decline action on
  /// Claude's single-choice approval form (`❯ 1. Yes` with no numbered "No").
  /// Dispatch via [BridgeClient.sendKey], not [BridgeClient.sendText].
  final String? key;

  bool get isKeyed => key != null && key!.isNotEmpty;

  factory BlockedOption.fromJson(Map<String, dynamic> j) => BlockedOption(
        index: (j['index'] as num?)?.toInt() ?? 0,
        label: (j['label'] as String?) ?? '',
        selected: j['selected'] == true,
        key: j['key'] as String?,
      );
}

/// Coarse visual severity for a blocked agent, derived from `blocked.category`
/// (Herdr's own detection rule id, filled server-side via `agent.explain`).
///
/// The category is **optional** — an older bridge, an unrecognised prompt, or a
/// failed `agent.explain` all leave it absent. We degrade to [permission] in
/// that case: still clearly an approval (lock, elevated), but we never *upgrade*
/// an unknown prompt to [danger].
enum BlockSeverity {
  /// Approving runs a command / grants a tool — the highest-stakes prompts.
  /// `dangerous_command_approval`, `tool_approval`.
  danger,

  /// A permission grant that isn't a raw command: file writes, generic
  /// permission prompts, or an absent/unknown category.
  permission,

  /// A plain choice with no permission stakes — `question_panel`.
  question,
}

/// The parsed agent card from `GET /agent-state` — what the agent is doing and,
/// when blocked, the exact question + options it's waiting on.
class AgentState {
  const AgentState({
    required this.paneId,
    required this.agentKind,
    required this.agentStatus,
    required this.headline,
    required this.detail,
    required this.blockedQuestion,
    required this.blockedCategory,
    required this.options,
    required this.parsed,
    this.permissionMode,
  });

  final String paneId;
  final String agentKind;
  final String agentStatus;
  final String headline;
  final String detail;

  /// The prompt the agent is waiting on — present only when blocked.
  final String? blockedQuestion;

  /// Coarse semantic class of the block from Herdr's own detection
  /// (`blocked.category`), e.g. `tool_approval`, `dangerous_command_approval`,
  /// `question_panel`, `write_file_approval`, `generic_permission_prompt`.
  /// **Optional** — absent on an older bridge or an unrecognised prompt. Style
  /// off [blockSeverity] rather than matching the raw string, so a new rule id
  /// degrades cleanly instead of falling through unstyled.
  final String? blockedCategory;

  /// Selectable choices in display order — empty for a free-form prompt.
  final List<BlockedOption> options;
  final bool parsed;

  /// Claude's permission mode (`default`/`acceptEdits`/`plan`/`auto`/…). Present
  /// only for Claude panes when readable; absent for other kinds — treat the
  /// value as an opaque label and offer a single "cycle" action.
  final String? permissionMode;

  bool get isBlocked => agentStatus == 'blocked';

  /// The agent is actively producing output (generating a reply, running a
  /// tool) — drives the chat's "thinking…" indicator.
  bool get isWorking => agentStatus == 'working';

  /// Visual severity for the current block, mapped from [blockedCategory].
  /// Absent/unknown → [BlockSeverity.permission] (never over-warns as danger).
  BlockSeverity get blockSeverity => switch (blockedCategory) {
        'dangerous_command_approval' || 'tool_approval' => BlockSeverity.danger,
        'question_panel' => BlockSeverity.question,
        _ => BlockSeverity.permission,
      };

  /// A short human label for the block category (for a badge/pill), or null
  /// when there's nothing worth labelling (a plain question, or absent).
  String? get blockedCategoryLabel => switch (blockedCategory) {
        'dangerous_command_approval' => 'Dangerous command',
        'tool_approval' => 'Tool permission',
        'write_file_approval' => 'File write',
        'generic_permission_prompt' => 'Permission',
        _ => null,
      };

  factory AgentState.fromJson(Map<String, dynamic> j) {
    final blocked = j['blocked'];
    final opts = (blocked is Map ? blocked['options'] : null);
    return AgentState(
      paneId: (j['pane_id'] as String?) ?? '',
      agentKind: (j['agent_kind'] as String?) ?? '',
      agentStatus: (j['agent_status'] as String?) ?? 'unknown',
      headline: (j['headline'] as String?) ?? '',
      detail: (j['detail'] as String?) ?? '',
      blockedQuestion: blocked is Map ? blocked['question'] as String? : null,
      blockedCategory: blocked is Map ? blocked['category'] as String? : null,
      options: opts is List
          ? opts
              .whereType<Map>()
              .map((o) => BlockedOption.fromJson(Map<String, dynamic>.from(o)))
              .toList()
          : const [],
      parsed: j['parsed'] != false,
      permissionMode: j['permission_mode'] as String?,
    );
  }
}

/// Where an uploaded image landed, from `POST /image`.
///
/// [path] is the whole point: an absolute path inside the pane's own working
/// directory. Coding agents read an image when handed a path, so putting this
/// where the user is typing — the composer, or the terminal — *is* the
/// attachment; no agent protocol is involved. See docs/CONTRACT-image.md.
class ImageDrop {
  const ImageDrop({
    required this.path,
    required this.relativePath,
    required this.contentType,
    required this.bytes,
  });

  /// Absolute path to the written file — what gets typed.
  final String path;

  /// The same file relative to the pane's cwd (`.gothalo/images/…`). Display
  /// only; the agent gets [path], since its cwd isn't necessarily the shell's.
  final String relativePath;

  /// What the bridge *sniffed* the bytes as, not what we claimed they were.
  final String contentType;
  final int bytes;
}

/// One directory the phone is allowed to browse from, per `GET /browse`. Roots
/// are derived on the host — the operator's home directory and the parents of
/// spaces Herdr already has open — never configured or guessed here.
class BrowseRoot {
  const BrowseRoot({required this.path, required this.label, required this.kind});

  final String path;
  final String label;

  /// `home` or `project`. Only used to pick the icon; an unknown value renders
  /// as a plain folder rather than breaking the picker.
  final String kind;

  factory BrowseRoot.fromJson(Map<String, dynamic> j) => BrowseRoot(
        path: (j['path'] as String?) ?? '',
        label: (j['label'] as String?) ?? '',
        kind: (j['kind'] as String?) ?? '',
      );
}

/// One directory inside a [BrowseListing]. There is no entry type for a file:
/// `/browse` is directories-only and never returns one.
class BrowseEntry {
  const BrowseEntry({
    required this.name,
    required this.path,
    required this.isRepo,
    required this.isSymlink,
    required this.openWorkspaceId,
  });

  final String name;
  final String path;

  /// Whether the directory holds a `.git`. It decides which Herdr method opens
  /// it — `worktree.open` for a checkout, `workspace.create` otherwise — so it
  /// is behaviour, not just a badge.
  final bool isRepo;
  final bool isSymlink;

  /// The workspace already open at this directory, or empty. Session-qualified.
  final String openWorkspaceId;

  bool get isOpen => openWorkspaceId.isNotEmpty;

  factory BrowseEntry.fromJson(Map<String, dynamic> j) => BrowseEntry(
        name: (j['name'] as String?) ?? '',
        path: (j['path'] as String?) ?? '',
        isRepo: j['is_repo'] == true,
        isSymlink: j['is_symlink'] == true,
        openWorkspaceId: (j['open_workspace_id'] as String?) ?? '',
      );
}

/// One directory's browsable children plus the navigation context, from
/// `GET /browse`. See `docs/CONTRACT-browse.md`.
class BrowseListing {
  const BrowseListing({
    required this.path,
    required this.parent,
    required this.isRepo,
    required this.openWorkspaceId,
    required this.roots,
    required this.entries,
    required this.truncated,
    required this.limit,
  });

  final String path;

  /// The directory above [path], or empty when [path] is a root — which is how
  /// the picker knows to stop offering "up" rather than tracking roots itself.
  final String parent;

  /// Whether [path] itself is a git checkout, on the same terms as
  /// [BrowseEntry.isRepo]. It is what lets "open the directory I'm standing in"
  /// pick the same Herdr method as "open that one in the list".
  final bool isRepo;

  /// The workspace already open at [path] itself, or empty.
  final String openWorkspaceId;
  final List<BrowseRoot> roots;
  final List<BrowseEntry> entries;

  /// True when the host had more children than it would return. Surfaced, never
  /// silently swallowed: a truncated listing that looks complete is how you
  /// conclude a project isn't there.
  final bool truncated;
  final int limit;

  bool get canGoUp => parent.isNotEmpty;
  bool get isOpen => openWorkspaceId.isNotEmpty;

  factory BrowseListing.fromJson(Map<String, dynamic> j) => BrowseListing(
        path: (j['path'] as String?) ?? '',
        parent: (j['parent'] as String?) ?? '',
        isRepo: j['is_repo'] == true,
        openWorkspaceId: (j['open_workspace_id'] as String?) ?? '',
        roots: (j['roots'] as List? ?? const [])
            .whereType<Map>()
            .map((r) => BrowseRoot.fromJson(Map<String, dynamic>.from(r)))
            .toList(),
        entries: (j['entries'] as List? ?? const [])
            .whereType<Map>()
            .map((e) => BrowseEntry.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        truncated: j['truncated'] == true,
        limit: (j['limit'] as num?)?.toInt() ?? 0,
      );
}

/// Why a browser refused a request before it ever reached the bridge.
///
/// Both look identical to the app — status 0, no headers, no reason — but they
/// are fixed in completely different places, so they must not share a message.
enum BrowserBlock {
  /// The bridge did not name this page's origin as allowed. Always an
  /// inference; see [BridgeClient._asBridgeException] for why.
  cors,

  /// An `https` page may not reach an `http` bridge. Decidable rather than
  /// inferred: both schemes are in hand.
  mixedContent,
}

/// Thrown for any bridge call that fails — network down, non-2xx, or a body we
/// couldn't parse. Carries a human message for the UI and the status code when
/// there was one (e.g. 401 bad token, 502 bridge daemon not running).
class BridgeException implements Exception {
  BridgeException(this.message, {this.statusCode, this.blockedBy});

  final String message;
  final int? statusCode;

  /// Set when the browser stopped this request itself, and by which rule.
  ///
  /// Worth carrying rather than leaving in prose, because these are the
  /// failures that look exactly like an unreachable server while being fixed
  /// somewhere else entirely — a config line on the bridge, or a different
  /// URL on the phone. Null for every ordinary failure.
  final BrowserBlock? blockedBy;

  bool get isAuth => statusCode == 401 || statusCode == 403;
  bool get isBridgeDown => statusCode == 502 || statusCode == 503;

  @override
  String toString() => 'BridgeException($statusCode): $message';
}

/// The one seam the app talks to the bridge through.
///
/// Built from a [Connection] ({baseUrl, bearer}); a single dio interceptor
/// injects `Authorization: Bearer <token>` on every request, so no call site
/// ever handles the token. Swap the [Connection] (manual settings today, QR
/// pairing later) and every call re-targets — nothing here is hardcoded.
class BridgeClient {
  BridgeClient(this.connection, {Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: connection.baseUrl,
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 8),
              headers: {'Accept': 'application/json'},
            ),
          ) {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          options.headers['Authorization'] = 'Bearer ${connection.bearer}';
          handler.next(options);
        },
      ),
    );
  }

  final Connection connection;
  final Dio _dio;

  /// `GET /snapshot` → the current Herdr state. Unwraps the
  /// `{ result: { snapshot: {...} } }` envelope and returns just the snapshot.
  Future<Snapshot> getSnapshot() async {
    try {
      final res = await _dio.get<Map<String, dynamic>>('/snapshot');
      final body = res.data;
      if (body == null) {
        throw BridgeException('Empty snapshot response');
      }
      // Be tolerant of envelope shape: prefer result.snapshot, but accept a
      // bare snapshot or a bare agents list too.
      final result = body['result'];
      final snapNode = (result is Map ? result['snapshot'] : null) ??
          body['snapshot'] ??
          body;
      if (snapNode is! Map) {
        throw BridgeException('Unexpected snapshot shape');
      }
      return Snapshot.fromJson(Map<String, dynamic>.from(snapNode));
    } on DioException catch (e) {
      throw _asBridgeException(e);
    }
  }

  /// `GET /info` → this bridge's own identity: `server_id` and `server_name`.
  ///
  /// The app stores the id against the saved server so an incoming push, which
  /// carries only `server_id`, can be traced back to the server it came from —
  /// for attribution in the alerts log and for routing a notification tap. A
  /// bridge older than this endpoint 404s; callers treat that as "unknown" and
  /// carry on.
  /// `version` is the bridge's capability level, hand-bumped on the bridge when
  /// it gains something the app may branch on. Zero means a bridge old enough
  /// not to report one.
  Future<({String serverId, String serverName, int version})> info() async {
    try {
      final res = await _dio.get<Map<String, dynamic>>('/info');
      final body = res.data ?? const <String, dynamic>{};
      return (
        serverId: (body['server_id'] as String?) ?? '',
        serverName: (body['server_name'] as String?) ?? '',
        version: (body['version'] as num?)?.toInt() ?? 0,
      );
    } on DioException catch (e) {
      throw _asBridgeException(e);
    }
  }

  /// `GET /usage` → live provider quota windows. The bridge reads provider
  /// credentials on the host and never sends them to the app.
  Future<UsageSnapshot> getUsage() async {
    try {
      final res = await _dio.get<Map<String, dynamic>>('/usage');
      final body = res.data;
      if (body == null) throw BridgeException('Empty usage response');
      return UsageSnapshot.fromJson(body);
    } on DioException catch (e) {
      throw _asBridgeException(e);
    }
  }

  /// `POST /send {pane, text}` → types [text] into the given Herdr pane. Include
  /// a trailing `\n` in [text] to submit.
  Future<void> sendText(String pane, String text) async {
    try {
      await _dio.post<dynamic>('/send', data: {'pane': pane, 'text': text});
    } on DioException catch (e) {
      throw _asBridgeException(e);
    }
  }

  /// `POST /send {pane, key}` → sends a raw keystroke instead of typed text —
  /// for a [BlockedOption] that has no [BlockedOption.index] and is only
  /// reachable via a keystroke (e.g. `"esc"` to decline a single-choice
  /// approval form).
  Future<void> sendKey(String pane, String key) async {
    try {
      await _dio.post<dynamic>('/send', data: {'pane': pane, 'key': key});
    } on DioException catch (e) {
      throw _asBridgeException(e);
    }
  }

  /// `POST /approve {agent, seq}` → one-tap idempotent approval for a blocked
  /// agent (D8). [agent] is the pane id; [seq] is that agent's
  /// `state_change_seq` from the snapshot. The confirm keystroke is chosen
  /// server-side per agent kind, so the app sends none itself. The bridge no-ops
  /// (`applied:false` + a [ApproveResult.reason]) when the agent is no longer
  /// blocked at [seq]; the call is always `200`.
  Future<ApproveResult> approve(String agent, int seq) async {
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        '/approve',
        data: {'agent': agent, 'seq': seq},
      );
      final body = res.data ?? const <String, dynamic>{};
      return ApproveResult(
        applied: body['applied'] == true,
        reason: body['reason'] as String?,
      );
    } on DioException catch (e) {
      throw _asBridgeException(e);
    }
  }

  /// `POST /pane/new` → creates a terminal and returns its identity so we can
  /// `/attach` to it. Provide [workspaceId] to open a fresh tab in that space,
  /// or [splitFrom] to split an existing pane ([splitFrom] wins if both given).
  /// [command], when set, is typed and run in the new pane; a command that fails
  /// still yields a created pane (the bridge returns 200 either way).
  Future<NewPaneResult> createPane({
    String? workspaceId,
    String? splitFrom,
    String? direction,
    String? cwd,
    String? label,
    String? command,
  }) async {
    if ((workspaceId == null || workspaceId.isEmpty) &&
        (splitFrom == null || splitFrom.isEmpty)) {
      throw BridgeException('createPane needs a workspaceId or splitFrom');
    }
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        '/pane/new',
        data: {
          if (splitFrom != null && splitFrom.isNotEmpty) 'split_from': splitFrom,
          if (workspaceId != null && workspaceId.isNotEmpty)
            'workspace_id': workspaceId,
          if (direction != null && direction.isNotEmpty) 'direction': direction,
          if (cwd != null && cwd.isNotEmpty) 'cwd': cwd,
          if (label != null && label.isNotEmpty) 'label': label,
          if (command != null && command.isNotEmpty) 'command': command,
        },
      );
      final body = res.data ?? const <String, dynamic>{};
      final paneId = body['pane_id'] as String?;
      if (paneId == null || paneId.isEmpty) {
        throw BridgeException('Bridge did not return a new pane id');
      }
      return NewPaneResult(
        paneId: paneId,
        tabId: body['tab_id'] as String? ?? '',
        workspaceId: body['workspace_id'] as String? ?? workspaceId ?? '',
      );
    } on DioException catch (e) {
      throw _asBridgeException(e);
    }
  }

  /// `GET /agent-state?pane=<id>` → the parsed agent card (status, headline, and
  /// when blocked the question + options). Agent panes only; a non-agent or
  /// unsupported pane throws.
  ///
  /// The card is built from the pane's current screen. The bridge can also read
  /// the pane's SCROLLBACK for a richer detail/transcript (`?recent=1`), but
  /// Herdr can only capture that by physically scrolling the pane — visible as a
  /// jump to whoever is watching it on the desktop, once per call. Nothing in the
  /// app needs it: the chat screen streams the real transcript, and the activity
  /// line wants current state rather than history. So we never ask.
  Future<AgentState> getAgentState(String pane) async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        '/agent-state',
        queryParameters: {'pane': pane},
      );
      final body = res.data;
      if (body == null) throw BridgeException('Empty agent-state response');
      return AgentState.fromJson(body);
    } on DioException catch (e) {
      throw _asBridgeException(e);
    }
  }

  /// `GET /diff?pane=<id>` → an agent pane's working-tree changes (branch +
  /// one unified diff per changed file), plus the pane's [GitContext]. Agent
  /// panes only — a non-agent pane throws (404). See CONTRACT-diff.md.
  ///
  /// [contextOnly] narrows the request to the git context and skips the diff
  /// itself — the read behind the "Create PR" gate, which needs to know whether
  /// the pane is on a pushable feature branch and has no use for a single line
  /// of diff. Diffing a large tree is the expensive half of this endpoint, so a
  /// gate that runs on screen build must not pay for it.
  Future<DiffResult> getDiff(String pane, {bool contextOnly = false}) async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        '/diff',
        queryParameters: {'pane': pane, if (contextOnly) 'context': '1'},
      );
      final body = res.data;
      if (body == null) throw BridgeException('Empty diff response');
      return DiffResult.fromJson(body);
    } on DioException catch (e) {
      throw _asBridgeException(e);
    }
  }

  /// `GET /diff/expand?pane=<id>&path=…&start=…&count=…` → `count` lines of
  /// that file's current content, for expanding a collapsed unchanged region
  /// between two hunks. See CONTRACT-diff.md.
  ///
  /// `git diff` only ships three lines of context around each change, so those
  /// lines are simply absent from `/diff` — there is nothing to expand
  /// client-side. Fetched per tap rather than by inflating every diff, since
  /// most files never get the tap.
  Future<DiffContext> getDiffContext(
    String pane, {
    required String path,
    required int start,
    required int count,
  }) async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        '/diff/expand',
        queryParameters: {
          'pane': pane,
          'path': path,
          'start': start,
          'count': count,
        },
      );
      final body = res.data;
      if (body == null) throw BridgeException('Empty diff-expand response');
      return DiffContext.fromJson(body);
    } on DioException catch (e) {
      throw _asBridgeException(e);
    }
  }

  /// `GET /commands?pane=<id>` → the slash commands this pane's agent accepts,
  /// for the composer typeahead. See CONTRACT-commands.md.
  ///
  /// Returns an empty list rather than throwing for every "no typeahead here"
  /// case — an agent kind with no command surface, a plain pane, or a bridge too
  /// old to have the endpoint (404). The composer degrades to a plain text field
  /// and the user is told nothing, because there is nothing they could do about
  /// it. A genuine transport failure still throws.
  Future<List<SlashCommand>> getCommands(String pane) async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        '/commands',
        queryParameters: {'pane': pane},
      );
      final list = (res.data ?? const {})['commands'];
      if (list is! List) return const [];
      return list
          .whereType<Map>()
          .map((c) => SlashCommand.fromJson(Map<String, dynamic>.from(c)))
          .where((c) => c.name.isNotEmpty)
          .toList();
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return const [];
      throw _asBridgeException(e);
    }
  }

  /// `GET /suggestions?pane=<id>` → the handful of one-tap actions that make
  /// sense for what is running in that pane right now. See
  /// CONTRACT-suggestions.md.
  ///
  /// Returns an empty list rather than throwing for every "nothing to offer
  /// here" case, including a bridge too old to have the endpoint (404) and a
  /// pane that has since closed (404). This is a convenience surface: an error
  /// state in front of it would cost the user more attention than the feature
  /// gives back, and there is nothing they could do about either cause.
  ///
  /// Suggestions carrying an action this build does not implement are dropped
  /// here, so a caller never has to render a chip it cannot honour.
  Future<List<PaneSuggestion>> getSuggestions(String pane) async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        '/suggestions',
        queryParameters: {'pane': pane},
      );
      final list = (res.data ?? const {})['suggestions'];
      if (list is! List) return const [];
      return list
          .whereType<Map>()
          .map((s) => PaneSuggestion.fromJson(Map<String, dynamic>.from(s)))
          .where((s) => s.label.isNotEmpty && s.isActionable)
          .toList();
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return const [];
      throw _asBridgeException(e);
    }
  }

  /// `GET /timeline` → the recent agent-activity log, **newest first**: one
  /// entry per status transition, each carrying how long the agent spent in the
  /// status it just left. See CONTRACT-timeline.md.
  ///
  /// Purely a read of the bridge's in-memory ring — no Herdr call — so it is
  /// cheap enough to poll and still answers while Herdr itself is down. [limit]
  /// is clamped server-side; [pane] restricts the log to one agent.
  ///
  /// A bridge older than this endpoint 404s and a bridge with recording
  /// disabled 503s; both surface as a [BridgeException] the caller renders as
  /// "no history".
  Future<List<TimelineEntry>> getTimeline({int? limit, String? pane}) async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        '/timeline',
        queryParameters: {
          'limit': ?limit,
          if (pane != null && pane.isNotEmpty) 'pane': pane,
        },
      );
      final entries = (res.data ?? const {})['entries'];
      if (entries is! List) return const [];
      return entries
          .whereType<Map>()
          .map((e) => TimelineEntry.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } on DioException catch (e) {
      throw _asBridgeException(e);
    }
  }

  /// `GET /agents/available` → the agent kinds this host can actually launch.
  ///
  /// Empty is a meaningful answer and never an error: a bridge older than the
  /// lifecycle endpoints 404s, and a host with no agents installed answers an
  /// empty list. Both mean the same thing to the UI — don't offer to start one —
  /// so both collapse to `[]` here rather than making every caller branch.
  Future<List<AvailableAgent>> availableAgents() async {
    try {
      final res = await _dio.get<Map<String, dynamic>>('/agents/available');
      final agents = (res.data ?? const {})['agents'];
      if (agents is! List) return const [];
      return agents
          .whereType<Map>()
          .map((a) => AvailableAgent.fromJson(Map<String, dynamic>.from(a)))
          .toList();
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return const [];
      throw _asBridgeException(e);
    }
  }

  /// `POST /agent/start` → launch [kind] and return where it landed.
  ///
  /// Exactly one target: [paneId] reuses an existing idle shell pane,
  /// [splitFrom] splits one, [workspaceId] opens a new tab. [cwd] must be an
  /// absolute, existing directory (the bridge validates and rejects otherwise)
  /// and is only accepted for the two creating forms — an existing pane keeps
  /// its own directory. [prompt] is submitted as the agent's first message.
  Future<StartAgentResult> startAgent({
    required String kind,
    String? paneId,
    String? splitFrom,
    String? workspaceId,
    String? direction,
    String? label,
    String? cwd,
    String? prompt,
  }) async {
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        '/agent/start',
        data: {
          'kind': kind,
          if (paneId != null && paneId.isNotEmpty) 'pane_id': paneId,
          if (splitFrom != null && splitFrom.isNotEmpty) 'split_from': splitFrom,
          if (workspaceId != null && workspaceId.isNotEmpty)
            'workspace_id': workspaceId,
          if (direction != null && direction.isNotEmpty) 'direction': direction,
          if (label != null && label.isNotEmpty) 'label': label,
          if (cwd != null && cwd.isNotEmpty) 'cwd': cwd,
          if (prompt != null && prompt.isNotEmpty) 'prompt': prompt,
        },
        options: _launchOptions,
      );
      final body = res.data ?? const <String, dynamic>{};
      final result = StartAgentResult.fromJson(body);
      if (result.paneId.isEmpty) {
        throw BridgeException('Bridge did not return a pane for the new agent');
      }
      return result;
    } on DioException catch (e) {
      throw _asLaunchException(e);
    }
  }

  /// `POST /agent/restart {pane_id}` → stop the agent in [paneId] and start the
  /// same kind again in the same pane and directory.
  ///
  /// Destructive: the running turn is killed and the replacement starts with no
  /// conversation history. Confirm before calling.
  Future<void> restartAgent(String paneId, {String? prompt}) async {
    try {
      await _dio.post<dynamic>(
        '/agent/restart',
        data: {
          'pane_id': paneId,
          if (prompt != null && prompt.isNotEmpty) 'prompt': prompt,
        },
        options: _launchOptions,
      );
    } on DioException catch (e) {
      throw _asLaunchException(e);
    }
  }

  /// `POST /agent/stop {pane_id}` → quit the agent in [paneId], leaving the pane
  /// open at a shell prompt.
  ///
  /// Destructive: whatever it was doing is interrupted. The bridge only answers
  /// `200` once it has *observed* the pane back at its prompt — a `409` means the
  /// agent ignored the interrupts and is still running, so treat it as "not
  /// stopped", never as a slow success. Confirm before calling.
  Future<void> stopAgent(String paneId) async {
    try {
      await _dio.post<dynamic>(
        '/agent/stop',
        data: {'pane_id': paneId},
        options: _launchOptions,
      );
    } on DioException catch (e) {
      throw _asLaunchException(e);
    }
  }

  /// The lifecycle endpoints are the only ones that legitimately take tens of
  /// seconds: Herdr blocks a start until it has *verified* the agent is up, and
  /// blocks a stop until the pane is back at its shell. The default 8s receive
  /// timeout would abort those mid-flight and report a failure for a launch that
  /// then succeeds on the host — the worst possible outcome, since the app would
  /// show an error next to a real running agent.
  static final _launchOptions = Options(
    receiveTimeout: const Duration(seconds: 120),
    sendTimeout: const Duration(seconds: 30),
  );

  /// Lifecycle failures are explained in the bridge's plain-text body — "cwd
  /// does not exist: /nope", "pane w1:p3 is busy running npm run dev", "the
  /// claude agent did not exit within 12s and is still running". Those sentences
  /// are the whole value of the response, and the generic mapper would throw
  /// them away for "Bridge request failed", so this prefers the body and falls
  /// back to the generic mapping when there isn't one.
  BridgeException _asLaunchException(DioException e) {
    final data = e.response?.data;
    if (data is String) {
      final message = data.trim();
      if (message.isNotEmpty && message.length <= 400) {
        return BridgeException(message, statusCode: e.response?.statusCode);
      }
    }
    return _asBridgeException(e);
  }

  /// `POST /register-token {token}` → registers this device's FCM token so the
  /// bridge can push `blocked`/`done` notifications to it.
  Future<void> registerToken(String fcmToken) async {
    try {
      await _dio.post<dynamic>('/register-token', data: {'token': fcmToken});
    } on DioException catch (e) {
      throw _asBridgeException(e);
    }
  }

  /// `GET /browse?path=&hidden=` → the host's directory tree, read-only and
  /// directories-only, so a project can be picked from the phone.
  ///
  /// [path] absent means "start at the first root" (the operator's home
  /// directory). A bridge older than the endpoint 404s — callers treat that as
  /// "this server can't browse" and hide the picker, the same gating every
  /// other added endpoint uses.
  Future<BrowseListing> browse({String? path, bool showHidden = false}) async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        '/browse',
        queryParameters: {
          if (path != null && path.isNotEmpty) 'path': path,
          if (showHidden) 'hidden': '1',
        },
      );
      return BrowseListing.fromJson(res.data ?? const <String, dynamic>{});
    } on DioException catch (e) {
      throw _asBridgeException(e);
    }
  }

  /// `POST /herdr {method, params, session}` — the allowlisted generic proxy
  /// onto Herdr's command surface (worktree/tab/pane create+close, plus reads).
  /// Returns the `result` object verbatim. A disallowed method (`403`), unknown
  /// target (`404`), or Herdr error (`502`) throws a [BridgeException] carrying
  /// the proxy's `{error}` message.
  ///
  /// [session] names which Herdr session to run against. It only matters for
  /// methods whose params carry no id to infer it from — `workspace.create`
  /// takes a bare `cwd`, so without this the space always lands in the default
  /// session. Ids in the result come back session-qualified either way.
  Future<Map<String, dynamic>> herdrCommand(
    String method, [
    Map<String, dynamic> params = const {},
    String? session,
  ]) async {
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        '/herdr',
        data: {
          'method': method,
          'params': params,
          if (session != null && session.isNotEmpty) 'session': session,
        },
      );
      final result = (res.data ?? const {})['result'];
      return result is Map ? Map<String, dynamic>.from(result) : {};
    } on DioException catch (e) {
      final data = e.response?.data;
      if (data is Map && data['error'] is String) {
        throw BridgeException(
          data['error'] as String,
          statusCode: e.response?.statusCode,
        );
      }
      throw _asBridgeException(e);
    }
  }

  /// `GET /branch-info?workspace_id=<id>` → the preflight behind "also delete
  /// the branch" in the remove-worktree confirm. See
  /// `docs/CONTRACT-branch-delete.md`.
  ///
  /// Returns null rather than throwing when the option simply cannot be
  /// offered: a bridge too old to have the endpoint (404), or any failure
  /// reaching it. The confirm dialog then falls back to exactly what it was
  /// before this feature existed — removing a worktree must not become harder
  /// because a side question could not be answered. A bridge that *can* answer
  /// but says "not deletable" returns a [BranchInfo] carrying the reason, which
  /// is a different thing and is shown.
  Future<BranchInfo?> branchInfo(String workspaceId) async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        '/branch-info',
        queryParameters: {'workspace_id': workspaceId},
      );
      final body = res.data;
      if (body == null) return null;
      return BranchInfo.fromJson(body);
    } on DioException {
      return null;
    }
  }

  /// `POST /branch-delete {repo_root, branch, force}` → delete a local branch.
  ///
  /// Call this only after the worktree removal has succeeded: git refuses to
  /// delete a branch that is still checked out, and so does the bridge. [force]
  /// is the explicit opt-in to losing unmerged commits; it does not override
  /// the default-branch or still-checked-out refusals, which have no override.
  ///
  /// A refusal is a `409` carrying the bridge's reason, which surfaces as a
  /// [BridgeException] whose message is worth showing verbatim — "worktree
  /// gone, branch kept, here's why" is a normal outcome, not a crash.
  Future<BranchDeleteResult> deleteBranch({
    required String repoRoot,
    required String branch,
    bool force = false,
  }) async {
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        '/branch-delete',
        data: {'repo_root': repoRoot, 'branch': branch, 'force': force},
      );
      return BranchDeleteResult.fromJson(res.data ?? const {});
    } on DioException catch (e) {
      final data = e.response?.data;
      if (data is Map && data['error'] is String) {
        throw BridgeException(
          data['error'] as String,
          statusCode: e.response?.statusCode,
        );
      }
      throw _asBridgeException(e);
    }
  }

  // Herdr's `agent.view.*` projection is deliberately NOT used. Herdr accepts
  // `agent.view.set` and reports the view active, but as of herdr 0.8.0
  // (protocol 19) no read applies it — `agent.list` and `session.snapshot` both
  // return the unprojected list, and there is no projected read method — so the
  // handshake ordered nothing. Attention ordering is the bridge's job instead:
  // it stamps `attention_rank` on every agent in `/snapshot` (see
  // `Agent.attention`), which is authoritative and shared by every surface.

  /// `POST /agent-mode/cycle {pane}` → advance a Claude pane's permission mode
  /// by one Shift+Tab. Returns the new mode (best-effort read-back; null if it
  /// didn't settle in time). Throws `409` for a non-Claude pane.
  Future<String?> cycleAgentMode(String pane) async {
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        '/agent-mode/cycle',
        data: {'pane': pane},
      );
      return (res.data ?? const {})['permission_mode'] as String?;
    } on DioException catch (e) {
      throw _asBridgeException(e);
    }
  }

  /// The largest upload `POST /image` accepts (10 MiB, inclusive) — mirrors
  /// `imagedrop.MaxBytes` on the bridge. Checked client-side in [uploadImage]
  /// so the common mistake ("I picked the 40 MP one") fails instantly instead
  /// of after a slow tailnet upload that ends in a 413.
  static const int maxImageBytes = 10 * 1024 * 1024;

  /// `POST /image?pane=…` with the raw bytes → the absolute path the bridge
  /// wrote inside that pane's working directory (the agent's when the pane
  /// hosts one, the pane's own when it doesn't — a plain shell pane can be
  /// handed a path just as well).
  ///
  /// The body is raw bytes, **not** multipart: a filename is the one thing the
  /// endpoint refuses to accept, so we have nothing to name a part with. The
  /// bridge sniffs the type from the bytes and derives both the extension and
  /// the filename itself (CONTRACT-image.md).
  ///
  /// [onProgress] reports sent/total. A phone pushing a few megabytes over a
  /// tailnet is slow enough that a silent upload reads as a hang, so the caller
  /// is expected to show it. The timeouts are raised well past the client's
  /// 8-second default for the same reason — that default is tuned for small
  /// JSON calls and would abort a perfectly healthy photo upload.
  ///
  /// Throws [BridgeException]; a `404` here means the bridge predates the
  /// endpoint rather than "no such agent", so it gets its own message.
  Future<ImageDrop> uploadImage(
    String pane,
    List<int> bytes, {
    void Function(int sent, int total)? onProgress,
  }) async {
    if (bytes.isEmpty) {
      throw BridgeException('That image is empty.');
    }
    if (bytes.length > maxImageBytes) {
      final mb = (bytes.length / (1024 * 1024)).toStringAsFixed(1);
      throw BridgeException(
        'That image is ${mb}MB — the limit is '
        '${maxImageBytes ~/ (1024 * 1024)}MB.',
      );
    }
    try {
      // Typed `dynamic`, not `Map`, on purpose: a 200 whose body isn't the JSON
      // we expect (a captive portal, a proxy's HTML) would fail the cast
      // *outside* the DioException catch below and surface as a raw TypeError.
      // Shape-check it here instead so every failure is a BridgeException.
      final res = await _dio.post<dynamic>(
        '/image',
        data: Stream.fromIterable([bytes]),
        queryParameters: {'pane': pane},
        onSendProgress: onProgress,
        options: Options(
          headers: {
            Headers.contentTypeHeader: 'application/octet-stream',
            // Dio won't length a raw stream by itself, and the bridge's
            // over-cap fast path keys off Content-Length — without this an
            // oversized body would be buffered before being refused.
            Headers.contentLengthHeader: bytes.length,
          },
          sendTimeout: const Duration(seconds: 90),
          receiveTimeout: const Duration(seconds: 30),
        ),
      );
      final data = res.data;
      if (data is! Map) {
        throw BridgeException('The bridge returned an unexpected response.');
      }
      final body = Map<String, dynamic>.from(data);
      final path = body['path'] as String?;
      if (path == null || path.isEmpty) {
        throw BridgeException(
          'The bridge stored the image but returned no path.',
        );
      }
      return ImageDrop(
        path: path,
        relativePath: (body['relative_path'] as String?) ?? path,
        contentType: (body['content_type'] as String?) ?? '',
        bytes: (body['bytes'] as num?)?.toInt() ?? bytes.length,
      );
    } on DioException catch (e) {
      throw _asImageException(e);
    }
  }

  /// [uploadImage]'s error mapping. `/image` has failure modes the generic
  /// mapper has no words for — and its `404` means something different here
  /// (an old bridge, not a missing agent), which is exactly the case a user
  /// would otherwise spend a while misreading.
  BridgeException _asImageException(DioException e) {
    final code = e.response?.statusCode;
    final message = switch (code) {
      404 =>
        'This bridge is too old to accept images. Update it and try again.',
      413 => 'That image is too large for the bridge (10MB limit).',
      415 => 'That file isn\'t a PNG, JPEG, GIF or WebP.',
      _ => null,
    };
    if (message != null) return BridgeException(message, statusCode: code);
    if (e.type == DioExceptionType.sendTimeout) {
      return BridgeException(
        'Upload timed out. The tailnet may be slow — try again.',
        statusCode: code,
      );
    }
    return _asBridgeException(e);
  }

  BridgeException _asBridgeException(DioException e) {
    final code = e.response?.statusCode;

    // Mixed content is checked first because it produces the same empty
    // failure as a CORS block, but unlike CORS it is DECIDABLE rather than
    // inferred. Getting the order wrong sends someone to edit allowed_origins
    // for a problem no bridge config can fix.
    //
    // A browser refuses a disallowed cross-origin response *to the page*, so
    // either failure arrives here indistinguishable from a dead network:
    // status 0, no headers, no reason. That opacity is deliberate on the
    // browser's part and no probe gets around it — which is why the CORS
    // wording stays hedged. It is still a strong inference: on the same
    // tailnet a cross-origin call that fails instantly with nothing attached
    // is far more often a missing allowed_origins entry than a machine that
    // just went down.
    if (_looksBrowserBlocked(e)) {
      final block = blockFor(
        pageOrigin: _pageOrigin,
        baseUrl: connection.baseUrl,
      );
      switch (block) {
        case BrowserBlock.mixedContent:
          return BridgeException(
            'This page is served over https, so the browser will not let it '
            'reach a bridge over http. Use that bridge\'s https URL — '
            '`tailscale serve` gives it one — and update this server\'s address.',
            blockedBy: block,
          );
        case BrowserBlock.cors:
          return BridgeException(
            'The browser blocked this before it reached the bridge — most '
            'likely CORS. Add "$_pageOrigin" to allowed_origins in '
            '~/.gothalo/config.json on that machine and restart it. (If the '
            'bridge is simply off, that looks identical from a browser.)',
            blockedBy: block,
          );
        case null:
          break;
      }
    }

    final message = switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.sendTimeout =>
        'Timed out reaching the bridge. Is the tailnet up?',
      DioExceptionType.connectionError =>
        'Could not reach the bridge. Check the URL and that you\'re on the tailnet.',
      _ => switch (code) {
        401 || 403 => 'Unauthorized — the bearer token was rejected.',
        502 || 503 => 'Bridge is unreachable (502/503). Is the daemon running?',
        _ => e.message ?? 'Bridge request failed',
      },
    };
    return BridgeException(message, statusCode: code);
  }

  /// The shape both browser-side blocks share: we are in a browser (nothing
  /// else enforces these rules) and the request died with no response at all
  /// (a reply that arrived — even a 401 — proves the browser let it through).
  /// Which rule applies is [blockFor]'s job.
  bool _looksBrowserBlocked(DioException e) {
    if (!kIsWeb || e.response != null) return false;
    return e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.unknown;
  }

  /// Which browser rule, if any, stops a page at [pageOrigin] from reaching
  /// [baseUrl]. Null when the browser has no objection — same origin, or off
  /// the web entirely — which leaves an ordinary network failure.
  ///
  /// Pure and public so it can be tested: the live path is gated on [kIsWeb],
  /// which is false under `flutter test`, so the decision would otherwise go
  /// unverified on every platform that can run the suite.
  static BrowserBlock? blockFor({
    required String? pageOrigin,
    required String baseUrl,
  }) {
    if (pageOrigin == null) return null;
    final target = Uri.tryParse(baseUrl);
    if (target == null) return null;
    // Mixed content outranks CORS: it is decided by scheme alone, and it holds
    // even for an origin the bridge does allow.
    if (pageOrigin.startsWith('https:') && target.isScheme('http')) {
      return BrowserBlock.mixedContent;
    }
    final targetOrigin = _originOf(baseUrl);
    if (targetOrigin != null && targetOrigin != pageOrigin) {
      return BrowserBlock.cors;
    }
    return null;
  }

  /// `Uri.origin` throws on anything that is not http(s) with a host, which a
  /// hand-typed base URL can easily be.
  static String? _originOf(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.isScheme('http') && !uri.isScheme('https')) {
      return null;
    }
    return uri.host.isEmpty ? null : uri.origin;
  }

  /// Null off the web, where [Uri.base] is a filesystem path rather than a page.
  static String? get _pageOrigin => kIsWeb ? _originOf(Uri.base.toString()) : null;
}
