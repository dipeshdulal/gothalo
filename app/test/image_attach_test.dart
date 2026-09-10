import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/features/attach/image_attach.dart';

/// Mounts the strip the way both screens do: pinned above whatever bar started
/// the upload.
Future<void> _pumpStatus(
  WidgetTester tester,
  ImageAttachController controller,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [ImageUploadStatus(controller: controller)],
        ),
      ),
    ),
  );
}

void main() {
  group('attachPathText', () {
    // A bare path stops at the first space — for a shell reading a command line
    // and for an agent reading a prompt alike — so a path with whitespace has to
    // arrive quoted or it names a file that doesn't exist.
    test('quotes a path containing whitespace', () {
      expect(
        attachPathText('/Users/d/My Projects/.gothalo/images/a.png'),
        '"/Users/d/My Projects/.gothalo/images/a.png"',
      );
    });

    test('leaves an ordinary path alone', () {
      expect(
        attachPathText('/repo/.gothalo/images/20260805-142530-9f86d081.png'),
        '/repo/.gothalo/images/20260805-142530-9f86d081.png',
      );
    });
  });

  group('ImageUploadStatus', () {
    testWidgets('shows nothing while idle', (tester) async {
      final controller = ImageAttachController();
      addTearDown(controller.dispose);
      await _pumpStatus(tester, controller);

      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.textContaining('Uploading'), findsNothing);
    });

    // Determinate, with real numbers: a phone pushing megabytes over a tailnet
    // is slow enough that a bare spinner is indistinguishable from a hang.
    testWidgets('reports progress in megabytes', (tester) async {
      final controller = _StubController()
        ..setUploading(sent: 512 * 1024, total: 2 * 1024 * 1024);
      addTearDown(controller.dispose);
      await _pumpStatus(tester, controller);

      expect(find.text('Uploading image… 0.5MB of 2.0MB'), findsOneWidget);
      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, closeTo(0.25, 0.001));
    });

    // The strip names what is going out — a 20MB deck takes long enough that
    // "image" would read as the wrong upload.
    testWidgets('says document when a document is uploading', (tester) async {
      final controller = _StubController(kind: 'document')
        ..setUploading(sent: 512 * 1024, total: 2 * 1024 * 1024);
      addTearDown(controller.dispose);
      await _pumpStatus(tester, controller);

      expect(find.text('Uploading document… 0.5MB of 2.0MB'), findsOneWidget);
    });

    // The failure latches in place — a snackbar disappears while the user is
    // still deciding whether the upload is worth another try.
    testWidgets('holds a failure until it is dismissed', (tester) async {
      final controller = ImageAttachController();
      addTearDown(controller.dispose);
      controller.fail('That image is too large for the bridge (10MB limit).');
      await _pumpStatus(tester, controller);

      expect(find.textContaining('too large'), findsOneWidget);

      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pump();
      expect(find.textContaining('too large'), findsNothing);
      expect(controller.isIdle, isTrue);
    });
  });
}

/// Drives the controller into the mid-upload state the widget test needs. The
/// real path there runs through `image_picker` and a live bridge, neither of
/// which a widget test has — but the strip's job is to render the numbers, and
/// those are what this pins.
class _StubController extends ImageAttachController {
  _StubController({String kind = 'image'}) : _kind = kind;

  final String _kind;
  bool _uploading = false;
  int _sent = 0;
  int _total = 0;

  void setUploading({required int sent, required int total}) {
    _uploading = true;
    _sent = sent;
    _total = total;
    notifyListeners();
  }

  @override
  String get kind => _kind;
  @override
  bool get uploading => _uploading;
  @override
  int get sent => _sent;
  @override
  int get total => _total;
  @override
  bool get isIdle => !_uploading && error == null;
}
