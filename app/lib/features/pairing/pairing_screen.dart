import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/theme.dart';
import '../../core/tokens.dart';

import '../../core/connection/connection_providers.dart';
import '../push/push_service.dart';
import 'camera_release_io.dart'
    if (dart.library.js_interop) 'camera_release_web.dart';
import 'pairing_service.dart';

/// Scan a pairing QR (`{"url":…,"code":…}`), redeem it for a per-device bearer,
/// and save it as the active connection so the flock loads against it.
class PairingScreen extends ConsumerStatefulWidget {
  const PairingScreen({super.key});

  @override
  ConsumerState<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends ConsumerState<PairingScreen> {
  final _scanner = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  final _deviceName = TextEditingController();
  bool _pairing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadDefaultName();
  }

  Future<void> _loadDefaultName() async {
    var name = 'My phone';
    try {
      if (Platform.isAndroid) {
        final info = await DeviceInfoPlugin().androidInfo;
        name = '${info.manufacturer} ${info.model}'.trim();
      } else if (Platform.isIOS) {
        final info = await DeviceInfoPlugin().iosInfo;
        name = info.name;
      }
    } catch (_) {
      // keep the fallback
    }
    if (mounted && _deviceName.text.isEmpty) _deviceName.text = name;
  }

  @override
  void dispose() {
    _scanner.dispose();
    // mobile_scanner's web implementation loses its MediaStream reference
    // without stopping the tracks, so the camera would stay on for the life of
    // the page. Harmless on native, where dispose() already released it.
    releaseCameraStreams();
    _deviceName.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_pairing) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null) continue;
      final payload = ConnectPayload.tryParse(raw);
      if (payload != null) {
        await _pair(payload);
        return;
      }
    }
  }

  Future<void> _pair(ConnectPayload payload) async {
    setState(() {
      _pairing = true;
      _error = null;
    });
    await _scanner.stop();
    try {
      final deviceName = _deviceName.text.trim().isEmpty
          ? 'My phone'
          : _deviceName.text.trim();
      // 1) Redeem the code for a bearer (network), sending this device's FCM
      // token so the bridge can push to it (empty if push isn't configured).
      final fcmToken = await ref.read(pushControllerProvider.future) ?? '';
      final connection = await ref
          .read(pairingServiceProvider)
          .pair(payload, deviceName: deviceName, fcmToken: fcmToken);
      // 2) Save it (deduped by URL) and make it active, using the live ref.
      final result = await ref.read(serversRepositoryProvider).save(connection);
      await ref.read(activeServerIdProvider.notifier).set(result.saved.id);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.existed
                ? '${result.saved.name} is already paired — refreshed ✓'
                : 'Paired with ${result.saved.name} 🎉',
          ),
        ),
      );
      context.go('/inbox');
    } catch (e) {
      // Never leave the overlay spinning — surface any failure and let the
      // user scan again.
      if (!mounted) return;
      setState(() {
        _pairing = false;
        _error = e is PairingException ? e.message : 'Pairing failed. $e';
      });
      await _scanner.start();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: AppTheme.scaffoldBase(Theme.of(context).brightness),
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text('Pair via QR'),
        actions: [
          IconButton(
            tooltip: 'Torch',
            onPressed: () => _scanner.toggleTorch(),
            icon: const Icon(Icons.flash_on),
          ),
          IconButton(
            tooltip: 'Flip camera',
            onPressed: () => _scanner.switchCamera(),
            icon: const Icon(Icons.cameraswitch),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _scanner,
            onDetect: _onDetect,
            errorBuilder: (context, error) => _CameraError(error: error),
          ),
          // Dim + framing window.
          const _ScanOverlay(),
          // Bottom sheet: instructions, device name, errors.
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              child: Container(
                margin: const EdgeInsets.all(16),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.96),
                  borderRadius: Radii.mdAll,
                  border: Border.all(color: scheme.hairline),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Run  gothalo pair  on the host and point the camera at '
                      'the QR it prints.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _deviceName,
                      // Border and density come from the theme.
                      decoration: const InputDecoration(
                        labelText: 'This device\'s name',
                        prefixIcon: Icon(Icons.smartphone),
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Icon(
                            Icons.error_outline,
                            color: scheme.error,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _error!,
                              style: TextStyle(color: scheme.error),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (_pairing)
            Container(
              color: Colors.black54,
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Pairing…', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A translucent scrim with a clear square "window" to aim the QR into.
class _ScanOverlay extends StatelessWidget {
  const _ScanOverlay();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = constraints.maxWidth * 0.7;
        return Center(
          child: Container(
            width: side,
            height: side,
            decoration: BoxDecoration(
              border: Border.all(
                color: Theme.of(context).colorScheme.primary,
                width: 3,
              ),
              borderRadius: BorderRadius.circular(20),
            ),
          ),
        );
      },
    );
  }
}

class _CameraError extends StatelessWidget {
  const _CameraError({required this.error});
  final MobileScannerException error;

  @override
  Widget build(BuildContext context) {
    final denied = error.errorCode == MobileScannerErrorCode.permissionDenied;
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.no_photography_outlined,
                color: Colors.white70,
                size: 56,
              ),
              const SizedBox(height: 16),
              Text(
                denied
                    ? 'Camera permission is needed to scan the pairing QR. '
                          'Enable it in Settings, then reopen this screen.'
                    : 'Couldn\'t start the camera.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
