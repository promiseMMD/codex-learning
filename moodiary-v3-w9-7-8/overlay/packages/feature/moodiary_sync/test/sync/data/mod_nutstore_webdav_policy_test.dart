import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_sync/src/data/nutstore_webdav_policy.dart';

void main() {
  test('recognizes the exact Nutstore host, not lookalikes', () {
    expect(NutstoreWebDavPolicy.isOfficialHost(
      'https://dav.jianguoyun.com/dav/'), true);
    expect(NutstoreWebDavPolicy.isOfficialHost(
      'https://dav.jianguoyun.com.evil.example/dav/'), false);
    expect(NutstoreWebDavPolicy.isOfficialHost(
      'https://example.com/dav/'), false);
  });

  test('official server is HTTPS, /dav/, and contains no URL secrets', () {
    expect(NutstoreWebDavPolicy.isSupportedEndpoint(
      'https://dav.jianguoyun.com/dav/'), true);
    expect(NutstoreWebDavPolicy.isSupportedEndpoint(
      'https://dav.jianguoyun.com/dav/Moodiary/'), true);
    for (final bad in [
      'http://dav.jianguoyun.com/dav/',
      'https://dav.jianguoyun.com/other/',
      'https://user:password@dav.jianguoyun.com/dav/',
      'https://dav.jianguoyun.com:8443/dav/',
      'https://dav.jianguoyun.com/dav/?token=secret',
      'https://dav.jianguoyun.com/dav/#secret',
    ]) {
      expect(NutstoreWebDavPolicy.isSupportedEndpoint(bad), false,
          reason:bad);
      expect(() => NutstoreWebDavPolicy.requireSafeEndpoint(bad),
          throwsFormatException, reason:bad);
    }
  });

  test('other WebDAV providers are not restricted to Nutstore host', () {
    expect(() => NutstoreWebDavPolicy.requireSafeEndpoint(
      'http://192.168.1.3:8090/webdav/'), returnsNormally);
    expect(() => NutstoreWebDavPolicy.guardObjectListing(
      'https://example.com/webdav/', 751), returnsNormally);
    expect(() => NutstoreWebDavPolicy.guardUploadSize(
      'https://example.com/webdav/', 700000000), returnsNormally);
  });

  test('750 entry uncertainty fails closed, never pretends a full listing', () {
    const endpoint=NutstoreWebDavPolicy.officialUrl;
    expect(() => NutstoreWebDavPolicy.guardObjectListing(endpoint,749),
        returnsNormally);
    expect(() => NutstoreWebDavPolicy.guardObjectListing(endpoint,750),
        throwsStateError);
    expect(() => NutstoreWebDavPolicy.guardObjectListing(endpoint,1000),
        throwsStateError);
  });

  test('default 500M per-file upload boundary is checked before transfer', () {
    const endpoint=NutstoreWebDavPolicy.officialUrl;
    expect(() => NutstoreWebDavPolicy.guardUploadSize(endpoint,500000000),
        returnsNormally);
    expect(() => NutstoreWebDavPolicy.guardUploadSize(endpoint,500000001),
        throwsStateError);
  });
}
