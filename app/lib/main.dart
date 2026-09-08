import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/connection/server_switch.dart';
import 'core/router.dart';
import 'core/theme.dart';
import 'data/bridge/bridge_providers.dart';
import 'features/inbox/inbox_providers.dart';
import 'features/push/push_payload.dart';
import 'features/push/push_service.dart';
import 'features/push/web_tap_io.dart'
    if (dart.library.js_interop) 'features/push/web_tap_web.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Firebase is optional at boot: without google-services.json this throws, and
  // we simply run without push rather than crash. Push activates once Firebase
  // is configured.
  try {
    // Native reads google-services.json / the iOS plist at boot; web
    // initialises later in PushController against the active bridge's
    // project (GET /firebase-config), so a generic build pairs anywhere.
    // Passing null on native keeps that automatic path exactly as it was.
    if (!kIsWeb) {
      await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(
        firebaseMessagingBackgroundHandler,
      );
    }
  } catch (e) {
    debugPrint('Firebase not configured — push disabled: $e');
  }
  runApp(const ProviderScope(child: GothaloApp()));
}

/// Lets code outside the widget tree raise a message — a notification tap is
/// handled by a listener, not by a screen, so it has no BuildContext of its own.
final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// gothalo — a self-hosted mobile remote for Herdr. Dark-first, follows the OS.
class GothaloApp extends ConsumerStatefulWidget {
  const GothaloApp({super.key});

  @override
  ConsumerState<GothaloApp> createState() => _GothaloAppState();
}

class _GothaloAppState extends ConsumerState<GothaloApp> {
  @override
  void initState() {
    super.initState();
    pendingDeepLink.addListener(_handleDeepLink);
    // Web taps arrive from the service worker (launch URL or message stream)
    // rather than the plugin channels; this queues them the same way.
    initWebNotificationTaps();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Start push (permission, token, listeners); no-ops if Firebase is absent.
      ref.read(pushControllerProvider);
      _handleDeepLink(); // a cold-start deep-link may already be queued
    });
  }

  /// Navigate to the agent a tapped notification is about.
  ///
  /// The alert names the bridge it came from, which need not be the server the
  /// app is currently pointed at — so this switches servers first when they
  /// differ. Without that, tapping an alert from one machine opened whatever
  /// pane happened to share that id on another, or nothing at all.
  void _handleDeepLink() {
    final target = pendingDeepLink.value;
    if (target == null || target.pane.isEmpty) return;
    pendingDeepLink.value = null;
    unawaited(_navigateTo(target));
  }

  Future<void> _navigateTo(DeepLinkTarget target) async {
    final routable = await activateServer(ref, target.serverId);
    if (!mounted) return;
    if (!routable) {
      // The push named a bridge this phone has no record of. Opening the pane
      // anyway would run it against whatever server is active, and pane ids are
      // not unique across servers — so it could show, and act on, a real but
      // unrelated agent on the wrong machine. Say so instead.
      _showUnroutable(target.serverName);
      return;
    }
    // `prompt=1` asks the transcript to surface the blocked prompt's options
    // sheet unasked — a notification tap means the user is coming to answer.
    ref
        .read(routerProvider)
        .push('/transcript/${Uri.encodeComponent(target.pane)}?prompt=1');
  }

  void _showUnroutable(String serverName) {
    final who = serverName.isEmpty ? 'another server' : serverName;
    scaffoldMessengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 6),
          content: Text(
            "$who hasn't identified itself to this phone yet — update gothalo "
            'on it, then open it once here.',
          ),
        ),
      );
  }

  @override
  void dispose() {
    pendingDeepLink.removeListener(_handleDeepLink);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Learn which bridge each server is, so a push can be attributed to one.
    // WATCHED, not read once: at first frame the active connection is still
    // loading and the bridge client is null, and a read would cache that null
    // for the whole session — leaving every server unidentified and every
    // notification action unroutable.
    // Both are subscribed with listen, not watch: it holds them alive and lets
    // them recompute when the active bridge changes, WITHOUT rebuilding the
    // whole app every time a snapshot arrives.
    //
    // Learn which bridge each server is, so a push can be attributed to one.
    // Subscribed rather than read once: at first frame the active connection is
    // still loading and the bridge client is null, and a one-shot read would
    // cache that null for the session — leaving every server unidentified and
    // every notification action unroutable.
    ref.listen(serverIdentityProvider, (_, _) {});
    // Bring the live `/events` connection up with the app rather than with a
    // screen. It used to be created by whichever surface first watched it, so
    // the app could sit on the servers list indefinitely with no socket at all —
    // and everything downstream of it looked frozen. With no server configured
    // this settles into an error state and starts nothing, which is correct.
    ref.listen(snapshotControllerProvider, (_, _) {});
    return MaterialApp.router(
      title: 'gothalo',
      scaffoldMessengerKey: scaffoldMessengerKey,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      routerConfig: ref.watch(routerProvider),
      // No app-wide backdrop here: each screen paints its OWN opaque backdrop
      // via AppBackground, so pages slide as solid layers instead of showing
      // through one another during a transition. See AppBackground.
      //
      // Status-bar icons must read over the screen's backdrop. This is the one
      // place Theme is guaranteed valid for any screen (it runs inside the
      // MaterialApp), and it follows the theme's own brightness, which tracks
      // the OS since themeMode is system.
      builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: Theme.of(context).brightness == Brightness.dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        child: child!,
      ),
    );
  }
}
