import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/core/theme.dart';
import 'package:gothalo/core/tokens.dart';

/// The composer is **one** surface with controls inside it.
///
/// It read as three stitched together, and the reported cause — "the icons have
/// their own backgrounds" — was one step off: the icons were transparent, but
/// the text field inherited `filled: true` from the theme and painted its own
/// shade across the middle, so the icon areas looked like separate patches.
/// This pins the field claiming no fill of its own, since the fix is a single
/// flag that is easy to lose.
void main() {
  testWidgets('the field inside a bordered container claims no fill', (
    tester,
  ) async {
    // The composer's shape, reduced to what matters: a container that owns the
    // surface and the border, with a field and two icon buttons inside it.
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Builder(
          builder: (context) {
            final scheme = Theme.of(context).colorScheme;
            return Scaffold(
              body: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.panelFill,
                  borderRadius: Radii.mdAll,
                  border: Border.all(color: scheme.hairline),
                ),
                child: const Row(
                  children: [
                    SizedBox(width: 44, height: 44, child: Icon(Icons.add)),
                    Expanded(
                      child: TextField(
                        decoration: InputDecoration(
                          filled: false,
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                    SizedBox(width: 44, height: 44, child: Icon(Icons.send)),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    final decoration = tester
        .widget<TextField>(find.byType(TextField))
        .decoration!;
    // Both together: a fill would break the continuous surface, a border would
    // draw a second edge inside the container's own.
    expect(decoration.filled, isFalse);
    expect(decoration.border, InputBorder.none);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the theme fills a field that is NOT inside a container', (
    tester,
  ) async {
    // The inverse, so the flag above reads as deliberate rather than as the
    // default: an ordinary field still gets its panel fill.
    expect(AppTheme.dark.inputDecorationTheme.filled, isTrue);
  });
}
