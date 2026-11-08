// W9.7.6 — crash-recoverable generation slot, isolated from the app's live DB.
//
// IMPORTANT: this module is NOT a production restore, backup UI, or WebDAV
// activation. A slot can only be created at a previously absent root; its
// generations are independent test snapshots, never the running app storage.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:path/path.dart' as p;

import 'mod_month_verified_manifest_v1.dart';

final class ModSlotSimulatedProcessDeath implements Exception {
  const ModSlotSimulatedProcessDeath(this.at);
  final String at;
}

final class ModMonthRecoverySlotV1 {
  const ModMonthRecoverySlotV1._(this.root);
  final String root;

  static const _format='moodiary-isolated-generation-slot';
  static const _proofFormat='moodiary-restored-generation-proof';
  static const _version=1;
  static const _proofName='generation-proof.json';
  static const _rootName='slot-identity.json';
  static const _pointerName='active.json';
  static const _journalName='recovery-journal.json';
  static const _maxProofBytes=4*1024*1024;

  static Never _fail(String reason) => throw ModBundleInvalid(reason);
  static bool _id(String id) =>
      RegExp(r'^[a-zA-Z0-9_-]{8,64}$').hasMatch(id);

  Directory get _dir => Directory(root);
  Directory get _generations => Directory(p.join(root,'generations'));
  File get _identity => File(p.join(root,_rootName));
  File get _active => File(p.join(root,_pointerName));
  File get _journal => File(p.join(root,_journalName));
  File get _lock => File(p.join(root,'.slot-lock'));

  Directory _generation(String id) => Directory(p.join(_generations.path,id));
  Directory _incoming(String id) =>
      Directory(p.join(_generations.path,'.incoming-$id'));

  static String _sha(List<int> bytes) => sha256.convert(bytes).toString();
  static String _jsonSha(Object value) => _sha(utf8.encode(jsonEncode(value)));

  static Future<ModMonthRecoverySlotV1> createNew(String path) async {
    final dest=p.normalize(p.absolute(path));
    if (await FileSystemEntity.type(dest,followLinks:false)!=
        FileSystemEntityType.notFound) _fail('slot_destination_exists');
    if (await FileSystemEntity.type(p.dirname(dest),followLinks:false)!=
        FileSystemEntityType.directory) _fail('slot_parent_missing');
    final dir=await Directory(dest).create();
    try {
      final slot=ModMonthRecoverySlotV1._(dest);
      await slot._generations.create();
      await slot._identity.writeAsString(jsonEncode({
        'format':_format,'version':_version,'isolatedOnly':true,
      }),flush:true);
      return slot;
    } catch (_) {
      await dir.delete(recursive:true);
      rethrow;
    }
  }

  /// Reopen only a directory that was explicitly created as an isolated slot.
  static Future<ModMonthRecoverySlotV1> openExisting(String path) async {
    final slot=ModMonthRecoverySlotV1._(p.normalize(p.absolute(path)));
    await slot._checkRoot();
    return slot;
  }

  static Future<Map<String,dynamic>> _readJson(File file,int limit) async {
    if (await FileSystemEntity.type(file.path,followLinks:false)!=
        FileSystemEntityType.file) _fail('slot_missing_regular_file');
    final length=await file.length();
    if (length<2 || length>limit) _fail('slot_metadata_size_limit');
    final Object? parsed;
    try { parsed=jsonDecode(await file.readAsString()); }
    catch (_) { _fail('slot_invalid_json'); }
    if (parsed is! Map<String,dynamic>) _fail('slot_invalid_json');
    return parsed;
  }

  Future<void> _checkRoot() async {
    if (await FileSystemEntity.type(root,followLinks:false)!=
        FileSystemEntityType.directory ||
        await FileSystemEntity.type(_generations.path,followLinks:false)!=
        FileSystemEntityType.directory) _fail('not_an_isolated_slot');
    final info=await _readJson(_identity,1024);
    if (info.length!=3 || info['format']!=_format ||
        info['version']!=_version || info['isolatedOnly']!=true) {
      _fail('not_an_isolated_slot');
    }
  }

  static Future<void> _writeAtomic(File dest,Map<String,dynamic> object) async {
    final next=File(dest.path+'.next');
    if (await FileSystemEntity.type(next.path,followLinks:false)!=
        FileSystemEntityType.notFound) _fail('slot_pending_temp_collision');
    await next.writeAsString(jsonEncode(object),flush:true);
    await next.rename(dest.path);
  }

  static Future<void> _dropNext(File target) async {
    final next=File(target.path+'.next');
    final kind=await FileSystemEntity.type(next.path,followLinks:false);
    if (kind==FileSystemEntityType.file) {
      await next.delete();
    } else if (kind!=FileSystemEntityType.notFound) {
      _fail('unsafe_pending_slot_file');
    }
  }

  static Future<T> _withLock<T>(File file,Future<T> Function() action) async {
    final handle=await file.open(mode:FileMode.append);
    try {
      await handle.lock(FileLock.exclusive);
      return await action();
    } finally {
      try { await handle.unlock(); } finally { await handle.close(); }
    }
  }

  static Future<String> _fingerprint(File file) async {
    final before=await file.stat();
    if (before.type!=FileSystemEntityType.file) _fail('not_a_regular_file');
    // Keep the file stream outside the Dart heap even for large videos.
    final digest=await sha256.bind(file.openRead()).first;
    final after=await file.stat();
    if (before.size!=after.size || before.modified!=after.modified ||
        before.changed!=after.changed) _fail('file_changed_while_hashing');
    return digest.toString();
  }

  static bool _allowedPayload(String relative) =>
      relative=='restore-state.json' ||
      relative=='database/restored.sqlite' ||
      (relative.startsWith('media/') &&
          ModMonthVerifiedManifestV1.allowsEntryPath(relative));

  static Future<List<Map<String,Object>>> _inventory(String directory,
      {bool skipProof=false}) async {
    if (await FileSystemEntity.type(directory,followLinks:false)!=
        FileSystemEntityType.directory) _fail('payload_not_directory');
    final rows=<Map<String,Object>>[];
    var mediaSize=0;
    var foundDb=false,foundState=false;
    await for (final entry in Directory(directory)
        .list(recursive:true,followLinks:false)) {
      final type=await FileSystemEntity.type(entry.path,followLinks:false);
      if (type==FileSystemEntityType.directory) continue;
      if (type!=FileSystemEntityType.file) _fail('unsafe_restore_symlink');
      final name=p.relative(entry.path,from:directory).replaceAll(
        p.separator,'/');
      if (name==_proofName && skipProof) continue;
      if (!_allowedPayload(name)) _fail('unrecognized_restore_payload');
      if (rows.length>=ModMonthVerifiedManifestV1.maxStagedFiles+2) {
        _fail('restore_too_many_files');
      }
      if (name=='database/restored.sqlite') foundDb=true;
      if (name=='restore-state.json') foundState=true;
      final size=await File(entry.path).length();
      mediaSize+=size;
      if (mediaSize>512*1024*1024*1024) _fail('restore_too_large');
      rows.add({
        'path':name,'size':size,'sha256':await _fingerprint(File(entry.path)),
      });
    }
    if (!foundDb || !foundState) _fail('incomplete_native_restore');
    rows.sort((a,b)=>(a['path'] as String).compareTo(b['path'] as String));
    return rows;
  }

  static Future<void> _verifyState(String directory) async {
    final state=await _readJson(
      File(p.join(directory,'restore-state.json')),1024);
    if (state.length!=4 ||
        state['format']!='moodiary-isolated-restore' ||
        state['version']!=1 || state['phase']!='ready' ||
        state['liveDataModified']!=false) {
      _fail('restore_not_ready');
    }
  }

  static Future<String> _verifySqlite(String directory) async {
    final file=File(p.join(directory,'database','restored.sqlite'));
    if (await FileSystemEntity.type(file.path,followLinks:false)!=
        FileSystemEntityType.file) _fail('missing_restored_sqlite');
    final db=MoodiaryDatabase.forTesting(NativeDatabase(file));
    try {
      await db.customSelect('SELECT 1').get();
      final foreign=await db.customSelect('PRAGMA foreign_key_check').get();
      if (foreign.isNotEmpty) _fail('restore_foreign_key_violation');
      final integrity=await db.customSelect('PRAGMA integrity_check').get();
      if (integrity.length!=1 ||
          integrity.first.read<String>('integrity_check')!='ok') {
        _fail('restore_integrity_failure');
      }
      final graph=await ModMonthGraphArchiveV1.exportGraph(db);
      return _sha(utf8.encode(graph));
    } finally {
      await db.close();
    }
  }

  static Future<Map<String,dynamic>> _createProof(
    String directory,String generation,
  ) async {
    await _verifyState(directory);
    final graph=await _verifySqlite(directory);
    final files=await _inventory(directory);
    final value=<String,dynamic>{
      'format':_proofFormat,'version':_version,
      'generation':generation,'graphSha256':graph,'files':files,
    };
    return {...value,'sha256':_jsonSha(value)};
  }

  static Future<String> _verifyGeneration(Directory dir,String id) async {
    if (!_id(id)) _fail('invalid_generation_id');
    if (await FileSystemEntity.type(dir.path,followLinks:false)!=
        FileSystemEntityType.directory) _fail('missing_generation');
    final proof=await _readJson(File(p.join(dir.path,_proofName)),
      _maxProofBytes);
    if (proof.length!=6 || proof['format']!=_proofFormat ||
        proof['version']!=_version || proof['generation']!=id ||
        proof['graphSha256'] is! String || proof['sha256'] is! String ||
        proof['files'] is! List) _fail('generation_proof_invalid');
    final payload=<String,dynamic>{
      'format':proof['format'],'version':proof['version'],
      'generation':proof['generation'],'graphSha256':proof['graphSha256'],
      'files':proof['files'],
    };
    if (_jsonSha(payload)!=proof['sha256']) _fail('generation_proof_changed');
    await _verifyState(dir.path);
    final graph=await _verifySqlite(dir.path);
    if (graph!=proof['graphSha256']) _fail('generation_graph_changed');
    final files=await _inventory(dir.path,skipProof:true);
    if (jsonEncode(files)!=jsonEncode(proof['files'])) {
      _fail('generation_files_changed');
    }
    return proof['sha256'] as String;
  }

  static Map<String,dynamic> _pointer(String generation,String checksum) =>
      {'format':_format,'version':_version,'active':generation,
        'proofSha256':checksum};

  Future<Map<String,dynamic>?> _readPointer() async {
    final kind=await FileSystemEntity.type(_active.path,followLinks:false);
    if (kind==FileSystemEntityType.notFound) return null;
    final pointer=await _readJson(_active,1024);
    final gen=pointer['active'];
    if (pointer.length!=4 || pointer['format']!=_format ||
        pointer['version']!=_version || gen is! String || !_id(gen) ||
        pointer['proofSha256'] is! String) {
      _fail('active_pointer_invalid');
    }
    return pointer;
  }

  Future<Map<String,dynamic>?> _readJournal() async {
    final type=await FileSystemEntity.type(_journal.path,followLinks:false);
    if (type==FileSystemEntityType.notFound) return null;
    final value=await _readJson(_journal,1024);
    final previous=value['previous'];
    final next=value['next'];
    if (value.length!=5 || value['format']!=_format ||
        value['version']!=_version || next is! String || !_id(next) ||
        (previous!=null && (previous is! String || !_id(previous))) ||
        previous==next ||
        !const ['copying','verified','installed','committed']
          .contains(value['phase'])) {
      _fail('invalid_restore_journal');
    }
    return value;
  }

  Future<void> _journalPhase(String next,String? old,String phase) =>
      _writeAtomic(_journal,{
        'format':_format,'version':_version,
        'previous':old,'next':next,'phase':phase,
      });

  /// Recovery chooses the already committed pointer, NOT journal phase. If
  /// the pointer still selects the old generation, the new generation is
  /// abandoned. Previously active bytes are never overwritten or deleted.
  Future<String> _recoverLocked() async {
    await _dropNext(_journal);
    await _dropNext(_active);
    final journal=await _readJournal();
    final pointer=await _readPointer();
    if (journal==null) {
      if (pointer!=null) {
        final id=pointer['active'] as String;
        final sha=await _verifyGeneration(_generation(id),id);
        if (sha!=pointer['proofSha256']) _fail('active_proof_mismatch');
      }
      return 'clean';
    }
    final old=journal['previous'] as String?;
    final next=journal['next'] as String;
    final current=pointer?['active'] as String?;
    if (current!=old && current!=next) _fail('journal_pointer_disagreement');
    if (old!=null) {
      final oldProof=await _verifyGeneration(_generation(old),old);
      if (current==old && pointer?['proofSha256']!=oldProof) {
        _fail('previous_generation_proof_mismatch');
      }
    }
    final incoming=_incoming(next);
    if (current==next) {
      // Revalidate committed generation even after an abrupt death. If the
      // new generation is corrupt, fall back to the original verified one.
      try {
        final sha=await _verifyGeneration(_generation(next),next);
        if (sha!=pointer?['proofSha256']) _fail('active_proof_mismatch');
      } catch (_) {
        if (old==null) rethrow;
        final good=await _verifyGeneration(_generation(old),old);
        await _writeAtomic(_active,_pointer(old,good));
        await _journal.delete();
        return 'rolled_back_invalid_new';
      }
      if (await incoming.exists()) await incoming.delete(recursive:true);
      await _journal.delete();
      return 'committed';
    }
    if (current==null && old!=null) _fail('lost_previous_pointer');
    if (await incoming.exists()) {
      await incoming.delete(recursive:true);
    }
    final installed=_generation(next);
    if (await FileSystemEntity.type(installed.path,followLinks:false)!=
        FileSystemEntityType.notFound) {
      // Do not delete arbitrary unverified data if a directory was forged.
      await _verifyGeneration(installed,next);
      await installed.delete(recursive:true);
    }
    await _journal.delete();
    return 'rolled_back';
  }

  /// Explicit recovery after process restart; idempotent when clean.
  Future<String> recover() async {
    await _checkRoot();
    return _withLock(_lock,() => _recoverLocked());
  }

  /// Returns a *verified* independent generation directory, never the live
  /// app DB. The method fails closed if an interrupted transaction exists.
  Future<String?> currentDirectory() async {
    await _checkRoot();
    return _withLock(_lock,() async {
      if (await _journal.exists()) _fail('restart_recovery_required');
      final pointer=await _readPointer();
      if (pointer==null) return null;
      final id=pointer['active'] as String;
      if (await _verifyGeneration(_generation(id),id)!=
          pointer['proofSha256']) _fail('active_proof_mismatch');
      return _generation(id).path;
    });
  }

  static Future<void> _checkpoint(
    Future<void> Function(String)? callback,String phase,
  ) async {
    if (callback!=null) await callback(phase);
  }

  static Future<void> _copyPayload(String from,String to) async {
    final entries=await _inventory(from);
    for (final receipt in entries) {
      final relative=receipt['path'] as String;
      final dest=File(p.joinAll([to,...relative.split('/')]));
      await dest.parent.create(recursive:true);
      final src=File(p.joinAll([from,...relative.split('/')]));
      await src.openRead().pipe(dest.openWrite());
    }
    if (jsonEncode(await _inventory(to))!=jsonEncode(entries)) {
      _fail('generation_copy_not_identical');
    }
    if (jsonEncode(await _inventory(from))!=jsonEncode(entries)) {
      _fail('generation_source_changed');
    }
  }

  /// Installs a previously verified W9.7.5 restore into a private immutable
  /// generation. No code here opens any live application storage path.
  Future<void> installVerified({
    required String sourceDirectory,
    required String generationId,
    Future<void> Function(String)? checkpoint,
  }) async {
    if (!_id(generationId)) _fail('invalid_generation_id');
    await _checkRoot();
    final source=p.normalize(p.absolute(sourceDirectory));
    if (p.isWithin(root,source) || source==root) {
      _fail('slot_source_must_be_external');
    }
    await _withLock(_lock,() async {
      await _recoverLocked();
      final previous=await _readPointer();
      final old=previous?['active'] as String?;
      final destination=_generation(generationId);
      final incoming=_incoming(generationId);
      if (old==generationId ||
          await FileSystemEntity.type(destination.path,followLinks:false)!=
              FileSystemEntityType.notFound ||
          await FileSystemEntity.type(incoming.path,followLinks:false)!=
              FileSystemEntityType.notFound) {
        _fail('generation_already_exists');
      }
      await _verifyState(source);
      await _verifySqlite(source);
      try {
        await _journalPhase(generationId,old,'copying');
        await _checkpoint(checkpoint,'journal_written');
        await incoming.create();
        await _copyPayload(source,incoming.path);
        await _checkpoint(checkpoint,'files_copied');
        final proof=await _createProof(incoming.path,generationId);
        await File(p.join(incoming.path,_proofName)).writeAsString(
          jsonEncode(proof),flush:true);
        await _verifyGeneration(incoming,generationId);
        await _journalPhase(generationId,old,'verified');
        await _checkpoint(checkpoint,'generation_verified');
        await incoming.rename(destination.path);
        await _checkpoint(checkpoint,'directory_moved');
        await _journalPhase(generationId,old,'installed');
        await _checkpoint(checkpoint,'generation_installed');
        final checksum=await _verifyGeneration(destination,generationId);
        await _writeAtomic(_active,_pointer(generationId,checksum));
        await _checkpoint(checkpoint,'pointer_written');
        await _journalPhase(generationId,old,'committed');
        await _checkpoint(checkpoint,'journal_committed');
        await _journal.delete();
      } on ModSlotSimulatedProcessDeath {
        // Emulates an immediate process termination: leave disk exactly as
        // it was, then use a freshly reopened slot to call recover().
        rethrow;
      } catch (_) {
        await _recoverLocked();
        rethrow;
      }
    });
  }
}
