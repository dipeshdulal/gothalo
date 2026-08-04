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
  tabId: json['tab_id'] as String? ?? '',
  cwd: json['cwd'] as String? ?? '',
  foregroundCwd: json['foreground_cwd'] as String? ?? '',
  branch: json['branch'] as String? ?? '',
  focused: json['focused'] as bool? ?? false,
  session: json['agent_session'] == null
      ? null
      : AgentSession.fromJson(json['agent_session'] as Map<String, dynamic>),
  stateChangeSeq: (json['state_change_seq'] as num?)?.toInt(),
  attentionRank: (json['attention_rank'] as num?)?.toInt(),
);

Map<String, dynamic> _$AgentToJson(_Agent instance) => <String, dynamic>{
  'agent': instance.agent,
  'agent_status': _$AgentStatusEnumMap[instance.agentStatus]!,
  'pane_id': instance.paneId,
  'terminal_title_stripped': instance.title,
  'workspace_id': instance.workspaceId,
  'tab_id': instance.tabId,
  'cwd': instance.cwd,
  'foreground_cwd': instance.foregroundCwd,
  'branch': instance.branch,
  'focused': instance.focused,
  'agent_session': instance.session,
  'state_change_seq': instance.stateChangeSeq,
  'attention_rank': instance.attentionRank,
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

_Pane _$PaneFromJson(Map<String, dynamic> json) => _Pane(
  paneId: json['pane_id'] as String? ?? '',
  tabId: json['tab_id'] as String? ?? '',
  workspaceId: json['workspace_id'] as String? ?? '',
  title: json['terminal_title_stripped'] as String? ?? '',
  agentStatus:
      $enumDecodeNullable(
        _$AgentStatusEnumMap,
        json['agent_status'],
        unknownValue: AgentStatus.unknown,
      ) ??
      AgentStatus.unknown,
  focused: json['focused'] as bool? ?? false,
  cwd: json['cwd'] as String? ?? '',
  foregroundCwd: json['foreground_cwd'] as String? ?? '',
);

Map<String, dynamic> _$PaneToJson(_Pane instance) => <String, dynamic>{
  'pane_id': instance.paneId,
  'tab_id': instance.tabId,
  'workspace_id': instance.workspaceId,
  'terminal_title_stripped': instance.title,
  'agent_status': _$AgentStatusEnumMap[instance.agentStatus]!,
  'focused': instance.focused,
  'cwd': instance.cwd,
  'foreground_cwd': instance.foregroundCwd,
};

_TabInfo _$TabInfoFromJson(Map<String, dynamic> json) => _TabInfo(
  tabId: json['tab_id'] as String? ?? '',
  workspaceId: json['workspace_id'] as String? ?? '',
  label: json['label'] as String? ?? '',
  number: (json['number'] as num?)?.toInt() ?? 0,
  paneCount: (json['pane_count'] as num?)?.toInt() ?? 0,
  focused: json['focused'] as bool? ?? false,
);

Map<String, dynamic> _$TabInfoToJson(_TabInfo instance) => <String, dynamic>{
  'tab_id': instance.tabId,
  'workspace_id': instance.workspaceId,
  'label': instance.label,
  'number': instance.number,
  'pane_count': instance.paneCount,
  'focused': instance.focused,
};

_WorkspaceInfo _$WorkspaceInfoFromJson(Map<String, dynamic> json) =>
    _WorkspaceInfo(
      workspaceId: json['workspace_id'] as String? ?? '',
      label: json['label'] as String? ?? '',
      number: (json['number'] as num?)?.toInt() ?? 0,
      tabCount: (json['tab_count'] as num?)?.toInt() ?? 0,
      paneCount: (json['pane_count'] as num?)?.toInt() ?? 0,
      activeTabId: json['active_tab_id'] as String? ?? '',
      agentStatus:
          $enumDecodeNullable(
            _$AgentStatusEnumMap,
            json['agent_status'],
            unknownValue: AgentStatus.unknown,
          ) ??
          AgentStatus.unknown,
      focused: json['focused'] as bool? ?? false,
    );

Map<String, dynamic> _$WorkspaceInfoToJson(_WorkspaceInfo instance) =>
    <String, dynamic>{
      'workspace_id': instance.workspaceId,
      'label': instance.label,
      'number': instance.number,
      'tab_count': instance.tabCount,
      'pane_count': instance.paneCount,
      'active_tab_id': instance.activeTabId,
      'agent_status': _$AgentStatusEnumMap[instance.agentStatus]!,
      'focused': instance.focused,
    };

_Snapshot _$SnapshotFromJson(Map<String, dynamic> json) => _Snapshot(
  agents:
      (json['agents'] as List<dynamic>?)
          ?.map((e) => Agent.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const <Agent>[],
  panes:
      (json['panes'] as List<dynamic>?)
          ?.map((e) => Pane.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const <Pane>[],
  tabs:
      (json['tabs'] as List<dynamic>?)
          ?.map((e) => TabInfo.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const <TabInfo>[],
  workspaces:
      (json['workspaces'] as List<dynamic>?)
          ?.map((e) => WorkspaceInfo.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const <WorkspaceInfo>[],
  focusedPaneId: json['focused_pane_id'] as String? ?? '',
);

Map<String, dynamic> _$SnapshotToJson(_Snapshot instance) => <String, dynamic>{
  'agents': instance.agents,
  'panes': instance.panes,
  'tabs': instance.tabs,
  'workspaces': instance.workspaces,
  'focused_pane_id': instance.focusedPaneId,
};
