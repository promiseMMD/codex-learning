import 'mod_month_store.dart';

/// Shared native ordering, independent of modification time and input order.
int modCompareBlocks(ModStoredBlock a, ModStoredBlock b) {
  final event = a.occurredAtMs.compareTo(b.occurredAtMs);
  if (event != 0) return event;
  final created = a.createdAtMs.compareTo(b.createdAtMs);
  return created != 0 ? created : a.blockId.compareTo(b.blockId);
}

bool modValidArchiveDay(String day) {
  if (!RegExp(r'^[0-9]{4}-(0[1-9]|1[0-2])-[0-9]{2}$').hasMatch(day)) return false;
  final year = int.parse(day.substring(0, 4));
  if (year < 1) return false;
  final month = int.parse(day.substring(5, 7));
  final date = int.parse(day.substring(8, 10));
  final parsed = DateTime.utc(year, month, date);
  return parsed.year == year && parsed.month == month && parsed.day == date;
}

/// Date selection is explicit. A month browse defaults to day one only when
/// no day was selected and the selected month differs from the current month.
DateTime modInitialBlockTime({required String monthKey, String? dayKey,
  required DateTime now}) {
  final day = dayKey ?? (monthKey ==
    '${now.year.toString().padLeft(4,'0')}-${now.month.toString().padLeft(2,'0')}'
      ? '${monthKey}-${now.day.toString().padLeft(2,'0')}' : '$monthKey-01');
  if (!modValidArchiveDay(day) || !day.startsWith('$monthKey-')) {
    throw ArgumentError('invalid_initial_archive_day');
  }
  if (dayKey == null && day ==
    '${now.year.toString().padLeft(4,'0')}-${now.month.toString().padLeft(2,'0')}-${now.day.toString().padLeft(2,'0')}') return now;
  return DateTime(int.parse(day.substring(0,4)),int.parse(day.substring(5,7)),
    int.parse(day.substring(8)),now.hour,now.minute,now.second,
    now.millisecond,now.microsecond);
}
