// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'suggestions_providers.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// A cheap fingerprint of how the snapshot currently sees one pane: its agent's
/// status, or `none` for a plain pane, or `gone` once the pane has closed.
///
/// This exists so [paneSuggestions] can be **event-driven rather than polled**.
/// The snapshot is already pushed over `WS /events`, and Riverpod only
/// propagates a change when this string actually differs — so an agent going
/// working → idle refetches the suggestions once, and the twenty heartbeat and
/// unrelated-pane frames in between cost nothing.
///
/// Status is the right trigger because it is when the answers change: an agent
/// that just finished a turn is an agent that has just written the files the
/// "Review changes" chip is about.

@ProviderFor(paneSignal)
final paneSignalProvider = PaneSignalFamily._();

/// A cheap fingerprint of how the snapshot currently sees one pane: its agent's
/// status, or `none` for a plain pane, or `gone` once the pane has closed.
///
/// This exists so [paneSuggestions] can be **event-driven rather than polled**.
/// The snapshot is already pushed over `WS /events`, and Riverpod only
/// propagates a change when this string actually differs — so an agent going
/// working → idle refetches the suggestions once, and the twenty heartbeat and
/// unrelated-pane frames in between cost nothing.
///
/// Status is the right trigger because it is when the answers change: an agent
/// that just finished a turn is an agent that has just written the files the
/// "Review changes" chip is about.

final class PaneSignalProvider
    extends $FunctionalProvider<String, String, String>
    with $Provider<String> {
  /// A cheap fingerprint of how the snapshot currently sees one pane: its agent's
  /// status, or `none` for a plain pane, or `gone` once the pane has closed.
  ///
  /// This exists so [paneSuggestions] can be **event-driven rather than polled**.
  /// The snapshot is already pushed over `WS /events`, and Riverpod only
  /// propagates a change when this string actually differs — so an agent going
  /// working → idle refetches the suggestions once, and the twenty heartbeat and
  /// unrelated-pane frames in between cost nothing.
  ///
  /// Status is the right trigger because it is when the answers change: an agent
  /// that just finished a turn is an agent that has just written the files the
  /// "Review changes" chip is about.
  PaneSignalProvider._({
    required PaneSignalFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'paneSignalProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$paneSignalHash();

  @override
  String toString() {
    return r'paneSignalProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $ProviderElement<String> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  String create(Ref ref) {
    final argument = this.argument as String;
    return paneSignal(ref, argument);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(String value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<String>(value),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is PaneSignalProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$paneSignalHash() => r'3b50a200bb5f8e50d7b9477f7266d680ae840b51';

/// A cheap fingerprint of how the snapshot currently sees one pane: its agent's
/// status, or `none` for a plain pane, or `gone` once the pane has closed.
///
/// This exists so [paneSuggestions] can be **event-driven rather than polled**.
/// The snapshot is already pushed over `WS /events`, and Riverpod only
/// propagates a change when this string actually differs — so an agent going
/// working → idle refetches the suggestions once, and the twenty heartbeat and
/// unrelated-pane frames in between cost nothing.
///
/// Status is the right trigger because it is when the answers change: an agent
/// that just finished a turn is an agent that has just written the files the
/// "Review changes" chip is about.

final class PaneSignalFamily extends $Family
    with $FunctionalFamilyOverride<String, String> {
  PaneSignalFamily._()
    : super(
        retry: null,
        name: r'paneSignalProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  /// A cheap fingerprint of how the snapshot currently sees one pane: its agent's
  /// status, or `none` for a plain pane, or `gone` once the pane has closed.
  ///
  /// This exists so [paneSuggestions] can be **event-driven rather than polled**.
  /// The snapshot is already pushed over `WS /events`, and Riverpod only
  /// propagates a change when this string actually differs — so an agent going
  /// working → idle refetches the suggestions once, and the twenty heartbeat and
  /// unrelated-pane frames in between cost nothing.
  ///
  /// Status is the right trigger because it is when the answers change: an agent
  /// that just finished a turn is an agent that has just written the files the
  /// "Review changes" chip is about.

  PaneSignalProvider call(String pane) =>
      PaneSignalProvider._(argument: pane, from: this);

  @override
  String toString() => r'paneSignalProvider';
}

/// The one-tap actions worth offering for [pane] right now (`GET
/// /suggestions`).
///
/// Refetched when the screen opens and whenever [paneSignal] moves — never on a
/// timer. Combined with the bridge's own short per-pane cache, that keeps the
/// whole feature at roughly one Herdr round-trip per thing that actually
/// happened in the pane.
///
/// Never throws: the client already collapses "nothing to offer", "no such
/// pane" and "bridge too old" into an empty list, and a transport failure is
/// swallowed here. A row of chips is a convenience, and a convenience that can
/// put an error on the screen is not one.

@ProviderFor(paneSuggestions)
final paneSuggestionsProvider = PaneSuggestionsFamily._();

/// The one-tap actions worth offering for [pane] right now (`GET
/// /suggestions`).
///
/// Refetched when the screen opens and whenever [paneSignal] moves — never on a
/// timer. Combined with the bridge's own short per-pane cache, that keeps the
/// whole feature at roughly one Herdr round-trip per thing that actually
/// happened in the pane.
///
/// Never throws: the client already collapses "nothing to offer", "no such
/// pane" and "bridge too old" into an empty list, and a transport failure is
/// swallowed here. A row of chips is a convenience, and a convenience that can
/// put an error on the screen is not one.

final class PaneSuggestionsProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<PaneSuggestion>>,
          List<PaneSuggestion>,
          FutureOr<List<PaneSuggestion>>
        >
    with
        $FutureModifier<List<PaneSuggestion>>,
        $FutureProvider<List<PaneSuggestion>> {
  /// The one-tap actions worth offering for [pane] right now (`GET
  /// /suggestions`).
  ///
  /// Refetched when the screen opens and whenever [paneSignal] moves — never on a
  /// timer. Combined with the bridge's own short per-pane cache, that keeps the
  /// whole feature at roughly one Herdr round-trip per thing that actually
  /// happened in the pane.
  ///
  /// Never throws: the client already collapses "nothing to offer", "no such
  /// pane" and "bridge too old" into an empty list, and a transport failure is
  /// swallowed here. A row of chips is a convenience, and a convenience that can
  /// put an error on the screen is not one.
  PaneSuggestionsProvider._({
    required PaneSuggestionsFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'paneSuggestionsProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$paneSuggestionsHash();

  @override
  String toString() {
    return r'paneSuggestionsProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $FutureProviderElement<List<PaneSuggestion>> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<List<PaneSuggestion>> create(Ref ref) {
    final argument = this.argument as String;
    return paneSuggestions(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is PaneSuggestionsProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$paneSuggestionsHash() => r'a7aca30d71674f061054d6288c2017095e01aa35';

/// The one-tap actions worth offering for [pane] right now (`GET
/// /suggestions`).
///
/// Refetched when the screen opens and whenever [paneSignal] moves — never on a
/// timer. Combined with the bridge's own short per-pane cache, that keeps the
/// whole feature at roughly one Herdr round-trip per thing that actually
/// happened in the pane.
///
/// Never throws: the client already collapses "nothing to offer", "no such
/// pane" and "bridge too old" into an empty list, and a transport failure is
/// swallowed here. A row of chips is a convenience, and a convenience that can
/// put an error on the screen is not one.

final class PaneSuggestionsFamily extends $Family
    with $FunctionalFamilyOverride<FutureOr<List<PaneSuggestion>>, String> {
  PaneSuggestionsFamily._()
    : super(
        retry: null,
        name: r'paneSuggestionsProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  /// The one-tap actions worth offering for [pane] right now (`GET
  /// /suggestions`).
  ///
  /// Refetched when the screen opens and whenever [paneSignal] moves — never on a
  /// timer. Combined with the bridge's own short per-pane cache, that keeps the
  /// whole feature at roughly one Herdr round-trip per thing that actually
  /// happened in the pane.
  ///
  /// Never throws: the client already collapses "nothing to offer", "no such
  /// pane" and "bridge too old" into an empty list, and a transport failure is
  /// swallowed here. A row of chips is a convenience, and a convenience that can
  /// put an error on the screen is not one.

  PaneSuggestionsProvider call(String pane) =>
      PaneSuggestionsProvider._(argument: pane, from: this);

  @override
  String toString() => r'paneSuggestionsProvider';
}
