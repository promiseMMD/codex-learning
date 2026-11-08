// W9.6: deny incomplete legacy cloud/ZIP coverage of structured W9 blocks.
import 'db/database.dart';

class ModMonthArchiveBlocked implements Exception {
  final String code;
  const ModMonthArchiveBlocked(this.code);

  @override
  String toString() =>
      '长期记录的独立块、修改历史和删除信息尚未纳入完整备份协议。'
      '为防止不完整同步或恢复造成数据丢失，已暂停此操作；请保留手机本机数据。'
      '（$code）';
}

class ModMonthArchiveGate {
  const ModMonthArchiveGate._();
  static const _tables = <String>{
    'mod_month_pages', 'mod_month_blocks', 'mod_month_revisions',
    'mod_month_heads', 'mod_month_ops',
  };

  /// Before a real cloud/ZIP operation, fail closed on any structured data,
  /// unknown/missing schema or read failure. The legacy manifest has no
  /// Block/Revision/Head/Operation representation or complete restore.
  static Future<void> requireLegacyOnly(MoodiaryDatabase db) async {
    try {
      final found = await db.customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND name IN ('mod_month_pages','mod_month_blocks',"
        "'mod_month_revisions','mod_month_heads','mod_month_ops')",
      ).get();
      final present = found.map((row) => row.read<String>('name')).toSet();
      if (present.length != _tables.length || !present.containsAll(_tables)) {
        throw const ModMonthArchiveBlocked('structured_schema_incomplete');
      }
      final data = await db.customSelect('''
SELECT CASE WHEN
  EXISTS(SELECT 1 FROM mod_month_pages LIMIT 1) OR
  EXISTS(SELECT 1 FROM mod_month_blocks LIMIT 1) OR
  EXISTS(SELECT 1 FROM mod_month_revisions LIMIT 1) OR
  EXISTS(SELECT 1 FROM mod_month_heads LIMIT 1) OR
  EXISTS(SELECT 1 FROM mod_month_ops LIMIT 1)
THEN 1 ELSE 0 END AS has_data
''').getSingle();
      if (data.read<int>('has_data') != 0) {
        throw const ModMonthArchiveBlocked('structured_data_not_covered');
      }
    } on ModMonthArchiveBlocked {
      rethrow;
    } catch (_) {
      throw const ModMonthArchiveBlocked('structured_inspection_failed');
    }
  }
}
