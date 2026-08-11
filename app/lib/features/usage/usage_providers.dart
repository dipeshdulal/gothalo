import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/bridge/bridge_providers.dart';
import '../../data/bridge/models/usage.dart';

/// Live Claude quota data for the active bridge. Usage is deliberately polled
/// much less often than agent state: quota windows move in minutes, not frames.
final claudeUsageProvider = FutureProvider.autoDispose<ClaudeUsage?>((
  ref,
) async {
  final timer = Timer(const Duration(minutes: 1), ref.invalidateSelf);
  ref.onDispose(timer.cancel);

  final client = ref.watch(bridgeClientProvider);
  if (client == null) return null;
  try {
    final snapshot = await client.getUsage();
    return snapshot.claude.available ? snapshot.claude : null;
  } catch (_) {
    // Usage is an optional glance, never a reason to make the home screen fail.
    return null;
  }
});
