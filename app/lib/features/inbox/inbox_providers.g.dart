// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'inbox_providers.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
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

@ProviderFor(SnapshotController)
final snapshotControllerProvider = SnapshotControllerProvider._();

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
final class SnapshotControllerProvider
    extends $AsyncNotifierProvider<SnapshotController, Snapshot> {
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
  SnapshotControllerProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'snapshotControllerProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$snapshotControllerHash();

  @$internal
  @override
  SnapshotController create() => SnapshotController();
}

String _$snapshotControllerHash() =>
    r'96649046796abf3fc986abbdc5a3de59467e6428';

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

abstract class _$SnapshotController extends $AsyncNotifier<Snapshot> {
  FutureOr<Snapshot> build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<AsyncValue<Snapshot>, Snapshot>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AsyncValue<Snapshot>, Snapshot>,
              AsyncValue<Snapshot>,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
