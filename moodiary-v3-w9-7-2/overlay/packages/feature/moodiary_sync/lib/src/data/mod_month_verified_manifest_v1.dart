// W9.7.2: verified closure manifest over a staged legacy archive and W9 graph.
//
// This is a bounded, in-memory *staging verification contract*, NOT a new
// backup button or restore API. In particular, no WebDAV/sync guard is lifted.
// Production archives need a streamed, atomic filesystem/ZIP writer and
// crash-safe multi-object restore before calling this a full user backup.
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_models/moodiary_models.dart';

import 'model/manifest.dart';

final class ModBundleInvalid implements Exception {
  final String code;
  const ModBundleInvalid(this.code);
  @override
  String toString() => 'ModBundleInvalid($code)';
}

/// The base manifest/objects use the existing LocalArchive.writeArchive layout:
/// manifest.json, diary/<id>.json, category/<id>.json, place/<id>.json,
/// media/<kind>/<filename>. Append structured/month-graph.json before sealing.
final class ModMonthVerifiedManifestV1 {
  const ModMonthVerifiedManifestV1._();

  static const format = 'moodiary-verified-month-bundle';
  static const version = 1;
  static const graphPath = 'structured/month-graph.json';

  // An explicit safety limit for the staging implementation, not a limit on
  // future streamed backups. Never use this as a complete-backup interface
  // for long videos or unbounded photo libraries.
  static const maxStagedBytes = 256 * 1024 * 1024;
  static const maxStagedFiles = 20000;

  static Never _error(String code) => throw ModBundleInvalid(code);
  static String _hash(List<int> bytes) => sha256.convert(bytes).toString();

  static bool _safeName(String value) =>
      value.isNotEmpty && value.length <= 255 &&
      RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(value) &&
      value != '.' && value != '..' && !value.contains('..');

  static bool _validObjectId(String id) =>
      id.isNotEmpty && id.length <= 120 &&
      RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id);

  static bool _safePath(String path) {
    if (path == 'manifest.json' || path == graphPath) return true;
    final parts = path.split('/');
    if (parts.length == 2 &&
        const {'diary','category','place'}.contains(parts[0]) &&
        parts[1].endsWith('.json')) {
      return _validObjectId(parts[1].substring(0,parts[1].length-5));
    }
    if (parts.length == 3 && parts[0] == 'media' &&
        const {'image','audio','video','file'}.contains(parts[1])) {
      return _safeName(parts[2]);
    }
    return false;
  }

  static String _mediaPath(String kind, String name) {
    if (!_safeName(name)) _error('invalid_media_name');
    return 'media/$kind/$name';
  }

  static Set<String> _graphMedia(String graphEncoded) {
    final value = jsonDecode(graphEncoded) as Map<String,dynamic>;
    final tables = value['tables'] as Map<String,dynamic>;
    final revisions = tables['mod_month_revisions'] as List;
    final refs = <String>{};
    var visited = 0;
    void walk(Object? node, int depth) {
      if (++visited > 200000 || depth > 64) _error('graph_node_limit');
      if (node is! Map) _error('invalid_graph_node');
      final type = node['type'];
      final kind = switch (type) {
        'image' => 'image',
        'audio' => 'audio',
        'video' => 'video',
        'attachment' => 'file',
        _ => null,
      };
      final attrs = node['attrs'];
      if (kind != null) {
        if (attrs is! Map || attrs['src'] is! String) {
          _error('unresolved_media_reference');
        }
        refs.add(_mediaPath(kind,attrs['src'] as String));
      } else if (attrs is Map && attrs.containsKey('src')) {
        // Do not silently lose newer/unknown media node kinds.
        _error('unknown_media_node');
      }
      final content = node['content'];
      if (content != null) {
        if (content is! List) _error('invalid_graph_content');
        for (final item in content) {
          walk(item,depth+1);
        }
      }
    }
    for (final revision in revisions) {
      if (revision is! Map || revision['body_json'] is! String) {
        _error('invalid_graph_revision');
      }
      final Object? doc;
      try {
        doc = jsonDecode(revision['body_json'] as String);
      } catch (_) {
        _error('invalid_graph_tiptap');
      }
      walk(doc,0);
    }
    return refs;
  }

  static Set<String> _topicIds(String graphEncoded) {
    final graph = jsonDecode(graphEncoded) as Map<String,dynamic>;
    final pages = (graph['tables'] as Map<String,dynamic>)
        ['mod_month_pages'] as List;
    return {
      for (final page in pages)
        if (page is Map && page['topic_id'] is String)
          page['topic_id'] as String,
    };
  }

  static Set<String> _boundDiaryIds(String graphEncoded) {
    final graph = jsonDecode(graphEncoded) as Map<String,dynamic>;
    final pages = (graph['tables'] as Map<String,dynamic>)
        ['mod_month_pages'] as List;
    return {
      for (final page in pages)
        if (page is Map && page['diary_id'] is String)
          page['diary_id'] as String,
    };
  }

  /// Creates a canonical hash manifest AFTER all native and structured bytes
  /// have already been staged. Any missing Topic, projection or media is fatal.
  /// isTopic must use the same classification as the app's ModDiary.isTopic;
  /// it is required rather than inferring topic identity from a title.
  static String seal({
    required Map<String,Uint8List> staged,
    required bool Function(Diary) isTopic,
  }) {
    if (staged.length < 2 || staged.length > maxStagedFiles ||
        !staged.containsKey('manifest.json') ||
        !staged.containsKey(graphPath)) {
      _error('missing_required_archive_objects');
    }
    var bytes = 0;
    final paths = staged.keys.toList()..sort();
    for (final path in paths) {
      if (!_safePath(path)) _error('unsafe_archive_path');
      bytes += staged[path]!.lengthInBytes;
      if (bytes > maxStagedBytes) _error('streaming_archive_required');
    }

    late final String graphEncoded;
    try {
      graphEncoded = utf8.decode(staged[graphPath]!,allowMalformed:false);
      ModMonthGraphArchiveV1.verify(graphEncoded);
    } catch (_) {
      _error('invalid_structured_graph');
    }

    late final SyncManifest legacy;
    try {
      final object = jsonDecode(utf8.decode(staged['manifest.json']!));
      if (object is! Map<String,dynamic>) _error('invalid_legacy_manifest');
      legacy = SyncManifest.fromJson(object);
    } catch (_) {
      _error('invalid_legacy_manifest');
    }

    final native = <String,Diary>{};
    final requiredMedia = <String>{};
    final referencedPaths = <String>{'manifest.json',graphPath};
    for (final entry in legacy.entries.entries) {
      final key=entry.key, info=entry.value;
      String path;
      if (key.startsWith(SyncKeys.diaryPrefix)) {
        path=SyncKeys.diaryObjectPath(key.substring(
          SyncKeys.diaryPrefix.length));
      } else if (key.startsWith(SyncKeys.categoryPrefix)) {
        path=SyncKeys.categoryObjectPath(key.substring(
          SyncKeys.categoryPrefix.length));
      } else if (key.startsWith(SyncKeys.placePrefix)) {
        path=SyncKeys.placeObjectPath(key.substring(
          SyncKeys.placePrefix.length));
      } else {
        // The existing archive format only has these live entity prefixes.
        _error('unknown_legacy_entity');
      }
      if (!_safePath(path)) _error('unsafe_legacy_entity');
      if (info.deleted) {
        if (staged.containsKey(path)) _error('deleted_entity_has_payload');
        continue;
      }
      if (!staged.containsKey(path)) _error('missing_native_entity');
      referencedPaths.add(path);
      if (key.startsWith(SyncKeys.diaryPrefix)) {
        final id=key.substring(SyncKeys.diaryPrefix.length);
        try {
          final json=jsonDecode(utf8.decode(staged[path]!));
          if (json is! Map<String,dynamic>) _error('invalid_native_diary');
          final diary=Diary.fromJson(json);
          if (diary.id != id) _error('native_diary_id_mismatch');
          native[id]=diary;
          // Native media arrays may omit references still present in
          // older TipTap/markdown content; require the union of both.
          final derived=DiaryContent.of(diary).media;
          for (final (kind, names) in <(String,List<String>)>[
            ('image',{...diary.imageName,...derived.images}.toList()),
            ('audio',{...diary.audioName,...derived.audios}.toList()),
            ('video',{...diary.videoName,...derived.videos}.toList()),
            ('file',{...diary.fileName,...derived.files}.toList()),
          ]) {
            for (final name in names) {
              final ref='$kind/$name';
              final file=_mediaPath(kind,name);
              if (!info.media.contains(ref)) {
                _error('missing_native_media_manifest_reference');
              }
              requiredMedia.add(file);
            }
          }
        } on ModBundleInvalid {
          rethrow;
        } catch (_) {
          _error('invalid_native_diary');
        }
      }
      for (final ref in info.media) {
        final parts=ref.split('/');
        if (parts.length != 2 ||
            !const {'image','audio','video','file'}.contains(parts[0])) {
          _error('invalid_legacy_media_ref');
        }
        requiredMedia.add(_mediaPath(parts[0],parts[1]));
      }
    }

    for (final id in _topicIds(graphEncoded)) {
      final topic=native[id];
      if (topic == null || !topic.show || !isTopic(topic)) {
        _error('topic_identity_not_verified');
      }
    }
    for (final id in _boundDiaryIds(graphEncoded)) {
      if (!native.containsKey(id)) _error('bound_diary_not_backed_up');
    }
    requiredMedia.addAll(_graphMedia(graphEncoded));
    for (final path in requiredMedia) {
      if (!staged.containsKey(path)) _error('missing_media_bytes');
      referencedPaths.add(path);
    }

    // Refuse stray entity files that cannot be recovered through the native
    // manifest. Extra media is permitted as a conservative, explicit asset.
    for (final path in paths) {
      if (path.startsWith('diary/') ||
          path.startsWith('category/') ||
          path.startsWith('place/')) {
        if (!referencedPaths.contains(path)) _error('orphan_entity_payload');
      }
    }
    final listing=[
      for (final path in paths)
        <String,Object?>{
          'path':path,
          'size':staged[path]!.lengthInBytes,
          'sha256':_hash(staged[path]!),
        }
    ];
    final payload=<String,Object?>{
      'format':format, 'version':version,
      'topics':(_topicIds(graphEncoded).toList()..sort()),
      'files':listing,
    };
    return jsonEncode({...payload,'sha256':_hash(utf8.encode(jsonEncode(payload)))});
  }

  /// A changed byte, added/removed path, stale manifest, corrupted graph or
  /// missing original media is rejected before any restoration begins.
  static void verify({
    required String manifest,
    required Map<String,Uint8List> staged,
    required bool Function(Diary) isTopic,
  }) {
    final Object? parsed;
    try {
      parsed=jsonDecode(manifest);
    } catch (_) {
      _error('invalid_bundle_manifest');
    }
    if (parsed is! Map<String,dynamic> ||
        parsed.length != 5 ||
        parsed['format'] != format || parsed['version'] != version ||
        parsed['topics'] is! List || parsed['files'] is! List ||
        parsed['sha256'] is! String) {
      _error('invalid_bundle_manifest');
    }
    final normalized=seal(staged:staged,isTopic:isTopic);
    if (manifest != normalized) _error('bundle_integrity_mismatch');
  }
}
