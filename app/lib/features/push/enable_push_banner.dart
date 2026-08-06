import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'notification_permission_io.dart'
    if (dart.library.js_interop) 'notification_permission_web.dart';
import 'push_service.dart';

/// Offers to turn on push where the app cannot simply ask: iOS only honours a
/// web notification-permission request made inside a user gesture, so startup
/// code asking is silently refused and the user never sees a prompt. Shown
/// only on web while permission is still undecided; a tap routes a real
/// gesture into [PushController.enable].
class EnablePushBanner extends ConsumerStatefulWidget {
  const EnablePushBanner({super.key});

  @override
  ConsumerState<EnablePushBanner> createState() => _EnablePushBannerState();
}

class _EnablePushBannerState extends ConsumerState<EnablePushBanner> {
  bool _dismissed = false;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    if (_dismissed || !kIsWeb || webNotificationPermission != 'default') {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.secondaryContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            children: [
              Icon(
                Icons.notifications_active_outlined,
                size: 20,
                color: scheme.onSecondaryContainer,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Get notified when an agent needs you',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSecondaryContainer,
                  ),
                ),
              ),
              TextButton(
                onPressed: _busy ? null : _enable,
                child: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Enable'),
              ),
              IconButton(
                tooltip: 'Not now',
                onPressed: () => setState(() => _dismissed = true),
                icon: const Icon(Icons.close, size: 18),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _enable() async {
    setState(() => _busy = true);
    final ok = await ref.read(pushControllerProvider.notifier).enable();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _dismissed = true;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Notifications enabled 🎉'
              : 'Notifications stayed off — check the browser permission',
        ),
      ),
    );
  }
}
