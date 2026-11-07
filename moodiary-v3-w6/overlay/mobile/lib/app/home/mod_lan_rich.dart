// W6 LAN rich-document contract, independently guarded from the W4
// simple text editor. All unsupported native nodes/media remain read-only.
import 'dart:convert';

import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_models/moodiary_models.dart';
import 'package:moodiary_utils/moodiary_utils.dart';

import 'mod_continuous.dart' show ModDiary;
import 'mod_lan_write.dart';

/// A strict, intentionally small, lossless subset of Moodiary's native
/// Tiptap v2 schema. Rich documents with unsupported extensions are NOT
/// edited through the LAN interface.
class ModLanRichDocument {
  static const maxDocumentBytes = 200000;
  static const maxNodes = 4000;
  static const maxDepth = 12;

  static Never _reject([String reason = 'unsupported_rich_document']) =>
      throw ModLanWriteException(422, reason);

  static bool _onlyKeys(Map value, Set<String> allowed) =>
      value.keys.every((key) => key is String && allowed.contains(key));

  static void _checkTextMarks(Object? marks) {
    if (marks == null) return;
    if (marks is! List || marks.isEmpty || marks.length > 12) _reject();
    final used = <String>{};
    for (final mark in marks) {
      if (mark is! Map || mark['type'] is! String) _reject();
      final type = mark['type'] as String;
      if (!used.add(type)) _reject();
      if (const {'bold', 'italic', 'underline', 'strike', 'code'}.contains(type)) {
        if (!_onlyKeys(mark, {'type'})) _reject();
      } else if (type == 'link') {
        if (!_onlyKeys(mark, {'type', 'attrs'})) _reject();
        final attrs = mark['attrs'];
        if (attrs is! Map || !_onlyKeys(attrs, {'href'})) _reject();
        final href = attrs['href'];
        if (href is! String || href.length > 2048) _reject();
        final uri = Uri.tryParse(href);
        if (uri == null ||
            !const {'http', 'https', 'mailto'}.contains(uri.scheme.toLowerCase())) {
          _reject('unsafe_link');
        }
        if (uri.scheme.toLowerCase() != 'mailto' && uri.host.isEmpty) {
          _reject('unsafe_link');
        }
      } else {
        _reject();
      }
    }
  }

  static void _checkInline(Object? contents, void Function() counted) {
    if (contents == null) return;
    if (contents is! List) _reject();
    for (final part in contents) {
      counted();
      if (part is! Map || part['type'] is! String) _reject();
      if (part['type'] == 'text') {
        if (!_onlyKeys(part, {'type', 'text', 'marks'})) _reject();
        if (part['text'] is! String || (part['text'] as String).isEmpty) _reject();
        _checkTextMarks(part['marks']);
      } else if (part['type'] == 'hardBreak') {
        if (!_onlyKeys(part, {'type'})) _reject();
      } else {
        _reject();
      }
    }
  }

  /// Encode only fully-understood blocks. Never normalize unsupported input.
  static String validate(Object? document) {
    if (document is! Map || !_onlyKeys(document, {'type', 'attrs', 'content'}) ||
        document['type'] != 'doc') {
      _reject();
    }
    final attrs = document['attrs'];
    if (attrs is! Map || !_onlyKeys(attrs, {'v'}) || attrs['v'] != 2) _reject();
    final content = document['content'];
    if (content is! List || content.isEmpty) _reject();
    var nodes = 0;
    void counted() {
      nodes++;
      if (nodes > maxNodes) _reject('rich_document_too_large');
    }

    for (final item in content) {
      counted();
      if (item is! Map) _reject();
      switch (item['type']) {
        case 'paragraph':
          if (!_onlyKeys(item, {'type', 'content'})) _reject();
          _checkInline(item['content'], counted);
        case 'heading':
          if (!_onlyKeys(item, {'type', 'content', 'attrs'})) _reject();
          final h = item['attrs'];
          if (h is! Map || !_onlyKeys(h, {'level'}) ||
              h['level'] is! int || (h['level'] as int) < 1 ||
              (h['level'] as int) > 6) {
            _reject();
          }
          _checkInline(item['content'], counted);
        default:
          _reject();
      }
    }
    final value = jsonEncode(document);
    if (utf8.encode(value).length > maxDocumentBytes) {
      _reject('rich_document_too_large');
    }
    // A document accepted here is canonical enough to preserve all content
    // through the existing TiptapContent representation.
    if (!TiptapContent.parse(value).isDoc) _reject();
    return value;
  }

  static bool canEdit(Diary diary) {
    if (!diary.show || diary.type != DiaryType.tiptap.value ||
        diary.imageName.isNotEmpty || diary.videoName.isNotEmpty ||
        diary.audioName.isNotEmpty || diary.fileName.isNotEmpty ||
        ModDiary.isTopic(diary) || ModDiary.isChild(diary)) {
      return false;
    }
    try {
      validate(jsonDecode(diary.content));
      return true;
    } catch (_) {
      return false;
    }
  }

  static Map<String, dynamic> editableDocument(Diary diary) {
    if (!canEdit(diary)) {
      throw const ModLanWriteException(409, 'rich_diary_read_only');
    }
    return (jsonDecode(diary.content) as Map).cast<String, dynamic>();
  }
}

/// Future TipTap client adapter calls these methods, never the text-only W4
/// flatten-and-replace API. Database write methods use transactional CAS.
class ModLanRichWriter {
  final DiaryRepository repository;
  const ModLanRichWriter(this.repository);

  Future<Diary> load(String value) async {
    final id = ModLanWriteSafety.id(value);
    final found = await repository.getDiaryByBusinessId(id);
    if (found == null || !found.show) {
      throw const ModLanWriteException(404, 'diary_not_found');
    }
    return found;
  }

  Future<Diary> create(Map<String, dynamic> input) async {
    final id = ModLanWriteSafety.id(input['id']);
    final title = ModLanWriteSafety.title(input['title']);
    final content = ModLanRichDocument.validate(input['document']);
    final text = TiptapContent.parse(content).plainText;
    if (title.trim().isEmpty && text.trim().isEmpty) {
      throw const ModLanWriteException(422, 'blank_diary');
    }

    final existing = await repository.getDiaryByBusinessId(id);
    if (existing != null) {
      if (ModLanRichDocument.canEdit(existing) &&
          existing.title == title && existing.content == content) {
        return existing;
      }
      throw const ModLanWriteException(409, 'id_collision');
    }
    final diary = Diary.create(
      title: title, content: content, contentText: text,
      imageName: const [], audioName: const [], videoName: const [],
      tags: const [], type: DiaryType.tiptap,
    ).copyWith(id: id);
    if (!await repository.insertADiaryIfAbsent(diary)) {
      final now = await repository.getDiaryByBusinessId(id);
      if (now != null && ModLanRichDocument.canEdit(now) &&
          now.title == title && now.content == content) {
        return now;
      }
      throw const ModLanWriteException(409, 'id_collision');
    }
    return (await repository.getDiaryByBusinessId(id)) ??
        (throw const ModLanWriteException(500, 'write_not_readable'));
  }

  Future<Diary> update(String value, Map<String, dynamic> input) async {
    final title = ModLanWriteSafety.title(input['title']);
    final content = ModLanRichDocument.validate(input['document']);
    final rev = input['revision'];
    if (rev is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(rev)) {
      throw const ModLanWriteException(422, 'invalid_revision');
    }
    final previous = await load(value);
    if (!ModLanRichDocument.canEdit(previous)) {
      throw const ModLanWriteException(409, 'rich_diary_read_only');
    }
    if (ModLanWriteSafety.revision(previous) != rev) {
      throw const ModLanWriteException(409, 'stale_revision');
    }
    final updated = previous.copyWith(
      title: title, content: content,
      contentText: TiptapContent.parse(content).plainText,
      lastModified: DateTime.now().toUtc(),
    );
    if (!await repository.updateADiaryIfCurrent(
        newDiary: updated, expectedSnapshot: previous)) {
      throw const ModLanWriteException(409, 'stale_revision');
    }
    return (await repository.getDiaryByBusinessId(previous.id)) ??
        (throw const ModLanWriteException(500, 'write_not_readable'));
  }
}
