import 'dart:convert';
import 'dart:io';

import '../overlay/mobile/lib/app/home/mod_lan_image_http.dart';
import '../overlay/mobile/lib/app/home/mod_lan_image_policy.dart';
import '../overlay/mobile/lib/app/home/mod_lan_image_staging.dart';

List<int> samplePng() => <int>[
  0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10,
  0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52,
  0, 0, 0, 2, 0, 0, 0, 2,
  ...List<int>.filled(32, 0),
];

Future<void> main() async {
  final privateRoot = await Directory.systemTemp.createTemp('w8-http-test-');
  final queue = ModLanImageStaging(
    privateCacheRoot: Directory('${privateRoot.path}/upload'),
    verifyDecodedImage: (file, mime) async {
      if (mime != 'image/png' || !await file.exists()) {
        throw StateError('invalid staged image passed to decoder');
      }
    },
  );
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final host = 'http://127.0.0.1:${server.port}';
  final calls = <String>[];
  final listen = server.listen((request) async {
    try {
      final identity = request.headers.value('x-test-session');
      final csrf = request.headers.value('x-test-csrf');
      final origin = request.headers.value(HttpHeaders.originHeader);
      if (identity != 'paired' || csrf != 'trusted-token' || origin != host) {
        request.response.statusCode = 403;
        request.response.write(jsonEncode({'error':'not_authorized'}));
      } else {
        calls.add('authorized');
        final image = await ModLanImageHttp.accept(
          request: request,
          authorizedSessionId: identity!,
          staging: queue,
        );
        request.response.statusCode = 201;
        request.response.write(jsonEncode({
          'id': image.id, 'sha256': image.sha256Hex, 'size': image.size,
          'state': 'staged_not_attached',
        }));
      }
    } on ModLanImagePolicyException catch (e) {
      request.response.statusCode = e.status;
      request.response.write(jsonEncode({'error': e.code}));
    } finally {
      await request.response.close();
    }
  });

  Future<({int status, Map<String,dynamic> body})> post(
    String mime, List<int> bytes, {
    String? session='paired',
    String? token='trusted-token',
    String? origin,
    String? encoding,
  }) async {
    final client = HttpClient();
    try {
      final rq = await client.postUrl(Uri.parse('$host/api/media/staged'));
      rq.headers.contentType=ContentType.parse(mime);
      rq.headers.set('x-test-session',session ?? '');
      rq.headers.set('x-test-csrf',token ?? '');
      rq.headers.set(HttpHeaders.originHeader,origin ?? host);
      if (encoding!=null) {
        rq.headers.set(HttpHeaders.contentEncodingHeader,encoding);
      }
      rq.contentLength=bytes.length;
      rq.add(bytes);
      final response=await rq.close();
      final body=jsonDecode(await utf8.decoder.bind(response).join())
          as Map<String,dynamic>;
      return (status:response.statusCode,body:body);
    } finally {
      client.close(force:true);
    }
  }

  try {
    final source=samplePng();
    final unauthorized=await post('image/png',source,token:'wrong');
    if(unauthorized.status!=403 || queue.pendingCount!=0) {
      throw StateError('unpaired browser must never stage image');
    }
    final valid=await post('image/png',source);
    if(valid.status!=201 || valid.body['size']!=source.length ||
        valid.body['state']!='staged_not_attached' ||
        queue.pendingCount!=1) {
      throw StateError('authorized image not staged correctly: $valid');
    }
    final forged=await post('image/jpeg',source);
    if(forged.status!=415 || forged.body['error']!='image_signature_mismatch') {
      throw StateError('forged MIME not rejected: $forged');
    }
    final encoding=await post('image/png',source,encoding:'gzip');
    if(encoding.status!=415 ||
        encoding.body['error']!='image_content_encoding_not_allowed') {
      throw StateError('compressed HTTP image not rejected: $encoding');
    }
    if(calls.length!=3 || queue.pendingCount!=1) {
      throw StateError('image staging should keep only one verified upload');
    }
    await queue.revokeSession('paired');
    if(queue.pendingCount!=0)throw StateError('session revoke did not erase staged image');
    print('W8 HTTP smoke: pairing gate, staging, forged MIME, encoding, cleanup passed');
  } finally {
    await server.close(force:true);
    await listen.cancel();
    await queue.close();
    await privateRoot.delete(recursive:true);
  }
}
