// W9.7.5: full native + W9 SQLite + media restore in a NEW isolated tree.
//
// No real app state is imported, replaced, merged, or synchronized here.
// This is a proof-of-recoverability gate only. Live activation would require
// a separate crash-safe multi-component promotion and recovery design.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_models/moodiary_models.dart';
import 'package:path/path.dart' as p;

import 'model/manifest.dart';
import 'mod_month_stream_stage_v1.dart';
import 'mod_month_verified_manifest_v1.dart';
import 'mod_month_zip_bundle_v1.dart';

final class ModMonthIsolatedRestoreV1 {
  const ModMonthIsolatedRestoreV1._();

  static Never _fail(String code) => throw ModBundleInvalid(code);

  static Future<void> _absent(String path) async {
    if (await FileSystemEntity.type(path,followLinks:false)!=
        FileSystemEntityType.notFound) _fail('restore_destination_exists');
  }

  static Future<void> _checkpoint(
      Future<void> Function(String)? checkpoint,String phase) async {
    if (checkpoint!=null) await checkpoint(phase);
  }

  static Future<void> _journal(Directory staging,String phase) async {
    final report=File(p.join(staging.path,'restore-state.json'));
    await report.writeAsString(jsonEncode({
      'format':'moodiary-isolated-restore',
      'version':1,
      'phase':phase,
      'liveDataModified':false,
    }),flush:true);
  }

  static Future<Map<String,dynamic>> _json(File file) async {
    final stat=await file.stat();
    if (stat.size<0 || stat.size>64*1024*1024) _fail('native_json_too_large');
    final Object? value;
    try {
      value=jsonDecode(await file.readAsString());
    } catch (_) {
      _fail('invalid_native_json');
    }
    if (value is! Map<String,dynamic>) _fail('invalid_native_json');
    return value;
  }

  static Future<
      ({Map<String,Diary> diaries,Map<String,Category> categories,
        Map<String,Place> places,Map<String,int> tombstones})
    > _loadNative(String dir) async {
    final manifest=SyncManifest.fromJson(await _json(
      File(p.join(dir,'manifest.json'))));
    final diaries=<String,Diary>{};
    final categories=<String,Category>{};
    final places=<String,Place>{};
    final tombstones=<String,int>{};
    final items=manifest.entries.entries.toList()
      ..sort((a,b)=>a.key.compareTo(b.key));
    for (final item in items) {
      final key=item.key, info=item.value;
      final List<String> parts=key.split(':');
      if (parts.length!=2 || parts[1].isEmpty ||
          !const ['d','c','p'].contains(parts[0])) {
        _fail('invalid_native_entity_key');
      }
      if (info.deleted) {
        if (tombstones.containsKey(key)) _fail('duplicate_tombstone');
        tombstones[key]=info.timeMs;
        continue;
      }
      final kind=parts[0];
      final id=parts[1];
      final folder=switch(kind) {
        'd'=>'diary',
        'c'=>'category',
        'p'=>'place',
        _=>throw StateError('invalid kind'),
      };
      final payload=await _json(File(p.join(dir,folder,id+'.json')));
      try {
        if (kind=='d') {
          final diary=Diary.fromJson(payload);
          if (diary.id!=id || diaries.containsKey(id)) {
            _fail('native_diary_id_mismatch');
          }
          diaries[id]=diary;
        } else if (kind=='c') {
          final category=Category.fromJson(payload);
          if (category.id!=id || categories.containsKey(id)) {
            _fail('native_category_id_mismatch');
          }
          categories[id]=category;
        } else {
          final place=Place.fromJson(payload);
          if (place.id!=id || places.containsKey(id)) {
            _fail('native_place_id_mismatch');
          }
          places[id]=place;
        }
      } on ModBundleInvalid {
        rethrow;
      } catch (_) {
        _fail('invalid_native_entity');
      }
    }
    for (final key in tombstones.keys) {
      final id=key.substring(2);
      if ((key.startsWith('d:') && diaries.containsKey(id)) ||
          (key.startsWith('c:') && categories.containsKey(id)) ||
          (key.startsWith('p:') && places.containsKey(id))) {
        _fail('active_entity_with_tombstone');
      }
    }
    return (
      diaries:diaries,categories:categories,
      places:places,tombstones:tombstones,
    );
  }

  static Future<void> _writeNative(MoodiaryDatabase db,({
      Map<String,Diary> diaries,Map<String,Category> categories,
      Map<String,Place> places,Map<String,int> tombstones,
    }) native) => db.transaction(() async {
    // Preserve original business IDs, dates, original content and tags.
    // This is an isolated destination only: strict INSERT, no UPSERT or LWW.
    for (final category in native.categories.values) {
      await db.customStatement(
        'INSERT INTO categories'
        '(id,name,last_modified,parent_id,color) VALUES(?,?,?,?,?)',
        [category.id,category.categoryName,dbTime(category.lastModified),
          category.parentId,category.color]);
    }
    for (final place in native.places.values) {
      await db.customStatement(
        'INSERT INTO places'
        '(id,name,latitude,longitude,icon,last_modified)'
        ' VALUES(?,?,?,?,?,?)',
        [place.id,place.name,place.latitude,place.longitude,
          place.icon,dbTime(place.lastModified)]);
    }
    for (final diary in native.diaries.values) {
      await db.customStatement(
        'INSERT INTO diaries'
        '(id,category_id,title,content,content_text,time,last_modified,show,'
        'mood_level,type,aspect,place_id,weather_icon,weather_temp,weather_text)'
        ' VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
        [diary.id,diary.categoryId,diary.title,diary.content,diary.contentText,
          dbTime(diary.time),dbTime(diary.lastModified),diary.show?1:0,
          diary.mood?.score,diary.type,diary.aspect,diary.placeId,
          diary.weather?.icon,diary.weather?.temp,diary.weather?.text]);
      for (final (kind,names) in <(String,List<String>)>[
        ('image',diary.imageName),('audio',diary.audioName),
        ('video',diary.videoName),('file',diary.fileName),
      ]) {
        final mediaNames=DiaryContent.of(diary).mediaNames;
        for (var index=0;index<names.length;index++) {
          await db.customStatement(
            'INSERT INTO diary_media'
            '(diary_id,kind,seq,file_name,name) VALUES(?,?,?,?,?)',
            [diary.id,kind,index,names[index],mediaNames[names[index]]]);
        }
      }
      for (var index=0;index<diary.tags.length;index++) {
        await db.customStatement(
          'INSERT INTO diary_tags(diary_id,seq,tag) VALUES(?,?,?)',
          [diary.id,index,diary.tags[index]]);
      }
      for (final link in DiaryContent.of(diary).links.toSet()) {
        await db.customStatement(
          'INSERT INTO diary_links(src_id,dst_id) VALUES(?,?)',
          [diary.id,link]);
      }
    }
    for (final marker in native.tombstones.entries) {
      await db.customStatement(
        'INSERT INTO tombstones'
        '("key",time_ms,pushed_backends_json) VALUES(?,?,?)',
        [marker.key,marker.value,'[]']);
    }
  });

  static void _compareJson(Object a,Object b,String code) {
    if (jsonEncode(a)!=jsonEncode(b)) _fail(code);
  }

  static Future<void> _verifyReadback(MoodiaryDatabase db,({
      Map<String,Diary> diaries,Map<String,Category> categories,
      Map<String,Place> places,Map<String,int> tombstones,
    }) native,String graph) async {
    if (await ModMonthGraphArchiveV1.exportGraph(db)!=graph) {
      _fail('structured_graph_readback_mismatch');
    }
    final actualDiaries={
      for (final d in await DiaryRepository(db).getAllDiaries()) d.id:d,
    };
    if (actualDiaries.length!=native.diaries.length ||
        actualDiaries.keys.toSet().difference(native.diaries.keys.toSet())
          .isNotEmpty) _fail('native_diary_count_mismatch');
    for (final entry in native.diaries.entries) {
      _compareJson(entry.value.toJson(),actualDiaries[entry.key]!.toJson(),
        'native_diary_readback_mismatch');
    }
    final actualCategories={
      for (final c in await CategoryRepository(db).getAllCategories()) c.id:c,
    };
    if (actualCategories.length!=native.categories.length ||
        actualCategories.keys.toSet().difference(native.categories.keys.toSet())
          .isNotEmpty) _fail('native_category_count_mismatch');
    for (final entry in native.categories.entries) {
      _compareJson(entry.value.toJson(),actualCategories[entry.key]!.toJson(),
        'native_category_readback_mismatch');
    }
    final actualPlaces={
      for (final p in await PlaceRepository(db).getAllPlaces()) p.id:p,
    };
    if (actualPlaces.length!=native.places.length ||
        actualPlaces.keys.toSet().difference(native.places.keys.toSet())
          .isNotEmpty) _fail('native_place_count_mismatch');
    for (final entry in native.places.entries) {
      _compareJson(entry.value.toJson(),actualPlaces[entry.key]!.toJson(),
        'native_place_readback_mismatch');
    }
    final markers=await db.customSelect(
      'SELECT "key",time_ms,pushed_backends_json FROM tombstones'
      ' ORDER BY "key"').get();
    if (markers.length!=native.tombstones.length) {
      _fail('native_tombstone_count_mismatch');
    }
    for (final marker in markers) {
      final key=marker.read<String>('key');
      if (native.tombstones[key]!=marker.read<int>('time_ms') ||
          marker.read<String>('pushed_backends_json')!='[]') {
        _fail('native_tombstone_readback_mismatch');
      }
    }
    final foreign=await db.customSelect('PRAGMA foreign_key_check').get();
    if (foreign.isNotEmpty) _fail('sqlite_foreign_key_violation');
    final integrity=await db.customSelect('PRAGMA integrity_check').get();
    if (integrity.length!=1 ||
        integrity.first.read<String>('integrity_check')!='ok') {
      _fail('sqlite_integrity_check_failed');
    }
  }

  static Future<String> _digest(File source) async =>
      (await sha256.bind(source.openRead()).first).toString();

  static Future<void> _copyMedia(
      String sourceDirectory,String destinationDirectory) async {
    final source=Directory(p.join(sourceDirectory,'media'));
    if (!await source.exists()) return;
    final target=Directory(p.join(destinationDirectory,'media'));
    await for (final item in source.list(recursive:true,followLinks:false)) {
      final type=await FileSystemEntity.type(item.path,followLinks:false);
      if (type==FileSystemEntityType.directory) continue;
      if (type!=FileSystemEntityType.file) _fail('unsafe_media_source');
      final path=p.relative(item.path,from:source.path);
      final name=path.replaceAll(p.separator,'/');
      if (!ModMonthVerifiedManifestV1.allowsEntryPath('media/'+name)) {
        _fail('invalid_media_restore_path');
      }
      final to=File(p.join(target.path,path));
      await to.parent.create(recursive:true);
      final before=await File(item.path).stat();
      await item.openRead().pipe(to.openWrite());
      final after=await File(item.path).stat();
      if (before.size!=after.size || before.modified!=after.modified ||
          await _digest(File(item.path))!=await _digest(to)) {
        _fail('media_copy_not_identical');
      }
    }
  }

  /// Produces a brand-new isolated preview at [outputDirectory]. It refuses
  /// pre-existing paths and NEVER opens the app's live SQLite or media path.
  /// A thrown checkpoint is a test-only injected fault.
  static Future<String> restoreZipToNewIsolatedDirectory({
    required String zipPath,
    required String outputDirectory,
    required bool Function(Diary) isTopic,
    ModMonthZipTransportV1 transport = const ModMonthNativeZipTransportV1(),
    Future<void> Function(String)? checkpoint,
  }) async {
    final target=p.normalize(p.absolute(outputDirectory));
    await _absent(target);
    final parent=Directory(p.dirname(target));
    if (await FileSystemEntity.type(parent.path,followLinks:false)!=
        FileSystemEntityType.directory) _fail('output_parent_missing');
    final staged=await parent.createTemp('.moodiary-w975-');
    MoodiaryDatabase? db;
    try {
      await _journal(staged,'created');
      final verified=p.join(staged.path,'verified-input');
      await ModMonthZipBundleV1.extractVerifiedIntoIsolatedDirectory(
        zipPath:zipPath,outputDirectory:verified,
        isTopic:isTopic,transport:transport);
      await _checkpoint(checkpoint,'source_verified');
      final native=await _loadNative(verified);
      final graph=await File(p.join(verified,
        ModMonthVerifiedManifestV1.graphPath)).readAsString();
      final database=Directory(p.join(staged.path,'database'));
      await database.create();
      final dbPath=p.join(database.path,'restored.sqlite');
      db=MoodiaryDatabase.forTesting(NativeDatabase(File(dbPath)));
      await db.customSelect('SELECT 1').get();
      await ModMonthGraphArchiveV1
        .restoreIntoIsolatedEmptyDatabaseForTest(db,graph);
      await _journal(staged,'graph_restored');
      await _checkpoint(checkpoint,'graph_restored');
      await _writeNative(db,native);
      await _journal(staged,'native_restored');
      await _checkpoint(checkpoint,'native_restored');
      await _verifyReadback(db,native,graph);
      await db.close();
      db=null;
      await _copyMedia(verified,staged.path);
      await _journal(staged,'media_restored');
      await _checkpoint(checkpoint,'media_restored');
      // Reopen actual SQLite database on disk; do not trust the original
      // drift connection or only an in-memory snapshot.
      db=MoodiaryDatabase.forTesting(NativeDatabase(File(dbPath)));
      await db.customSelect('SELECT 1').get();
      await _verifyReadback(db,native,graph);
      await db.close();
      db=null;
      // Review input again after all copies, then independently re-hash
      // each restored media file against the verified ZIP manifest.
      await ModMonthStreamStageV1.verifyPublished(
        verified,isTopic:isTopic);
      final bundled=await _json(File(p.join(verified,
        ModMonthStreamStageV1.manifestPath)));
      final receipts=bundled['files'];
      if (receipts is! List) _fail('missing_media_receipts');
      for (final item in receipts) {
        if (item is! Map || item['path'] is! String) {
          _fail('malformed_media_receipt');
        }
        final path=item['path'] as String;
        if (!path.startsWith('media/')) continue;
        final restored=File(p.joinAll([staged.path,...path.split('/')]));
        if (await FileSystemEntity.type(restored.path,followLinks:false)!=
            FileSystemEntityType.file ||
            await restored.length()!=item['size'] ||
            await _digest(restored)!=item['sha256']) {
          _fail('media_readback_mismatch');
        }
      }
      await _journal(staged,'readback_complete');
      await _checkpoint(checkpoint,'readback_complete');
      // Drop the transient full extracted ZIP copy: live media and sqlite
      // already have independently verified, complete isolated copies.
      await Directory(verified).delete(recursive:true);
      await _journal(staged,'ready');
      await _checkpoint(checkpoint,'before_publish');
      await _absent(target);
      await staged.rename(target);
      return target;
    } catch (_) {
      if (db!=null) {
        try { await db.close(); } catch (_) {}
      }
      try {
        if (await staged.exists()) await staged.delete(recursive:true);
      } catch (_) {}
      rethrow;
    }
  }
}
