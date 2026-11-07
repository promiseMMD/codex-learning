// W8.2 private, bounded, expiring staging for authenticated LAN image uploads.
//
// Uploads remain in an application-owned temporary directory. Never promote
// them to Moodiary's permanent image library until a later CAS-guarded diary
// attachment transaction is ready. This module is intentionally not an HTTP
// endpoint, and cannot modify the diary database.
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'mod_lan_image_policy.dart';

typedef ModLanImageDecodeValidator = Future<void> Function(
  File path,
  String detectedMime,
);

class ModLanStagedImage {
  final String id;
  final String owner;
  final String mime;
  final String sha256Hex;
  final int size;
  final File file;
  final DateTime expiresAt;

  const ModLanStagedImage({
    required this.id,
    required this.owner,
    required this.mime,
    required this.sha256Hex,
    required this.size,
    required this.file,
    required this.expiresAt,
  });
}

class ModLanImageStaging {
  static const maxPending = 8;
  static const maxConcurrent = 2;
  static const lifetime = Duration(minutes: 15);

  final Directory privateCacheRoot;
  final ModLanImageDecodeValidator verifyDecodedImage;
  final DateTime Function() _clock;
  final Random _rng;
  final Map<String, ModLanStagedImage> _pending = {};
  final Set<String> _leased = {};
  int _inFlight = 0;
  bool _closed = false;

  ModLanImageStaging({
    required this.privateCacheRoot,
    required this.verifyDecodedImage,
    DateTime Function()? clock,
    Random? secureRandom,
  }) : _clock = clock ?? DateTime.now,
       _rng = secureRandom ?? Random.secure();

  int get pendingCount => _pending.length;

  String _id() => List<int>.generate(24, (_) => _rng.nextInt(256))
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();

  static Never _bad(int status, String code) =>
      throw ModLanImagePolicyException(status, code);

  Future<void> _erase(ModLanStagedImage item) async {
    final dir = item.file.parent;
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  Future<void> sweep() async {
    final expired = _pending.values.where((v) =>
        !_leased.contains(v.id) && !_clock().isBefore(v.expiresAt)).toList();
    for (final value in expired) {
      _pending.remove(value.id);
      await _erase(value);
    }
  }

  Future<ModLanStagedImage> accept({
    required String ownerSession,
    required String contentType,
    required int? contentLength,
    required Stream<List<int>> body,
  }) async {
    if (_closed) _bad(503, 'upload_service_stopped');
    if (ownerSession.isEmpty) _bad(401, 'pairing_required');

    // Refuse forbidden MIME or size before writing any request bytes.
    final meter = ModLanImageIntake(
      contentType: contentType,
      contentLength: contentLength,
    );
    await sweep();
    if (_inFlight >= maxConcurrent) _bad(429, 'too_many_active_uploads');
    if (_pending.length + _inFlight >= maxPending) {
      _bad(429, 'too_many_pending_uploads');
    }

    ++_inFlight;
    Directory? stagingDir;
    try {
      // Each request gets an isolated, unguessable directory under a
      // caller-supplied APPLICATION-PRIVATE cache root.
      await privateCacheRoot.create(recursive: true);
      stagingDir = await privateCacheRoot.createTemp('lan-staged-');
      final file = File(stagingDir.path + '/image');
      final sink = file.openWrite();
      try {
        await for (final chunk in body) {
          meter.addChunk(chunk);
          sink.add(chunk);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      meter.finish();
      // Mandatory real decoder validation is supplied by the platform
      // adapter and must check original dimensions and decode at low res.
      await verifyDecodedImage(file, meter.declaredMime);
      final digest = await sha256.bind(file.openRead()).first;
      final item = ModLanStagedImage(
        id: _id(),
        owner: ownerSession,
        mime: meter.declaredMime,
        sha256Hex: digest.toString(),
        size: meter.received,
        file: file,
        expiresAt: _clock().add(lifetime),
      );
      _pending[item.id] = item;
      return item;
    } catch (_) {
      if (stagingDir != null && await stagingDir.exists()) {
        await stagingDir.delete(recursive: true);
      }
      rethrow;
    } finally {
      --_inFlight;
    }
  }

  /// Authorize a future committed diary transaction to use an image.
  /// Only the same paired session may consume it. Failed CAS leaves the
  /// file in staging for explicit retry, never reports upload success.
  Future<T> consumeWith<T>({
    required String id,
    required String ownerSession,
    required Future<T> Function(ModLanStagedImage staged) commit,
  }) async {
    if (_closed) _bad(503, 'upload_service_stopped');
    final item = _pending[id];
    if (item == null || !_clock().isBefore(item.expiresAt)) {
      _bad(404, 'staged_image_not_found');
    }
    if (item.owner != ownerSession) _bad(403, 'upload_session_mismatch');
    if (!_leased.add(id)) _bad(409, 'staged_image_busy');
    try {
      final result = await commit(item);
      _pending.remove(id);
      await _erase(item);
      return result;
    } finally {
      _leased.remove(id);
    }
  }

  Future<void> revokeSession(String ownerSession) async {
    final targets = _pending.values.where((v) =>
        v.owner == ownerSession && !_leased.contains(v.id)).toList();
    for (final v in targets) {
      _pending.remove(v.id);
      await _erase(v);
    }
  }

  /// Stop accepting new requests; remove all remaining private drafts.
  Future<void> close() async {
    if (_inFlight != 0 || _leased.isNotEmpty) {
      _bad(409, 'upload_operation_in_progress');
    }
    _closed = true;
    for (final item in _pending.values.toList()) {
      _pending.remove(item.id);
      await _erase(item);
    }
  }
}
