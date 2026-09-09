import 'package:flutter_test/flutter_test.dart';
import 'package:gothalo/data/bridge/bridge_client.dart';

/// A browser stops some bridge calls before they leave the tab, and reports
/// every one of them identically: status 0, no headers, no reason. The app has
/// to name the rule anyway, because the two rules are fixed in completely
/// different places — one is a config line on the bridge, the other is a
/// different URL on the phone. Naming the wrong one sends people to edit a
/// file that cannot help them.
void main() {
  BrowserBlock? blockFor(String? page, String base) =>
      BridgeClient.blockFor(pageOrigin: page, baseUrl: base);

  group('mixed content', () {
    // The regression this exists for: the hosted app is https, and the README
    // hands out a plain-http tailnet address for GOTHALO_ADDR. That pairing is
    // blocked on scheme alone, and no allowed_origins entry changes it.
    test('an https page reaching an http bridge is mixed content, not CORS', () {
      expect(
        blockFor('https://dipeshdulal.github.io', 'http://100.88.0.122:8787'),
        BrowserBlock.mixedContent,
      );
    });

    test('holds even for an origin the bridge would allow', () {
      // Same host, so CORS has no objection — the scheme alone decides.
      expect(
        blockFor('https://box.tail.ts.net', 'http://box.tail.ts.net:8787'),
        BrowserBlock.mixedContent,
      );
    });

    test('an http page reaching an http bridge is not mixed content', () {
      // Only https pages are held to this rule; cross-origin still applies.
      expect(
        blockFor('http://localhost:1234', 'http://box.tail.ts.net:8787'),
        BrowserBlock.cors,
      );
    });
  });

  group('cors', () {
    test('a cross-origin https bridge is the CORS case', () {
      expect(
        blockFor('https://dipeshdulal.github.io', 'https://box.tail.ts.net:8787'),
        BrowserBlock.cors,
      );
    });

    test('same origin is never blocked', () {
      expect(blockFor('https://box.tail.ts.net', 'https://box.tail.ts.net'), isNull);
    });

    test('a differing port is still a different origin', () {
      expect(
        blockFor('https://box.tail.ts.net', 'https://box.tail.ts.net:8787'),
        BrowserBlock.cors,
      );
    });
  });

  group('no verdict', () {
    test('off the web there is no page origin and so no browser rule', () {
      expect(blockFor(null, 'http://box.tail.ts.net:8787'), isNull);
    });

    test('an unparseable target yields no verdict rather than a wrong one', () {
      // A hand-typed address that is not http(s) tells us nothing; better to
      // fall through to the ordinary network message than to invent a cause.
      expect(blockFor('https://dipeshdulal.github.io', 'not a url'), isNull);
      expect(blockFor('https://dipeshdulal.github.io', 'ftp://box/'), isNull);
    });
  });
}
