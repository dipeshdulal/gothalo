// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'push_service.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// Owns the push lifecycle: notification permission, the FCM token, foreground
/// rendering, and (re)registering the token with the active bridge. Its value
/// is the current FCM token (null if unavailable), which the pairing flow reads
/// to send as `fcm_token`.

@ProviderFor(PushController)
final pushControllerProvider = PushControllerProvider._();

/// Owns the push lifecycle: notification permission, the FCM token, foreground
/// rendering, and (re)registering the token with the active bridge. Its value
/// is the current FCM token (null if unavailable), which the pairing flow reads
/// to send as `fcm_token`.
final class PushControllerProvider
    extends $AsyncNotifierProvider<PushController, String?> {
  /// Owns the push lifecycle: notification permission, the FCM token, foreground
  /// rendering, and (re)registering the token with the active bridge. Its value
  /// is the current FCM token (null if unavailable), which the pairing flow reads
  /// to send as `fcm_token`.
  PushControllerProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'pushControllerProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$pushControllerHash();

  @$internal
  @override
  PushController create() => PushController();
}

String _$pushControllerHash() => r'bc01eebabe38908460de53a4d15385edda5d21c1';

/// Owns the push lifecycle: notification permission, the FCM token, foreground
/// rendering, and (re)registering the token with the active bridge. Its value
/// is the current FCM token (null if unavailable), which the pairing flow reads
/// to send as `fcm_token`.

abstract class _$PushController extends $AsyncNotifier<String?> {
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
