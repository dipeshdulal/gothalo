import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:image_picker/image_picker.dart';

import '../../data/bridge/bridge_client.dart';

/// Pick an image, upload it to a pane, hand back the path the bridge wrote —
/// the one copy of that flow, shared by the transcript composer and the
/// terminal's accessory bar.
///
/// The path IS the attachment. Coding agents read an image when handed a file
/// path, so once the bytes are inside the pane's own working directory (the
/// bridge's `POST /image` puts them there — see docs/CONTRACT-image.md) there is
/// nothing further to negotiate: whatever is running in that pane just needs to
/// be told where. Which is also why this is worth sharing between two screens
/// that otherwise have nothing in common: the *destination* differs (a text
/// composer, a PTY stream), the pick-upload-report half does not.
///
/// **It deliberately never sends.** The caller receives the path and inserts it
/// wherever the user is typing; the prompt around it ("why is this button
/// misaligned?") is the point, and that is the user's to write.
class ImageAttachController extends ChangeNotifier {
  final ImagePicker _picker = ImagePicker();

  bool _uploading = false;
  int _sent = 0;
  int _total = 0;
  String? _error;
  bool _disposed = false;

  /// True from the moment bytes start going out until the path comes back.
  bool get uploading => _uploading;

  /// Bytes sent / total, for the determinate progress bar. A phone pushing a
  /// few megabytes over a tailnet is slow enough that a bare spinner is
  /// indistinguishable from a hang, which is the one thing this must not look
  /// like.
  int get sent => _sent;
  int get total => _total;

  /// The last failure, latched until dismissed or superseded — a snackbar
  /// disappears while the user is still deciding whether to retry.
  String? get error => _error;

  /// Nothing to show: no upload running and no failure standing.
  bool get isIdle => !_uploading && _error == null;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void dismissError() {
    if (_error == null) return;
    _error = null;
    _notify();
  }

  /// Surface a failure that happened outside the upload itself — the terminal
  /// uses it when the path arrives but the socket that would type it is down.
  void fail(String message) {
    _uploading = false;
    _error = message;
    _notify();
  }

  /// Pick from [source], upload to [pane], then hand the absolute path to
  /// [onPath]. One upload at a time, so the progress bar always describes the
  /// upload the user is watching.
  ///
  /// Nothing here throws: every failure lands in [error] for the host screen to
  /// show, because the two callers both display it the same way.
  Future<void> attach({
    required BridgeClient? client,
    required String pane,
    required ImageSource source,
    required void Function(String path) onPath,
  }) async {
    if (client == null || _uploading) return;

    final XFile? picked;
    try {
      picked = await _picker.pickImage(source: source);
    } on PlatformException catch (e) {
      // Denied permission, or no camera. The plugin's own message names which.
      fail(e.message ?? 'Could not open the picker.');
      return;
    } catch (e) {
      // Anything else — a missing platform implementation, an interop
      // failure — must surface too: swallowed, the button just silently does
      // nothing, which is exactly how a build problem hid here once.
      fail('Picker failed: $e');
      return;
    }
    if (picked == null || _disposed) return; // cancelled

    final bytes = await picked.readAsBytes();
    if (_disposed) return;
    _uploading = true;
    _sent = 0;
    _total = bytes.length;
    _error = null;
    _notify();

    try {
      final drop = await client.uploadImage(
        pane,
        bytes,
        onProgress: (sent, total) {
          _sent = sent;
          // A chunked send reports total as -1; keep the byte count we measured
          // rather than letting the bar go indeterminate mid-upload.
          if (total > 0) _total = total;
          _notify();
        },
      );
      if (_disposed) return;
      _uploading = false;
      _notify();
      onPath(drop.path);
    } catch (e) {
      if (_disposed) return;
      _uploading = false;
      _error = e is BridgeException ? e.message : '$e';
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}

/// Ask where the image comes from. Two sources, because the two real uses are
/// different: a screenshot already in the camera roll ("this screen is wrong"),
/// and something in front of you right now (a whiteboard, a monitor, a device
/// showing the bug).
///
/// [onPick] is called from inside the tap handler, immediately after the sheet
/// pops, rather than by the caller awaiting this future: on the web the picker
/// is a synthetic click on a file input, which Safari only honors while the
/// tap's user activation is still live. Awaiting the sheet's pop animation
/// first spends it — the tap then closes the sheet and silently nothing opens
/// (the iOS PWA symptom).
Future<void> showImageSourceSheet(
  BuildContext context, {
  required void Function(ImageSource source) onPick,
}) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Photo library'),
            subtitle: const Text('A screenshot you already took'),
            onTap: () {
              Navigator.pop(sheetContext);
              onPick(ImageSource.gallery);
            },
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Camera'),
            subtitle: const Text('Shoot a screen or whiteboard'),
            onTap: () {
              Navigator.pop(sheetContext);
              onPick(ImageSource.camera);
            },
          ),
        ],
      ),
    ),
  );
}

/// The dropped path as it should be typed — quoted when it contains whitespace,
/// because an agent (or a shell) reading a bare path stops at the first space.
String attachPathText(String path) =>
    path.contains(RegExp(r'\s')) ? '"$path"' : path;

/// The upload strip: a determinate progress bar while bytes are going out, or a
/// failure that stays put until dismissed. Nothing at all when [controller] is
/// idle, so hosts can keep it unconditionally in their layout.
///
/// Determinate on purpose. The upload crosses a tailnet from a phone, which can
/// genuinely take tens of seconds for a few megabytes; against a bare spinner
/// that is indistinguishable from a hung request, and the user's next move
/// (wait, or give up and retry) depends entirely on telling those two apart.
///
/// The failure does not use a snackbar for the mirror-image reason: it vanishes
/// on a timer, and "is the tailnet down or was that image just too big?" is a
/// question people re-read.
class ImageUploadStatus extends StatelessWidget {
  const ImageUploadStatus({super.key, required this.controller});

  final ImageAttachController controller;

  static String _mb(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (controller.isIdle) return const SizedBox.shrink();

        final scheme = Theme.of(context).colorScheme;
        final uploading = controller.uploading;
        final sent = controller.sent;
        final total = controller.total;
        final failed = !uploading && controller.error != null;

        return Container(
          width: double.infinity,
          color: failed ? scheme.errorContainer : scheme.surfaceContainerHigh,
          padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
          child: Row(
            children: [
              Icon(
                failed ? Icons.error_outline : Icons.upload_outlined,
                size: 16,
                color: failed
                    ? scheme.onErrorContainer
                    : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: failed
                    ? Text(
                        controller.error!,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onErrorContainer,
                        ),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            total > 0
                                ? 'Uploading image… ${_mb(sent)} of ${_mb(total)}'
                                : 'Uploading image…',
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 5),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              minHeight: 3,
                              // Null (indeterminate) only before the first
                              // progress callback, so the bar never sits frozen
                              // at zero.
                              value: total > 0 && sent > 0 ? sent / total : null,
                            ),
                          ),
                        ],
                      ),
              ),
              if (failed)
                IconButton(
                  tooltip: 'Dismiss',
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  onPressed: controller.dismissError,
                  icon: Icon(Icons.close, color: scheme.onErrorContainer),
                ),
            ],
          ),
        );
      },
    );
  }
}
