import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_sync/src/data/mod_month_orphan_inspector_v1.dart';
import 'package:moodiary_sync/src/data/mod_month_verified_manifest_v1.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory sandbox;
  setUp(() async {
    sandbox=await Directory.systemTemp.createTemp('w977-orphan-inspection-');
  });
  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive:true);
  });

  Future<Directory> restore(String id,String? phase) async {
    final dir=Directory(p.join(sandbox.path,'.moodiary-w975-'+id));
    await dir.create();
    if (phase!=null) {
      await File(p.join(dir.path,'restore-state.json')).writeAsString(jsonEncode({
        'format':'moodiary-isolated-restore','version':1,
        'phase':phase,'liveDataModified':false,
      }),flush:true);
    }
    return dir;
  }

  test('read only detects known interrupted restore phases',() async {
    final phases=[
      'created','graph_restored','native_restored','media_restored',
      'readback_complete','ready',
    ];
    for (var index=0;index<phases.length;index++) {
      final dir=await restore('phase-'+index.toString(),phases[index]);
      await File(p.join(dir.path,'user-media.txt'))
        .writeAsString('preserve even partial write');
    }
    final report=await ModMonthOrphanInspectorV1
      .scanPrivateParent(sandbox.path);
    expect(report.length,phases.length);
    expect(report.map((e)=>e.phase).toSet(),phases.toSet());
    for (final finding in report) {
      expect(finding.kind,ModMonthOrphanTypeV1.isolatedRestore);
      expect(finding.condition,
        finding.phase=='ready'
          ? ModMonthOrphanConditionV1.readyButUnverified
          : ModMonthOrphanConditionV1.incompleteRestore);
      expect(finding.requiresHumanReview,isTrue);
      expect(finding.modifiedUtc,isNotNull);
      expect(await File(p.join(sandbox.path,finding.name,'user-media.txt'))
        .readAsString(),'preserve even partial write');
    }
    final again=await ModMonthOrphanInspectorV1
      .scanPrivateParent(sandbox.path);
    expect(again.map((e)=>e.phase).toList(),
      report.map((e)=>e.phase).toList());
  });

  test('ZIP staging cannot be interpreted as completed restore',() async {
    final folder=Directory(p.join(sandbox.path,'.moodiary-w974-zip-data'));
    await folder.create();
    final existing=File(p.join(folder.path,'pending.zip'));
    await existing.writeAsBytes([0x50,0x4b,0x03,0x04]);
    final report=await ModMonthOrphanInspectorV1
      .scanPrivateParent(sandbox.path);
    expect(report,hasLength(1));
    expect(report.single.kind,ModMonthOrphanTypeV1.archiveZip);
    expect(report.single.condition,
      ModMonthOrphanConditionV1.unknownArchiveStage);
    expect(report.single.phase,isNull);
    expect(await existing.readAsBytes(),[0x50,0x4b,0x03,0x04]);
  });

  test('invalid or absent restore journals remain untrusted',() async {
    await restore('missing',null);
    final malformed=await restore('malformed','created');
    await File(p.join(malformed.path,'restore-state.json'))
      .writeAsString('{ unclosed');
    final wrong=await restore('wrong','ready');
    await File(p.join(wrong.path,'restore-state.json')).writeAsString(
      '{"format":"moodiary-isolated-restore","version":1,'
      '"phase":"ready","liveDataModified":true}');
    await restore('forged','done_and_live');
    final report=await ModMonthOrphanInspectorV1
      .scanPrivateParent(sandbox.path);
    expect(report.length,4);
    for (final entry in report) {
      expect(entry.condition,
        ModMonthOrphanConditionV1.invalidRestoreJournal);
      expect(entry.phase,isNull);
    }
    expect(await wrong.exists(),isTrue);
  });

  test('oversized state and symlinked journal cannot be considered ready',
      () async {
    final large=await restore('oversize','ready');
    await File(p.join(large.path,'restore-state.json')).writeAsBytes(
      List.filled(ModMonthOrphanInspectorV1.maxStateBytes+1,65));
    final linkDir=await restore('linked','ready');
    final victim=File(p.join(sandbox.path,'outside.json'));
    await victim.writeAsString(jsonEncode({
      'format':'moodiary-isolated-restore','version':1,
      'phase':'ready','liveDataModified':false,
    }));
    await File(p.join(linkDir.path,'restore-state.json')).delete();
    await Link(p.join(linkDir.path,'restore-state.json')).create(victim.path);
    final report=await ModMonthOrphanInspectorV1
      .scanPrivateParent(sandbox.path);
    expect(report.length,2);
    expect(report.every((e)=>e.condition==
      ModMonthOrphanConditionV1.invalidRestoreJournal),isTrue);
    expect(await victim.readAsString(),contains('ready'));
  });

  test('symlink staging directory and regular files never get followed',
      () async {
    final outside=Directory(p.join(sandbox.path,'outside-user-data'));
    await outside.create();
    final original=File(p.join(outside.path,'only-copy.txt'));
    await original.writeAsString('never read or delete this');
    await Link(p.join(sandbox.path,'.moodiary-w975-forged'))
      .create(outside.path);
    await File(p.join(sandbox.path,'.moodiary-w974-not-a-dir'))
      .writeAsString('do not follow');
    final report=await ModMonthOrphanInspectorV1
      .scanPrivateParent(sandbox.path);
    expect(report.length,2);
    expect(report.every((e)=>e.condition==
      ModMonthOrphanConditionV1.unsafeStagingEntry),isTrue);
    expect(await original.readAsString(),'never read or delete this');
  });

  test('symlink parent and non-directory parents fail closed',() async {
    await Link(p.join(sandbox.path,'alias')).create(sandbox.path);
    await expectLater(
      ModMonthOrphanInspectorV1.scanPrivateParent(p.join(sandbox.path,'alias')),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','orphan_parent_not_private_directory')));
    await expectLater(
      ModMonthOrphanInspectorV1.scanPrivateParent(
        p.join(sandbox.path,'nonexistent')),throwsA(isA<ModBundleInvalid>()));
  });

  test('scanner stays shallow and ignores unrelated folders',() async {
    final nested=Directory(p.join(
      sandbox.path,'regular','.moodiary-w975-nested'));
    await nested.create(recursive:true);
    await Directory(p.join(sandbox.path,'.moodiary-w975-')).create();
    await Directory(p.join(sandbox.path,'moodiary-w975-similar')).create();
    final report=await ModMonthOrphanInspectorV1
      .scanPrivateParent(sandbox.path);
    expect(report,isEmpty);
    expect(await nested.exists(),isTrue);
  });

  test('over-limit quarantine inventory fails without deleting any files',
      () async {
    for (var i=0;i<=ModMonthOrphanInspectorV1.maxKnownStagingEntries;i++) {
      await Directory(p.join(sandbox.path,
        '.moodiary-w974-limit-'+i.toString())).create();
    }
    await expectLater(
      ModMonthOrphanInspectorV1.scanPrivateParent(sandbox.path),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','orphan_staging_limit')));
    expect(await Directory(p.join(sandbox.path,'.moodiary-w974-limit-0'))
      .exists(),isTrue);
  });
}
