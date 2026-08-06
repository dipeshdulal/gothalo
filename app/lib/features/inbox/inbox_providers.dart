import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/connection/connection.dart';
import '../../data/bridge/bridge_client.dart';
import '../../data/bridge/bridge_providers.dart';
import '../../data/bridge/models/snapshot.dart';

part 'inbox_providers.g.dart';

/// The live Herdr state for the active server — the app's single source of
/// truth, driven by the bridge's `WS /events` push stream.
///
/// Design: we treat `/events` purely as a **change signal**, not a data source.
/// The bridge sends a full **snapshot** frame on connect (the seed); every
/// subsequent frame just means "something changed" → we pull the authoritative,
/// already-typed state from `/snapshot` (coalescing bursts with a short
/// debounce). We deliberately **do not parse individual event types or
/// payloads** — so new or renamed Herdr events need no app changes, and there's
/// no hand-maintained delta-merge to drift out of sync. A dropped socket or a
/// `seq` gap reconnects and reseeds. If `/events` is unavailable (older bridge,
/// transient), it falls back to a one-shot `/snapshot` and retries the stream in
/// the background.
///
/// Every surface reads this one provider, so they're all live off a single
/// connection — no per-action refetch, no polling.
@riverpod
class SnapshotController extends _$SnapshotController {
  WebSocketChannel? _ch;
  StreamSubscription<dynamic>? _sub;
  Timer? _reconnectTimer;
  Timer? _resnapTimer;
  Timer? _watchdog;
  AppLifecycleListener? _lifecycle;
  int _attempts = 0;
  int _lastSeq = -1;
  bool _disposed = false;
  Connection? _conn;

  /// How long the stream may be silent before we assume the socket is dead.
  ///
  /// The bridge sends a heartbeat frame every 20s, so silence past this means
  /// frames have stopped arriving — which is the ONLY way to notice a half-open
  /// socket. When the bridge is killed behind `tailscale serve`, or the phone's
  /// radio sleeps, or a NAT entry expires, the connection dies without either
  /// side sending a close: `onDone` never fires, the existing reconnect logic is
  /// never invoked, and the app serves stale state indefinitely while believing
  /// it is live. Generous enough (2.5x) to ride out a slow tailnet.
  static const _silenceTimeout = Duration(seconds: 50);

  @override
  Future<Snapshot> build() async {
    // Keep the live `/events` connection alive for the whole session — without
    // this the provider auto-disposes whenever no screen is watching it (brief
    // navigation gaps, heavy rebuilds), which tears the socket down and
    // reconnects in a loop, so live updates never land. One durable connection.
    ref.keepAlive();
    // Rebuilding (a different active server, a re-pair) runs the previous
    // build's onDispose first, which latches _disposed. Clear it so the new
    // connection can arm its watchdog and reconnect — otherwise switching
    // servers yields a socket that can never heal itself.
    _disposed = false;
    ref.onDispose(_teardown);
    // A phone suspends sockets while the screen is off, and the death is rarely
    // announced. Coming back to the app is the one moment we know for certain
    // the connection may be stale, so re-establish it rather than trust it.
    _lifecycle ??= AppLifecycleListener(
      onResume: () {
        if (!_disposed) _scheduleReconnect(immediate: true);
      },
    );
    final client = ref.watch(bridgeClientProvider);
    if (client == null) {
      throw BridgeException('No bridge connection configured yet.');
    }
    _conn = client.connection;
    try {
      return await _connectAndSeed();
    } catch (_) {
      // `/events` unavailable (older bridge, transient) → show a one-shot
      // snapshot and keep retrying the stream in the background.
      _scheduleReconnect();
      return client.getSnapshot();
    }
  }

  Uri _eventsUri(Connection c) {
    final base = Uri.parse(c.baseUrl);
    return Uri(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: '/events',
      queryParameters: {'token': c.bearer},
    );
  }

  /// Open the stream, wait for the snapshot frame, wire the ongoing listener,
  /// and return the seed snapshot.
  Future<Snapshot> _connectAndSeed() async {
    final ch = WebSocketChannel.connect(_eventsUri(_conn!));
    _ch = ch;
    await ch.ready;
    _armWatchdog();
    final seed = Completer<Snapshot>();
    _sub = ch.stream.listen(
      (message) => _onFrame(message, seed),
      onDone: _handleDrop,
      onError: (_) => _handleDrop(),
      cancelOnError: true,
    );
    return seed.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () =>
          throw BridgeException('Timed out waiting for the /events snapshot'),
    );
  }

  /// Restart the silence timer. Called for every frame — a heartbeat counts, and
  /// that is the whole point of it.
  void _armWatchdog() {
    _watchdog?.cancel();
    if (_disposed) return;
    _watchdog = Timer(_silenceTimeout, () {
      if (_disposed) return;
      // Nothing for 50s on a link that heartbeats every 20s: the socket is gone
      // even though the stream never told us.
      _scheduleReconnect(immediate: true);
    });
  }

  void _onFrame(dynamic message, Completer<Snapshot> seed) {
    if (message is! String) return;
    _armWatchdog();
    final Map<String, dynamic> frame;
    try {
      final decoded = jsonDecode(message);
      if (decoded is! Map<String, dynamic>) return;
      frame = decoded;
    } catch (_) {
      return;
    }

    // "Still here" — it exists to be received, nothing more. It deliberately
    // carries no seq, so returning here keeps it from being read as a change
    // signal and triggering a pointless re-snapshot every 20 seconds.
    if (frame['type'] == 'heartbeat') return;

    final seq = (frame['seq'] as num?)?.toInt();

    // A frame carrying a full snapshot is a (re)seed. We key off the presence of
    // the `snapshot` field rather than a type string, so nothing here depends on
    // the event vocabulary.
    if (frame['snapshot'] != null) {
      final snap = _parseSnapshot(frame['snapshot']);
      if (snap == null) return;
      _lastSeq = seq ?? _lastSeq;
      _attempts = 0;
      if (!seed.isCompleted) {
        seed.complete(snap);
      } else {
        state = AsyncData(snap);
      }
      return;
    }

    // Any other frame is just "something changed". A `seq` gap means we missed
    // frames → reconnect + reseed; otherwise pull the authoritative state.
    if (seq != null) {
      if (_lastSeq >= 0 && seq > _lastSeq + 1) {
        _scheduleReconnect();
        return;
      }
      _lastSeq = seq;
    }
    _scheduleResnapshot();
  }

  /// Accept the same envelope shapes as [BridgeClient.getSnapshot].
  Snapshot? _parseSnapshot(dynamic node) {
    if (node is! Map) return null;
    final result = node['result'];
    final snapNode = (result is Map ? result['snapshot'] : null) ??
        node['snapshot'] ??
        node;
    if (snapNode is! Map) return null;
    try {
      return Snapshot.fromJson(Map<String, dynamic>.from(snapNode));
    } catch (_) {
      return null;
    }
  }

  /// Debounced authoritative refetch — coalesces a burst of change signals into
  /// one `GET /snapshot`.
  void _scheduleResnapshot() {
    _resnapTimer?.cancel();
    _resnapTimer = Timer(const Duration(milliseconds: 250), () async {
      final client = ref.read(bridgeClientProvider);
      if (client == null || _disposed) return;
      try {
        final snap = await client.getSnapshot();
        if (!_disposed) state = AsyncData(snap);
      } catch (_) {
        // Stream stays authoritative; a genuine drop reconnects separately.
      }
    });
  }

  void _handleDrop() {
    if (_disposed) return;
    _scheduleReconnect();
  }

  /// Tear the socket down and queue another attempt. [immediate] skips the
  /// backoff for a reconnect we triggered ourselves (resume, silence timeout)
  /// rather than one caused by a failure.
  void _scheduleReconnect({bool immediate = false}) {
    _watchdog?.cancel();
    _watchdog = null;
    _sub?.cancel();
    _sub = null;
    _ch?.sink.close();
    _ch = null;
    if (_disposed) return;
    if (immediate) {
      _attempts = 0;
    } else {
      _attempts++;
    }
    final delay = immediate
        ? Duration.zero
        : Duration(seconds: _attempts.clamp(1, 8));
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, _reconnectRun);
  }

  Future<void> _reconnectRun() async {
    if (_disposed) return;
    // Re-read the active connection rather than giving up on the cached one.
    // Returning early here used to end the retry loop permanently: no further
    // attempt was ever scheduled, so one unlucky tick left the app offline for
    // the rest of the session.
    _conn ??= ref.read(bridgeClientProvider)?.connection;
    if (_conn == null) {
      _scheduleReconnect();
      return;
    }
    try {
      state = AsyncData(await _connectAndSeed());
    } catch (_) {
      _scheduleReconnect(); // keep trying with backoff
    }
  }

  /// Manual pull-to-refresh — an immediate authoritative refetch.
  Future<void> refresh() async {
    final client = ref.read(bridgeClientProvider);
    if (client == null) return;
    try {
      state = AsyncData(await client.getSnapshot());
    } catch (_) {
      // Leave the last good state in place.
    }
  }

  void _teardown() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _resnapTimer?.cancel();
    _watchdog?.cancel();
    _lifecycle?.dispose();
    _lifecycle = null;
    _sub?.cancel();
    _ch?.sink.close();
  }
}

