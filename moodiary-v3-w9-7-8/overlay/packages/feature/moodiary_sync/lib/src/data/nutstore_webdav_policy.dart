// Moodiary V3 W9.7.8 — Nutstore WebDAV compatibility guards.
// This is a conservative fail-closed provider policy, not a claim that
// the underlying Rust client handles all remote HTTP pagination or quotas.
final class NutstoreWebDavPolicy {
  NutstoreWebDavPolicy._();

  static const officialUrl = 'https://dav.jianguoyun.com/dav/';
  static const maxSingleListing = 750;
  static const maxDefaultUploadBytes = 500 * 1000 * 1000;

  static Uri? _parse(String text) => Uri.tryParse(text.trim());

  static bool isOfficialHost(String text) {
    final uri = _parse(text);
    return uri != null && uri.host.toLowerCase() == 'dav.jianguoyun.com';
  }

  static bool isSupportedEndpoint(String text) {
    final uri = _parse(text);
    return uri != null &&
      uri.scheme == 'https' &&
      uri.host.toLowerCase() == 'dav.jianguoyun.com' &&
      (!uri.hasPort || uri.port == 443) &&
      uri.userInfo.isEmpty &&
      !uri.hasQuery && !uri.hasFragment &&
      uri.path.startsWith('/dav/');
  }

  /// Non-Nutstore WebDAV endpoints are unaffected.
  static void requireSafeEndpoint(String text) {
    if (isOfficialHost(text) && !isSupportedEndpoint(text)) {
      throw const FormatException(
        'Nutstore WebDAV requires the official HTTPS /dav/ endpoint, '
        'without embedded credentials, query or fragment.',
      );
    }
  }

  /// Nutstore states that a single WebDAV listing may contain only 750
  /// entries. The Rust adapter does not expose a pagination-complete flag.
  /// At or above the boundary, abort rather than treating a partial listing
  /// as complete (which could otherwise prompt destructive sync actions).
  static void guardObjectListing(String endpoint, int count) {
    if (isOfficialHost(endpoint) && count >= maxSingleListing) {
      throw StateError(
        'Nutstore WebDAV returned at least 750 objects; completeness '
        'is unverified. Abort sync until paginated listing is supported.',
      );
    }
  }

  /// Official help center states 500M is the default WebDAV upload limit.
  /// Private-cloud / account-specific overrides are not assumed.
  static void guardUploadSize(String endpoint, int bytes) {
    if (isOfficialHost(endpoint) &&
        bytes > maxDefaultUploadBytes) {
      throw StateError(
        'Nutstore default WebDAV per-file upload limit is 500M; '
        'split the archive or use a smaller individual object.',
      );
    }
  }
}
