// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'bridge_providers.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// A [BridgeClient] for the active connection, rebuilt automatically whenever
/// [ActiveConnection] changes (settings save today, QR pairing later). Returns
/// null while there is no connection configured.

@ProviderFor(bridgeClient)
final bridgeClientProvider = BridgeClientProvider._();

/// A [BridgeClient] for the active connection, rebuilt automatically whenever
/// [ActiveConnection] changes (settings save today, QR pairing later). Returns
/// null while there is no connection configured.

final class BridgeClientProvider
    extends $FunctionalProvider<BridgeClient?, BridgeClient?, BridgeClient?>
    with $Provider<BridgeClient?> {
  /// A [BridgeClient] for the active connection, rebuilt automatically whenever
  /// [ActiveConnection] changes (settings save today, QR pairing later). Returns
  /// null while there is no connection configured.
  BridgeClientProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'bridgeClientProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$bridgeClientHash();

  @$internal
  @override
  $ProviderElement<BridgeClient?> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  BridgeClient? create(Ref ref) {
    return bridgeClient(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(BridgeClient? value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<BridgeClient?>(value),
    );
  }
}

String _$bridgeClientHash() => r'e1c3737ce4724fede6f0defd96faf6e46f0bb21d';

/// Learn (and remember) which bridge the active server actually is.
///
/// A push carries only the sending bridge's `server_id`, so the app needs the
/// reverse mapping to attribute an alert, route a notification tap, or act on a
/// tray button — all of which can happen with no UI running. Asking `GET /info`
/// whenever we connect is what populates it, including for servers that were
/// paired before the bridge reported an identity at all.
///
/// Best-effort: an older bridge 404s and the server simply stays unattributed.

@ProviderFor(serverIdentity)
final serverIdentityProvider = ServerIdentityProvider._();

/// Learn (and remember) which bridge the active server actually is.
///
/// A push carries only the sending bridge's `server_id`, so the app needs the
/// reverse mapping to attribute an alert, route a notification tap, or act on a
/// tray button — all of which can happen with no UI running. Asking `GET /info`
/// whenever we connect is what populates it, including for servers that were
/// paired before the bridge reported an identity at all.
///
/// Best-effort: an older bridge 404s and the server simply stays unattributed.

final class ServerIdentityProvider
    extends $FunctionalProvider<AsyncValue<String?>, String?, FutureOr<String?>>
    with $FutureModifier<String?>, $FutureProvider<String?> {
  /// Learn (and remember) which bridge the active server actually is.
  ///
  /// A push carries only the sending bridge's `server_id`, so the app needs the
  /// reverse mapping to attribute an alert, route a notification tap, or act on a
  /// tray button — all of which can happen with no UI running. Asking `GET /info`
  /// whenever we connect is what populates it, including for servers that were
  /// paired before the bridge reported an identity at all.
  ///
  /// Best-effort: an older bridge 404s and the server simply stays unattributed.
  ServerIdentityProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'serverIdentityProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$serverIdentityHash();

  @$internal
  @override
  $FutureProviderElement<String?> $createElement($ProviderPointer pointer) =>
      $FutureProviderElement(pointer);

  @override
  FutureOr<String?> create(Ref ref) {
    return serverIdentity(ref);
  }
}

String _$serverIdentityHash() => r'7c7753d615d9c26d8e3efe3527ef080348454eff';
