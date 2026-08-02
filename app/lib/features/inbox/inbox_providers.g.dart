// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'inbox_providers.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// The live inbox, fetched from `/snapshot`.
///
/// `build()` runs the first fetch and re-runs automatically if the active
/// connection changes (via [bridgeClientProvider]). [refresh] backs
/// pull-to-refresh. dio does the fetching here; persistence (drift) is a
/// separate concern handled by [inboxHistory] and the FCM path.

@ProviderFor(SnapshotController)
final snapshotControllerProvider = SnapshotControllerProvider._();

/// The live inbox, fetched from `/snapshot`.
///
/// `build()` runs the first fetch and re-runs automatically if the active
/// connection changes (via [bridgeClientProvider]). [refresh] backs
/// pull-to-refresh. dio does the fetching here; persistence (drift) is a
/// separate concern handled by [inboxHistory] and the FCM path.
final class SnapshotControllerProvider
    extends $AsyncNotifierProvider<SnapshotController, Snapshot> {
  /// The live inbox, fetched from `/snapshot`.
  ///
  /// `build()` runs the first fetch and re-runs automatically if the active
  /// connection changes (via [bridgeClientProvider]). [refresh] backs
  /// pull-to-refresh. dio does the fetching here; persistence (drift) is a
  /// separate concern handled by [inboxHistory] and the FCM path.
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
    r'0e0d7137210f3c95eae3f20612368ab3fcc6a1c9';

/// The live inbox, fetched from `/snapshot`.
///
/// `build()` runs the first fetch and re-runs automatically if the active
/// connection changes (via [bridgeClientProvider]). [refresh] backs
/// pull-to-refresh. dio does the fetching here; persistence (drift) is a
/// separate concern handled by [inboxHistory] and the FCM path.

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
