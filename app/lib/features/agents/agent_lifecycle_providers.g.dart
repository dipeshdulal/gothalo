// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'agent_lifecycle_providers.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// The agent kinds the active server can actually launch (`GET
/// /agents/available`).
///
/// Fetched per server rather than held as a constant because "which agents
/// exist" is a fact about a particular machine: the same app talks to a laptop
/// with Claude only and a workstation with four agents installed. The bridge
/// discovers the set from Herdr's own catalog and the host's PATH, so this
/// list is the only thing the launch UI is allowed to offer.
///
/// Not kept alive: it is read when the launch sheet opens, and re-reading it
/// after installing an agent on the host is exactly the behaviour wanted.

@ProviderFor(availableAgents)
final availableAgentsProvider = AvailableAgentsProvider._();

/// The agent kinds the active server can actually launch (`GET
/// /agents/available`).
///
/// Fetched per server rather than held as a constant because "which agents
/// exist" is a fact about a particular machine: the same app talks to a laptop
/// with Claude only and a workstation with four agents installed. The bridge
/// discovers the set from Herdr's own catalog and the host's PATH, so this
/// list is the only thing the launch UI is allowed to offer.
///
/// Not kept alive: it is read when the launch sheet opens, and re-reading it
/// after installing an agent on the host is exactly the behaviour wanted.

final class AvailableAgentsProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<AvailableAgent>>,
          List<AvailableAgent>,
          FutureOr<List<AvailableAgent>>
        >
    with
        $FutureModifier<List<AvailableAgent>>,
        $FutureProvider<List<AvailableAgent>> {
  /// The agent kinds the active server can actually launch (`GET
  /// /agents/available`).
  ///
  /// Fetched per server rather than held as a constant because "which agents
  /// exist" is a fact about a particular machine: the same app talks to a laptop
  /// with Claude only and a workstation with four agents installed. The bridge
  /// discovers the set from Herdr's own catalog and the host's PATH, so this
  /// list is the only thing the launch UI is allowed to offer.
  ///
  /// Not kept alive: it is read when the launch sheet opens, and re-reading it
  /// after installing an agent on the host is exactly the behaviour wanted.
  AvailableAgentsProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'availableAgentsProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$availableAgentsHash();

  @$internal
  @override
  $FutureProviderElement<List<AvailableAgent>> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<List<AvailableAgent>> create(Ref ref) {
    return availableAgents(ref);
  }
}

String _$availableAgentsHash() => r'd1551cbe91b316adce8dd5bc549ced043df79f02';
