// W9.8.4.15 — production full native + W9 history + media backup/import.
// The existing recovery inventory remains read-only and is not used here.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_models/moodiary_models.dart';
import 'package:moodiary_platform/moodiary_platform.dart';
import 'package:path/path.dart' as p;

import 'package:moodiary_sync/src/data/archive_apply.dart';
import 'package:moodiary_sync/src/data/impl/local_archive.dart';
import 'package:moodiary_sync/src/data/incremental_engine.dart';
import 'package:moodiary_sync/src/data/model/manifest.dart';
import 'package:moodiary_sync/src/data/mod_month_stream_stage_v2.dart';
import 'package:moodiary_sync/src/data/mod_month_verified_manifest_v2.dart';
import 'package:moodiary_sync/src/data/mod_month_zip_bundle_v2.dart';
import 'package:moodiary_sync/src/data/sync.dart';

final class ModMonthFullBackupException implements Exception {
  final String code;
  const ModMonthFullBackupException(this.code);
  @override
  String toString() => 'ModMonthFullBackupException($code)';
}

final class ModMonthFullBackupArchiveV1 {
  const ModMonthFullBackupArchiveV1._();

  static const _journalFormat='moodiary-full-migration';
  static const _journalVersion=1;
  static const _graphPath=ModMonthVerifiedManifestV2.graphPath;
  static const _bundleManifest='verified-day-bundle-v2.json';
  static const _topicTag='__moodiary_mod_topic_v1';

  static Never _fail(String code)=>throw ModMonthFullBackupException(code);

  /// Exact predicate used by the mobile app's ModDiary.isTopic implementation.
  static bool _isTopic(Diary diary)=>diary.tags.contains(_topicTag);

  static bool _safeMediaName(String value)=>
      value.isNotEmpty && value.length<=255 &&
      RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(value) &&
      value!='.' && value!='..' && !value.contains('..');

  static Set<String> _graphMediaPaths(String encoded) {
    final envelope=jsonDecode(encoded) as Map<String,dynamic>;
    final graph=envelope['monthGraph'] as Map<String,dynamic>;
    final tables=graph['tables'] as Map<String,dynamic>;
    final revisions=tables['mod_month_revisions'] as List<dynamic>;
    final paths=<String>{};
    var visited=0;

    void walk(Object? node,int depth) {
      if(++visited>200000 || depth>64)_fail('graph_media_node_limit');
      if(node is! Map)_fail('invalid_graph_media_node');
      final kind=switch(node['type']) {
        'image'=>'image',
        'audio'=>'audio',
        'video'=>'video',
        'attachment'=>'file',
        _=>null,
      };
      final attrs=node['attrs'];
      if(kind!=null) {
        if(attrs is! Map || attrs['src'] is! String) {
          _fail('unresolved_graph_media_reference');
        }
        final name=attrs['src'] as String;
        if(!_safeMediaName(name))_fail('invalid_graph_media_name');
        paths.add('media/$kind/$name');
      } else if(attrs is Map && attrs.containsKey('src')) {
        _fail('unknown_graph_media_node');
      }
      final children=node['content'];
      if(children!=null) {
        if(children is! List)_fail('invalid_graph_media_content');
        for(final child in children) {
          walk(child,depth+1);
        }
      }
    }

    for(final raw in revisions) {
      if(raw is! Map || raw['body_json'] is! String) {
        _fail('invalid_graph_revision');
      }
      final Object? document;
      try {
        document=jsonDecode(raw['body_json'] as String);
      } catch (_) {
        _fail('invalid_graph_revision_json');
      }
      walk(document,0);
    }
    return paths;
  }

  static Future<String> _hashFile(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  static Future<void> _writeJournal(
    File file,String sourceSha,String phase,
  ) async {
    await file.parent.create(recursive:true);
    final type=await FileSystemEntity.type(file.path,followLinks:false);
    if(type!=FileSystemEntityType.notFound &&
       type!=FileSystemEntityType.file) {
      _fail('migration_journal_not_regular_file');
    }
    final temp=File(file.path+'.tmp');
    final body=jsonEncode({
      'format':_journalFormat,
      'version':_journalVersion,
      'sourceSha256':sourceSha,
      'phase':phase,
      'updatedAtMs':DateTime.now().millisecondsSinceEpoch,
    });
    await temp.writeAsString(body,flush:true);
    await temp.rename(file.path);
  }

  static Future<Map<String,dynamic>?> _readJournal(File file) async {
    final type=await FileSystemEntity.type(file.path,followLinks:false);
    if(type==FileSystemEntityType.notFound)return null;
    if(type!=FileSystemEntityType.file)_fail('migration_journal_not_regular_file');
    final Object? value;
    try {
      value=jsonDecode(await file.readAsString());
    } catch (_) {
      _fail('migration_journal_corrupt');
    }
    if(value is! Map<String,dynamic> ||
       value['format']!=_journalFormat ||
       value['version']!=_journalVersion ||
       value['sourceSha256'] is! String ||
       !const {'verified','native_imported','graph_imported','completed'}
           .contains(value['phase'])) {
      _fail('migration_journal_invalid');
    }
    return value;
  }

  static Future<File> _journalFile() async {
    final root=Directory(p.join(
      PlatformService.get().applicationSupportPath,
      '.moodiary-migration',
    ));
    await root.create(recursive:true);
    return File(p.join(root.path,'full-v1.json'));
  }

  static Future<void> _requireEmptyTarget(MoodiaryDatabase db) async {
    const tables=[
      'diaries','categories','places','tombstones',
      'mod_month_pages','mod_month_blocks','mod_month_revisions',
      'mod_month_heads','mod_month_ops','mod_day_pages',
    ];
    for(final table in tables) {
      final row=await db.customSelect(
        'SELECT COUNT(*) AS n FROM $table').getSingle();
      if(row.read<int>('n')!=0)_fail('migration_target_not_empty');
    }
  }

  /// Validate the current destination BEFORE replaying a recorded migration.
  ///
  /// A journal is proof of a selected source archive, not permission to merge
  /// arbitrary records into a nonempty target. A crash can leave a subset of
  /// native rows, but every such row must belong to that exact archive.
  static Future<void> validateResumeTarget({
    required MoodiaryDatabase db,
    required SyncManifest manifest,
    required String graph,
    required String phase,
  }) async {
    if (!const {'verified', 'native_imported', 'graph_imported'}
        .contains(phase)) {
      _fail('migration_resume_phase_invalid');
    }
    final allowPartial = phase == 'verified';

    // Database last_modified is stored in microseconds; native manifest timeMs
    // is in milliseconds. Match the manifest's declared precision only.
    Future<void> verifyTable(String table, String prefix) async {
      final expected = <String, int>{
        for (final entry in manifest.entries.entries)
          if (!entry.value.deleted && entry.key.startsWith(prefix))
            entry.key.substring(prefix.length): entry.value.timeMs,
      };
      final rows = await db.customSelect(
        'SELECT id,last_modified FROM $table',
      ).get();
      if (!allowPartial && rows.length != expected.length) {
        _fail('migration_resume_native_mismatch');
      }
      for (final row in rows) {
        final id = row.read<String>('id');
        if (expected[id] !=
            row.read<int>('last_modified') ~/ Duration.microsecondsPerMillisecond) {
          _fail('migration_resume_native_mismatch');
        }
      }
    }

    await verifyTable('diaries', SyncKeys.diaryPrefix);
    await verifyTable('categories', SyncKeys.categoryPrefix);
    await verifyTable('places', SyncKeys.placePrefix);

    final expectedDeleted = <String, int>{
      for (final entry in manifest.entries.entries)
        if (entry.value.deleted) entry.key: entry.value.timeMs,
    };
    final actualDeleted = await TombstoneRepository(db).getAll();
    if (!allowPartial && actualDeleted.length != expectedDeleted.length) {
      _fail('migration_resume_tombstone_mismatch');
    }
    for (final row in actualDeleted) {
      if (expectedDeleted[row.key] != row.timeMs) {
        _fail('migration_resume_tombstone_mismatch');
      }
    }

    const graphTables = [
      'mod_month_pages', 'mod_month_blocks', 'mod_month_revisions',
      'mod_month_heads', 'mod_month_ops', 'mod_day_pages',
    ];
    var occupied = false;
    for (final table in graphTables) {
      final count = await db.customSelect(
        'SELECT COUNT(*) AS n FROM $table',
      ).getSingle();
      if (count.read<int>('n') != 0) occupied = true;
    }
    if (!occupied) {
      if (phase == 'graph_imported') {
        // An empty graph is valid only when the archive's graph is empty too.
        final actual = await ModMonthGraphArchiveV2.exportGraph(db);
        if (actual != graph) _fail('migration_resume_graph_mismatch');
      }
      return;
    }
    // The W9 graph is written atomically. A mixed/partial graph is NEVER
    // considered a recoverable state, even when the source SHA matches.
    try {
      final actual = await ModMonthGraphArchiveV2.exportGraph(db);
      if (actual != graph) _fail('migration_resume_graph_mismatch');
    } on ModMonthFullBackupException {
      rethrow;
    } catch (_) {
      _fail('migration_resume_graph_mismatch');
    }
  }

  /// Build a user-facing ZIP containing native records, every W9 revision,
  /// operation, day mapping and all media used by current or historical data.
  static Future<String> export({required MoodiaryDatabase db}) =>
      IncrementalSyncEngine.runExclusive(() async {
    final snapshot=await db.transaction(() async {
      final diaries=await DiaryRepository(db).getAllDiaries();
      final categories=await CategoryRepository(db).getAllCategories();
      final places=await PlaceRepository(db).getAllPlaces();
      final tombstones=await TombstoneRepository(db).getAll();
      final graph=await ModMonthGraphArchiveV2.exportGraph(db);
      return (
        diaries:diaries,
        categories:categories,
        places:places,
        tombstones:tombstones,
        graph:graph,
      );
    });

    final cache=PlatformService.get().applicationCachePath;
    final media=PlatformService.get().applicationSupportPath;
    final stamp=DateTime.now().microsecondsSinceEpoch;
    final stagePath=p.join(cache,'moodiary-full-stage-$stamp');
    final zipPath=p.join(cache,'moodiary-full-backup-$stamp.zip');
    final stage=await ModMonthStreamStageV2.create(stagePath);

    try {
      await LocalArchive.writeArchive(
        sink:stage,
        diaries:snapshot.diaries,
        categories:snapshot.categories,
        places:snapshot.places,
        tombstones:snapshot.tombstones,
        mediaBaseDir:media,
      );

      // The native archive includes current Diary media. Add every media
      // object referenced only by an older W9 revision (including tombstones).
      final nativeManifestRaw=jsonDecode(
        await File(p.join(stage.stagingPath,'manifest.json')).readAsString(),
      ) as Map<String,dynamic>;
      final nativeManifest=SyncManifest.fromJson(nativeManifestRaw);
      final nativeMedia={
        for(final ref in nativeManifest.referencedMedia()) 'media/$ref',
      };
      for(final path in _graphMediaPaths(snapshot.graph).difference(nativeMedia)) {
        final parts=path.split('/');
        final source=File(p.join(media,parts[1],parts[2]));
        if(await FileSystemEntity.type(source.path,followLinks:false)!=
            FileSystemEntityType.file) {
          _fail('historical_media_missing');
        }
        await stage.addLocalFile(path,source.path);
      }

      await stage.addBytes(
        _graphPath,
        Uint8List.fromList(utf8.encode(snapshot.graph)),
      );
      final published=await stage.publish(isTopic:_isTopic);
      return await ModMonthZipBundleV2.createVerified(
        sourceDirectory:published,
        outputZip:zipPath,
        isTopic:_isTopic,
      );
    } catch (_) {
      await stage.abort();
      rethrow;
    } finally {
      final published=Directory(stagePath);
      if(await published.exists()) {
        await published.delete(recursive:true);
      }
    }
  });

  /// Import only a full W9 bundle. A normal upstream ZIP without the complete
  /// graph is rejected rather than silently losing revision/operation history.
  static Future<SyncReport> importZip({
    required String zipPath,
    required MoodiaryDatabase db,
  }) async {
    final source=File(zipPath);
    if(await FileSystemEntity.type(source.path,followLinks:false)!=
        FileSystemEntityType.file) {
      _fail('source_zip_missing');
    }
    final sourceSha=await _hashFile(source);
    final journal=await _journalFile();
    final previous=await _readJournal(journal);
    if(previous!=null) {
      if(previous['sourceSha256']!=sourceSha) {
        _fail('different_source_for_incomplete_migration');
      }
      if(previous['phase']=='completed')_fail('migration_already_completed');
    }

    final cache=PlatformService.get().applicationCachePath;
    final temp=await Directory(cache).createTemp('moodiary-full-migration-');
    try {
      final verified=p.join(temp.path,'verified');
      await ModMonthZipBundleV2.extractVerifiedIntoIsolatedDirectory(
        zipPath:source.path,
        outputDirectory:verified,
        isTopic:_isTopic,
      );
      final graphFile=File(p.joinAll([verified,..._graphPath.split('/')]));
      final graph=await graphFile.readAsString();
      final manifestRaw=jsonDecode(
        await File(p.join(verified,'manifest.json')).readAsString(),
      );
      if(manifestRaw is! Map<String,dynamic>)_fail('native_manifest_invalid');
      final nativeManifest=SyncManifest.fromJson(manifestRaw);
      if(previous==null) {
        await _requireEmptyTarget(db);
      } else {
        await validateResumeTarget(
          db: db,
          manifest: nativeManifest,
          graph: graph,
          phase: previous['phase'] as String,
        );
      }
      // A source file may be replaced while an expensive ZIP verification
      // runs. Never bind an earlier SHA to bytes verified later.
      if(await _hashFile(source)!=sourceSha) {
        _fail('source_changed_during_verification');
      }
      // Bind the source only after the ZIP and all full-history receipts verify;
      // a malformed ZIP must not lock the target to an unusable source file.
      await _writeJournal(journal,sourceSha,'verified');

      final report=await LocalArchive.importDirectory(
        verified,
        policy:const FullMigrationRestorePolicy(),
        afterApply:(nativeReport) async {
          if(nativeReport.failed!=0 || nativeReport.cancelled) {
            _fail('native_import_incomplete');
          }
          await _verifyNativeEntities(db,nativeManifest);
          await TombstoneRepository(db).putAll([
            for(final entry in nativeManifest.entries.entries)
              if(entry.value.deleted)
                SyncTombstone(
                  key:entry.key,
                  timeMs:entry.value.timeMs,
                  pushedBackends:const [],
                ),
          ]);
          await _verifyNativeTombstones(db,nativeManifest);
          await _writeJournal(journal,sourceSha,'native_imported');

          await _copyAndVerifyAllMedia(verified);
          await ModMonthGraphArchiveV2.restoreIntoEmptyDatabase(db,graph);
          await _writeJournal(journal,sourceSha,'graph_imported');

          await _verifyNativeEntities(db,nativeManifest);
          await _verifyNativeTombstones(db,nativeManifest);
          await _verifyGraph(db,graph);
          await _verifyDatabase(db);
          await _writeJournal(journal,sourceSha,'completed');
        },
      );
      if(report.failed!=0 || report.cancelled)_fail('native_import_incomplete');
      return report;
    } finally {
      if(await temp.exists())await temp.delete(recursive:true);
    }
  }

  static Future<void> _verifyNativeEntities(
    MoodiaryDatabase db,SyncManifest manifest,
  ) async {
    final expectedDiaries={
      for(final e in manifest.entries.entries)
        if(e.key.startsWith(SyncKeys.diaryPrefix) && !e.value.deleted)
          e.key.substring(SyncKeys.diaryPrefix.length):e.value.timeMs,
    };
    final expectedCategories={
      for(final e in manifest.entries.entries)
        if(e.key.startsWith(SyncKeys.categoryPrefix) && !e.value.deleted)
          e.key.substring(SyncKeys.categoryPrefix.length):e.value.timeMs,
    };
    final expectedPlaces={
      for(final e in manifest.entries.entries)
        if(e.key.startsWith(SyncKeys.placePrefix) && !e.value.deleted)
          e.key.substring(SyncKeys.placePrefix.length):e.value.timeMs,
    };
    // SQLite stores microseconds; the manifest intentionally stores millis.
    Future<Map<String,int>> read(String table) async {
      final rows=await db.customSelect(
        'SELECT id,last_modified FROM $table').get();
      return {
        for(final row in rows)
          row.read<String>('id'):
            row.read<int>('last_modified') ~/ Duration.microsecondsPerMillisecond,
      };
    }
    bool same(Map<String,int> a,Map<String,int> b) {
      if(a.length!=b.length)return false;
      for(final e in b.entries) {
        if(a[e.key]!=e.value)return false;
      }
      return true;
    }
    if(!same(await read('diaries'),expectedDiaries) ||
       !same(await read('categories'),expectedCategories) ||
       !same(await read('places'),expectedPlaces)) {
      _fail('native_entity_readback_mismatch');
    }
  }

  static Future<void> _verifyNativeTombstones(
    MoodiaryDatabase db,SyncManifest manifest,
  ) async {
    final expected={
      for(final e in manifest.entries.entries)
        if(e.value.deleted)e.key:e.value.timeMs,
    };
    final actual={
      for(final item in await TombstoneRepository(db).getAll())
        item.key:item.timeMs,
    };
    if(expected.length!=actual.length ||
       expected.entries.any((e)=>actual[e.key]!=e.value)) {
      _fail('native_tombstone_readback_mismatch');
    }
  }

  static Future<void> _copyAndVerifyAllMedia(String verified) async {
    final bundle=jsonDecode(await File(
      p.join(verified,_bundleManifest),
    ).readAsString()) as Map<String,dynamic>;
    final files=bundle['files'];
    if(files is! List)_fail('bundle_media_receipts_missing');
    final mediaBase=PlatformService.get().applicationSupportPath;
    for(final raw in files) {
      if(raw is! Map || raw['path'] is! String ||
         raw['size'] is! int || raw['sha256'] is! String) {
        _fail('bundle_media_receipt_invalid');
      }
      final path=raw['path'] as String;
      if(!path.startsWith('media/'))continue;
      final parts=path.split('/');
      if(parts.length!=3 || !_safeMediaName(parts[2])) {
        _fail('bundle_media_path_invalid');
      }
      final expectedSize=raw['size'] as int;
      final expectedSha=raw['sha256'] as String;
      final from=File(p.joinAll([verified,...parts]));
      if(await FileSystemEntity.type(from.path,followLinks:false)!=
          FileSystemEntityType.file ||
         await from.length()!=expectedSize ||
         await _hashFile(from)!=expectedSha) {
        _fail('bundle_media_source_mismatch');
      }
      final to=File(p.join(mediaBase,parts[1],parts[2]));
      final targetType=await FileSystemEntity.type(to.path,followLinks:false);
      if(targetType==FileSystemEntityType.file) {
        if(await to.length()!=expectedSize || await _hashFile(to)!=expectedSha) {
          _fail('bundle_media_destination_collision');
        }
        continue;
      }
      if(targetType!=FileSystemEntityType.notFound) {
        _fail('bundle_media_destination_unsafe');
      }
      await to.parent.create(recursive:true);
      final partial=File(to.path+'.moodiary-'+expectedSha+'.partial');
      final partialType=await FileSystemEntity.type(
        partial.path,followLinks:false);
      if(partialType!=FileSystemEntityType.notFound) {
        if(partialType!=FileSystemEntityType.file) {
          _fail('bundle_media_partial_unsafe');
        }
        await partial.delete();
      }
      final sink=partial.openWrite();
      try {
        await from.openRead().pipe(sink);
      } catch (_) {
        await sink.close();
        rethrow;
      }
      if(await partial.length()!=expectedSize ||
         await _hashFile(partial)!=expectedSha) {
        await partial.delete();
        _fail('bundle_media_copy_mismatch');
      }
      await partial.rename(to.path);
    }
  }

  static Future<void> _verifyGraph(
    MoodiaryDatabase db,String expected,
  ) async {
    final actual=await ModMonthGraphArchiveV2.exportGraph(db);
    if(actual!=expected)_fail('month_graph_readback_mismatch');
    final decoded=jsonDecode(expected) as Map<String,dynamic>;
    final tables=(decoded['monthGraph'] as Map<String,dynamic>)['tables']
        as Map<String,dynamic>;
    final counts=<String,int>{
      for(final name in [
        'mod_month_pages','mod_month_blocks','mod_month_revisions',
        'mod_month_heads','mod_month_ops',
      ]) name:(tables[name] as List<dynamic>).length,
      'mod_day_pages':(decoded['dayPages'] as List<dynamic>).length,
    };
    for(final entry in counts.entries) {
      final row=await db.customSelect(
        'SELECT COUNT(*) AS n FROM '+entry.key).getSingle();
      if(row.read<int>('n')!=entry.value)_fail('month_graph_row_count_mismatch');
    }
  }

  static Future<void> _verifyDatabase(MoodiaryDatabase db) async {
    final integrity=await db.customSelect('PRAGMA integrity_check').getSingle();
    if(integrity.read<String>('integrity_check')!='ok') {
      _fail('sqlite_integrity_check_failed');
    }
    final foreignKeys=await db.customSelect('PRAGMA foreign_key_check').get();
    if(foreignKeys.isNotEmpty)_fail('sqlite_foreign_key_check_failed');
  }
}
