// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'connection_providers.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// The encrypted key/value store for secrets (bearers + the active-server id).

@ProviderFor(secureStorage)
final secureStorageProvider = SecureStorageProvider._();

/// The encrypted key/value store for secrets (bearers + the active-server id).

final class SecureStorageProvider
    extends
        $FunctionalProvider<
          FlutterSecureStorage,
          FlutterSecureStorage,
          FlutterSecureStorage
        >
    with $Provider<FlutterSecureStorage> {
  /// The encrypted key/value store for secrets (bearers + the active-server id).
  SecureStorageProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'secureStorageProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$secureStorageHash();

  @$internal
  @override
  $ProviderElement<FlutterSecureStorage> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  FlutterSecureStorage create(Ref ref) {
    return secureStorage(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(FlutterSecureStorage value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<FlutterSecureStorage>(value),
    );
  }
}

String _$secureStorageHash() => r'0cd1b80f91784467390034386f925a0be155bfbd';

/// Writes/reads servers: non-secret fields to drift, bearer to secure storage.
/// The single place server state is mutated, so the list and active connection
/// stay consistent.

@ProviderFor(serversRepository)
final serversRepositoryProvider = ServersRepositoryProvider._();

/// Writes/reads servers: non-secret fields to drift, bearer to secure storage.
/// The single place server state is mutated, so the list and active connection
/// stay consistent.

final class ServersRepositoryProvider
    extends
        $FunctionalProvider<
          ServersRepository,
          ServersRepository,
          ServersRepository
        >
    with $Provider<ServersRepository> {
  /// Writes/reads servers: non-secret fields to drift, bearer to secure storage.
  /// The single place server state is mutated, so the list and active connection
  /// stay consistent.
  ServersRepositoryProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'serversRepositoryProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$serversRepositoryHash();

  @$internal
  @override
  $ProviderElement<ServersRepository> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  ServersRepository create(Ref ref) {
    return serversRepository(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(ServersRepository value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<ServersRepository>(value),
    );
  }
}

String _$serversRepositoryHash() => r'2f100640f3cf17c12a18f6cfa27c8300eb6ba014';

/// The id of the selected server, persisted in secure storage.

@ProviderFor(ActiveServerId)
final activeServerIdProvider = ActiveServerIdProvider._();

/// The id of the selected server, persisted in secure storage.
final class ActiveServerIdProvider
    extends $AsyncNotifierProvider<ActiveServerId, String?> {
  /// The id of the selected server, persisted in secure storage.
  ActiveServerIdProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'activeServerIdProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$activeServerIdHash();

  @$internal
  @override
  ActiveServerId create() => ActiveServerId();
}

String _$activeServerIdHash() => r'a58c7a6a3e7d2212aff2aa3bafd7d3da42bda965';

/// The id of the selected server, persisted in secure storage.

abstract class _$ActiveServerId extends $AsyncNotifier<String?> {
  FutureOr<String?> build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<AsyncValue<String?>, String?>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AsyncValue<String?>, String?>,
              AsyncValue<String?>,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

/// The list of saved servers (non-secret), reactive off drift, with the active
/// one flagged. Drives the servers screen.

@ProviderFor(servers)
final serversProvider = ServersProvider._();

/// The list of saved servers (non-secret), reactive off drift, with the active
/// one flagged. Drives the servers screen.

final class ServersProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<ServerSummary>>,
          List<ServerSummary>,
          Stream<List<ServerSummary>>
        >
    with
        $FutureModifier<List<ServerSummary>>,
        $StreamProvider<List<ServerSummary>> {
  /// The list of saved servers (non-secret), reactive off drift, with the active
  /// one flagged. Drives the servers screen.
  ServersProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'serversProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$serversHash();

  @$internal
  @override
  $StreamProviderElement<List<ServerSummary>> $createElement(
    $ProviderPointer pointer,
  ) => $StreamProviderElement(pointer);

  @override
  Stream<List<ServerSummary>> create(Ref ref) {
    return servers(ref);
  }
}

String _$serversHash() => r'65cf9d8e0c6c20670bc10f703944e68551154019';

/// The active [Connection] (with its bearer), assembled from the active id +
/// its drift profile + its secure-storage bearer. Null when no server is
/// selected. Everything that talks to a bridge watches this.

@ProviderFor(activeConnection)
final activeConnectionProvider = ActiveConnectionProvider._();

/// The active [Connection] (with its bearer), assembled from the active id +
/// its drift profile + its secure-storage bearer. Null when no server is
/// selected. Everything that talks to a bridge watches this.

final class ActiveConnectionProvider
    extends
        $FunctionalProvider<
          AsyncValue<Connection?>,
          Connection?,
          FutureOr<Connection?>
        >
    with $FutureModifier<Connection?>, $FutureProvider<Connection?> {
  /// The active [Connection] (with its bearer), assembled from the active id +
  /// its drift profile + its secure-storage bearer. Null when no server is
  /// selected. Everything that talks to a bridge watches this.
  ActiveConnectionProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'activeConnectionProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$activeConnectionHash();

  @$internal
  @override
  $FutureProviderElement<Connection?> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<Connection?> create(Ref ref) {
    return activeConnection(ref);
  }
}

String _$activeConnectionHash() => r'981f9a2990167df93245aab0a212e97a3d9fab7f';
