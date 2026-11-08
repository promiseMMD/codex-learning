// W9.8.1: additive daily projection index, not a native Diary migration.
// Existing W9 month blocks and all original Diary rows are left unchanged.
// The nullable diary_id is reserved for a later guarded native projection.
const List<String> modDaySchemaDdl = [
  '''
CREATE TABLE IF NOT EXISTS mod_day_pages (
  topic_id TEXT NOT NULL,
  day_key TEXT NOT NULL,
  diary_id TEXT UNIQUE REFERENCES diaries(id) ON DELETE RESTRICT,
  visible_local INTEGER NOT NULL DEFAULT 1
    CHECK (visible_local IN (0, 1)),
  created_ms INTEGER NOT NULL CHECK (created_ms >= 0),
  PRIMARY KEY (topic_id, day_key),
  CHECK (length(day_key) = 10 AND
    day_key GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND
    substr(day_key, 6, 2) BETWEEN '01' AND '12' AND
    substr(day_key, 9, 2) BETWEEN '01' AND '31')
)
''',
  '''
CREATE INDEX IF NOT EXISTS idx_mod_day_pages_topic_day
  ON mod_day_pages (topic_id, day_key DESC)
''',
];

Future<void> createModDaySchema(
  Future<void> Function(String statement) execute,
) async {
  for (final sql in modDaySchemaDdl) {
    await execute(sql);
  }
}

// A full application reset clears custom rows before the parent Diaries.
const List<String> modDayClearStatements = [
  'DELETE FROM mod_day_pages',
];
