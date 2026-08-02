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

 String get agent;@JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown) AgentStatus get agentStatus;@JsonKey(name: 'pane_id') String get paneId;@JsonKey(name: 'terminal_title_stripped') String get title;@JsonKey(name: 'workspace_id') String get workspaceId;@JsonKey(name: 'tab_id') String get tabId; String get cwd; bool get focused;@JsonKey(name: 'agent_session') AgentSession? get session;/// Herdr's monotonic sequence for this agent's state. Backs idempotent
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
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Agent&&(identical(other.agent, agent) || other.agent == agent)&&(identical(other.agentStatus, agentStatus) || other.agentStatus == agentStatus)&&(identical(other.paneId, paneId) || other.paneId == paneId)&&(identical(other.title, title) || other.title == title)&&(identical(other.workspaceId, workspaceId) || other.workspaceId == workspaceId)&&(identical(other.tabId, tabId) || other.tabId == tabId)&&(identical(other.cwd, cwd) || other.cwd == cwd)&&(identical(other.focused, focused) || other.focused == focused)&&(identical(other.session, session) || other.session == session)&&(identical(other.stateChangeSeq, stateChangeSeq) || other.stateChangeSeq == stateChangeSeq));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,agent,agentStatus,paneId,title,workspaceId,tabId,cwd,focused,session,stateChangeSeq);

@override
String toString() {
  return 'Agent(agent: $agent, agentStatus: $agentStatus, paneId: $paneId, title: $title, workspaceId: $workspaceId, tabId: $tabId, cwd: $cwd, focused: $focused, session: $session, stateChangeSeq: $stateChangeSeq)';
}


}

/// @nodoc
abstract mixin class $AgentCopyWith<$Res>  {
  factory $AgentCopyWith(Agent value, $Res Function(Agent) _then) = _$AgentCopyWithImpl;
@useResult
$Res call({
 String agent,@JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown) AgentStatus agentStatus,@JsonKey(name: 'pane_id') String paneId,@JsonKey(name: 'terminal_title_stripped') String title,@JsonKey(name: 'workspace_id') String workspaceId,@JsonKey(name: 'tab_id') String tabId, String cwd, bool focused,@JsonKey(name: 'agent_session') AgentSession? session,@JsonKey(name: 'state_change_seq') int? stateChangeSeq
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
@pragma('vm:prefer-inline') @override $Res call({Object? agent = null,Object? agentStatus = null,Object? paneId = null,Object? title = null,Object? workspaceId = null,Object? tabId = null,Object? cwd = null,Object? focused = null,Object? session = freezed,Object? stateChangeSeq = freezed,}) {
  return _then(_self.copyWith(
agent: null == agent ? _self.agent : agent // ignore: cast_nullable_to_non_nullable
as String,agentStatus: null == agentStatus ? _self.agentStatus : agentStatus // ignore: cast_nullable_to_non_nullable
as AgentStatus,paneId: null == paneId ? _self.paneId : paneId // ignore: cast_nullable_to_non_nullable
as String,title: null == title ? _self.title : title // ignore: cast_nullable_to_non_nullable
as String,workspaceId: null == workspaceId ? _self.workspaceId : workspaceId // ignore: cast_nullable_to_non_nullable
as String,tabId: null == tabId ? _self.tabId : tabId // ignore: cast_nullable_to_non_nullable
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String agent, @JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown)  AgentStatus agentStatus, @JsonKey(name: 'pane_id')  String paneId, @JsonKey(name: 'terminal_title_stripped')  String title, @JsonKey(name: 'workspace_id')  String workspaceId, @JsonKey(name: 'tab_id')  String tabId,  String cwd,  bool focused, @JsonKey(name: 'agent_session')  AgentSession? session, @JsonKey(name: 'state_change_seq')  int? stateChangeSeq)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Agent() when $default != null:
return $default(_that.agent,_that.agentStatus,_that.paneId,_that.title,_that.workspaceId,_that.tabId,_that.cwd,_that.focused,_that.session,_that.stateChangeSeq);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String agent, @JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown)  AgentStatus agentStatus, @JsonKey(name: 'pane_id')  String paneId, @JsonKey(name: 'terminal_title_stripped')  String title, @JsonKey(name: 'workspace_id')  String workspaceId, @JsonKey(name: 'tab_id')  String tabId,  String cwd,  bool focused, @JsonKey(name: 'agent_session')  AgentSession? session, @JsonKey(name: 'state_change_seq')  int? stateChangeSeq)  $default,) {final _that = this;
switch (_that) {
case _Agent():
return $default(_that.agent,_that.agentStatus,_that.paneId,_that.title,_that.workspaceId,_that.tabId,_that.cwd,_that.focused,_that.session,_that.stateChangeSeq);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String agent, @JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown)  AgentStatus agentStatus, @JsonKey(name: 'pane_id')  String paneId, @JsonKey(name: 'terminal_title_stripped')  String title, @JsonKey(name: 'workspace_id')  String workspaceId, @JsonKey(name: 'tab_id')  String tabId,  String cwd,  bool focused, @JsonKey(name: 'agent_session')  AgentSession? session, @JsonKey(name: 'state_change_seq')  int? stateChangeSeq)?  $default,) {final _that = this;
switch (_that) {
case _Agent() when $default != null:
return $default(_that.agent,_that.agentStatus,_that.paneId,_that.title,_that.workspaceId,_that.tabId,_that.cwd,_that.focused,_that.session,_that.stateChangeSeq);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _Agent extends Agent {
  const _Agent({this.agent = '', @JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown) this.agentStatus = AgentStatus.unknown, @JsonKey(name: 'pane_id') this.paneId = '', @JsonKey(name: 'terminal_title_stripped') this.title = '', @JsonKey(name: 'workspace_id') this.workspaceId = '', @JsonKey(name: 'tab_id') this.tabId = '', this.cwd = '', this.focused = false, @JsonKey(name: 'agent_session') this.session, @JsonKey(name: 'state_change_seq') this.stateChangeSeq}): super._();
  factory _Agent.fromJson(Map<String, dynamic> json) => _$AgentFromJson(json);

@override@JsonKey() final  String agent;
@override@JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown) final  AgentStatus agentStatus;
@override@JsonKey(name: 'pane_id') final  String paneId;
@override@JsonKey(name: 'terminal_title_stripped') final  String title;
@override@JsonKey(name: 'workspace_id') final  String workspaceId;
@override@JsonKey(name: 'tab_id') final  String tabId;
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
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _Agent&&(identical(other.agent, agent) || other.agent == agent)&&(identical(other.agentStatus, agentStatus) || other.agentStatus == agentStatus)&&(identical(other.paneId, paneId) || other.paneId == paneId)&&(identical(other.title, title) || other.title == title)&&(identical(other.workspaceId, workspaceId) || other.workspaceId == workspaceId)&&(identical(other.tabId, tabId) || other.tabId == tabId)&&(identical(other.cwd, cwd) || other.cwd == cwd)&&(identical(other.focused, focused) || other.focused == focused)&&(identical(other.session, session) || other.session == session)&&(identical(other.stateChangeSeq, stateChangeSeq) || other.stateChangeSeq == stateChangeSeq));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,agent,agentStatus,paneId,title,workspaceId,tabId,cwd,focused,session,stateChangeSeq);

@override
String toString() {
  return 'Agent(agent: $agent, agentStatus: $agentStatus, paneId: $paneId, title: $title, workspaceId: $workspaceId, tabId: $tabId, cwd: $cwd, focused: $focused, session: $session, stateChangeSeq: $stateChangeSeq)';
}


}

/// @nodoc
abstract mixin class _$AgentCopyWith<$Res> implements $AgentCopyWith<$Res> {
  factory _$AgentCopyWith(_Agent value, $Res Function(_Agent) _then) = __$AgentCopyWithImpl;
@override @useResult
$Res call({
 String agent,@JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown) AgentStatus agentStatus,@JsonKey(name: 'pane_id') String paneId,@JsonKey(name: 'terminal_title_stripped') String title,@JsonKey(name: 'workspace_id') String workspaceId,@JsonKey(name: 'tab_id') String tabId, String cwd, bool focused,@JsonKey(name: 'agent_session') AgentSession? session,@JsonKey(name: 'state_change_seq') int? stateChangeSeq
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
@override @pragma('vm:prefer-inline') $Res call({Object? agent = null,Object? agentStatus = null,Object? paneId = null,Object? title = null,Object? workspaceId = null,Object? tabId = null,Object? cwd = null,Object? focused = null,Object? session = freezed,Object? stateChangeSeq = freezed,}) {
  return _then(_Agent(
agent: null == agent ? _self.agent : agent // ignore: cast_nullable_to_non_nullable
as String,agentStatus: null == agentStatus ? _self.agentStatus : agentStatus // ignore: cast_nullable_to_non_nullable
as AgentStatus,paneId: null == paneId ? _self.paneId : paneId // ignore: cast_nullable_to_non_nullable
as String,title: null == title ? _self.title : title // ignore: cast_nullable_to_non_nullable
as String,workspaceId: null == workspaceId ? _self.workspaceId : workspaceId // ignore: cast_nullable_to_non_nullable
as String,tabId: null == tabId ? _self.tabId : tabId // ignore: cast_nullable_to_non_nullable
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
mixin _$WorkspaceInfo {

@JsonKey(name: 'workspace_id') String get workspaceId; String get label; int get number;@JsonKey(name: 'tab_count') int get tabCount;@JsonKey(name: 'pane_count') int get paneCount;@JsonKey(name: 'active_tab_id') String get activeTabId;@JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown) AgentStatus get agentStatus; bool get focused;
/// Create a copy of WorkspaceInfo
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$WorkspaceInfoCopyWith<WorkspaceInfo> get copyWith => _$WorkspaceInfoCopyWithImpl<WorkspaceInfo>(this as WorkspaceInfo, _$identity);

  /// Serializes this WorkspaceInfo to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is WorkspaceInfo&&(identical(other.workspaceId, workspaceId) || other.workspaceId == workspaceId)&&(identical(other.label, label) || other.label == label)&&(identical(other.number, number) || other.number == number)&&(identical(other.tabCount, tabCount) || other.tabCount == tabCount)&&(identical(other.paneCount, paneCount) || other.paneCount == paneCount)&&(identical(other.activeTabId, activeTabId) || other.activeTabId == activeTabId)&&(identical(other.agentStatus, agentStatus) || other.agentStatus == agentStatus)&&(identical(other.focused, focused) || other.focused == focused));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,workspaceId,label,number,tabCount,paneCount,activeTabId,agentStatus,focused);

@override
String toString() {
  return 'WorkspaceInfo(workspaceId: $workspaceId, label: $label, number: $number, tabCount: $tabCount, paneCount: $paneCount, activeTabId: $activeTabId, agentStatus: $agentStatus, focused: $focused)';
}


}

/// @nodoc
abstract mixin class $WorkspaceInfoCopyWith<$Res>  {
  factory $WorkspaceInfoCopyWith(WorkspaceInfo value, $Res Function(WorkspaceInfo) _then) = _$WorkspaceInfoCopyWithImpl;
@useResult
$Res call({
@JsonKey(name: 'workspace_id') String workspaceId, String label, int number,@JsonKey(name: 'tab_count') int tabCount,@JsonKey(name: 'pane_count') int paneCount,@JsonKey(name: 'active_tab_id') String activeTabId,@JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown) AgentStatus agentStatus, bool focused
});




}
/// @nodoc
class _$WorkspaceInfoCopyWithImpl<$Res>
    implements $WorkspaceInfoCopyWith<$Res> {
  _$WorkspaceInfoCopyWithImpl(this._self, this._then);

  final WorkspaceInfo _self;
  final $Res Function(WorkspaceInfo) _then;

/// Create a copy of WorkspaceInfo
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? workspaceId = null,Object? label = null,Object? number = null,Object? tabCount = null,Object? paneCount = null,Object? activeTabId = null,Object? agentStatus = null,Object? focused = null,}) {
  return _then(_self.copyWith(
workspaceId: null == workspaceId ? _self.workspaceId : workspaceId // ignore: cast_nullable_to_non_nullable
as String,label: null == label ? _self.label : label // ignore: cast_nullable_to_non_nullable
as String,number: null == number ? _self.number : number // ignore: cast_nullable_to_non_nullable
as int,tabCount: null == tabCount ? _self.tabCount : tabCount // ignore: cast_nullable_to_non_nullable
as int,paneCount: null == paneCount ? _self.paneCount : paneCount // ignore: cast_nullable_to_non_nullable
as int,activeTabId: null == activeTabId ? _self.activeTabId : activeTabId // ignore: cast_nullable_to_non_nullable
as String,agentStatus: null == agentStatus ? _self.agentStatus : agentStatus // ignore: cast_nullable_to_non_nullable
as AgentStatus,focused: null == focused ? _self.focused : focused // ignore: cast_nullable_to_non_nullable
as bool,
  ));
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function(@JsonKey(name: 'workspace_id')  String workspaceId,  String label,  int number, @JsonKey(name: 'tab_count')  int tabCount, @JsonKey(name: 'pane_count')  int paneCount, @JsonKey(name: 'active_tab_id')  String activeTabId, @JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown)  AgentStatus agentStatus,  bool focused)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _WorkspaceInfo() when $default != null:
return $default(_that.workspaceId,_that.label,_that.number,_that.tabCount,_that.paneCount,_that.activeTabId,_that.agentStatus,_that.focused);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function(@JsonKey(name: 'workspace_id')  String workspaceId,  String label,  int number, @JsonKey(name: 'tab_count')  int tabCount, @JsonKey(name: 'pane_count')  int paneCount, @JsonKey(name: 'active_tab_id')  String activeTabId, @JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown)  AgentStatus agentStatus,  bool focused)  $default,) {final _that = this;
switch (_that) {
case _WorkspaceInfo():
return $default(_that.workspaceId,_that.label,_that.number,_that.tabCount,_that.paneCount,_that.activeTabId,_that.agentStatus,_that.focused);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function(@JsonKey(name: 'workspace_id')  String workspaceId,  String label,  int number, @JsonKey(name: 'tab_count')  int tabCount, @JsonKey(name: 'pane_count')  int paneCount, @JsonKey(name: 'active_tab_id')  String activeTabId, @JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown)  AgentStatus agentStatus,  bool focused)?  $default,) {final _that = this;
switch (_that) {
case _WorkspaceInfo() when $default != null:
return $default(_that.workspaceId,_that.label,_that.number,_that.tabCount,_that.paneCount,_that.activeTabId,_that.agentStatus,_that.focused);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _WorkspaceInfo implements WorkspaceInfo {
  const _WorkspaceInfo({@JsonKey(name: 'workspace_id') this.workspaceId = '', this.label = '', this.number = 0, @JsonKey(name: 'tab_count') this.tabCount = 0, @JsonKey(name: 'pane_count') this.paneCount = 0, @JsonKey(name: 'active_tab_id') this.activeTabId = '', @JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown) this.agentStatus = AgentStatus.unknown, this.focused = false});
  factory _WorkspaceInfo.fromJson(Map<String, dynamic> json) => _$WorkspaceInfoFromJson(json);

@override@JsonKey(name: 'workspace_id') final  String workspaceId;
@override@JsonKey() final  String label;
@override@JsonKey() final  int number;
@override@JsonKey(name: 'tab_count') final  int tabCount;
@override@JsonKey(name: 'pane_count') final  int paneCount;
@override@JsonKey(name: 'active_tab_id') final  String activeTabId;
@override@JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown) final  AgentStatus agentStatus;
@override@JsonKey() final  bool focused;

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
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _WorkspaceInfo&&(identical(other.workspaceId, workspaceId) || other.workspaceId == workspaceId)&&(identical(other.label, label) || other.label == label)&&(identical(other.number, number) || other.number == number)&&(identical(other.tabCount, tabCount) || other.tabCount == tabCount)&&(identical(other.paneCount, paneCount) || other.paneCount == paneCount)&&(identical(other.activeTabId, activeTabId) || other.activeTabId == activeTabId)&&(identical(other.agentStatus, agentStatus) || other.agentStatus == agentStatus)&&(identical(other.focused, focused) || other.focused == focused));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,workspaceId,label,number,tabCount,paneCount,activeTabId,agentStatus,focused);

@override
String toString() {
  return 'WorkspaceInfo(workspaceId: $workspaceId, label: $label, number: $number, tabCount: $tabCount, paneCount: $paneCount, activeTabId: $activeTabId, agentStatus: $agentStatus, focused: $focused)';
}


}

/// @nodoc
abstract mixin class _$WorkspaceInfoCopyWith<$Res> implements $WorkspaceInfoCopyWith<$Res> {
  factory _$WorkspaceInfoCopyWith(_WorkspaceInfo value, $Res Function(_WorkspaceInfo) _then) = __$WorkspaceInfoCopyWithImpl;
@override @useResult
$Res call({
@JsonKey(name: 'workspace_id') String workspaceId, String label, int number,@JsonKey(name: 'tab_count') int tabCount,@JsonKey(name: 'pane_count') int paneCount,@JsonKey(name: 'active_tab_id') String activeTabId,@JsonKey(name: 'agent_status', unknownEnumValue: AgentStatus.unknown) AgentStatus agentStatus, bool focused
});




}
/// @nodoc
class __$WorkspaceInfoCopyWithImpl<$Res>
    implements _$WorkspaceInfoCopyWith<$Res> {
  __$WorkspaceInfoCopyWithImpl(this._self, this._then);

  final _WorkspaceInfo _self;
  final $Res Function(_WorkspaceInfo) _then;

/// Create a copy of WorkspaceInfo
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? workspaceId = null,Object? label = null,Object? number = null,Object? tabCount = null,Object? paneCount = null,Object? activeTabId = null,Object? agentStatus = null,Object? focused = null,}) {
  return _then(_WorkspaceInfo(
workspaceId: null == workspaceId ? _self.workspaceId : workspaceId // ignore: cast_nullable_to_non_nullable
as String,label: null == label ? _self.label : label // ignore: cast_nullable_to_non_nullable
as String,number: null == number ? _self.number : number // ignore: cast_nullable_to_non_nullable
as int,tabCount: null == tabCount ? _self.tabCount : tabCount // ignore: cast_nullable_to_non_nullable
as int,paneCount: null == paneCount ? _self.paneCount : paneCount // ignore: cast_nullable_to_non_nullable
as int,activeTabId: null == activeTabId ? _self.activeTabId : activeTabId // ignore: cast_nullable_to_non_nullable
as String,agentStatus: null == agentStatus ? _self.agentStatus : agentStatus // ignore: cast_nullable_to_non_nullable
as AgentStatus,focused: null == focused ? _self.focused : focused // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}


/// @nodoc
mixin _$Snapshot {

 List<Agent> get agents; List<Pane> get panes; List<TabInfo> get tabs; List<WorkspaceInfo> get workspaces;@JsonKey(name: 'focused_pane_id') String get focusedPaneId;
/// Create a copy of Snapshot
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SnapshotCopyWith<Snapshot> get copyWith => _$SnapshotCopyWithImpl<Snapshot>(this as Snapshot, _$identity);

  /// Serializes this Snapshot to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Snapshot&&const DeepCollectionEquality().equals(other.agents, agents)&&const DeepCollectionEquality().equals(other.panes, panes)&&const DeepCollectionEquality().equals(other.tabs, tabs)&&const DeepCollectionEquality().equals(other.workspaces, workspaces)&&(identical(other.focusedPaneId, focusedPaneId) || other.focusedPaneId == focusedPaneId));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(agents),const DeepCollectionEquality().hash(panes),const DeepCollectionEquality().hash(tabs),const DeepCollectionEquality().hash(workspaces),focusedPaneId);

@override
String toString() {
  return 'Snapshot(agents: $agents, panes: $panes, tabs: $tabs, workspaces: $workspaces, focusedPaneId: $focusedPaneId)';
}


}

/// @nodoc
abstract mixin class $SnapshotCopyWith<$Res>  {
  factory $SnapshotCopyWith(Snapshot value, $Res Function(Snapshot) _then) = _$SnapshotCopyWithImpl;
@useResult
$Res call({
 List<Agent> agents, List<Pane> panes, List<TabInfo> tabs, List<WorkspaceInfo> workspaces,@JsonKey(name: 'focused_pane_id') String focusedPaneId
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
@pragma('vm:prefer-inline') @override $Res call({Object? agents = null,Object? panes = null,Object? tabs = null,Object? workspaces = null,Object? focusedPaneId = null,}) {
  return _then(_self.copyWith(
agents: null == agents ? _self.agents : agents // ignore: cast_nullable_to_non_nullable
as List<Agent>,panes: null == panes ? _self.panes : panes // ignore: cast_nullable_to_non_nullable
as List<Pane>,tabs: null == tabs ? _self.tabs : tabs // ignore: cast_nullable_to_non_nullable
as List<TabInfo>,workspaces: null == workspaces ? _self.workspaces : workspaces // ignore: cast_nullable_to_non_nullable
as List<WorkspaceInfo>,focusedPaneId: null == focusedPaneId ? _self.focusedPaneId : focusedPaneId // ignore: cast_nullable_to_non_nullable
as String,
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( List<Agent> agents,  List<Pane> panes,  List<TabInfo> tabs,  List<WorkspaceInfo> workspaces, @JsonKey(name: 'focused_pane_id')  String focusedPaneId)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Snapshot() when $default != null:
return $default(_that.agents,_that.panes,_that.tabs,_that.workspaces,_that.focusedPaneId);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( List<Agent> agents,  List<Pane> panes,  List<TabInfo> tabs,  List<WorkspaceInfo> workspaces, @JsonKey(name: 'focused_pane_id')  String focusedPaneId)  $default,) {final _that = this;
switch (_that) {
case _Snapshot():
return $default(_that.agents,_that.panes,_that.tabs,_that.workspaces,_that.focusedPaneId);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( List<Agent> agents,  List<Pane> panes,  List<TabInfo> tabs,  List<WorkspaceInfo> workspaces, @JsonKey(name: 'focused_pane_id')  String focusedPaneId)?  $default,) {final _that = this;
switch (_that) {
case _Snapshot() when $default != null:
return $default(_that.agents,_that.panes,_that.tabs,_that.workspaces,_that.focusedPaneId);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _Snapshot extends Snapshot {
  const _Snapshot({final  List<Agent> agents = const <Agent>[], final  List<Pane> panes = const <Pane>[], final  List<TabInfo> tabs = const <TabInfo>[], final  List<WorkspaceInfo> workspaces = const <WorkspaceInfo>[], @JsonKey(name: 'focused_pane_id') this.focusedPaneId = ''}): _agents = agents,_panes = panes,_tabs = tabs,_workspaces = workspaces,super._();
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
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _Snapshot&&const DeepCollectionEquality().equals(other._agents, _agents)&&const DeepCollectionEquality().equals(other._panes, _panes)&&const DeepCollectionEquality().equals(other._tabs, _tabs)&&const DeepCollectionEquality().equals(other._workspaces, _workspaces)&&(identical(other.focusedPaneId, focusedPaneId) || other.focusedPaneId == focusedPaneId));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(_agents),const DeepCollectionEquality().hash(_panes),const DeepCollectionEquality().hash(_tabs),const DeepCollectionEquality().hash(_workspaces),focusedPaneId);

@override
String toString() {
  return 'Snapshot(agents: $agents, panes: $panes, tabs: $tabs, workspaces: $workspaces, focusedPaneId: $focusedPaneId)';
}


}

/// @nodoc
abstract mixin class _$SnapshotCopyWith<$Res> implements $SnapshotCopyWith<$Res> {
  factory _$SnapshotCopyWith(_Snapshot value, $Res Function(_Snapshot) _then) = __$SnapshotCopyWithImpl;
@override @useResult
$Res call({
 List<Agent> agents, List<Pane> panes, List<TabInfo> tabs, List<WorkspaceInfo> workspaces,@JsonKey(name: 'focused_pane_id') String focusedPaneId
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
@override @pragma('vm:prefer-inline') $Res call({Object? agents = null,Object? panes = null,Object? tabs = null,Object? workspaces = null,Object? focusedPaneId = null,}) {
  return _then(_Snapshot(
agents: null == agents ? _self._agents : agents // ignore: cast_nullable_to_non_nullable
as List<Agent>,panes: null == panes ? _self._panes : panes // ignore: cast_nullable_to_non_nullable
as List<Pane>,tabs: null == tabs ? _self._tabs : tabs // ignore: cast_nullable_to_non_nullable
as List<TabInfo>,workspaces: null == workspaces ? _self._workspaces : workspaces // ignore: cast_nullable_to_non_nullable
as List<WorkspaceInfo>,focusedPaneId: null == focusedPaneId ? _self.focusedPaneId : focusedPaneId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
