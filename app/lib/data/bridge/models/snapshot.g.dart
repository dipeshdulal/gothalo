// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'snapshot.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_Agent _$AgentFromJson(Map<String, dynamic> json) => _Agent(
  agent: json['agent'] as String? ?? '',
  agentStatus:
      $enumDecodeNullable(
        _$AgentStatusEnumMap,
        json['agent_status'],
        unknownValue: AgentStatus.unknown,
      ) ??
      AgentStatus.unknown,
  paneId: json['pane_id'] as String? ?? '',
  title: json['terminal_title_stripped'] as String? ?? '',
  workspaceId: json['workspace_id'] as String? ?? '',
  cwd: json['cwd'] as String? ?? '',
  focused: json['focused'] as bool? ?? false,
  session: json['agent_session'] == null
      ? null
      : AgentSession.fromJson(json['agent_session'] as Map<String, dynamic>),
  stateChangeSeq: (json['state_change_seq'] as num?)?.toInt(),
);

Map<String, dynamic> _$AgentToJson(_Agent instance) => <String, dynamic>{
  'agent': instance.agent,
  'agent_status': _$AgentStatusEnumMap[instance.agentStatus]!,
  'pane_id': instance.paneId,
  'terminal_title_stripped': instance.title,
  'workspace_id': instance.workspaceId,
  'cwd': instance.cwd,
  'focused': instance.focused,
  'agent_session': instance.session,
  'state_change_seq': instance.stateChangeSeq,
};

const _$AgentStatusEnumMap = {
  AgentStatus.idle: 'idle',
  AgentStatus.working: 'working',
  AgentStatus.blocked: 'blocked',
  AgentStatus.done: 'done',
  AgentStatus.unknown: 'unknown',
};

_AgentSession _$AgentSessionFromJson(Map<String, dynamic> json) =>
    _AgentSession(value: json['value'] as String?);

Map<String, dynamic> _$AgentSessionToJson(_AgentSession instance) =>
    <String, dynamic>{'value': instance.value};

_Snapshot _$SnapshotFromJson(Map<String, dynamic> json) => _Snapshot(
  agents:
      (json['agents'] as List<dynamic>?)
          ?.map((e) => Agent.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const <Agent>[],
);

Map<String, dynamic> _$SnapshotToJson(_Snapshot instance) => <String, dynamic>{
  'agents': instance.agents,
};
