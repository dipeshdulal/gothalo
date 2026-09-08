import 'package:freezed_annotation/freezed_annotation.dart';

part 'connection.freezed.dart';
part 'connection.g.dart';

/// How the bridge connection was established — drives the settings UI and,
/// later, whether the bearer can be re-minted (QR re-pair) or must be re-typed.
enum ConnectionSource { manual, paired }

/// Everything needed to reach one bridge: a base URL and a bearer token.
///
/// This is the single seam the whole app talks to the bridge through. Today it
/// is populated manually from the settings screen; once the backend's QR
/// pairing lands (`POST /pair {code, device_name, fcm_token}` → per-device
/// bearer), the scanner screen populates the exact same shape. Nothing
/// downstream — [BridgeClient], the providers, the UI — needs to know which.
///
/// The [bearer] is a secret: it is persisted in `flutter_secure_storage`, never
/// in the drift database. Only the non-secret fields ([name], [baseUrl],
/// [deviceId]) are safe to store in plain SQLite as a saved profile.
@freezed
sealed class Connection with _$Connection {
  const Connection._();

  const factory Connection({
    /// Stable local id for this saved connection (also the secure-storage key
    /// under which the bearer is stored).
    required String id,

    /// User-facing label, e.g. "Mac Studio".
    required String name,

    /// e.g. `https://<host>.<tailnet>.ts.net` — no trailing slash.
    required String baseUrl,

    /// Bearer token for `Authorization: Bearer <token>`. Secret.
    required String bearer,

    /// Per-device id the backend will assign at pairing time; null until then.
    String? deviceId,
    @Default(ConnectionSource.manual) ConnectionSource source,
  }) = _Connection;

  factory Connection.fromJson(Map<String, dynamic> json) =>
      _$ConnectionFromJson(json);

  /// An optional **dev** server seeded on first launch, so the inbox can be
  /// tested before pairing exists — WITHOUT any secret in tracked source.
  ///
  /// The bearer comes only from a `--dart-define=DEV_BEARER=…` supplied at build
  /// time (read from the gitignored `.gothalo-dev.json`); with no define it
  /// returns null and the app simply starts at an empty server list. The base
  /// URL default is the public production URL from `docs/API.md`, not a secret.
  ///
  /// Run with, e.g.:
  ///   flutter run --dart-define=DEV_BEARER=$(jq -r .bearer .gothalo-dev.json) \
  ///               --dart-define=DEV_BASE_URL=$(jq -r .baseUrl .gothalo-dev.json)
  static Connection? devSeed() {
    const bearer = String.fromEnvironment('DEV_BEARER');
    if (bearer.isEmpty) return null;
    const baseUrl = String.fromEnvironment('DEV_BASE_URL', defaultValue: '');
    if (baseUrl.isEmpty) return null;
    const name = String.fromEnvironment('DEV_NAME', defaultValue: 'Dev server');
    return const Connection(id: 'dev', name: name, baseUrl: baseUrl, bearer: bearer);
  }

  bool get isValid =>
      baseUrl.startsWith('http') && Uri.tryParse(baseUrl) != null;

  /// The non-secret half, safe to persist in the drift `profiles` table.
  Map<String, Object?> toProfileRow() => {
    'id': id,
    'name': name,
    'base_url': baseUrl,
    'device_id': deviceId,
    'source': source.name,
  };
}
