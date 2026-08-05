// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $ProfilesTable extends Profiles with TableInfo<$ProfilesTable, Profile> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ProfilesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _baseUrlMeta = const VerificationMeta(
    'baseUrl',
  );
  @override
  late final GeneratedColumn<String> baseUrl = GeneratedColumn<String>(
    'base_url',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deviceIdMeta = const VerificationMeta(
    'deviceId',
  );
  @override
  late final GeneratedColumn<String> deviceId = GeneratedColumn<String>(
    'device_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  @override
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
    'source',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('manual'),
  );
  static const VerificationMeta _serverIdMeta = const VerificationMeta(
    'serverId',
  );
  @override
  late final GeneratedColumn<String> serverId = GeneratedColumn<String>(
    'server_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    baseUrl,
    deviceId,
    source,
    serverId,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'profiles';
  @override
  VerificationContext validateIntegrity(
    Insertable<Profile> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('base_url')) {
      context.handle(
        _baseUrlMeta,
        baseUrl.isAcceptableOrUnknown(data['base_url']!, _baseUrlMeta),
      );
    } else if (isInserting) {
      context.missing(_baseUrlMeta);
    }
    if (data.containsKey('device_id')) {
      context.handle(
        _deviceIdMeta,
        deviceId.isAcceptableOrUnknown(data['device_id']!, _deviceIdMeta),
      );
    }
    if (data.containsKey('source')) {
      context.handle(
        _sourceMeta,
        source.isAcceptableOrUnknown(data['source']!, _sourceMeta),
      );
    }
    if (data.containsKey('server_id')) {
      context.handle(
        _serverIdMeta,
        serverId.isAcceptableOrUnknown(data['server_id']!, _serverIdMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Profile map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Profile(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      baseUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}base_url'],
      )!,
      deviceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}device_id'],
      ),
      source: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source'],
      )!,
      serverId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_id'],
      )!,
    );
  }

  @override
  $ProfilesTable createAlias(String alias) {
    return $ProfilesTable(attachedDatabase, alias);
  }
}

class Profile extends DataClass implements Insertable<Profile> {
  final String id;
  final String name;
  final String baseUrl;
  final String? deviceId;
  final String source;

  /// The bridge's own id (`GET /info` → `server_id`), as opposed to [id], which
  /// is this phone's local id for the saved entry.
  ///
  /// Every push carries the sending bridge's `server_id`, and a phone is paired
  /// with several bridges under the *same* FCM token — so this column is the
  /// only thing that can answer "which of my servers did this alert come from",
  /// and therefore which server a notification tap should open. Empty until the
  /// bridge has been reached once (or for a bridge too old to report one).
  final String serverId;
  const Profile({
    required this.id,
    required this.name,
    required this.baseUrl,
    this.deviceId,
    required this.source,
    required this.serverId,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    map['base_url'] = Variable<String>(baseUrl);
    if (!nullToAbsent || deviceId != null) {
      map['device_id'] = Variable<String>(deviceId);
    }
    map['source'] = Variable<String>(source);
    map['server_id'] = Variable<String>(serverId);
    return map;
  }

  ProfilesCompanion toCompanion(bool nullToAbsent) {
    return ProfilesCompanion(
      id: Value(id),
      name: Value(name),
      baseUrl: Value(baseUrl),
      deviceId: deviceId == null && nullToAbsent
          ? const Value.absent()
          : Value(deviceId),
      source: Value(source),
      serverId: Value(serverId),
    );
  }

  factory Profile.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Profile(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      baseUrl: serializer.fromJson<String>(json['baseUrl']),
      deviceId: serializer.fromJson<String?>(json['deviceId']),
      source: serializer.fromJson<String>(json['source']),
      serverId: serializer.fromJson<String>(json['serverId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'baseUrl': serializer.toJson<String>(baseUrl),
      'deviceId': serializer.toJson<String?>(deviceId),
      'source': serializer.toJson<String>(source),
      'serverId': serializer.toJson<String>(serverId),
    };
  }

  Profile copyWith({
    String? id,
    String? name,
    String? baseUrl,
    Value<String?> deviceId = const Value.absent(),
    String? source,
    String? serverId,
  }) => Profile(
    id: id ?? this.id,
    name: name ?? this.name,
    baseUrl: baseUrl ?? this.baseUrl,
    deviceId: deviceId.present ? deviceId.value : this.deviceId,
    source: source ?? this.source,
    serverId: serverId ?? this.serverId,
  );
  Profile copyWithCompanion(ProfilesCompanion data) {
    return Profile(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      baseUrl: data.baseUrl.present ? data.baseUrl.value : this.baseUrl,
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
      source: data.source.present ? data.source.value : this.source,
      serverId: data.serverId.present ? data.serverId.value : this.serverId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Profile(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('baseUrl: $baseUrl, ')
          ..write('deviceId: $deviceId, ')
          ..write('source: $source, ')
          ..write('serverId: $serverId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, name, baseUrl, deviceId, source, serverId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Profile &&
          other.id == this.id &&
          other.name == this.name &&
          other.baseUrl == this.baseUrl &&
          other.deviceId == this.deviceId &&
          other.source == this.source &&
          other.serverId == this.serverId);
}

class ProfilesCompanion extends UpdateCompanion<Profile> {
  final Value<String> id;
  final Value<String> name;
  final Value<String> baseUrl;
  final Value<String?> deviceId;
  final Value<String> source;
  final Value<String> serverId;
  final Value<int> rowid;
  const ProfilesCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.baseUrl = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.source = const Value.absent(),
    this.serverId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ProfilesCompanion.insert({
    required String id,
    required String name,
    required String baseUrl,
    this.deviceId = const Value.absent(),
    this.source = const Value.absent(),
    this.serverId = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name),
       baseUrl = Value(baseUrl);
  static Insertable<Profile> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<String>? baseUrl,
    Expression<String>? deviceId,
    Expression<String>? source,
    Expression<String>? serverId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (baseUrl != null) 'base_url': baseUrl,
      if (deviceId != null) 'device_id': deviceId,
      if (source != null) 'source': source,
      if (serverId != null) 'server_id': serverId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ProfilesCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<String>? baseUrl,
    Value<String?>? deviceId,
    Value<String>? source,
    Value<String>? serverId,
    Value<int>? rowid,
  }) {
    return ProfilesCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      deviceId: deviceId ?? this.deviceId,
      source: source ?? this.source,
      serverId: serverId ?? this.serverId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (baseUrl.present) {
      map['base_url'] = Variable<String>(baseUrl.value);
    }
    if (deviceId.present) {
      map['device_id'] = Variable<String>(deviceId.value);
    }
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (serverId.present) {
      map['server_id'] = Variable<String>(serverId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ProfilesCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('baseUrl: $baseUrl, ')
          ..write('deviceId: $deviceId, ')
          ..write('source: $source, ')
          ..write('serverId: $serverId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AgentEventsTable extends AgentEvents
    with TableInfo<$AgentEventsTable, AgentEvent> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AgentEventsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _rowIdMeta = const VerificationMeta('rowId');
  @override
  late final GeneratedColumn<int> rowId = GeneratedColumn<int>(
    'row_id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _profileIdMeta = const VerificationMeta(
    'profileId',
  );
  @override
  late final GeneratedColumn<String> profileId = GeneratedColumn<String>(
    'profile_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serverIdMeta = const VerificationMeta(
    'serverId',
  );
  @override
  late final GeneratedColumn<String> serverId = GeneratedColumn<String>(
    'server_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _serverNameMeta = const VerificationMeta(
    'serverName',
  );
  @override
  late final GeneratedColumn<String> serverName = GeneratedColumn<String>(
    'server_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _agentMeta = const VerificationMeta('agent');
  @override
  late final GeneratedColumn<String> agent = GeneratedColumn<String>(
    'agent',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _paneIdMeta = const VerificationMeta('paneId');
  @override
  late final GeneratedColumn<String> paneId = GeneratedColumn<String>(
    'pane_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _workspaceIdMeta = const VerificationMeta(
    'workspaceId',
  );
  @override
  late final GeneratedColumn<String> workspaceId = GeneratedColumn<String>(
    'workspace_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _stateChangeSeqMeta = const VerificationMeta(
    'stateChangeSeq',
  );
  @override
  late final GeneratedColumn<int> stateChangeSeq = GeneratedColumn<int>(
    'state_change_seq',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _receivedAtMeta = const VerificationMeta(
    'receivedAt',
  );
  @override
  late final GeneratedColumn<int> receivedAt = GeneratedColumn<int>(
    'received_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _handledMeta = const VerificationMeta(
    'handled',
  );
  @override
  late final GeneratedColumn<bool> handled = GeneratedColumn<bool>(
    'handled',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("handled" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [
    rowId,
    profileId,
    serverId,
    serverName,
    agent,
    paneId,
    workspaceId,
    title,
    status,
    stateChangeSeq,
    receivedAt,
    handled,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'agent_events';
  @override
  VerificationContext validateIntegrity(
    Insertable<AgentEvent> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('row_id')) {
      context.handle(
        _rowIdMeta,
        rowId.isAcceptableOrUnknown(data['row_id']!, _rowIdMeta),
      );
    }
    if (data.containsKey('profile_id')) {
      context.handle(
        _profileIdMeta,
        profileId.isAcceptableOrUnknown(data['profile_id']!, _profileIdMeta),
      );
    } else if (isInserting) {
      context.missing(_profileIdMeta);
    }
    if (data.containsKey('server_id')) {
      context.handle(
        _serverIdMeta,
        serverId.isAcceptableOrUnknown(data['server_id']!, _serverIdMeta),
      );
    }
    if (data.containsKey('server_name')) {
      context.handle(
        _serverNameMeta,
        serverName.isAcceptableOrUnknown(data['server_name']!, _serverNameMeta),
      );
    }
    if (data.containsKey('agent')) {
      context.handle(
        _agentMeta,
        agent.isAcceptableOrUnknown(data['agent']!, _agentMeta),
      );
    } else if (isInserting) {
      context.missing(_agentMeta);
    }
    if (data.containsKey('pane_id')) {
      context.handle(
        _paneIdMeta,
        paneId.isAcceptableOrUnknown(data['pane_id']!, _paneIdMeta),
      );
    } else if (isInserting) {
      context.missing(_paneIdMeta);
    }
    if (data.containsKey('workspace_id')) {
      context.handle(
        _workspaceIdMeta,
        workspaceId.isAcceptableOrUnknown(
          data['workspace_id']!,
          _workspaceIdMeta,
        ),
      );
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    } else if (isInserting) {
      context.missing(_statusMeta);
    }
    if (data.containsKey('state_change_seq')) {
      context.handle(
        _stateChangeSeqMeta,
        stateChangeSeq.isAcceptableOrUnknown(
          data['state_change_seq']!,
          _stateChangeSeqMeta,
        ),
      );
    }
    if (data.containsKey('received_at')) {
      context.handle(
        _receivedAtMeta,
        receivedAt.isAcceptableOrUnknown(data['received_at']!, _receivedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_receivedAtMeta);
    }
    if (data.containsKey('handled')) {
      context.handle(
        _handledMeta,
        handled.isAcceptableOrUnknown(data['handled']!, _handledMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {rowId};
  @override
  AgentEvent map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AgentEvent(
      rowId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}row_id'],
      )!,
      profileId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}profile_id'],
      )!,
      serverId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_id'],
      )!,
      serverName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_name'],
      )!,
      agent: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}agent'],
      )!,
      paneId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}pane_id'],
      )!,
      workspaceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}workspace_id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      stateChangeSeq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}state_change_seq'],
      ),
      receivedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}received_at'],
      )!,
      handled: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}handled'],
      )!,
    );
  }

  @override
  $AgentEventsTable createAlias(String alias) {
    return $AgentEventsTable(attachedDatabase, alias);
  }
}

class AgentEvent extends DataClass implements Insertable<AgentEvent> {
  final int rowId;
  final String profileId;

  /// The bridge that sent the push (its `server_id`). Recorded straight from the
  /// payload because a push arrives in a background isolate that has no notion
  /// of an "active" server — attribution has to come from the message itself,
  /// not from whatever the UI happened to be showing.
  final String serverId;
  final String serverName;
  final String agent;
  final String paneId;
  final String workspaceId;
  final String title;

  /// The status this event represents (stored as its enum name).
  final String status;

  /// Herdr's `state_change_seq` for the agent at the time of the event.
  final int? stateChangeSeq;

  /// When the event landed on this device (unix millis, UTC).
  final int receivedAt;

  /// Whether the user has acted on / dismissed this event.
  final bool handled;
  const AgentEvent({
    required this.rowId,
    required this.profileId,
    required this.serverId,
    required this.serverName,
    required this.agent,
    required this.paneId,
    required this.workspaceId,
    required this.title,
    required this.status,
    this.stateChangeSeq,
    required this.receivedAt,
    required this.handled,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['row_id'] = Variable<int>(rowId);
    map['profile_id'] = Variable<String>(profileId);
    map['server_id'] = Variable<String>(serverId);
    map['server_name'] = Variable<String>(serverName);
    map['agent'] = Variable<String>(agent);
    map['pane_id'] = Variable<String>(paneId);
    map['workspace_id'] = Variable<String>(workspaceId);
    map['title'] = Variable<String>(title);
    map['status'] = Variable<String>(status);
    if (!nullToAbsent || stateChangeSeq != null) {
      map['state_change_seq'] = Variable<int>(stateChangeSeq);
    }
    map['received_at'] = Variable<int>(receivedAt);
    map['handled'] = Variable<bool>(handled);
    return map;
  }

  AgentEventsCompanion toCompanion(bool nullToAbsent) {
    return AgentEventsCompanion(
      rowId: Value(rowId),
      profileId: Value(profileId),
      serverId: Value(serverId),
      serverName: Value(serverName),
      agent: Value(agent),
      paneId: Value(paneId),
      workspaceId: Value(workspaceId),
      title: Value(title),
      status: Value(status),
      stateChangeSeq: stateChangeSeq == null && nullToAbsent
          ? const Value.absent()
          : Value(stateChangeSeq),
      receivedAt: Value(receivedAt),
      handled: Value(handled),
    );
  }

  factory AgentEvent.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AgentEvent(
      rowId: serializer.fromJson<int>(json['rowId']),
      profileId: serializer.fromJson<String>(json['profileId']),
      serverId: serializer.fromJson<String>(json['serverId']),
      serverName: serializer.fromJson<String>(json['serverName']),
      agent: serializer.fromJson<String>(json['agent']),
      paneId: serializer.fromJson<String>(json['paneId']),
      workspaceId: serializer.fromJson<String>(json['workspaceId']),
      title: serializer.fromJson<String>(json['title']),
      status: serializer.fromJson<String>(json['status']),
      stateChangeSeq: serializer.fromJson<int?>(json['stateChangeSeq']),
      receivedAt: serializer.fromJson<int>(json['receivedAt']),
      handled: serializer.fromJson<bool>(json['handled']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'rowId': serializer.toJson<int>(rowId),
      'profileId': serializer.toJson<String>(profileId),
      'serverId': serializer.toJson<String>(serverId),
      'serverName': serializer.toJson<String>(serverName),
      'agent': serializer.toJson<String>(agent),
      'paneId': serializer.toJson<String>(paneId),
      'workspaceId': serializer.toJson<String>(workspaceId),
      'title': serializer.toJson<String>(title),
      'status': serializer.toJson<String>(status),
      'stateChangeSeq': serializer.toJson<int?>(stateChangeSeq),
      'receivedAt': serializer.toJson<int>(receivedAt),
      'handled': serializer.toJson<bool>(handled),
    };
  }

  AgentEvent copyWith({
    int? rowId,
    String? profileId,
    String? serverId,
    String? serverName,
    String? agent,
    String? paneId,
    String? workspaceId,
    String? title,
    String? status,
    Value<int?> stateChangeSeq = const Value.absent(),
    int? receivedAt,
    bool? handled,
  }) => AgentEvent(
    rowId: rowId ?? this.rowId,
    profileId: profileId ?? this.profileId,
    serverId: serverId ?? this.serverId,
    serverName: serverName ?? this.serverName,
    agent: agent ?? this.agent,
    paneId: paneId ?? this.paneId,
    workspaceId: workspaceId ?? this.workspaceId,
    title: title ?? this.title,
    status: status ?? this.status,
    stateChangeSeq: stateChangeSeq.present
        ? stateChangeSeq.value
        : this.stateChangeSeq,
    receivedAt: receivedAt ?? this.receivedAt,
    handled: handled ?? this.handled,
  );
  AgentEvent copyWithCompanion(AgentEventsCompanion data) {
    return AgentEvent(
      rowId: data.rowId.present ? data.rowId.value : this.rowId,
      profileId: data.profileId.present ? data.profileId.value : this.profileId,
      serverId: data.serverId.present ? data.serverId.value : this.serverId,
      serverName: data.serverName.present
          ? data.serverName.value
          : this.serverName,
      agent: data.agent.present ? data.agent.value : this.agent,
      paneId: data.paneId.present ? data.paneId.value : this.paneId,
      workspaceId: data.workspaceId.present
          ? data.workspaceId.value
          : this.workspaceId,
      title: data.title.present ? data.title.value : this.title,
      status: data.status.present ? data.status.value : this.status,
      stateChangeSeq: data.stateChangeSeq.present
          ? data.stateChangeSeq.value
          : this.stateChangeSeq,
      receivedAt: data.receivedAt.present
          ? data.receivedAt.value
          : this.receivedAt,
      handled: data.handled.present ? data.handled.value : this.handled,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AgentEvent(')
          ..write('rowId: $rowId, ')
          ..write('profileId: $profileId, ')
          ..write('serverId: $serverId, ')
          ..write('serverName: $serverName, ')
          ..write('agent: $agent, ')
          ..write('paneId: $paneId, ')
          ..write('workspaceId: $workspaceId, ')
          ..write('title: $title, ')
          ..write('status: $status, ')
          ..write('stateChangeSeq: $stateChangeSeq, ')
          ..write('receivedAt: $receivedAt, ')
          ..write('handled: $handled')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    rowId,
    profileId,
    serverId,
    serverName,
    agent,
    paneId,
    workspaceId,
    title,
    status,
    stateChangeSeq,
    receivedAt,
    handled,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AgentEvent &&
          other.rowId == this.rowId &&
          other.profileId == this.profileId &&
          other.serverId == this.serverId &&
          other.serverName == this.serverName &&
          other.agent == this.agent &&
          other.paneId == this.paneId &&
          other.workspaceId == this.workspaceId &&
          other.title == this.title &&
          other.status == this.status &&
          other.stateChangeSeq == this.stateChangeSeq &&
          other.receivedAt == this.receivedAt &&
          other.handled == this.handled);
}

class AgentEventsCompanion extends UpdateCompanion<AgentEvent> {
  final Value<int> rowId;
  final Value<String> profileId;
  final Value<String> serverId;
  final Value<String> serverName;
  final Value<String> agent;
  final Value<String> paneId;
  final Value<String> workspaceId;
  final Value<String> title;
  final Value<String> status;
  final Value<int?> stateChangeSeq;
  final Value<int> receivedAt;
  final Value<bool> handled;
  const AgentEventsCompanion({
    this.rowId = const Value.absent(),
    this.profileId = const Value.absent(),
    this.serverId = const Value.absent(),
    this.serverName = const Value.absent(),
    this.agent = const Value.absent(),
    this.paneId = const Value.absent(),
    this.workspaceId = const Value.absent(),
    this.title = const Value.absent(),
    this.status = const Value.absent(),
    this.stateChangeSeq = const Value.absent(),
    this.receivedAt = const Value.absent(),
    this.handled = const Value.absent(),
  });
  AgentEventsCompanion.insert({
    this.rowId = const Value.absent(),
    required String profileId,
    this.serverId = const Value.absent(),
    this.serverName = const Value.absent(),
    required String agent,
    required String paneId,
    this.workspaceId = const Value.absent(),
    this.title = const Value.absent(),
    required String status,
    this.stateChangeSeq = const Value.absent(),
    required int receivedAt,
    this.handled = const Value.absent(),
  }) : profileId = Value(profileId),
       agent = Value(agent),
       paneId = Value(paneId),
       status = Value(status),
       receivedAt = Value(receivedAt);
  static Insertable<AgentEvent> custom({
    Expression<int>? rowId,
    Expression<String>? profileId,
    Expression<String>? serverId,
    Expression<String>? serverName,
    Expression<String>? agent,
    Expression<String>? paneId,
    Expression<String>? workspaceId,
    Expression<String>? title,
    Expression<String>? status,
    Expression<int>? stateChangeSeq,
    Expression<int>? receivedAt,
    Expression<bool>? handled,
  }) {
    return RawValuesInsertable({
      if (rowId != null) 'row_id': rowId,
      if (profileId != null) 'profile_id': profileId,
      if (serverId != null) 'server_id': serverId,
      if (serverName != null) 'server_name': serverName,
      if (agent != null) 'agent': agent,
      if (paneId != null) 'pane_id': paneId,
      if (workspaceId != null) 'workspace_id': workspaceId,
      if (title != null) 'title': title,
      if (status != null) 'status': status,
      if (stateChangeSeq != null) 'state_change_seq': stateChangeSeq,
      if (receivedAt != null) 'received_at': receivedAt,
      if (handled != null) 'handled': handled,
    });
  }

  AgentEventsCompanion copyWith({
    Value<int>? rowId,
    Value<String>? profileId,
    Value<String>? serverId,
    Value<String>? serverName,
    Value<String>? agent,
    Value<String>? paneId,
    Value<String>? workspaceId,
    Value<String>? title,
    Value<String>? status,
    Value<int?>? stateChangeSeq,
    Value<int>? receivedAt,
    Value<bool>? handled,
  }) {
    return AgentEventsCompanion(
      rowId: rowId ?? this.rowId,
      profileId: profileId ?? this.profileId,
      serverId: serverId ?? this.serverId,
      serverName: serverName ?? this.serverName,
      agent: agent ?? this.agent,
      paneId: paneId ?? this.paneId,
      workspaceId: workspaceId ?? this.workspaceId,
      title: title ?? this.title,
      status: status ?? this.status,
      stateChangeSeq: stateChangeSeq ?? this.stateChangeSeq,
      receivedAt: receivedAt ?? this.receivedAt,
      handled: handled ?? this.handled,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (rowId.present) {
      map['row_id'] = Variable<int>(rowId.value);
    }
    if (profileId.present) {
      map['profile_id'] = Variable<String>(profileId.value);
    }
    if (serverId.present) {
      map['server_id'] = Variable<String>(serverId.value);
    }
    if (serverName.present) {
      map['server_name'] = Variable<String>(serverName.value);
    }
    if (agent.present) {
      map['agent'] = Variable<String>(agent.value);
    }
    if (paneId.present) {
      map['pane_id'] = Variable<String>(paneId.value);
    }
    if (workspaceId.present) {
      map['workspace_id'] = Variable<String>(workspaceId.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (stateChangeSeq.present) {
      map['state_change_seq'] = Variable<int>(stateChangeSeq.value);
    }
    if (receivedAt.present) {
      map['received_at'] = Variable<int>(receivedAt.value);
    }
    if (handled.present) {
      map['handled'] = Variable<bool>(handled.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AgentEventsCompanion(')
          ..write('rowId: $rowId, ')
          ..write('profileId: $profileId, ')
          ..write('serverId: $serverId, ')
          ..write('serverName: $serverName, ')
          ..write('agent: $agent, ')
          ..write('paneId: $paneId, ')
          ..write('workspaceId: $workspaceId, ')
          ..write('title: $title, ')
          ..write('status: $status, ')
          ..write('stateChangeSeq: $stateChangeSeq, ')
          ..write('receivedAt: $receivedAt, ')
          ..write('handled: $handled')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $ProfilesTable profiles = $ProfilesTable(this);
  late final $AgentEventsTable agentEvents = $AgentEventsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [profiles, agentEvents];
}

typedef $$ProfilesTableCreateCompanionBuilder =
    ProfilesCompanion Function({
      required String id,
      required String name,
      required String baseUrl,
      Value<String?> deviceId,
      Value<String> source,
      Value<String> serverId,
      Value<int> rowid,
    });
typedef $$ProfilesTableUpdateCompanionBuilder =
    ProfilesCompanion Function({
      Value<String> id,
      Value<String> name,
      Value<String> baseUrl,
      Value<String?> deviceId,
      Value<String> source,
      Value<String> serverId,
      Value<int> rowid,
    });

class $$ProfilesTableFilterComposer
    extends Composer<_$AppDatabase, $ProfilesTable> {
  $$ProfilesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get baseUrl => $composableBuilder(
    column: $table.baseUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverId => $composableBuilder(
    column: $table.serverId,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ProfilesTableOrderingComposer
    extends Composer<_$AppDatabase, $ProfilesTable> {
  $$ProfilesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get baseUrl => $composableBuilder(
    column: $table.baseUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverId => $composableBuilder(
    column: $table.serverId,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ProfilesTableAnnotationComposer
    extends Composer<_$AppDatabase, $ProfilesTable> {
  $$ProfilesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get baseUrl =>
      $composableBuilder(column: $table.baseUrl, builder: (column) => column);

  GeneratedColumn<String> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);

  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<String> get serverId =>
      $composableBuilder(column: $table.serverId, builder: (column) => column);
}

class $$ProfilesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ProfilesTable,
          Profile,
          $$ProfilesTableFilterComposer,
          $$ProfilesTableOrderingComposer,
          $$ProfilesTableAnnotationComposer,
          $$ProfilesTableCreateCompanionBuilder,
          $$ProfilesTableUpdateCompanionBuilder,
          (Profile, BaseReferences<_$AppDatabase, $ProfilesTable, Profile>),
          Profile,
          PrefetchHooks Function()
        > {
  $$ProfilesTableTableManager(_$AppDatabase db, $ProfilesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ProfilesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ProfilesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ProfilesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> baseUrl = const Value.absent(),
                Value<String?> deviceId = const Value.absent(),
                Value<String> source = const Value.absent(),
                Value<String> serverId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ProfilesCompanion(
                id: id,
                name: name,
                baseUrl: baseUrl,
                deviceId: deviceId,
                source: source,
                serverId: serverId,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String name,
                required String baseUrl,
                Value<String?> deviceId = const Value.absent(),
                Value<String> source = const Value.absent(),
                Value<String> serverId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ProfilesCompanion.insert(
                id: id,
                name: name,
                baseUrl: baseUrl,
                deviceId: deviceId,
                source: source,
                serverId: serverId,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ProfilesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ProfilesTable,
      Profile,
      $$ProfilesTableFilterComposer,
      $$ProfilesTableOrderingComposer,
      $$ProfilesTableAnnotationComposer,
      $$ProfilesTableCreateCompanionBuilder,
      $$ProfilesTableUpdateCompanionBuilder,
      (Profile, BaseReferences<_$AppDatabase, $ProfilesTable, Profile>),
      Profile,
      PrefetchHooks Function()
    >;
typedef $$AgentEventsTableCreateCompanionBuilder =
    AgentEventsCompanion Function({
      Value<int> rowId,
      required String profileId,
      Value<String> serverId,
      Value<String> serverName,
      required String agent,
      required String paneId,
      Value<String> workspaceId,
      Value<String> title,
      required String status,
      Value<int?> stateChangeSeq,
      required int receivedAt,
      Value<bool> handled,
    });
typedef $$AgentEventsTableUpdateCompanionBuilder =
    AgentEventsCompanion Function({
      Value<int> rowId,
      Value<String> profileId,
      Value<String> serverId,
      Value<String> serverName,
      Value<String> agent,
      Value<String> paneId,
      Value<String> workspaceId,
      Value<String> title,
      Value<String> status,
      Value<int?> stateChangeSeq,
      Value<int> receivedAt,
      Value<bool> handled,
    });

class $$AgentEventsTableFilterComposer
    extends Composer<_$AppDatabase, $AgentEventsTable> {
  $$AgentEventsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get rowId => $composableBuilder(
    column: $table.rowId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get profileId => $composableBuilder(
    column: $table.profileId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverId => $composableBuilder(
    column: $table.serverId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverName => $composableBuilder(
    column: $table.serverName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get agent => $composableBuilder(
    column: $table.agent,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get paneId => $composableBuilder(
    column: $table.paneId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get workspaceId => $composableBuilder(
    column: $table.workspaceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get stateChangeSeq => $composableBuilder(
    column: $table.stateChangeSeq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get receivedAt => $composableBuilder(
    column: $table.receivedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get handled => $composableBuilder(
    column: $table.handled,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AgentEventsTableOrderingComposer
    extends Composer<_$AppDatabase, $AgentEventsTable> {
  $$AgentEventsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get rowId => $composableBuilder(
    column: $table.rowId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get profileId => $composableBuilder(
    column: $table.profileId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverId => $composableBuilder(
    column: $table.serverId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverName => $composableBuilder(
    column: $table.serverName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get agent => $composableBuilder(
    column: $table.agent,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get paneId => $composableBuilder(
    column: $table.paneId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get workspaceId => $composableBuilder(
    column: $table.workspaceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get stateChangeSeq => $composableBuilder(
    column: $table.stateChangeSeq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get receivedAt => $composableBuilder(
    column: $table.receivedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get handled => $composableBuilder(
    column: $table.handled,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AgentEventsTableAnnotationComposer
    extends Composer<_$AppDatabase, $AgentEventsTable> {
  $$AgentEventsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get rowId =>
      $composableBuilder(column: $table.rowId, builder: (column) => column);

  GeneratedColumn<String> get profileId =>
      $composableBuilder(column: $table.profileId, builder: (column) => column);

  GeneratedColumn<String> get serverId =>
      $composableBuilder(column: $table.serverId, builder: (column) => column);

  GeneratedColumn<String> get serverName => $composableBuilder(
    column: $table.serverName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get agent =>
      $composableBuilder(column: $table.agent, builder: (column) => column);

  GeneratedColumn<String> get paneId =>
      $composableBuilder(column: $table.paneId, builder: (column) => column);

  GeneratedColumn<String> get workspaceId => $composableBuilder(
    column: $table.workspaceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<int> get stateChangeSeq => $composableBuilder(
    column: $table.stateChangeSeq,
    builder: (column) => column,
  );

  GeneratedColumn<int> get receivedAt => $composableBuilder(
    column: $table.receivedAt,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get handled =>
      $composableBuilder(column: $table.handled, builder: (column) => column);
}

class $$AgentEventsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $AgentEventsTable,
          AgentEvent,
          $$AgentEventsTableFilterComposer,
          $$AgentEventsTableOrderingComposer,
          $$AgentEventsTableAnnotationComposer,
          $$AgentEventsTableCreateCompanionBuilder,
          $$AgentEventsTableUpdateCompanionBuilder,
          (
            AgentEvent,
            BaseReferences<_$AppDatabase, $AgentEventsTable, AgentEvent>,
          ),
          AgentEvent,
          PrefetchHooks Function()
        > {
  $$AgentEventsTableTableManager(_$AppDatabase db, $AgentEventsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AgentEventsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AgentEventsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AgentEventsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> rowId = const Value.absent(),
                Value<String> profileId = const Value.absent(),
                Value<String> serverId = const Value.absent(),
                Value<String> serverName = const Value.absent(),
                Value<String> agent = const Value.absent(),
                Value<String> paneId = const Value.absent(),
                Value<String> workspaceId = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<int?> stateChangeSeq = const Value.absent(),
                Value<int> receivedAt = const Value.absent(),
                Value<bool> handled = const Value.absent(),
              }) => AgentEventsCompanion(
                rowId: rowId,
                profileId: profileId,
                serverId: serverId,
                serverName: serverName,
                agent: agent,
                paneId: paneId,
                workspaceId: workspaceId,
                title: title,
                status: status,
                stateChangeSeq: stateChangeSeq,
                receivedAt: receivedAt,
                handled: handled,
              ),
          createCompanionCallback:
              ({
                Value<int> rowId = const Value.absent(),
                required String profileId,
                Value<String> serverId = const Value.absent(),
                Value<String> serverName = const Value.absent(),
                required String agent,
                required String paneId,
                Value<String> workspaceId = const Value.absent(),
                Value<String> title = const Value.absent(),
                required String status,
                Value<int?> stateChangeSeq = const Value.absent(),
                required int receivedAt,
                Value<bool> handled = const Value.absent(),
              }) => AgentEventsCompanion.insert(
                rowId: rowId,
                profileId: profileId,
                serverId: serverId,
                serverName: serverName,
                agent: agent,
                paneId: paneId,
                workspaceId: workspaceId,
                title: title,
                status: status,
                stateChangeSeq: stateChangeSeq,
                receivedAt: receivedAt,
                handled: handled,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AgentEventsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $AgentEventsTable,
      AgentEvent,
      $$AgentEventsTableFilterComposer,
      $$AgentEventsTableOrderingComposer,
      $$AgentEventsTableAnnotationComposer,
      $$AgentEventsTableCreateCompanionBuilder,
      $$AgentEventsTableUpdateCompanionBuilder,
      (
        AgentEvent,
        BaseReferences<_$AppDatabase, $AgentEventsTable, AgentEvent>,
      ),
      AgentEvent,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$ProfilesTableTableManager get profiles =>
      $$ProfilesTableTableManager(_db, _db.profiles);
  $$AgentEventsTableTableManager get agentEvents =>
      $$AgentEventsTableTableManager(_db, _db.agentEvents);
}
