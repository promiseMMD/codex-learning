// W9.7.4: bounded central-directory inspection before Rust ZIP extraction.
// Deliberately excludes encrypted archives and unsupported ZIP64 directory
// offsets; ZIP64 per-file sizes are understood for stored large media.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'mod_month_verified_manifest_v1.dart';

final class ModMonthZipPreflightV1 {
  const ModMonthZipPreflightV1._();

  static const maxDirectoryBytes = 32 * 1024 * 1024;
  static const maxMetadataEntryBytes = 64 * 1024 * 1024;
  static const maxManifestBytes = 4 * 1024 * 1024;
  static const maxMediaEntryBytes = 64 * 1024 * 1024 * 1024;
  static const maxExpandedBytes = 512 * 1024 * 1024 * 1024;
  static const maxEntries = ModMonthVerifiedManifestV1.maxStagedFiles + 1;

  static Never _fail(String reason) => throw ModBundleInvalid(reason);

  static bool _acceptedName(String name) =>
      name == 'verified-bundle.json' ||
      ModMonthVerifiedManifestV1.allowsEntryPath(name);

  static int _u16(ByteData data, int at) =>
      data.getUint16(at, Endian.little);
  static int _u32(ByteData data, int at) =>
      data.getUint32(at, Endian.little);

  static int _u64(ByteData data, int at) {
    final low = _u32(data, at);
    final high = _u32(data, at + 4);
    if (high >= 0x80000000) _fail('zip64_size_too_large');
    return high * 4294967296 + low;
  }

  /// Only examines ZIP structure. No archive extraction and no user data
  /// mutation occurs here. Actual file SHA-256 checks happen after extraction.
  static Future<List<String>> inspect(String zipPath) async {
    if (await FileSystemEntity.type(zipPath, followLinks: false) !=
        FileSystemEntityType.file) {
      _fail('zip_not_regular_file');
    }
    final reader = await File(zipPath).open();
    try {
      final length = await reader.length();
      if (length < 22) _fail('zip_truncated');
      final tailLength = math.min(length, 65557);
      await reader.setPosition(length - tailLength);
      final tail = Uint8List.fromList(await reader.read(tailLength));
      if (tail.length != tailLength) _fail('zip_truncated');
      final tailData = ByteData.sublistView(tail);
      var eocd = -1;
      for (var index = tailLength - 22; index >= 0; index--) {
        if (_u32(tailData, index) == 0x06054b50 &&
            index + 22 + _u16(tailData, index + 20) == tailLength) {
          eocd = index;
          break;
        }
      }
      if (eocd < 0) _fail('zip_eocd_missing');
      final disk = _u16(tailData, eocd + 4);
      final directoryDisk = _u16(tailData, eocd + 6);
      final diskCount = _u16(tailData, eocd + 8);
      final entryCount = _u16(tailData, eocd + 10);
      final directoryBytes = _u32(tailData, eocd + 12);
      final directoryOffset = _u32(tailData, eocd + 16);
      if (disk != 0 || directoryDisk != 0 || diskCount != entryCount) {
        _fail('multidisk_zip_not_supported');
      }
      if (entryCount < 3 || entryCount > maxEntries ||
          entryCount == 0xffff || directoryBytes == 0xffffffff ||
          directoryOffset == 0xffffffff) {
        _fail('zip_directory_unsupported');
      }
      if (directoryBytes > maxDirectoryBytes ||
          directoryOffset + directoryBytes != length - tailLength + eocd) {
        _fail('zip_directory_bounds');
      }
      await reader.setPosition(directoryOffset);
      final central = Uint8List.fromList(await reader.read(directoryBytes));
      if (central.length != directoryBytes) _fail('zip_directory_truncated');
      final data = ByteData.sublistView(central);
      final names = <String>[];
      final seen = <String>{};
      var at = 0;
      var expanded = 0;
      var metadataExpanded = 0;
      for (var i = 0; i < entryCount; i++) {
        if (at + 46 > central.length ||
            _u32(data, at) != 0x02014b50) {
          _fail('invalid_central_entry');
        }
        final flags = _u16(data, at + 8);
        final method = _u16(data, at + 10);
        final compressed32 = _u32(data, at + 20);
        final plain32 = _u32(data, at + 24);
        final nameLen = _u16(data, at + 28);
        final extraLen = _u16(data, at + 30);
        final commentLen = _u16(data, at + 32);
        final diskStart = _u16(data, at + 34);
        final external = _u32(data, at + 38);
        final localOffset = _u32(data, at + 42);
        final end = at + 46 + nameLen + extraLen + commentLen;
        if (end > central.length || nameLen == 0 || diskStart != 0 ||
            localOffset >= directoryOffset) {
          _fail('invalid_central_entry_bounds');
        }
        if ((flags & 0x0001) != 0 || (flags & 0x0040) != 0 ||
            (method != 0 && method != 8)) {
          _fail('unsupported_zip_encryption_or_compression');
        }
        String name;
        try {
          name = utf8.decode(central.sublist(at + 46, at + 46 + nameLen),
              allowMalformed: false);
        } catch (_) {
          _fail('zip_filename_not_utf8');
        }
        if (!_acceptedName(name) || !seen.add(name)) {
          _fail('unsafe_or_duplicate_zip_entry');
        }
        final unixMode = (external >> 16) & 0xffff;
        final fileType = unixMode & 0xf000;
        if (fileType != 0 && fileType != 0x8000) {
          _fail('zip_special_file_not_allowed');
        }
        var plain = plain32;
        var compressed = compressed32;
        if (plain32 == 0xffffffff || compressed32 == 0xffffffff) {
          var extraAt = at + 46 + nameLen;
          final extraEnd = extraAt + extraLen;
          var found = false;
          while (extraAt + 4 <= extraEnd) {
            final fieldId = _u16(data, extraAt);
            final size = _u16(data, extraAt + 2);
            extraAt += 4;
            if (extraAt + size > extraEnd) _fail('invalid_zip64_extra');
            if (fieldId == 0x0001) {
              var cursor = extraAt;
              if (plain32 == 0xffffffff) {
                if (cursor + 8 > extraAt + size) _fail('invalid_zip64_extra');
                plain = _u64(data, cursor);
                cursor += 8;
              }
              if (compressed32 == 0xffffffff) {
                if (cursor + 8 > extraAt + size) _fail('invalid_zip64_extra');
                compressed = _u64(data, cursor);
              }
              found = true;
              break;
            }
            extraAt += size;
          }
          if (!found) _fail('missing_zip64_extra');
        }
        final isMedia = name.startsWith('media/');
        if (plain > (isMedia ? maxMediaEntryBytes : maxMetadataEntryBytes) ||
            (name == 'verified-bundle.json' &&
                plain > maxManifestBytes) ||
            (isMedia && (method != 0 || compressed != plain))) {
          _fail('zip_payload_quota_or_media_compression');
        }
        if (!isMedia) {
          metadataExpanded += plain;
          if (metadataExpanded > maxMetadataEntryBytes) {
            _fail('zip_total_metadata_limit');
          }
        }
        expanded += plain;
        if (expanded > maxExpandedBytes) _fail('zip_expansion_limit');
        names.add(name);
        at = end;
      }
      if (at != central.length ||
          !seen.contains('verified-bundle.json') ||
          !seen.contains('manifest.json') ||
          !seen.contains(ModMonthVerifiedManifestV1.graphPath)) {
        _fail('zip_required_entries_missing');
      }
      return names;
    } finally {
      await reader.close();
    }
  }
}
