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

 String get agent;@JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown) AgentStatus get agentStatus;@JsonKey(name: 'pane_id') String get paneId;@JsonKey(name: 'terminal_title_stripped') String get title;@JsonKey(name: 'workspace_id') String get workspaceId; String get cwd; bool get focused;@JsonKey(name: 'agent_session') AgentSession? get session;/// Herdr's monotonic sequence for this agent's state. Backs idempotent
/// approvals (D8): an approve tap carries this seq and the bridge no-ops if
/// the agent is no longer blocked at it.
@JsonKey(name: 'state_change_seq') int? get stateChangeSeq;
/// Create a copy of Agent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AgentCopyWith<Agent> get copyWith => _$AgentCopyWithImpl<Agent>(this as Agent, _$identity);

  /// Serializes this Agent to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Agent&&(identical(other.agent, agent) || other.agent == agent)&&(identical(other.agentStatus, agentStatus) || other.agentStatus == agentStatus)&&(identical(other.paneId, paneId) || other.paneId == paneId)&&(identical(other.title, title) || other.title == title)&&(identical(other.workspaceId, workspaceId) || other.workspaceId == workspaceId)&&(identical(other.cwd, cwd) || other.cwd == cwd)&&(identical(other.focused, focused) || other.focused == focused)&&(identical(other.session, session) || other.session == session)&&(identical(other.stateChangeSeq, stateChangeSeq) || other.stateChangeSeq == stateChangeSeq));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,agent,agentStatus,paneId,title,workspaceId,cwd,focused,session,stateChangeSeq);

@override
String toString() {
  return 'Agent(agent: $agent, agentStatus: $agentStatus, paneId: $paneId, title: $title, workspaceId: $workspaceId, cwd: $cwd, focused: $focused, session: $session, stateChangeSeq: $stateChangeSeq)';
}


}

/// @nodoc
abstract mixin class $AgentCopyWith<$Res>  {
  factory $AgentCopyWith(Agent value, $Res Function(Agent) _then) = _$AgentCopyWithImpl;
@useResult
$Res call({
 String agent,@JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown) AgentStatus agentStatus,@JsonKey(name: 'pane_id') String paneId,@JsonKey(name: 'terminal_title_stripped') String title,@JsonKey(name: 'workspace_id') String workspaceId, String cwd, bool focused,@JsonKey(name: 'agent_session') AgentSession? session,@JsonKey(name: 'state_change_seq') int? stateChangeSeq
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
@pragma('vm:prefer-inline') @override $Res call({Object? agent = null,Object? agentStatus = null,Object? paneId = null,Object? title = null,Object? workspaceId = null,Object? cwd = null,Object? focused = null,Object? session = freezed,Object? stateChangeSeq = freezed,}) {
  return _then(_self.copyWith(
agent: null == agent ? _self.agent : agent // ignore: cast_nullable_to_non_nullable
as String,agentStatus: null == agentStatus ? _self.agentStatus : agentStatus // ignore: cast_nullable_to_non_nullable
as AgentStatus,paneId: null == paneId ? _self.paneId : paneId // ignore: cast_nullable_to_non_nullable
as String,title: null == title ? _self.title : title // ignore: cast_nullable_to_non_nullable
as String,workspaceId: null == workspaceId ? _self.workspaceId : workspaceId // ignore: cast_nullable_to_non_nullable
as String,cwd: null == cwd ? _self.cwd : cwd // ignore: cast_nullable_to_non_nullable
as String,focused: null == focused ? _self.focused : focused // ignore: cast_nullable_to_non_nullable
as bool,session: freezed == session ? _self.session : session // ignore: cast_nullable_to_non_nullable
as AgentSession?,stateChangeSeq: freezed == stateChangeSeq ? _self.stateChangeSeq : stateChangeSeq // ignore: cast_nullable_to_non_nullable
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String agent, @JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown)  AgentStatus agentStatus, @JsonKey(name: 'pane_id')  String paneId, @JsonKey(name: 'terminal_title_stripped')  String title, @JsonKey(name: 'workspace_id')  String workspaceId,  String cwd,  bool focused, @JsonKey(name: 'agent_session')  AgentSession? session, @JsonKey(name: 'state_change_seq')  int? stateChangeSeq)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Agent() when $default != null:
return $default(_that.agent,_that.agentStatus,_that.paneId,_that.title,_that.workspaceId,_that.cwd,_that.focused,_that.session,_that.stateChangeSeq);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String agent, @JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown)  AgentStatus agentStatus, @JsonKey(name: 'pane_id')  String paneId, @JsonKey(name: 'terminal_title_stripped')  String title, @JsonKey(name: 'workspace_id')  String workspaceId,  String cwd,  bool focused, @JsonKey(name: 'agent_session')  AgentSession? session, @JsonKey(name: 'state_change_seq')  int? stateChangeSeq)  $default,) {final _that = this;
switch (_that) {
case _Agent():
return $default(_that.agent,_that.agentStatus,_that.paneId,_that.title,_that.workspaceId,_that.cwd,_that.focused,_that.session,_that.stateChangeSeq);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String agent, @JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown)  AgentStatus agentStatus, @JsonKey(name: 'pane_id')  String paneId, @JsonKey(name: 'terminal_title_stripped')  String title, @JsonKey(name: 'workspace_id')  String workspaceId,  String cwd,  bool focused, @JsonKey(name: 'agent_session')  AgentSession? session, @JsonKey(name: 'state_change_seq')  int? stateChangeSeq)?  $default,) {final _that = this;
switch (_that) {
case _Agent() when $default != null:
return $default(_that.agent,_that.agentStatus,_that.paneId,_that.title,_that.workspaceId,_that.cwd,_that.focused,_that.session,_that.stateChangeSeq);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _Agent extends Agent {
  const _Agent({this.agent = '', @JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown) this.agentStatus = AgentStatus.unknown, @JsonKey(name: 'pane_id') this.paneId = '', @JsonKey(name: 'terminal_title_stripped') this.title = '', @JsonKey(name: 'workspace_id') this.workspaceId = '', this.cwd = '', this.focused = false, @JsonKey(name: 'agent_session') this.session, @JsonKey(name: 'state_change_seq') this.stateChangeSeq}): super._();
  factory _Agent.fromJson(Map<String, dynamic> json) => _$AgentFromJson(json);

@override@JsonKey() final  String agent;
@override@JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown) final  AgentStatus agentStatus;
@override@JsonKey(name: 'pane_id') final  String paneId;
@override@JsonKey(name: 'terminal_title_stripped') final  String title;
@override@JsonKey(name: 'workspace_id') final  String workspaceId;
@override@JsonKey() final  String cwd;
@override@JsonKey() final  bool focused;
@override@JsonKey(name: 'agent_session') final  AgentSession? session;
/// Herdr's monotonic sequence for this agent's state. Backs idempotent
/// approvals (D8): an approve tap carries this seq and the bridge no-ops if
/// the agent is no longer blocked at it.
@override@JsonKey(name: 'state_change_seq') final  int? stateChangeSeq;

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
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _Agent&&(identical(other.agent, agent) || other.agent == agent)&&(identical(other.agentStatus, agentStatus) || other.agentStatus == agentStatus)&&(identical(other.paneId, paneId) || other.paneId == paneId)&&(identical(other.title, title) || other.title == title)&&(identical(other.workspaceId, workspaceId) || other.workspaceId == workspaceId)&&(identical(other.cwd, cwd) || other.cwd == cwd)&&(identical(other.focused, focused) || other.focused == focused)&&(identical(other.session, session) || other.session == session)&&(identical(other.stateChangeSeq, stateChangeSeq) || other.stateChangeSeq == stateChangeSeq));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,agent,agentStatus,paneId,title,workspaceId,cwd,focused,session,stateChangeSeq);

@override
String toString() {
  return 'Agent(agent: $agent, agentStatus: $agentStatus, paneId: $paneId, title: $title, workspaceId: $workspaceId, cwd: $cwd, focused: $focused, session: $session, stateChangeSeq: $stateChangeSeq)';
}


}

/// @nodoc
abstract mixin class _$AgentCopyWith<$Res> implements $AgentCopyWith<$Res> {
  factory _$AgentCopyWith(_Agent value, $Res Function(_Agent) _then) = __$AgentCopyWithImpl;
@override @useResult
$Res call({
 String agent,@JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown) AgentStatus agentStatus,@JsonKey(name: 'pane_id') String paneId,@JsonKey(name: 'terminal_title_stripped') String title,@JsonKey(name: 'workspace_id') String workspaceId, String cwd, bool focused,@JsonKey(name: 'agent_session') AgentSession? session,@JsonKey(name: 'state_change_seq') int? stateChangeSeq
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
@override @pragma('vm:prefer-inline') $Res call({Object? agent = null,Object? agentStatus = null,Object? paneId = null,Object? title = null,Object? workspaceId = null,Object? cwd = null,Object? focused = null,Object? session = freezed,Object? stateChangeSeq = freezed,}) {
  return _then(_Agent(
agent: null == agent ? _self.agent : agent // ignore: cast_nullable_to_non_nullable
as String,agentStatus: null == agentStatus ? _self.agentStatus : agentStatus // ignore: cast_nullable_to_non_nullable
as AgentStatus,paneId: null == paneId ? _self.paneId : paneId // ignore: cast_nullable_to_non_nullable
as String,title: null == title ? _self.title : title // ignore: cast_nullable_to_non_nullable
as String,workspaceId: null == workspaceId ? _self.workspaceId : workspaceId // ignore: cast_nullable_to_non_nullable
as String,cwd: null == cwd ? _self.cwd : cwd // ignore: cast_nullable_to_non_nullable
as String,focused: null == focused ? _self.focused : focused // ignore: cast_nullable_to_non_nullable
as bool,session: freezed == session ? _self.session : session // ignore: cast_nullable_to_non_nullable
as AgentSession?,stateChangeSeq: freezed == stateChangeSeq ? _self.stateChangeSeq : stateChangeSeq // ignore: cast_nullable_to_non_nullable
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
mixin _$Snapshot {

 List<Agent> get agents;
/// Create a copy of Snapshot
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SnapshotCopyWith<Snapshot> get copyWith => _$SnapshotCopyWithImpl<Snapshot>(this as Snapshot, _$identity);

  /// Serializes this Snapshot to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Snapshot&&const DeepCollectionEquality().equals(other.agents, agents));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(agents));

@override
String toString() {
  return 'Snapshot(agents: $agents)';
}


}

/// @nodoc
abstract mixin class $SnapshotCopyWith<$Res>  {
  factory $SnapshotCopyWith(Snapshot value, $Res Function(Snapshot) _then) = _$SnapshotCopyWithImpl;
@useResult
$Res call({
 List<Agent> agents
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
@pragma('vm:prefer-inline') @override $Res call({Object? agents = null,}) {
  return _then(_self.copyWith(
agents: null == agents ? _self.agents : agents // ignore: cast_nullable_to_non_nullable
as List<Agent>,
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( List<Agent> agents)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Snapshot() when $default != null:
return $default(_that.agents);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( List<Agent> agents)  $default,) {final _that = this;
switch (_that) {
case _Snapshot():
return $default(_that.agents);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( List<Agent> agents)?  $default,) {final _that = this;
switch (_that) {
case _Snapshot() when $default != null:
return $default(_that.agents);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _Snapshot extends Snapshot {
  const _Snapshot({final  List<Agent> agents = const <Agent>[]}): _agents = agents,super._();
  factory _Snapshot.fromJson(Map<String, dynamic> json) => _$SnapshotFromJson(json);

 final  List<Agent> _agents;
@override@JsonKey() List<Agent> get agents {
  if (_agents is EqualUnmodifiableListView) return _agents;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_agents);
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
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _Snapshot&&const DeepCollectionEquality().equals(other._agents, _agents));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(_agents));

@override
String toString() {
  return 'Snapshot(agents: $agents)';
}


}

/// @nodoc
abstract mixin class _$SnapshotCopyWith<$Res> implements $SnapshotCopyWith<$Res> {
  factory _$SnapshotCopyWith(_Snapshot value, $Res Function(_Snapshot) _then) = __$SnapshotCopyWithImpl;
@override @useResult
$Res call({
 List<Agent> agents
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
@override @pragma('vm:prefer-inline') $Res call({Object? agents = null,}) {
  return _then(_Snapshot(
agents: null == agents ? _self._agents : agents // ignore: cast_nullable_to_non_nullable
as List<Agent>,
  ));
}


}

// dart format on
