import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/features/herdr_actions.dart';

/// Herdr does not validate a tab label at all: `tab.rename` with `""` is
/// accepted and blanks the name (verified against the live socket, herdr 0.8.0
/// / protocol 19). So every rule about what a tab may be called lives here, and
/// a nameless tab is a state the app must simply never create — from a phone
/// there is nothing left to long-press your way back from.
void main() {
  test('a plain name passes through', () {
    expect(normalizeTabLabel('api server'), 'api server');
  });

  test('surrounding whitespace is trimmed, not sent', () {
    expect(normalizeTabLabel('  api server \n'), 'api server');
  });

  test('empty and whitespace-only are rejected', () {
    expect(normalizeTabLabel(''), isNull);
    expect(normalizeTabLabel('   '), isNull);
    expect(normalizeTabLabel('\t\n '), isNull);
  });

  test('a name is rejected only once trimming cannot save it', () {
    // Trim first, then measure: padding a name to the limit is not the user
    // asking for a name that long.
    final atLimit = 'x' * maxTabLabelLength;
    expect(normalizeTabLabel(atLimit), atLimit);
    expect(normalizeTabLabel('  $atLimit  '), atLimit);
    expect(normalizeTabLabel('x' * (maxTabLabelLength + 1)), isNull);
  });
}
