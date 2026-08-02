// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'connection.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_Connection _$ConnectionFromJson(Map<String, dynamic> json) => _Connection(
  id: json['id'] as String,
  name: json['name'] as String,
  baseUrl: json['baseUrl'] as String,
  bearer: json['bearer'] as String,
  deviceId: json['deviceId'] as String?,
  source:
      $enumDecodeNullable(_$ConnectionSourceEnumMap, json['source']) ??
      ConnectionSource.manual,
);

Map<String, dynamic> _$ConnectionToJson(_Connection instance) =>
    <String, dynamic>{
      'id': instance.id,
      'name': instance.name,
      'baseUrl': instance.baseUrl,
      'bearer': instance.bearer,
      'deviceId': instance.deviceId,
      'source': _$ConnectionSourceEnumMap[instance.source]!,
    };

const _$ConnectionSourceEnumMap = {
  ConnectionSource.manual: 'manual',
  ConnectionSource.paired: 'paired',
};
