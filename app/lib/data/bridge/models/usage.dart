/// One live provider quota window returned by the bridge.
class UsageWindow {
  const UsageWindow({required this.utilization, this.resetsAt});

  final double utilization;
  final DateTime? resetsAt;

  factory UsageWindow.fromJson(Object? raw) {
    final map = raw is Map
        ? Map<String, dynamic>.from(raw)
        : const <String, dynamic>{};
    final reset = map['resets_at'];
    return UsageWindow(
      utilization: (map['utilization'] as num?)?.toDouble() ?? 0,
      resetsAt: reset is String ? DateTime.tryParse(reset)?.toLocal() : null,
    );
  }
}

/// Claude Code's live OAuth quota response. Unavailable means Claude is not
/// installed/authenticated on the bridge host, or its usage endpoint could not
/// be read; it is not an error the app needs to interrupt the operator about.
class ClaudeUsage {
  const ClaudeUsage({
    required this.available,
    this.reason,
    this.subscriptionType,
    this.fiveHour,
    this.sevenDay,
    this.sevenDaySonnet,
    this.sevenDayOpus,
  });

  final bool available;
  final String? reason;
  final String? subscriptionType;
  final UsageWindow? fiveHour;
  final UsageWindow? sevenDay;
  final UsageWindow? sevenDaySonnet;
  final UsageWindow? sevenDayOpus;

  factory ClaudeUsage.fromJson(Object? raw) {
    final map = raw is Map
        ? Map<String, dynamic>.from(raw)
        : const <String, dynamic>{};
    UsageWindow? window(String key) {
      final value = map[key];
      return value is Map ? UsageWindow.fromJson(value) : null;
    }

    return ClaudeUsage(
      available: map['available'] == true,
      reason: map['reason'] as String?,
      subscriptionType: map['subscription_type'] as String?,
      fiveHour: window('five_hour'),
      sevenDay: window('seven_day'),
      sevenDaySonnet: window('seven_day_sonnet'),
      sevenDayOpus: window('seven_day_opus'),
    );
  }
}

class UsageSnapshot {
  const UsageSnapshot({required this.fetchedAt, required this.claude});

  final DateTime? fetchedAt;
  final ClaudeUsage claude;

  factory UsageSnapshot.fromJson(Map<String, dynamic> json) => UsageSnapshot(
    fetchedAt: json['fetched_at'] is String
        ? DateTime.tryParse(json['fetched_at'] as String)?.toLocal()
        : null,
    claude: ClaudeUsage.fromJson(json['claude']),
  );
}
