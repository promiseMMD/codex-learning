import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../overlay/mobile/lib/app/home/mod_lan_image_policy.dart';
import '../overlay/mobile/lib/app/home/mod_lan_image_staging.dart';

void verify(bool condition, String label) {
  if (!condition) throw StateError('W8 staging test failed: $label');
}

Future<void> rejects(Future<dynamic> Function() run, int status,
    String code) async {
  try {
    await run();
  } on ModLanImagePolicyException catch (error) {
    verify(error.status == status && error.code == code,
        'expected $status/$code but received $error');
    return;
  }
  throw StateError('expected $status/$code error');
}

List<int> png() => [
      0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10,
      0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52,
      0, 0, 3, 0, 0, 0, 2, 0,
      ...List<int>.filled(64, 0),
    ];

Stream<List<int>> pieces(List<int> bytes) async* {
  yield bytes.sublist(0, 3);
  yield bytes.sublist(3, 27);
  yield bytes.sublist(27);
}

void main() async {
  final root = await Directory.systemTemp.createTemp('w8-stage-spec-');
  var now = DateTime.utc(2026, 11, 7);
  var decodeCalls = 0;
  final queue = ModLanImageStaging(
    privateCacheRoot: Directory(root.path + '/private'),
    clock: () => now,
    verifyDecodedImage: (file, mime) async {
      decodeCalls++;
      verify(await file.exists(), 'decoder sees private staged file');
      verify(mime == 'image/png', 'decoder sees verified MIME');
    },
  );
  final bytes = png();
  try {
    final uploaded = await queue.accept(
      ownerSession: 'paired-1',
      contentType: 'image/png',
      contentLength: bytes.length,
      body: pieces(bytes),
    );
    verify(decodeCalls == 1, 'must call actual image decoder callback');
    verify(uploaded.size == bytes.length, 'meter counts actual stream bytes');
    verify(uploaded.sha256Hex == sha256.convert(bytes).toString(),
        'hash covers complete staged file');
    verify(uploaded.id.length == 48, 'unguessable random identifier');
    verify(await uploaded.file.exists(), 'file is staged');
    verify(queue.pendingCount == 1, 'upload is not promoted to diary');

    await rejects(() => queue.consumeWith<int>(
      id: uploaded.id,
      ownerSession: 'paired-2',
      commit: (_) async => 3,
    ), 403, 'upload_session_mismatch');
    verify(queue.pendingCount == 1, 'cross-session attempt keeps file');

    try {
      await queue.consumeWith<void>(
        id: uploaded.id, ownerSession: 'paired-1',
        commit: (_) async => throw StateError('stale_revision'),
      );
      throw StateError('CAS failure not raised');
    } on StateError catch (error) {
      verify(error.message == 'stale_revision', 'expected test CAS failure');
    }
    verify(await uploaded.file.exists(), 'failed CAS does not destroy draft');

    final result = await queue.consumeWith<int>(
      id: uploaded.id,
      ownerSession: 'paired-1',
      commit: (item) async {
        verify(await item.file.exists(), 'CAS sees valid staged file');
        return 42;
      },
    );
    verify(result == 42, 'CAS callback result returned');
    verify(queue.pendingCount == 0, 'successful CAS removes draft');
    verify(!await uploaded.file.exists(), 'staged file deleted after commit');
    await rejects(() => queue.consumeWith<void>(
      id: uploaded.id, ownerSession: 'paired-1', commit: (_) async {},
    ), 404, 'staged_image_not_found');

    await rejects(() => queue.accept(
      ownerSession: 'paired-1', contentType: 'image/png',
      contentLength: bytes.length + 2, body: pieces(bytes),
    ), 422, 'image_incomplete');
    verify(queue.pendingCount == 0, 'truncated request cleaned');

    await rejects(() => queue.accept(
      ownerSession: 'paired-1', contentType: 'image/png',
      contentLength: bytes.length - 1, body: pieces(bytes),
    ), 413, 'image_length_exceeded');
    verify(queue.pendingCount == 0, 'overlong request cleaned');

    final keep = await queue.accept(
      ownerSession:'paired-1', contentType:'image/png',
      contentLength: bytes.length, body: pieces(bytes),
    );
    final remove = await queue.accept(
      ownerSession:'paired-2', contentType:'image/png',
      contentLength: bytes.length, body: pieces(bytes),
    );
    await queue.revokeSession('paired-1');
    verify(!await keep.file.exists(), 'revoke paired session clears drafts');
    verify(await remove.file.exists(), 'revoke does not affect other session');

    now = now.add(const Duration(minutes: 16));
    await queue.sweep();
    verify(!await remove.file.exists(), 'TTL removes expired staged images');

    final finalItem = await queue.accept(
      ownerSession: 'paired-1', contentType: 'image/png',
      contentLength: bytes.length, body: pieces(bytes),
    );
    await queue.close();
    verify(!await finalItem.file.exists(), 'shutdown cleans uncommitted image');
    await rejects(() => queue.accept(
      ownerSession: 'paired-1', contentType:'image/png',
      contentLength: bytes.length, body: pieces(bytes),
    ), 503, 'upload_service_stopped');

    print('W8 staging: stream bounds, digest, CAS, owner, TTL and cleanup passed');
  } finally {
    await root.delete(recursive: true);
  }
}
