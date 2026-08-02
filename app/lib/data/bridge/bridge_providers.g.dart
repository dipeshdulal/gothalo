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

String _$bridgeClientHash() => r'483d92fc9f1bd7821cccc4b8fc0b76cae1ae512d';
