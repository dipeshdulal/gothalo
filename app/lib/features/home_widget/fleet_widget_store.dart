import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';

import 'fleet_counts.dart';

/// The one Android `AppWidgetProvider` this app ships. Fully qualified because
/// `home_widget` resolves the receiver by class name.
const kFleetWidgetProvider = 'com.dipeshdulal.gothalo.FleetWidgetProvider';

/// Keys in the widget's shared store. **These are a contract with Kotlin**
/// (`FleetWidgetProvider.kt`) — see `docs/CONTRACT-android-widget.md`. A key the
/// Kotlin side does not know about simply renders as its default, silently, so
/// they only ever change in both places at once.
const kKeyNeedsYou = 'fleet.needs_you';
const kKeyWorking = 'fleet.working';
const kKeyDone = 'fleet.done';
const kKeyTotal = 'fleet.total';
const kKeyServers = 'fleet.servers';
const kKeyLines = 'fleet.lines';

/// Unix ms, **as a string**. The platform channel widens a Dart `int` to a Java
/// `Long` only once it no longer fits an `Int`, so a millisecond timestamp
/// lands as a `Long` and a zero lands as an `Int` — and `getLong` on a key
/// written by `putInt` throws. A string has one type on both sides.
const kKeyUpdatedAt = 'fleet.updated_at';

/// Internal to Dart: the per-server buckets [FleetCounts.merge] runs over.
/// Kotlin never reads it.
const _kKeyBuckets = 'fleet.buckets';

/// Lines are one string because the store holds primitives only; the Kotlin
/// side splits on this. `\n` rather than a fancier separator so a glance at the
/// stored value is readable.
const kLineSeparator = '\n';

/// The URI a widget tap launches the app with. Its host is what
/// `main.dart` routes on.
const kWidgetTapUri = 'gothalo://widget/priority';

/// Whether the home-screen widget exists on this platform at all.
///
/// `home_widget` registers Android and iOS only, so on web every call would
/// throw `MissingPluginException`. There is no iOS widget extension in this
/// repo (see the contract doc), so Android is the whole of it today.
bool get fleetWidgetSupported =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Read the per-server buckets back out of the widget store.
///
/// The store, not a database: the background push isolate has no Riverpod
/// container and the app has no other place both isolates already share. It
/// holds only counts that came from the bridge seconds ago, so a wipe costs one
/// refresh.
Future<Map<String, ServerCounts>> readFleetBuckets() async {
  if (!fleetWidgetSupported) return {};
  try {
    return decodeBuckets(await HomeWidget.getWidgetData<String>(_kKeyBuckets));
  } catch (e) {
    debugPrint('gothalo: widget read failed: $e');
    return {};
  }
}

/// Write [buckets], merge them, and repaint the widget.
///
/// [known] is every currently-saved server id; buckets for anything else are
/// dropped, so deleting a server takes its agents off the widget rather than
/// leaving them there until the next reinstall.
Future<void> publishFleetBuckets(
  Map<String, ServerCounts> buckets, {
  required Set<String> known,
}) async {
  if (!fleetWidgetSupported) return;
  final kept = {
    for (final e in buckets.entries)
      if (known.contains(e.key)) e.key: e.value,
  };
  // A paired server we have not read yet still counts as a server, so the
  // widget can tell "nothing needs you" from "no bridges paired".
  for (final id in known) {
    kept.putIfAbsent(id, () => const ServerCounts.empty(''));
  }
  final fleet = FleetCounts.merge(kept);
  try {
    await Future.wait([
      HomeWidget.saveWidgetData<String>(_kKeyBuckets, encodeBuckets(kept)),
      HomeWidget.saveWidgetData<int>(kKeyNeedsYou, fleet.needsYou),
      HomeWidget.saveWidgetData<int>(kKeyWorking, fleet.working),
      HomeWidget.saveWidgetData<int>(kKeyDone, fleet.done),
      HomeWidget.saveWidgetData<int>(kKeyTotal, fleet.total),
      HomeWidget.saveWidgetData<int>(kKeyServers, fleet.servers),
      HomeWidget.saveWidgetData<String>(
        kKeyLines,
        fleet.lines.join(kLineSeparator),
      ),
      HomeWidget.saveWidgetData<String>(kKeyUpdatedAt, '${fleet.updatedAt}'),
    ]);
    await HomeWidget.updateWidget(qualifiedAndroidName: kFleetWidgetProvider);
  } catch (e) {
    // A widget that fails to update is worth a log and nothing more — it must
    // never take down a snapshot refresh or a push.
    debugPrint('gothalo: widget publish failed: $e');
  }
}

/// How long an answer from [fleetWidgetInstalled] is trusted for.
///
/// The check gates the live snapshot path, which fires on every `/events`
/// frame, so it must not be a channel round-trip each time. Short enough that
/// adding the widget starts feeding it within a snapshot or two.
const _installProbeTtl = Duration(seconds: 30);

bool? _installed;
DateTime? _installedAt;

/// Whether the user has actually placed the widget on a home screen.
///
/// Every refresh path checks this first. The widget does no polling of its own
/// (`updatePeriodMillis` is 0), so the only cost it can impose on a phone is the
/// work the app does to feed it — and a widget nobody added should cost zero.
/// Errors answer "no" for the same reason.
Future<bool> fleetWidgetInstalled() async {
  if (!fleetWidgetSupported) return false;
  final at = _installedAt;
  if (_installed != null &&
      at != null &&
      DateTime.now().difference(at) < _installProbeTtl) {
    return _installed!;
  }
  try {
    final widgets = await HomeWidget.getInstalledWidgets();
    _installed = widgets.any(
      (w) => (w.androidClassName ?? '').endsWith('FleetWidgetProvider'),
    );
  } catch (e) {
    debugPrint('gothalo: widget probe failed: $e');
    _installed = false;
  }
  _installedAt = DateTime.now();
  return _installed!;
}

/// Forget the cached probe — used by tests, and by anything that has reason to
/// believe the home screen just changed.
@visibleForTesting
void resetFleetWidgetProbe() {
  _installed = null;
  _installedAt = null;
}
