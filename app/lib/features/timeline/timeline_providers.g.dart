// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'timeline_providers.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// The active server's recent agent activity, newest first.
///
/// `autoDispose` (the default) is load-bearing: the refresh timer below is
/// scoped to the provider's life, so closing the screen stops the polling
/// outright. A phone should not be waking a bridge for a screen nobody is
/// looking at.

@ProviderFor(activityTimeline)
final activityTimelineProvider = ActivityTimelineProvider._();

/// The active server's recent agent activity, newest first.
///
/// `autoDispose` (the default) is load-bearing: the refresh timer below is
/// scoped to the provider's life, so closing the screen stops the polling
/// outright. A phone should not be waking a bridge for a screen nobody is
/// looking at.

final class ActivityTimelineProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<TimelineEntry>>,
          List<TimelineEntry>,
          FutureOr<List<TimelineEntry>>
        >
    with
        $FutureModifier<List<TimelineEntry>>,
        $FutureProvider<List<TimelineEntry>> {
  /// The active server's recent agent activity, newest first.
  ///
  /// `autoDispose` (the default) is load-bearing: the refresh timer below is
  /// scoped to the provider's life, so closing the screen stops the polling
  /// outright. A phone should not be waking a bridge for a screen nobody is
  /// looking at.
  ActivityTimelineProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'activityTimelineProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$activityTimelineHash();

  @$internal
  @override
  $FutureProviderElement<List<TimelineEntry>> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<List<TimelineEntry>> create(Ref ref) {
    return activityTimeline(ref);
  }
}

String _$activityTimelineHash() => r'75ddc040f55e478723dc63c8d609cb6dadbc742a';
