// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'snapshot.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$Agent {

 String get agent;@JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown) AgentStatus get agentStatus;@JsonKey(name: 'pane_id') String get paneId;@JsonKey(name: 'terminal_title_stripped') String get title;@JsonKey(name: 'workspace_id') String get workspaceId;@JsonKey(name: 'tab_id') String get tabId; String get cwd;/// The pane's **live foreground** working directory (tracks a shell `cd`),
/// as reported by herdr. This is the "proper pane" cwd — preferred over the
/// launch [cwd] for git context (see [gitContext]). Falls back to [cwd]
/// when the bridge doesn't supply it.
@JsonKey(name: 'foreground_cwd') String get foregroundCwd;/// The agent's checked-out git **branch**, reported authoritatively by the
/// bridge (it asks git). Empty when the bridge doesn't supply it (an older
/// bridge, or a cwd that isn't a repo) — the app then falls back to
/// inferring the branch from [cwd]. See [branchName].
 String get branch; bool get focused;@JsonKey(name: 'agent_session') AgentSession? get session;/// Herdr's monotonic sequence for this agent's state. Backs idempotent
/// approvals (D8): an approve tap carries this seq and the bridge no-ops if
/// the agent is no longer blocked at it.
@JsonKey(name: 'state_change_seq') int? get stateChangeSeq;/// The bridge's authoritative "needs a human first" rank, lowest first. It
/// is computed server-side so every surface (inbox, priority, counts, the
/// aggregate header) orders identically instead of each deriving its own.
/// Null on an older bridge that doesn't send it — see [attention], which
/// falls back to the local [AgentStatus.rank].
@JsonKey(name: 'attention_rank') int? get attentionRank;/// The bridge's authoritative "what did I touch last" rank, lowest first
/// and unique within a snapshot. It is the tiebreak *within* an
/// [attentionRank], not a rival to it: what needs you still comes first,
/// this only decides the order among agents that need you equally — which
/// the snapshot's own arrival order used to decide, i.e. arbitrarily.
///
/// It is a **position in this snapshot's list**, not an identity: it shifts
/// as agents come and go. Compare it; never cache or diff it across
/// snapshots. Null on an older bridge — see [Agent.byAttentionThenRecency],
/// which falls back to [lastActivityTs].
@JsonKey(name: 'recency_rank') int? get recencyRank;/// When this agent last wrote to its transcript, in unix milliseconds —
/// the bridge's answer to "how long has it been like this".
///
/// Every other field describes NOW. This is the only one that dates it, and
/// it is what turns "blocked" into "blocked 50m" — the difference that
/// decides whether you pick the phone up.
///
/// **Null means unknown, never "just now".** Absent for a kind whose
/// sessions share one store (the bridge refuses to report another agent's
/// age as this one's) and for an agent that has not spoken yet. Render
/// nothing rather than "0s".
@JsonKey(name: 'last_activity_ts') int? get lastActivityTs;
/// Create a copy of Agent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AgentCopyWith<Agent> get copyWith => _$AgentCopyWithImpl<Agent>(this as Agent, _$identity);

  /// Serializes this Agent to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Agent&&(identical(other.agent, agent) || other.agent == agent)&&(identical(other.agentStatus, agentStatus) || other.agentStatus == agentStatus)&&(identical(other.paneId, paneId) || other.paneId == paneId)&&(identical(other.title, title) || other.title == title)&&(identical(other.workspaceId, workspaceId) || other.workspaceId == workspaceId)&&(identical(other.tabId, tabId) || other.tabId == tabId)&&(identical(other.cwd, cwd) || other.cwd == cwd)&&(identical(other.foregroundCwd, foregroundCwd) || other.foregroundCwd == foregroundCwd)&&(identical(other.branch, branch) || other.branch == branch)&&(identical(other.focused, focused) || other.focused == focused)&&(identical(other.session, session) || other.session == session)&&(identical(other.stateChangeSeq, stateChangeSeq) || other.stateChangeSeq == stateChangeSeq)&&(identical(other.attentionRank, attentionRank) || other.attentionRank == attentionRank)&&(identical(other.recencyRank, recencyRank) || other.recencyRank == recencyRank)&&(identical(other.lastActivityTs, lastActivityTs) || other.lastActivityTs == lastActivityTs));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,agent,agentStatus,paneId,title,workspaceId,tabId,cwd,foregroundCwd,branch,focused,session,stateChangeSeq,attentionRank,recencyRank,lastActivityTs);

@override
String toString() {
  return 'Agent(agent: $agent, agentStatus: $agentStatus, paneId: $paneId, title: $title, workspaceId: $workspaceId, tabId: $tabId, cwd: $cwd, foregroundCwd: $foregroundCwd, branch: $branch, focused: $focused, session: $session, stateChangeSeq: $stateChangeSeq, attentionRank: $attentionRank, recencyRank: $recencyRank, lastActivityTs: $lastActivityTs)';
}


}

/// @nodoc
abstract mixin class $AgentCopyWith<$Res>  {
  factory $AgentCopyWith(Agent value, $Res Function(Agent) _then) = _$AgentCopyWithImpl;
@useResult
$Res call({
 String agent,@JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown) AgentStatus agentStatus,@JsonKey(name: 'pane_id') String paneId,@JsonKey(name: 'terminal_title_stripped') String title,@JsonKey(name: 'workspace_id') String workspaceId,@JsonKey(name: 'tab_id') String tabId, String cwd,@JsonKey(name: 'foreground_cwd') String foregroundCwd, String branch, bool focused,@JsonKey(name: 'agent_session') AgentSession? session,@JsonKey(name: 'state_change_seq') int? stateChangeSeq,@JsonKey(name: 'attention_rank') int? attentionRank,@JsonKey(name: 'recency_rank') int? recencyRank,@JsonKey(name: 'last_activity_ts') int? lastActivityTs
});


$AgentSessionCopyWith<$Res>? get session;

}
/// @nodoc
class _$AgentCopyWithImpl<$Res>
    implements $AgentCopyWith<$Res> {
  _$AgentCopyWithImpl(this._self, this._then);

  final Agent _self;
  final $Res Function(Agent) _then;

/// Create a copy of Agent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? agent = null,Object? agentStatus = null,Object? paneId = null,Object? title = null,Object? workspaceId = null,Object? tabId = null,Object? cwd = null,Object? foregroundCwd = null,Object? branch = null,Object? focused = null,Object? session = freezed,Object? stateChangeSeq = freezed,Object? attentionRank = freezed,Object? recencyRank = freezed,Object? lastActivityTs = freezed,}) {
  return _then(_self.copyWith(
agent: null == agent ? _self.agent : agent // ignore: cast_nullable_to_non_nullable
as String,agentStatus: null == agentStatus ? _self.agentStatus : agentStatus // ignore: cast_nullable_to_non_nullable
as AgentStatus,paneId: null == paneId ? _self.paneId : paneId // ignore: cast_nullable_to_non_nullable
as String,title: null == title ? _self.title : title // ignore: cast_nullable_to_non_nullable
as String,workspaceId: null == workspaceId ? _self.workspaceId : workspaceId // ignore: cast_nullable_to_non_nullable
as String,tabId: null == tabId ? _self.tabId : tabId // ignore: cast_nullable_to_non_nullable
as String,cwd: null == cwd ? _self.cwd : cwd // ignore: cast_nullable_to_non_nullable
as String,foregroundCwd: null == foregroundCwd ? _self.foregroundCwd : foregroundCwd // ignore: cast_nullable_to_non_nullable
as String,branch: null == branch ? _self.branch : branch // ignore: cast_nullable_to_non_nullable
as String,focused: null == focused ? _self.focused : focused // ignore: cast_nullable_to_non_nullable
as bool,session: freezed == session ? _self.session : session // ignore: cast_nullable_to_non_nullable
as AgentSession?,stateChangeSeq: freezed == stateChangeSeq ? _self.stateChangeSeq : stateChangeSeq // ignore: cast_nullable_to_non_nullable
as int?,attentionRank: freezed == attentionRank ? _self.attentionRank : attentionRank // ignore: cast_nullable_to_non_nullable
as int?,recencyRank: freezed == recencyRank ? _self.recencyRank : recencyRank // ignore: cast_nullable_to_non_nullable
as int?,lastActivityTs: freezed == lastActivityTs ? _self.lastActivityTs : lastActivityTs // ignore: cast_nullable_to_non_nullable
as int?,
  ));
}
/// Create a copy of Agent
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$AgentSessionCopyWith<$Res>? get session {
    if (_self.session == null) {
    return null;
  }

  return $AgentSessionCopyWith<$Res>(_self.session!, (value) {
    return _then(_self.copyWith(session: value));
  });
}
}


/// Adds pattern-matching-related methods to [Agent].
extension AgentPatterns on Agent {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _Agent value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _Agent() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _Agent value)  $default,){
final _that = this;
switch (_that) {
case _Agent():
return $default(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _Agent value)?  $default,){
final _that = this;
switch (_that) {
case _Agent() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String agent, @JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown)  AgentStatus agentStatus, @JsonKey(name: 'pane_id')  String paneId, @JsonKey(name: 'terminal_title_stripped')  String title, @JsonKey(name: 'workspace_id')  String workspaceId, @JsonKey(name: 'tab_id')  String tabId,  String cwd, @JsonKey(name: 'foreground_cwd')  String foregroundCwd,  String branch,  bool focused, @JsonKey(name: 'agent_session')  AgentSession? session, @JsonKey(name: 'state_change_seq')  int? stateChangeSeq, @JsonKey(name: 'attention_rank')  int? attentionRank, @JsonKey(name: 'recency_rank')  int? recencyRank, @JsonKey(name: 'last_activity_ts')  int? lastActivityTs)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Agent() when $default != null:
return $default(_that.agent,_that.agentStatus,_that.paneId,_that.title,_that.workspaceId,_that.tabId,_that.cwd,_that.foregroundCwd,_that.branch,_that.focused,_that.session,_that.stateChangeSeq,_that.attentionRank,_that.recencyRank,_that.lastActivityTs);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String agent, @JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown)  AgentStatus agentStatus, @JsonKey(name: 'pane_id')  String paneId, @JsonKey(name: 'terminal_title_stripped')  String title, @JsonKey(name: 'workspace_id')  String workspaceId, @JsonKey(name: 'tab_id')  String tabId,  String cwd, @JsonKey(name: 'foreground_cwd')  String foregroundCwd,  String branch,  bool focused, @JsonKey(name: 'agent_session')  AgentSession? session, @JsonKey(name: 'state_change_seq')  int? stateChangeSeq, @JsonKey(name: 'attention_rank')  int? attentionRank, @JsonKey(name: 'recency_rank')  int? recencyRank, @JsonKey(name: 'last_activity_ts')  int? lastActivityTs)  $default,) {final _that = this;
switch (_that) {
case _Agent():
return $default(_that.agent,_that.agentStatus,_that.paneId,_that.title,_that.workspaceId,_that.tabId,_that.cwd,_that.foregroundCwd,_that.branch,_that.focused,_that.session,_that.stateChangeSeq,_that.attentionRank,_that.recencyRank,_that.lastActivityTs);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String agent, @JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown)  AgentStatus agentStatus, @JsonKey(name: 'pane_id')  String paneId, @JsonKey(name: 'terminal_title_stripped')  String title, @JsonKey(name: 'workspace_id')  String workspaceId, @JsonKey(name: 'tab_id')  String tabId,  String cwd, @JsonKey(name: 'foreground_cwd')  String foregroundCwd,  String branch,  bool focused, @JsonKey(name: 'agent_session')  AgentSession? session, @JsonKey(name: 'state_change_seq')  int? stateChangeSeq, @JsonKey(name: 'attention_rank')  int? attentionRank, @JsonKey(name: 'recency_rank')  int? recencyRank, @JsonKey(name: 'last_activity_ts')  int? lastActivityTs)?  $default,) {final _that = this;
switch (_that) {
case _Agent() when $default != null:
return $default(_that.agent,_that.agentStatus,_that.paneId,_that.title,_that.workspaceId,_that.tabId,_that.cwd,_that.foregroundCwd,_that.branch,_that.focused,_that.session,_that.stateChangeSeq,_that.attentionRank,_that.recencyRank,_that.lastActivityTs);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _Agent extends Agent {
  const _Agent({this.agent = '', @JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown) this.agentStatus = AgentStatus.unknown, @JsonKey(name: 'pane_id') this.paneId = '', @JsonKey(name: 'terminal_title_stripped') this.title = '', @JsonKey(name: 'workspace_id') this.workspaceId = '', @JsonKey(name: 'tab_id') this.tabId = '', this.cwd = '', @JsonKey(name: 'foreground_cwd') this.foregroundCwd = '', this.branch = '', this.focused = false, @JsonKey(name: 'agent_session') this.session, @JsonKey(name: 'state_change_seq') this.stateChangeSeq, @JsonKey(name: 'attention_rank') this.attentionRank, @JsonKey(name: 'recency_rank') this.recencyRank, @JsonKey(name: 'last_activity_ts') this.lastActivityTs}): super._();
  factory _Agent.fromJson(Map<String, dynamic> json) => _$AgentFromJson(json);

@override@JsonKey() final  String agent;
@override@JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown) final  AgentStatus agentStatus;
@override@JsonKey(name: 'pane_id') final  String paneId;
@override@JsonKey(name: 'terminal_title_stripped') final  String title;
@override@JsonKey(name: 'workspace_id') final  String workspaceId;
@override@JsonKey(name: 'tab_id') final  String tabId;
@override@JsonKey() final  String cwd;
/// The pane's **live foreground** working directory (tracks a shell `cd`),
/// as reported by herdr. This is the "proper pane" cwd — preferred over the
/// launch [cwd] for git context (see [gitContext]). Falls back to [cwd]
/// when the bridge doesn't supply it.
@override@JsonKey(name: 'foreground_cwd') final  String foregroundCwd;
/// The agent's checked-out git **branch**, reported authoritatively by the
/// bridge (it asks git). Empty when the bridge doesn't supply it (an older
/// bridge, or a cwd that isn't a repo) — the app then falls back to
/// inferring the branch from [cwd]. See [branchName].
@override@JsonKey() final  String branch;
@override@JsonKey() final  bool focused;
@override@JsonKey(name: 'agent_session') final  AgentSession? session;
/// Herdr's monotonic sequence for this agent's state. Backs idempotent
/// approvals (D8): an approve tap carries this seq and the bridge no-ops if
/// the agent is no longer blocked at it.
@override@JsonKey(name: 'state_change_seq') final  int? stateChangeSeq;
/// The bridge's authoritative "needs a human first" rank, lowest first. It
/// is computed server-side so every surface (inbox, priority, counts, the
/// aggregate header) orders identically instead of each deriving its own.
/// Null on an older bridge that doesn't send it — see [attention], which
/// falls back to the local [AgentStatus.rank].
@override@JsonKey(name: 'attention_rank') final  int? attentionRank;
/// The bridge's authoritative "what did I touch last" rank, lowest first
/// and unique within a snapshot. It is the tiebreak *within* an
/// [attentionRank], not a rival to it: what needs you still comes first,
/// this only decides the order among agents that need you equally — which
/// the snapshot's own arrival order used to decide, i.e. arbitrarily.
///
/// It is a **position in this snapshot's list**, not an identity: it shifts
/// as agents come and go. Compare it; never cache or diff it across
/// snapshots. Null on an older bridge — see [Agent.byAttentionThenRecency],
/// which falls back to [lastActivityTs].
@override@JsonKey(name: 'recency_rank') final  int? recencyRank;
/// When this agent last wrote to its transcript, in unix milliseconds —
/// the bridge's answer to "how long has it been like this".
///
/// Every other field describes NOW. This is the only one that dates it, and
/// it is what turns "blocked" into "blocked 50m" — the difference that
/// decides whether you pick the phone up.
///
/// **Null means unknown, never "just now".** Absent for a kind whose
/// sessions share one store (the bridge refuses to report another agent's
/// age as this one's) and for an agent that has not spoken yet. Render
/// nothing rather than "0s".
@override@JsonKey(name: 'last_activity_ts') final  int? lastActivityTs;

/// Create a copy of Agent
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$AgentCopyWith<_Agent> get copyWith => __$AgentCopyWithImpl<_Agent>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$AgentToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _Agent&&(identical(other.agent, agent) || other.agent == agent)&&(identical(other.agentStatus, agentStatus) || other.agentStatus == agentStatus)&&(identical(other.paneId, paneId) || other.paneId == paneId)&&(identical(other.title, title) || other.title == title)&&(identical(other.workspaceId, workspaceId) || other.workspaceId == workspaceId)&&(identical(other.tabId, tabId) || other.tabId == tabId)&&(identical(other.cwd, cwd) || other.cwd == cwd)&&(identical(other.foregroundCwd, foregroundCwd) || other.foregroundCwd == foregroundCwd)&&(identical(other.branch, branch) || other.branch == branch)&&(identical(other.focused, focused) || other.focused == focused)&&(identical(other.session, session) || other.session == session)&&(identical(other.stateChangeSeq, stateChangeSeq) || other.stateChangeSeq == stateChangeSeq)&&(identical(other.attentionRank, attentionRank) || other.attentionRank == attentionRank)&&(identical(other.recencyRank, recencyRank) || other.recencyRank == recencyRank)&&(identical(other.lastActivityTs, lastActivityTs) || other.lastActivityTs == lastActivityTs));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,agent,agentStatus,paneId,title,workspaceId,tabId,cwd,foregroundCwd,branch,focused,session,stateChangeSeq,attentionRank,recencyRank,lastActivityTs);

@override
String toString() {
  return 'Agent(agent: $agent, agentStatus: $agentStatus, paneId: $paneId, title: $title, workspaceId: $workspaceId, tabId: $tabId, cwd: $cwd, foregroundCwd: $foregroundCwd, branch: $branch, focused: $focused, session: $session, stateChangeSeq: $stateChangeSeq, attentionRank: $attentionRank, recencyRank: $recencyRank, lastActivityTs: $lastActivityTs)';
}


}

/// @nodoc
abstract mixin class _$AgentCopyWith<$Res> implements $AgentCopyWith<$Res> {
  factory _$AgentCopyWith(_Agent value, $Res Function(_Agent) _then) = __$AgentCopyWithImpl;
@override @useResult
$Res call({
 String agent,@JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown) AgentStatus agentStatus,@JsonKey(name: 'pane_id') String paneId,@JsonKey(name: 'terminal_title_stripped') String title,@JsonKey(name: 'workspace_id') String workspaceId,@JsonKey(name: 'tab_id') String tabId, String cwd,@JsonKey(name: 'foreground_cwd') String foregroundCwd, String branch, bool focused,@JsonKey(name: 'agent_session') AgentSession? session,@JsonKey(name: 'state_change_seq') int? stateChangeSeq,@JsonKey(name: 'attention_rank') int? attentionRank,@JsonKey(name: 'recency_rank') int? recencyRank,@JsonKey(name: 'last_activity_ts') int? lastActivityTs
});


@override $AgentSessionCopyWith<$Res>? get session;

}
/// @nodoc
class __$AgentCopyWithImpl<$Res>
    implements _$AgentCopyWith<$Res> {
  __$AgentCopyWithImpl(this._self, this._then);

  final _Agent _self;
  final $Res Function(_Agent) _then;

/// Create a copy of Agent
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? agent = null,Object? agentStatus = null,Object? paneId = null,Object? title = null,Object? workspaceId = null,Object? tabId = null,Object? cwd = null,Object? foregroundCwd = null,Object? branch = null,Object? focused = null,Object? session = freezed,Object? stateChangeSeq = freezed,Object? attentionRank = freezed,Object? recencyRank = freezed,Object? lastActivityTs = freezed,}) {
  return _then(_Agent(
agent: null == agent ? _self.agent : agent // ignore: cast_nullable_to_non_nullable
as String,agentStatus: null == agentStatus ? _self.agentStatus : agentStatus // ignore: cast_nullable_to_non_nullable
as AgentStatus,paneId: null == paneId ? _self.paneId : paneId // ignore: cast_nullable_to_non_nullable
as String,title: null == title ? _self.title : title // ignore: cast_nullable_to_non_nullable
as String,workspaceId: null == workspaceId ? _self.workspaceId : workspaceId // ignore: cast_nullable_to_non_nullable
as String,tabId: null == tabId ? _self.tabId : tabId // ignore: cast_nullable_to_non_nullable
as String,cwd: null == cwd ? _self.cwd : cwd // ignore: cast_nullable_to_non_nullable
as String,foregroundCwd: null == foregroundCwd ? _self.foregroundCwd : foregroundCwd // ignore: cast_nullable_to_non_nullable
as String,branch: null == branch ? _self.branch : branch // ignore: cast_nullable_to_non_nullable
as String,focused: null == focused ? _self.focused : focused // ignore: cast_nullable_to_non_nullable
as bool,session: freezed == session ? _self.session : session // ignore: cast_nullable_to_non_nullable
as AgentSession?,stateChangeSeq: freezed == stateChangeSeq ? _self.stateChangeSeq : stateChangeSeq // ignore: cast_nullable_to_non_nullable
as int?,attentionRank: freezed == attentionRank ? _self.attentionRank : attentionRank // ignore: cast_nullable_to_non_nullable
as int?,recencyRank: freezed == recencyRank ? _self.recencyRank : recencyRank // ignore: cast_nullable_to_non_nullable
as int?,lastActivityTs: freezed == lastActivityTs ? _self.lastActivityTs : lastActivityTs // ignore: cast_nullable_to_non_nullable
as int?,
  ));
}

/// Create a copy of Agent
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$AgentSessionCopyWith<$Res>? get session {
    if (_self.session == null) {
    return null;
  }

  return $AgentSessionCopyWith<$Res>(_self.session!, (value) {
    return _then(_self.copyWith(session: value));
  });
}
}


/// @nodoc
mixin _$AgentSession {

 String? get value;
/// Create a copy of AgentSession
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AgentSessionCopyWith<AgentSession> get copyWith => _$AgentSessionCopyWithImpl<AgentSession>(this as AgentSession, _$identity);

  /// Serializes this AgentSession to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AgentSession&&(identical(other.value, value) || other.value == value));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,value);

@override
String toString() {
  return 'AgentSession(value: $value)';
}


}

/// @nodoc
abstract mixin class $AgentSessionCopyWith<$Res>  {
  factory $AgentSessionCopyWith(AgentSession value, $Res Function(AgentSession) _then) = _$AgentSessionCopyWithImpl;
@useResult
$Res call({
 String? value
});




}
/// @nodoc
class _$AgentSessionCopyWithImpl<$Res>
    implements $AgentSessionCopyWith<$Res> {
  _$AgentSessionCopyWithImpl(this._self, this._then);

  final AgentSession _self;
  final $Res Function(AgentSession) _then;

/// Create a copy of AgentSession
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? value = freezed,}) {
  return _then(_self.copyWith(
value: freezed == value ? _self.value : value // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// Adds pattern-matching-related methods to [AgentSession].
extension AgentSessionPatterns on AgentSession {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _AgentSession value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _AgentSession() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _AgentSession value)  $default,){
final _that = this;
switch (_that) {
case _AgentSession():
return $default(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _AgentSession value)?  $default,){
final _that = this;
switch (_that) {
case _AgentSession() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String? value)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _AgentSession() when $default != null:
return $default(_that.value);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String? value)  $default,) {final _that = this;
switch (_that) {
case _AgentSession():
return $default(_that.value);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String? value)?  $default,) {final _that = this;
switch (_that) {
case _AgentSession() when $default != null:
return $default(_that.value);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _AgentSession implements AgentSession {
  const _AgentSession({this.value});
  factory _AgentSession.fromJson(Map<String, dynamic> json) => _$AgentSessionFromJson(json);

@override final  String? value;

/// Create a copy of AgentSession
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$AgentSessionCopyWith<_AgentSession> get copyWith => __$AgentSessionCopyWithImpl<_AgentSession>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$AgentSessionToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _AgentSession&&(identical(other.value, value) || other.value == value));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,value);

@override
String toString() {
  return 'AgentSession(value: $value)';
}


}

/// @nodoc
abstract mixin class _$AgentSessionCopyWith<$Res> implements $AgentSessionCopyWith<$Res> {
  factory _$AgentSessionCopyWith(_AgentSession value, $Res Function(_AgentSession) _then) = __$AgentSessionCopyWithImpl;
@override @useResult
$Res call({
 String? value
});




}
/// @nodoc
class __$AgentSessionCopyWithImpl<$Res>
    implements _$AgentSessionCopyWith<$Res> {
  __$AgentSessionCopyWithImpl(this._self, this._then);

  final _AgentSession _self;
  final $Res Function(_AgentSession) _then;

/// Create a copy of AgentSession
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? value = freezed,}) {
  return _then(_AgentSession(
value: freezed == value ? _self.value : value // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}


/// @nodoc
mixin _$Pane {

@JsonKey(name: 'pane_id') String get paneId;@JsonKey(name: 'tab_id') String get tabId;@JsonKey(name: 'workspace_id') String get workspaceId;@JsonKey(name: 'terminal_title_stripped') String get title;@JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown) AgentStatus get agentStatus; bool get focused; String get cwd;@JsonKey(name: 'foreground_cwd') String get foregroundCwd;
/// Create a copy of Pane
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PaneCopyWith<Pane> get copyWith => _$PaneCopyWithImpl<Pane>(this as Pane, _$identity);

  /// Serializes this Pane to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Pane&&(identical(other.paneId, paneId) || other.paneId == paneId)&&(identical(other.tabId, tabId) || other.tabId == tabId)&&(identical(other.workspaceId, workspaceId) || other.workspaceId == workspaceId)&&(identical(other.title, title) || other.title == title)&&(identical(other.agentStatus, agentStatus) || other.agentStatus == agentStatus)&&(identical(other.focused, focused) || other.focused == focused)&&(identical(other.cwd, cwd) || other.cwd == cwd)&&(identical(other.foregroundCwd, foregroundCwd) || other.foregroundCwd == foregroundCwd));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,paneId,tabId,workspaceId,title,agentStatus,focused,cwd,foregroundCwd);

@override
String toString() {
  return 'Pane(paneId: $paneId, tabId: $tabId, workspaceId: $workspaceId, title: $title, agentStatus: $agentStatus, focused: $focused, cwd: $cwd, foregroundCwd: $foregroundCwd)';
}


}

/// @nodoc
abstract mixin class $PaneCopyWith<$Res>  {
  factory $PaneCopyWith(Pane value, $Res Function(Pane) _then) = _$PaneCopyWithImpl;
@useResult
$Res call({
@JsonKey(name: 'pane_id') String paneId,@JsonKey(name: 'tab_id') String tabId,@JsonKey(name: 'workspace_id') String workspaceId,@JsonKey(name: 'terminal_title_stripped') String title,@JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown) AgentStatus agentStatus, bool focused, String cwd,@JsonKey(name: 'foreground_cwd') String foregroundCwd
});




}
/// @nodoc
class _$PaneCopyWithImpl<$Res>
    implements $PaneCopyWith<$Res> {
  _$PaneCopyWithImpl(this._self, this._then);

  final Pane _self;
  final $Res Function(Pane) _then;

/// Create a copy of Pane
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? paneId = null,Object? tabId = null,Object? workspaceId = null,Object? title = null,Object? agentStatus = null,Object? focused = null,Object? cwd = null,Object? foregroundCwd = null,}) {
  return _then(_self.copyWith(
paneId: null == paneId ? _self.paneId : paneId // ignore: cast_nullable_to_non_nullable
as String,tabId: null == tabId ? _self.tabId : tabId // ignore: cast_nullable_to_non_nullable
as String,workspaceId: null == workspaceId ? _self.workspaceId : workspaceId // ignore: cast_nullable_to_non_nullable
as String,title: null == title ? _self.title : title // ignore: cast_nullable_to_non_nullable
as String,agentStatus: null == agentStatus ? _self.agentStatus : agentStatus // ignore: cast_nullable_to_non_nullable
as AgentStatus,focused: null == focused ? _self.focused : focused // ignore: cast_nullable_to_non_nullable
as bool,cwd: null == cwd ? _self.cwd : cwd // ignore: cast_nullable_to_non_nullable
as String,foregroundCwd: null == foregroundCwd ? _self.foregroundCwd : foregroundCwd // ignore: cast_nullable_to_non_nullable
as String,
  ));
}

}


/// Adds pattern-matching-related methods to [Pane].
extension PanePatterns on Pane {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _Pane value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _Pane() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _Pane value)  $default,){
final _that = this;
switch (_that) {
case _Pane():
return $default(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _Pane value)?  $default,){
final _that = this;
switch (_that) {
case _Pane() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function(@JsonKey(name: 'pane_id')  String paneId, @JsonKey(name: 'tab_id')  String tabId, @JsonKey(name: 'workspace_id')  String workspaceId, @JsonKey(name: 'terminal_title_stripped')  String title, @JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown)  AgentStatus agentStatus,  bool focused,  String cwd, @JsonKey(name: 'foreground_cwd')  String foregroundCwd)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Pane() when $default != null:
return $default(_that.paneId,_that.tabId,_that.workspaceId,_that.title,_that.agentStatus,_that.focused,_that.cwd,_that.foregroundCwd);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function(@JsonKey(name: 'pane_id')  String paneId, @JsonKey(name: 'tab_id')  String tabId, @JsonKey(name: 'workspace_id')  String workspaceId, @JsonKey(name: 'terminal_title_stripped')  String title, @JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown)  AgentStatus agentStatus,  bool focused,  String cwd, @JsonKey(name: 'foreground_cwd')  String foregroundCwd)  $default,) {final _that = this;
switch (_that) {
case _Pane():
return $default(_that.paneId,_that.tabId,_that.workspaceId,_that.title,_that.agentStatus,_that.focused,_that.cwd,_that.foregroundCwd);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function(@JsonKey(name: 'pane_id')  String paneId, @JsonKey(name: 'tab_id')  String tabId, @JsonKey(name: 'workspace_id')  String workspaceId, @JsonKey(name: 'terminal_title_stripped')  String title, @JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown)  AgentStatus agentStatus,  bool focused,  String cwd, @JsonKey(name: 'foreground_cwd')  String foregroundCwd)?  $default,) {final _that = this;
switch (_that) {
case _Pane() when $default != null:
return $default(_that.paneId,_that.tabId,_that.workspaceId,_that.title,_that.agentStatus,_that.focused,_that.cwd,_that.foregroundCwd);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _Pane extends Pane {
  const _Pane({@JsonKey(name: 'pane_id') this.paneId = '', @JsonKey(name: 'tab_id') this.tabId = '', @JsonKey(name: 'workspace_id') this.workspaceId = '', @JsonKey(name: 'terminal_title_stripped') this.title = '', @JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown) this.agentStatus = AgentStatus.unknown, this.focused = false, this.cwd = '', @JsonKey(name: 'foreground_cwd') this.foregroundCwd = ''}): super._();
  factory _Pane.fromJson(Map<String, dynamic> json) => _$PaneFromJson(json);

@override@JsonKey(name: 'pane_id') final  String paneId;
@override@JsonKey(name: 'tab_id') final  String tabId;
@override@JsonKey(name: 'workspace_id') final  String workspaceId;
@override@JsonKey(name: 'terminal_title_stripped') final  String title;
@override@JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown) final  AgentStatus agentStatus;
@override@JsonKey() final  bool focused;
@override@JsonKey() final  String cwd;
@override@JsonKey(name: 'foreground_cwd') final  String foregroundCwd;

/// Create a copy of Pane
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$PaneCopyWith<_Pane> get copyWith => __$PaneCopyWithImpl<_Pane>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$PaneToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _Pane&&(identical(other.paneId, paneId) || other.paneId == paneId)&&(identical(other.tabId, tabId) || other.tabId == tabId)&&(identical(other.workspaceId, workspaceId) || other.workspaceId == workspaceId)&&(identical(other.title, title) || other.title == title)&&(identical(other.agentStatus, agentStatus) || other.agentStatus == agentStatus)&&(identical(other.focused, focused) || other.focused == focused)&&(identical(other.cwd, cwd) || other.cwd == cwd)&&(identical(other.foregroundCwd, foregroundCwd) || other.foregroundCwd == foregroundCwd));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,paneId,tabId,workspaceId,title,agentStatus,focused,cwd,foregroundCwd);

@override
String toString() {
  return 'Pane(paneId: $paneId, tabId: $tabId, workspaceId: $workspaceId, title: $title, agentStatus: $agentStatus, focused: $focused, cwd: $cwd, foregroundCwd: $foregroundCwd)';
}


}

/// @nodoc
abstract mixin class _$PaneCopyWith<$Res> implements $PaneCopyWith<$Res> {
  factory _$PaneCopyWith(_Pane value, $Res Function(_Pane) _then) = __$PaneCopyWithImpl;
@override @useResult
$Res call({
@JsonKey(name: 'pane_id') String paneId,@JsonKey(name: 'tab_id') String tabId,@JsonKey(name: 'workspace_id') String workspaceId,@JsonKey(name: 'terminal_title_stripped') String title,@JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown) AgentStatus agentStatus, bool focused, String cwd,@JsonKey(name: 'foreground_cwd') String foregroundCwd
});




}
/// @nodoc
class __$PaneCopyWithImpl<$Res>
    implements _$PaneCopyWith<$Res> {
  __$PaneCopyWithImpl(this._self, this._then);

  final _Pane _self;
  final $Res Function(_Pane) _then;

/// Create a copy of Pane
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? paneId = null,Object? tabId = null,Object? workspaceId = null,Object? title = null,Object? agentStatus = null,Object? focused = null,Object? cwd = null,Object? foregroundCwd = null,}) {
  return _then(_Pane(
paneId: null == paneId ? _self.paneId : paneId // ignore: cast_nullable_to_non_nullable
as String,tabId: null == tabId ? _self.tabId : tabId // ignore: cast_nullable_to_non_nullable
as String,workspaceId: null == workspaceId ? _self.workspaceId : workspaceId // ignore: cast_nullable_to_non_nullable
as String,title: null == title ? _self.title : title // ignore: cast_nullable_to_non_nullable
as String,agentStatus: null == agentStatus ? _self.agentStatus : agentStatus // ignore: cast_nullable_to_non_nullable
as AgentStatus,focused: null == focused ? _self.focused : focused // ignore: cast_nullable_to_non_nullable
as bool,cwd: null == cwd ? _self.cwd : cwd // ignore: cast_nullable_to_non_nullable
as String,foregroundCwd: null == foregroundCwd ? _self.foregroundCwd : foregroundCwd // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}


/// @nodoc
mixin _$TabInfo {

@JsonKey(name: 'tab_id') String get tabId;@JsonKey(name: 'workspace_id') String get workspaceId; String get label; int get number;@JsonKey(name: 'pane_count') int get paneCount; bool get focused;
/// Create a copy of TabInfo
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$TabInfoCopyWith<TabInfo> get copyWith => _$TabInfoCopyWithImpl<TabInfo>(this as TabInfo, _$identity);

  /// Serializes this TabInfo to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is TabInfo&&(identical(other.tabId, tabId) || other.tabId == tabId)&&(identical(other.workspaceId, workspaceId) || other.workspaceId == workspaceId)&&(identical(other.label, label) || other.label == label)&&(identical(other.number, number) || other.number == number)&&(identical(other.paneCount, paneCount) || other.paneCount == paneCount)&&(identical(other.focused, focused) || other.focused == focused));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,tabId,workspaceId,label,number,paneCount,focused);

@override
String toString() {
  return 'TabInfo(tabId: $tabId, workspaceId: $workspaceId, label: $label, number: $number, paneCount: $paneCount, focused: $focused)';
}


}

/// @nodoc
abstract mixin class $TabInfoCopyWith<$Res>  {
  factory $TabInfoCopyWith(TabInfo value, $Res Function(TabInfo) _then) = _$TabInfoCopyWithImpl;
@useResult
$Res call({
@JsonKey(name: 'tab_id') String tabId,@JsonKey(name: 'workspace_id') String workspaceId, String label, int number,@JsonKey(name: 'pane_count') int paneCount, bool focused
});




}
/// @nodoc
class _$TabInfoCopyWithImpl<$Res>
    implements $TabInfoCopyWith<$Res> {
  _$TabInfoCopyWithImpl(this._self, this._then);

  final TabInfo _self;
  final $Res Function(TabInfo) _then;

/// Create a copy of TabInfo
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? tabId = null,Object? workspaceId = null,Object? label = null,Object? number = null,Object? paneCount = null,Object? focused = null,}) {
  return _then(_self.copyWith(
tabId: null == tabId ? _self.tabId : tabId // ignore: cast_nullable_to_non_nullable
as String,workspaceId: null == workspaceId ? _self.workspaceId : workspaceId // ignore: cast_nullable_to_non_nullable
as String,label: null == label ? _self.label : label // ignore: cast_nullable_to_non_nullable
as String,number: null == number ? _self.number : number // ignore: cast_nullable_to_non_nullable
as int,paneCount: null == paneCount ? _self.paneCount : paneCount // ignore: cast_nullable_to_non_nullable
as int,focused: null == focused ? _self.focused : focused // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}

}


/// Adds pattern-matching-related methods to [TabInfo].
extension TabInfoPatterns on TabInfo {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _TabInfo value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _TabInfo() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _TabInfo value)  $default,){
final _that = this;
switch (_that) {
case _TabInfo():
return $default(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _TabInfo value)?  $default,){
final _that = this;
switch (_that) {
case _TabInfo() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function(@JsonKey(name: 'tab_id')  String tabId, @JsonKey(name: 'workspace_id')  String workspaceId,  String label,  int number, @JsonKey(name: 'pane_count')  int paneCount,  bool focused)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _TabInfo() when $default != null:
return $default(_that.tabId,_that.workspaceId,_that.label,_that.number,_that.paneCount,_that.focused);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function(@JsonKey(name: 'tab_id')  String tabId, @JsonKey(name: 'workspace_id')  String workspaceId,  String label,  int number, @JsonKey(name: 'pane_count')  int paneCount,  bool focused)  $default,) {final _that = this;
switch (_that) {
case _TabInfo():
return $default(_that.tabId,_that.workspaceId,_that.label,_that.number,_that.paneCount,_that.focused);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function(@JsonKey(name: 'tab_id')  String tabId, @JsonKey(name: 'workspace_id')  String workspaceId,  String label,  int number, @JsonKey(name: 'pane_count')  int paneCount,  bool focused)?  $default,) {final _that = this;
switch (_that) {
case _TabInfo() when $default != null:
return $default(_that.tabId,_that.workspaceId,_that.label,_that.number,_that.paneCount,_that.focused);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _TabInfo implements TabInfo {
  const _TabInfo({@JsonKey(name: 'tab_id') this.tabId = '', @JsonKey(name: 'workspace_id') this.workspaceId = '', this.label = '', this.number = 0, @JsonKey(name: 'pane_count') this.paneCount = 0, this.focused = false});
  factory _TabInfo.fromJson(Map<String, dynamic> json) => _$TabInfoFromJson(json);

@override@JsonKey(name: 'tab_id') final  String tabId;
@override@JsonKey(name: 'workspace_id') final  String workspaceId;
@override@JsonKey() final  String label;
@override@JsonKey() final  int number;
@override@JsonKey(name: 'pane_count') final  int paneCount;
@override@JsonKey() final  bool focused;

/// Create a copy of TabInfo
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$TabInfoCopyWith<_TabInfo> get copyWith => __$TabInfoCopyWithImpl<_TabInfo>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$TabInfoToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _TabInfo&&(identical(other.tabId, tabId) || other.tabId == tabId)&&(identical(other.workspaceId, workspaceId) || other.workspaceId == workspaceId)&&(identical(other.label, label) || other.label == label)&&(identical(other.number, number) || other.number == number)&&(identical(other.paneCount, paneCount) || other.paneCount == paneCount)&&(identical(other.focused, focused) || other.focused == focused));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,tabId,workspaceId,label,number,paneCount,focused);

@override
String toString() {
  return 'TabInfo(tabId: $tabId, workspaceId: $workspaceId, label: $label, number: $number, paneCount: $paneCount, focused: $focused)';
}


}

/// @nodoc
abstract mixin class _$TabInfoCopyWith<$Res> implements $TabInfoCopyWith<$Res> {
  factory _$TabInfoCopyWith(_TabInfo value, $Res Function(_TabInfo) _then) = __$TabInfoCopyWithImpl;
@override @useResult
$Res call({
@JsonKey(name: 'tab_id') String tabId,@JsonKey(name: 'workspace_id') String workspaceId, String label, int number,@JsonKey(name: 'pane_count') int paneCount, bool focused
});




}
/// @nodoc
class __$TabInfoCopyWithImpl<$Res>
    implements _$TabInfoCopyWith<$Res> {
  __$TabInfoCopyWithImpl(this._self, this._then);

  final _TabInfo _self;
  final $Res Function(_TabInfo) _then;

/// Create a copy of TabInfo
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? tabId = null,Object? workspaceId = null,Object? label = null,Object? number = null,Object? paneCount = null,Object? focused = null,}) {
  return _then(_TabInfo(
tabId: null == tabId ? _self.tabId : tabId // ignore: cast_nullable_to_non_nullable
as String,workspaceId: null == workspaceId ? _self.workspaceId : workspaceId // ignore: cast_nullable_to_non_nullable
as String,label: null == label ? _self.label : label // ignore: cast_nullable_to_non_nullable
as String,number: null == number ? _self.number : number // ignore: cast_nullable_to_non_nullable
as int,paneCount: null == paneCount ? _self.paneCount : paneCount // ignore: cast_nullable_to_non_nullable
as int,focused: null == focused ? _self.focused : focused // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}


/// @nodoc
mixin _$WorktreeInfo {

/// The space's own directory — the ONLY authoritative answer to "where does
/// this space live". Individual panes wander into subdirectories and linked
/// worktrees, so no pane's cwd can stand in for it.
@JsonKey(name: 'checkout_path') String get checkoutPath;@JsonKey(name: 'repo_name') String get repoName;@JsonKey(name: 'is_linked_worktree') bool get isLinkedWorktree;
/// Create a copy of WorktreeInfo
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$WorktreeInfoCopyWith<WorktreeInfo> get copyWith => _$WorktreeInfoCopyWithImpl<WorktreeInfo>(this as WorktreeInfo, _$identity);

  /// Serializes this WorktreeInfo to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is WorktreeInfo&&(identical(other.checkoutPath, checkoutPath) || other.checkoutPath == checkoutPath)&&(identical(other.repoName, repoName) || other.repoName == repoName)&&(identical(other.isLinkedWorktree, isLinkedWorktree) || other.isLinkedWorktree == isLinkedWorktree));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,checkoutPath,repoName,isLinkedWorktree);

@override
String toString() {
  return 'WorktreeInfo(checkoutPath: $checkoutPath, repoName: $repoName, isLinkedWorktree: $isLinkedWorktree)';
}


}

/// @nodoc
abstract mixin class $WorktreeInfoCopyWith<$Res>  {
  factory $WorktreeInfoCopyWith(WorktreeInfo value, $Res Function(WorktreeInfo) _then) = _$WorktreeInfoCopyWithImpl;
@useResult
$Res call({
@JsonKey(name: 'checkout_path') String checkoutPath,@JsonKey(name: 'repo_name') String repoName,@JsonKey(name: 'is_linked_worktree') bool isLinkedWorktree
});




}
/// @nodoc
class _$WorktreeInfoCopyWithImpl<$Res>
    implements $WorktreeInfoCopyWith<$Res> {
  _$WorktreeInfoCopyWithImpl(this._self, this._then);

  final WorktreeInfo _self;
  final $Res Function(WorktreeInfo) _then;

/// Create a copy of WorktreeInfo
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? checkoutPath = null,Object? repoName = null,Object? isLinkedWorktree = null,}) {
  return _then(_self.copyWith(
checkoutPath: null == checkoutPath ? _self.checkoutPath : checkoutPath // ignore: cast_nullable_to_non_nullable
as String,repoName: null == repoName ? _self.repoName : repoName // ignore: cast_nullable_to_non_nullable
as String,isLinkedWorktree: null == isLinkedWorktree ? _self.isLinkedWorktree : isLinkedWorktree // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}

}


/// Adds pattern-matching-related methods to [WorktreeInfo].
extension WorktreeInfoPatterns on WorktreeInfo {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _WorktreeInfo value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _WorktreeInfo() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _WorktreeInfo value)  $default,){
final _that = this;
switch (_that) {
case _WorktreeInfo():
return $default(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _WorktreeInfo value)?  $default,){
final _that = this;
switch (_that) {
case _WorktreeInfo() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function(@JsonKey(name: 'checkout_path')  String checkoutPath, @JsonKey(name: 'repo_name')  String repoName, @JsonKey(name: 'is_linked_worktree')  bool isLinkedWorktree)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _WorktreeInfo() when $default != null:
return $default(_that.checkoutPath,_that.repoName,_that.isLinkedWorktree);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function(@JsonKey(name: 'checkout_path')  String checkoutPath, @JsonKey(name: 'repo_name')  String repoName, @JsonKey(name: 'is_linked_worktree')  bool isLinkedWorktree)  $default,) {final _that = this;
switch (_that) {
case _WorktreeInfo():
return $default(_that.checkoutPath,_that.repoName,_that.isLinkedWorktree);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function(@JsonKey(name: 'checkout_path')  String checkoutPath, @JsonKey(name: 'repo_name')  String repoName, @JsonKey(name: 'is_linked_worktree')  bool isLinkedWorktree)?  $default,) {final _that = this;
switch (_that) {
case _WorktreeInfo() when $default != null:
return $default(_that.checkoutPath,_that.repoName,_that.isLinkedWorktree);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _WorktreeInfo implements WorktreeInfo {
  const _WorktreeInfo({@JsonKey(name: 'checkout_path') this.checkoutPath = '', @JsonKey(name: 'repo_name') this.repoName = '', @JsonKey(name: 'is_linked_worktree') this.isLinkedWorktree = false});
  factory _WorktreeInfo.fromJson(Map<String, dynamic> json) => _$WorktreeInfoFromJson(json);

/// The space's own directory — the ONLY authoritative answer to "where does
/// this space live". Individual panes wander into subdirectories and linked
/// worktrees, so no pane's cwd can stand in for it.
@override@JsonKey(name: 'checkout_path') final  String checkoutPath;
@override@JsonKey(name: 'repo_name') final  String repoName;
@override@JsonKey(name: 'is_linked_worktree') final  bool isLinkedWorktree;

/// Create a copy of WorktreeInfo
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$WorktreeInfoCopyWith<_WorktreeInfo> get copyWith => __$WorktreeInfoCopyWithImpl<_WorktreeInfo>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$WorktreeInfoToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _WorktreeInfo&&(identical(other.checkoutPath, checkoutPath) || other.checkoutPath == checkoutPath)&&(identical(other.repoName, repoName) || other.repoName == repoName)&&(identical(other.isLinkedWorktree, isLinkedWorktree) || other.isLinkedWorktree == isLinkedWorktree));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,checkoutPath,repoName,isLinkedWorktree);

@override
String toString() {
  return 'WorktreeInfo(checkoutPath: $checkoutPath, repoName: $repoName, isLinkedWorktree: $isLinkedWorktree)';
}


}

/// @nodoc
abstract mixin class _$WorktreeInfoCopyWith<$Res> implements $WorktreeInfoCopyWith<$Res> {
  factory _$WorktreeInfoCopyWith(_WorktreeInfo value, $Res Function(_WorktreeInfo) _then) = __$WorktreeInfoCopyWithImpl;
@override @useResult
$Res call({
@JsonKey(name: 'checkout_path') String checkoutPath,@JsonKey(name: 'repo_name') String repoName,@JsonKey(name: 'is_linked_worktree') bool isLinkedWorktree
});




}
/// @nodoc
class __$WorktreeInfoCopyWithImpl<$Res>
    implements _$WorktreeInfoCopyWith<$Res> {
  __$WorktreeInfoCopyWithImpl(this._self, this._then);

  final _WorktreeInfo _self;
  final $Res Function(_WorktreeInfo) _then;

/// Create a copy of WorktreeInfo
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? checkoutPath = null,Object? repoName = null,Object? isLinkedWorktree = null,}) {
  return _then(_WorktreeInfo(
checkoutPath: null == checkoutPath ? _self.checkoutPath : checkoutPath // ignore: cast_nullable_to_non_nullable
as String,repoName: null == repoName ? _self.repoName : repoName // ignore: cast_nullable_to_non_nullable
as String,isLinkedWorktree: null == isLinkedWorktree ? _self.isLinkedWorktree : isLinkedWorktree // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}


/// @nodoc
mixin _$WorkspaceInfo {

@JsonKey(name: 'workspace_id') String get workspaceId; String get label; int get number;@JsonKey(name: 'tab_count') int get tabCount;@JsonKey(name: 'pane_count') int get paneCount;@JsonKey(name: 'active_tab_id') String get activeTabId;@JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown) AgentStatus get agentStatus; bool get focused; WorktreeInfo? get worktree;
/// Create a copy of WorkspaceInfo
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$WorkspaceInfoCopyWith<WorkspaceInfo> get copyWith => _$WorkspaceInfoCopyWithImpl<WorkspaceInfo>(this as WorkspaceInfo, _$identity);

  /// Serializes this WorkspaceInfo to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is WorkspaceInfo&&(identical(other.workspaceId, workspaceId) || other.workspaceId == workspaceId)&&(identical(other.label, label) || other.label == label)&&(identical(other.number, number) || other.number == number)&&(identical(other.tabCount, tabCount) || other.tabCount == tabCount)&&(identical(other.paneCount, paneCount) || other.paneCount == paneCount)&&(identical(other.activeTabId, activeTabId) || other.activeTabId == activeTabId)&&(identical(other.agentStatus, agentStatus) || other.agentStatus == agentStatus)&&(identical(other.focused, focused) || other.focused == focused)&&(identical(other.worktree, worktree) || other.worktree == worktree));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,workspaceId,label,number,tabCount,paneCount,activeTabId,agentStatus,focused,worktree);

@override
String toString() {
  return 'WorkspaceInfo(workspaceId: $workspaceId, label: $label, number: $number, tabCount: $tabCount, paneCount: $paneCount, activeTabId: $activeTabId, agentStatus: $agentStatus, focused: $focused, worktree: $worktree)';
}


}

/// @nodoc
abstract mixin class $WorkspaceInfoCopyWith<$Res>  {
  factory $WorkspaceInfoCopyWith(WorkspaceInfo value, $Res Function(WorkspaceInfo) _then) = _$WorkspaceInfoCopyWithImpl;
@useResult
$Res call({
@JsonKey(name: 'workspace_id') String workspaceId, String label, int number,@JsonKey(name: 'tab_count') int tabCount,@JsonKey(name: 'pane_count') int paneCount,@JsonKey(name: 'active_tab_id') String activeTabId,@JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown) AgentStatus agentStatus, bool focused, WorktreeInfo? worktree
});


$WorktreeInfoCopyWith<$Res>? get worktree;

}
/// @nodoc
class _$WorkspaceInfoCopyWithImpl<$Res>
    implements $WorkspaceInfoCopyWith<$Res> {
  _$WorkspaceInfoCopyWithImpl(this._self, this._then);

  final WorkspaceInfo _self;
  final $Res Function(WorkspaceInfo) _then;

/// Create a copy of WorkspaceInfo
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? workspaceId = null,Object? label = null,Object? number = null,Object? tabCount = null,Object? paneCount = null,Object? activeTabId = null,Object? agentStatus = null,Object? focused = null,Object? worktree = freezed,}) {
  return _then(_self.copyWith(
workspaceId: null == workspaceId ? _self.workspaceId : workspaceId // ignore: cast_nullable_to_non_nullable
as String,label: null == label ? _self.label : label // ignore: cast_nullable_to_non_nullable
as String,number: null == number ? _self.number : number // ignore: cast_nullable_to_non_nullable
as int,tabCount: null == tabCount ? _self.tabCount : tabCount // ignore: cast_nullable_to_non_nullable
as int,paneCount: null == paneCount ? _self.paneCount : paneCount // ignore: cast_nullable_to_non_nullable
as int,activeTabId: null == activeTabId ? _self.activeTabId : activeTabId // ignore: cast_nullable_to_non_nullable
as String,agentStatus: null == agentStatus ? _self.agentStatus : agentStatus // ignore: cast_nullable_to_non_nullable
as AgentStatus,focused: null == focused ? _self.focused : focused // ignore: cast_nullable_to_non_nullable
as bool,worktree: freezed == worktree ? _self.worktree : worktree // ignore: cast_nullable_to_non_nullable
as WorktreeInfo?,
  ));
}
/// Create a copy of WorkspaceInfo
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$WorktreeInfoCopyWith<$Res>? get worktree {
    if (_self.worktree == null) {
    return null;
  }

  return $WorktreeInfoCopyWith<$Res>(_self.worktree!, (value) {
    return _then(_self.copyWith(worktree: value));
  });
}
}


/// Adds pattern-matching-related methods to [WorkspaceInfo].
extension WorkspaceInfoPatterns on WorkspaceInfo {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _WorkspaceInfo value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _WorkspaceInfo() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _WorkspaceInfo value)  $default,){
final _that = this;
switch (_that) {
case _WorkspaceInfo():
return $default(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _WorkspaceInfo value)?  $default,){
final _that = this;
switch (_that) {
case _WorkspaceInfo() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function(@JsonKey(name: 'workspace_id')  String workspaceId,  String label,  int number, @JsonKey(name: 'tab_count')  int tabCount, @JsonKey(name: 'pane_count')  int paneCount, @JsonKey(name: 'active_tab_id')  String activeTabId, @JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown)  AgentStatus agentStatus,  bool focused,  WorktreeInfo? worktree)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _WorkspaceInfo() when $default != null:
return $default(_that.workspaceId,_that.label,_that.number,_that.tabCount,_that.paneCount,_that.activeTabId,_that.agentStatus,_that.focused,_that.worktree);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function(@JsonKey(name: 'workspace_id')  String workspaceId,  String label,  int number, @JsonKey(name: 'tab_count')  int tabCount, @JsonKey(name: 'pane_count')  int paneCount, @JsonKey(name: 'active_tab_id')  String activeTabId, @JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown)  AgentStatus agentStatus,  bool focused,  WorktreeInfo? worktree)  $default,) {final _that = this;
switch (_that) {
case _WorkspaceInfo():
return $default(_that.workspaceId,_that.label,_that.number,_that.tabCount,_that.paneCount,_that.activeTabId,_that.agentStatus,_that.focused,_that.worktree);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function(@JsonKey(name: 'workspace_id')  String workspaceId,  String label,  int number, @JsonKey(name: 'tab_count')  int tabCount, @JsonKey(name: 'pane_count')  int paneCount, @JsonKey(name: 'active_tab_id')  String activeTabId, @JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown)  AgentStatus agentStatus,  bool focused,  WorktreeInfo? worktree)?  $default,) {final _that = this;
switch (_that) {
case _WorkspaceInfo() when $default != null:
return $default(_that.workspaceId,_that.label,_that.number,_that.tabCount,_that.paneCount,_that.activeTabId,_that.agentStatus,_that.focused,_that.worktree);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _WorkspaceInfo implements WorkspaceInfo {
  const _WorkspaceInfo({@JsonKey(name: 'workspace_id') this.workspaceId = '', this.label = '', this.number = 0, @JsonKey(name: 'tab_count') this.tabCount = 0, @JsonKey(name: 'pane_count') this.paneCount = 0, @JsonKey(name: 'active_tab_id') this.activeTabId = '', @JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown) this.agentStatus = AgentStatus.unknown, this.focused = false, this.worktree});
  factory _WorkspaceInfo.fromJson(Map<String, dynamic> json) => _$WorkspaceInfoFromJson(json);

@override@JsonKey(name: 'workspace_id') final  String workspaceId;
@override@JsonKey() final  String label;
@override@JsonKey() final  int number;
@override@JsonKey(name: 'tab_count') final  int tabCount;
@override@JsonKey(name: 'pane_count') final  int paneCount;
@override@JsonKey(name: 'active_tab_id') final  String activeTabId;
@override@JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown) final  AgentStatus agentStatus;
@override@JsonKey() final  bool focused;
@override final  WorktreeInfo? worktree;

/// Create a copy of WorkspaceInfo
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$WorkspaceInfoCopyWith<_WorkspaceInfo> get copyWith => __$WorkspaceInfoCopyWithImpl<_WorkspaceInfo>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$WorkspaceInfoToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _WorkspaceInfo&&(identical(other.workspaceId, workspaceId) || other.workspaceId == workspaceId)&&(identical(other.label, label) || other.label == label)&&(identical(other.number, number) || other.number == number)&&(identical(other.tabCount, tabCount) || other.tabCount == tabCount)&&(identical(other.paneCount, paneCount) || other.paneCount == paneCount)&&(identical(other.activeTabId, activeTabId) || other.activeTabId == activeTabId)&&(identical(other.agentStatus, agentStatus) || other.agentStatus == agentStatus)&&(identical(other.focused, focused) || other.focused == focused)&&(identical(other.worktree, worktree) || other.worktree == worktree));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,workspaceId,label,number,tabCount,paneCount,activeTabId,agentStatus,focused,worktree);

@override
String toString() {
  return 'WorkspaceInfo(workspaceId: $workspaceId, label: $label, number: $number, tabCount: $tabCount, paneCount: $paneCount, activeTabId: $activeTabId, agentStatus: $agentStatus, focused: $focused, worktree: $worktree)';
}


}

/// @nodoc
abstract mixin class _$WorkspaceInfoCopyWith<$Res> implements $WorkspaceInfoCopyWith<$Res> {
  factory _$WorkspaceInfoCopyWith(_WorkspaceInfo value, $Res Function(_WorkspaceInfo) _then) = __$WorkspaceInfoCopyWithImpl;
@override @useResult
$Res call({
@JsonKey(name: 'workspace_id') String workspaceId, String label, int number,@JsonKey(name: 'tab_count') int tabCount,@JsonKey(name: 'pane_count') int paneCount,@JsonKey(name: 'active_tab_id') String activeTabId,@JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown) AgentStatus agentStatus, bool focused, WorktreeInfo? worktree
});


@override $WorktreeInfoCopyWith<$Res>? get worktree;

}
/// @nodoc
class __$WorkspaceInfoCopyWithImpl<$Res>
    implements _$WorkspaceInfoCopyWith<$Res> {
  __$WorkspaceInfoCopyWithImpl(this._self, this._then);

  final _WorkspaceInfo _self;
  final $Res Function(_WorkspaceInfo) _then;

/// Create a copy of WorkspaceInfo
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? workspaceId = null,Object? label = null,Object? number = null,Object? tabCount = null,Object? paneCount = null,Object? activeTabId = null,Object? agentStatus = null,Object? focused = null,Object? worktree = freezed,}) {
  return _then(_WorkspaceInfo(
workspaceId: null == workspaceId ? _self.workspaceId : workspaceId // ignore: cast_nullable_to_non_nullable
as String,label: null == label ? _self.label : label // ignore: cast_nullable_to_non_nullable
as String,number: null == number ? _self.number : number // ignore: cast_nullable_to_non_nullable
as int,tabCount: null == tabCount ? _self.tabCount : tabCount // ignore: cast_nullable_to_non_nullable
as int,paneCount: null == paneCount ? _self.paneCount : paneCount // ignore: cast_nullable_to_non_nullable
as int,activeTabId: null == activeTabId ? _self.activeTabId : activeTabId // ignore: cast_nullable_to_non_nullable
as String,agentStatus: null == agentStatus ? _self.agentStatus : agentStatus // ignore: cast_nullable_to_non_nullable
as AgentStatus,focused: null == focused ? _self.focused : focused // ignore: cast_nullable_to_non_nullable
as bool,worktree: freezed == worktree ? _self.worktree : worktree // ignore: cast_nullable_to_non_nullable
as WorktreeInfo?,
  ));
}

/// Create a copy of WorkspaceInfo
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$WorktreeInfoCopyWith<$Res>? get worktree {
    if (_self.worktree == null) {
    return null;
  }

  return $WorktreeInfoCopyWith<$Res>(_self.worktree!, (value) {
    return _then(_self.copyWith(worktree: value));
  });
}
}


/// @nodoc
mixin _$Snapshot {

 List<Agent> get agents; List<Pane> get panes; List<TabInfo> get tabs; List<WorkspaceInfo> get workspaces;@JsonKey(name: 'focused_pane_id') String get focusedPaneId;/// Every Herdr session the bridge merged this snapshot from, default first
/// (see D14). It is the only place the app can learn a session exists when
/// that session has nothing in it — pane and workspace ids only name a
/// session once there is something to name — which is exactly the case the
/// "open a space" flow has to target. Empty on a bridge that predates the
/// field; treat that as the single default session.
 List<String> get sessions;
/// Create a copy of Snapshot
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SnapshotCopyWith<Snapshot> get copyWith => _$SnapshotCopyWithImpl<Snapshot>(this as Snapshot, _$identity);

  /// Serializes this Snapshot to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Snapshot&&const DeepCollectionEquality().equals(other.agents, agents)&&const DeepCollectionEquality().equals(other.panes, panes)&&const DeepCollectionEquality().equals(other.tabs, tabs)&&const DeepCollectionEquality().equals(other.workspaces, workspaces)&&(identical(other.focusedPaneId, focusedPaneId) || other.focusedPaneId == focusedPaneId)&&const DeepCollectionEquality().equals(other.sessions, sessions));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(agents),const DeepCollectionEquality().hash(panes),const DeepCollectionEquality().hash(tabs),const DeepCollectionEquality().hash(workspaces),focusedPaneId,const DeepCollectionEquality().hash(sessions));

@override
String toString() {
  return 'Snapshot(agents: $agents, panes: $panes, tabs: $tabs, workspaces: $workspaces, focusedPaneId: $focusedPaneId, sessions: $sessions)';
}


}

/// @nodoc
abstract mixin class $SnapshotCopyWith<$Res>  {
  factory $SnapshotCopyWith(Snapshot value, $Res Function(Snapshot) _then) = _$SnapshotCopyWithImpl;
@useResult
$Res call({
 List<Agent> agents, List<Pane> panes, List<TabInfo> tabs, List<WorkspaceInfo> workspaces,@JsonKey(name: 'focused_pane_id') String focusedPaneId, List<String> sessions
});




}
/// @nodoc
class _$SnapshotCopyWithImpl<$Res>
    implements $SnapshotCopyWith<$Res> {
  _$SnapshotCopyWithImpl(this._self, this._then);

  final Snapshot _self;
  final $Res Function(Snapshot) _then;

/// Create a copy of Snapshot
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? agents = null,Object? panes = null,Object? tabs = null,Object? workspaces = null,Object? focusedPaneId = null,Object? sessions = null,}) {
  return _then(_self.copyWith(
agents: null == agents ? _self.agents : agents // ignore: cast_nullable_to_non_nullable
as List<Agent>,panes: null == panes ? _self.panes : panes // ignore: cast_nullable_to_non_nullable
as List<Pane>,tabs: null == tabs ? _self.tabs : tabs // ignore: cast_nullable_to_non_nullable
as List<TabInfo>,workspaces: null == workspaces ? _self.workspaces : workspaces // ignore: cast_nullable_to_non_nullable
as List<WorkspaceInfo>,focusedPaneId: null == focusedPaneId ? _self.focusedPaneId : focusedPaneId // ignore: cast_nullable_to_non_nullable
as String,sessions: null == sessions ? _self.sessions : sessions // ignore: cast_nullable_to_non_nullable
as List<String>,
  ));
}

}


/// Adds pattern-matching-related methods to [Snapshot].
extension SnapshotPatterns on Snapshot {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _Snapshot value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _Snapshot() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _Snapshot value)  $default,){
final _that = this;
switch (_that) {
case _Snapshot():
return $default(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _Snapshot value)?  $default,){
final _that = this;
switch (_that) {
case _Snapshot() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( List<Agent> agents,  List<Pane> panes,  List<TabInfo> tabs,  List<WorkspaceInfo> workspaces, @JsonKey(name: 'focused_pane_id')  String focusedPaneId,  List<String> sessions)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Snapshot() when $default != null:
return $default(_that.agents,_that.panes,_that.tabs,_that.workspaces,_that.focusedPaneId,_that.sessions);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( List<Agent> agents,  List<Pane> panes,  List<TabInfo> tabs,  List<WorkspaceInfo> workspaces, @JsonKey(name: 'focused_pane_id')  String focusedPaneId,  List<String> sessions)  $default,) {final _that = this;
switch (_that) {
case _Snapshot():
return $default(_that.agents,_that.panes,_that.tabs,_that.workspaces,_that.focusedPaneId,_that.sessions);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( List<Agent> agents,  List<Pane> panes,  List<TabInfo> tabs,  List<WorkspaceInfo> workspaces, @JsonKey(name: 'focused_pane_id')  String focusedPaneId,  List<String> sessions)?  $default,) {final _that = this;
switch (_that) {
case _Snapshot() when $default != null:
return $default(_that.agents,_that.panes,_that.tabs,_that.workspaces,_that.focusedPaneId,_that.sessions);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _Snapshot extends Snapshot {
  const _Snapshot({final  List<Agent> agents = const <Agent>[], final  List<Pane> panes = const <Pane>[], final  List<TabInfo> tabs = const <TabInfo>[], final  List<WorkspaceInfo> workspaces = const <WorkspaceInfo>[], @JsonKey(name: 'focused_pane_id') this.focusedPaneId = '', final  List<String> sessions = const <String>[]}): _agents = agents,_panes = panes,_tabs = tabs,_workspaces = workspaces,_sessions = sessions,super._();
  factory _Snapshot.fromJson(Map<String, dynamic> json) => _$SnapshotFromJson(json);

 final  List<Agent> _agents;
@override@JsonKey() List<Agent> get agents {
  if (_agents is EqualUnmodifiableListView) return _agents;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_agents);
}

 final  List<Pane> _panes;
@override@JsonKey() List<Pane> get panes {
  if (_panes is EqualUnmodifiableListView) return _panes;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_panes);
}

 final  List<TabInfo> _tabs;
@override@JsonKey() List<TabInfo> get tabs {
  if (_tabs is EqualUnmodifiableListView) return _tabs;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_tabs);
}

 final  List<WorkspaceInfo> _workspaces;
@override@JsonKey() List<WorkspaceInfo> get workspaces {
  if (_workspaces is EqualUnmodifiableListView) return _workspaces;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_workspaces);
}

@override@JsonKey(name: 'focused_pane_id') final  String focusedPaneId;
/// Every Herdr session the bridge merged this snapshot from, default first
/// (see D14). It is the only place the app can learn a session exists when
/// that session has nothing in it — pane and workspace ids only name a
/// session once there is something to name — which is exactly the case the
/// "open a space" flow has to target. Empty on a bridge that predates the
/// field; treat that as the single default session.
 final  List<String> _sessions;
/// Every Herdr session the bridge merged this snapshot from, default first
/// (see D14). It is the only place the app can learn a session exists when
/// that session has nothing in it — pane and workspace ids only name a
/// session once there is something to name — which is exactly the case the
/// "open a space" flow has to target. Empty on a bridge that predates the
/// field; treat that as the single default session.
@override@JsonKey() List<String> get sessions {
  if (_sessions is EqualUnmodifiableListView) return _sessions;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_sessions);
}


/// Create a copy of Snapshot
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$SnapshotCopyWith<_Snapshot> get copyWith => __$SnapshotCopyWithImpl<_Snapshot>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$SnapshotToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _Snapshot&&const DeepCollectionEquality().equals(other._agents, _agents)&&const DeepCollectionEquality().equals(other._panes, _panes)&&const DeepCollectionEquality().equals(other._tabs, _tabs)&&const DeepCollectionEquality().equals(other._workspaces, _workspaces)&&(identical(other.focusedPaneId, focusedPaneId) || other.focusedPaneId == focusedPaneId)&&const DeepCollectionEquality().equals(other._sessions, _sessions));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(_agents),const DeepCollectionEquality().hash(_panes),const DeepCollectionEquality().hash(_tabs),const DeepCollectionEquality().hash(_workspaces),focusedPaneId,const DeepCollectionEquality().hash(_sessions));

@override
String toString() {
  return 'Snapshot(agents: $agents, panes: $panes, tabs: $tabs, workspaces: $workspaces, focusedPaneId: $focusedPaneId, sessions: $sessions)';
}


}

/// @nodoc
abstract mixin class _$SnapshotCopyWith<$Res> implements $SnapshotCopyWith<$Res> {
  factory _$SnapshotCopyWith(_Snapshot value, $Res Function(_Snapshot) _then) = __$SnapshotCopyWithImpl;
@override @useResult
$Res call({
 List<Agent> agents, List<Pane> panes, List<TabInfo> tabs, List<WorkspaceInfo> workspaces,@JsonKey(name: 'focused_pane_id') String focusedPaneId, List<String> sessions
});




}
/// @nodoc
class __$SnapshotCopyWithImpl<$Res>
    implements _$SnapshotCopyWith<$Res> {
  __$SnapshotCopyWithImpl(this._self, this._then);

  final _Snapshot _self;
  final $Res Function(_Snapshot) _then;

/// Create a copy of Snapshot
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? agents = null,Object? panes = null,Object? tabs = null,Object? workspaces = null,Object? focusedPaneId = null,Object? sessions = null,}) {
  return _then(_Snapshot(
agents: null == agents ? _self._agents : agents // ignore: cast_nullable_to_non_nullable
as List<Agent>,panes: null == panes ? _self._panes : panes // ignore: cast_nullable_to_non_nullable
as List<Pane>,tabs: null == tabs ? _self._tabs : tabs // ignore: cast_nullable_to_non_nullable
as List<TabInfo>,workspaces: null == workspaces ? _self._workspaces : workspaces // ignore: cast_nullable_to_non_nullable
as List<WorkspaceInfo>,focusedPaneId: null == focusedPaneId ? _self.focusedPaneId : focusedPaneId // ignore: cast_nullable_to_non_nullable
as String,sessions: null == sessions ? _self._sessions : sessions // ignore: cast_nullable_to_non_nullable
as List<String>,
  ));
}


}

// dart format on
