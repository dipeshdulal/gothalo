import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/connection/server_switch.dart';
import 'core/router.dart';
import 'core/theme.dart';
import 'data/bridge/bridge_providers.dart';
import 'features/push/push_payload.dart';
import 'features/push/push_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Firebase is optional at boot: without google-services.json this throws, and
  // we simply run without push rather than crash. Push activates once Firebase
  // is configured.
  try {
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  } catch (e) {
    debugPrint('Firebase not configured — push disabled: $e');
  }
  runApp(const ProviderScope(child: GothaloApp()));
}

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
    await activateServer(ref, target.serverId);
    if (!mounted) return;
    ref
        .read(routerProvider)
        .push('/transcript/${Uri.encodeComponent(target.pane)}');
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
    ref.watch(serverIdentityProvider);
    return MaterialApp.router(
      title: 'gothalo',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      routerConfig: ref.watch(routerProvider),
      // No app-wide backdrop here: each screen paints its OWN opaque backdrop
      // via AppBackground, so pages slide as solid layers instead of showing
      // through one another during a transition. See AppBackground.
    );
  }
}
