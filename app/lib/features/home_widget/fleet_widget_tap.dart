import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';

import 'fleet_widget_store.dart';

/// Where a widget tap lands. The widget answers one question — "does anything
/// need me?" — so it opens the screen that answers it in full, across every
/// server, rather than guessing at a single agent.
const kWidgetRoute = '/priority';

/// The tap URI's host, as set by `FleetWidgetProvider.kt`. Matched rather than
/// assumed so a second widget added later can route somewhere else without this
/// silently swallowing it.
const _kWidgetHost = 'widget';

/// Taps on the widget while the app is already running.
///
/// A separate path from the cold start below because Android delivers the two
/// differently: a running app gets `onNewIntent` (the activity is `singleTop`),
/// a dead one gets the launch intent.
Stream<Uri?> get fleetWidgetTaps =>
    fleetWidgetSupported ? HomeWidget.widgetClicked : const Stream.empty();

/// The widget tap that launched the app, if that is what launched it.
Future<Uri?> initialFleetWidgetTap() async {
  if (!fleetWidgetSupported) return null;
  try {
    return await HomeWidget.initiallyLaunchedFromHomeWidget();
  } catch (e) {
    debugPrint('gothalo: widget launch check failed: $e');
    return null;
  }
}

/// Whether [uri] is this widget asking for the Priority screen.
bool isFleetWidgetTap(Uri? uri) => uri != null && uri.host == _kWidgetHost;
