// W9: additive SQLite v4 tables for persistent monthly record blocks.
// Deliberately do NOT edit the existing diaries/media/tombstones tables.
// This file is loaded by the existing MoodiaryDatabase migration hook.
//
// Existing Moodiary diary rows are untouched. Historical beta migration and
// cloud serialization are separate, explicitly gated work.
const List<String> modMonthSchemaDdl = [
  '''
CREATE TABLE IF NOT EXISTS mod_month_pages (
  topic_id TEXT NOT NULL,
  month_key TEXT NOT NULL,
  diary_id TEXT,
  created_ms INTEGER NOT NULL,
  PRIMARY KEY (topic_id, month_key),
  UNIQUE (diary_id),
  CHECK (length(month_key) = 7 AND
    month_key GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]' AND
    substr(month_key, 6, 2) BETWEEN '01' AND '12')
)
''',
  '''
CREATE TABLE IF NOT EXISTS mod_month_blocks (
  block_id TEXT NOT NULL PRIMARY KEY,
  topic_id TEXT NOT NULL,
  month_key TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('entry', 'summary')),
  created_ms INTEGER NOT NULL,
  FOREIGN KEY (topic_id, month_key)
    REFERENCES mod_month_pages (topic_id, month_key)
    ON UPDATE CASCADE ON DELETE RESTRICT
)
''',
  // Only one monthly summary is allowed for one topic-month. Ordinary
  // entries have no limit. A conflicting remote summary must not overwrite.
  '''
CREATE UNIQUE INDEX IF NOT EXISTS idx_mod_month_unique_summary
  ON mod_month_blocks (topic_id, month_key) WHERE kind = 'summary'
''',
  '''
CREATE INDEX IF NOT EXISTS idx_mod_month_blocks_topic_month
  ON mod_month_blocks (topic_id, month_key, created_ms)
''',
  '''
CREATE TABLE IF NOT EXISTS mod_month_revisions (
  revision_id TEXT NOT NULL PRIMARY KEY,
  block_id TEXT NOT NULL REFERENCES mod_month_blocks (block_id)
    ON DELETE RESTRICT,
  parent_revision_id TEXT,
  month_key TEXT NOT NULL,
  day_key TEXT,
  occurred_at_ms INTEGER NOT NULL,
  body_json TEXT NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1)),
  edited_at_ms INTEGER NOT NULL,
  FOREIGN KEY (parent_revision_id)
    REFERENCES mod_month_revisions (revision_id) ON DELETE RESTRICT
)
''',
  '''
CREATE INDEX IF NOT EXISTS idx_mod_month_revisions_block
  ON mod_month_revisions (block_id, edited_at_ms, revision_id)
''',
  // Allows future imported divergent branches to be represented explicitly.
  // The local editor requires exactly one head; never silently LWW.
  '''
CREATE TABLE IF NOT EXISTS mod_month_heads (
  block_id TEXT NOT NULL REFERENCES mod_month_blocks (block_id)
    ON DELETE RESTRICT,
  revision_id TEXT NOT NULL REFERENCES mod_month_revisions (revision_id)
    ON DELETE RESTRICT,
  PRIMARY KEY (block_id, revision_id)
)
''',
  // Idempotency log for interrupted local/network requests. A reused op ID
  // with a different payload is always rejected.
  '''
CREATE TABLE IF NOT EXISTS mod_month_ops (
  operation_id TEXT NOT NULL PRIMARY KEY,
  payload_sha256 TEXT NOT NULL,
  block_id TEXT NOT NULL,
  revision_id TEXT NOT NULL,
  applied_at_ms INTEGER NOT NULL
)
''',
  '''
CREATE INDEX IF NOT EXISTS idx_mod_month_ops_block
  ON mod_month_ops (block_id, applied_at_ms)
''',
];

/// Run only inside the enclosing DB creation or schema migration transaction.
/// The statements are additive, and safe to retry after an interrupted upgrade.
Future<void> createModMonthSchema(
  Future<void> Function(String statement) execute,
) async {
  for (final sql in modMonthSchemaDdl) {
    await execute(sql);
  }
}

// SQLite custom tables are not part of Drift's generated allTables list.
// A full app reset must clear them explicitly, child-first.
const List<String> modMonthClearStatements = [
  'DELETE FROM mod_month_heads',
  'DELETE FROM mod_month_ops',
  'DELETE FROM mod_month_revisions',
  'DELETE FROM mod_month_blocks',
  'DELETE FROM mod_month_pages',
];
