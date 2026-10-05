import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android selections live in our bounded SAF cache. Desktop selections refer
/// to original files and are never removed by [release].
class PickedImportFile {
  const PickedImportFile._(this.file, this.name, {this.directory});
  final XFile file;
  final String name;
  final Directory? directory;

  Future<void> release() async {
    try {
      if (directory != null && await directory!.exists()) {
        await directory!.delete(recursive: true);
      }
    } on FileSystemException {
      // The OS can reclaim an unavailable cache after the operation finishes.
    }
  }
}

Future<PickedImportFile?> pickImportFile({
  required XTypeGroup type,
  required int maxBytes,
}) async {
  if (Platform.isAndroid) {
    return pickAndroidImportFile(type: type, maxBytes: maxBytes);
  }
  final file = await openFile(acceptedTypeGroups: [type]);
  return file == null ? null : PickedImportFile._(file, file.name);
}

/// Kept separately so the channel contract and cache lifecycle can be tested
/// without allocating an entire selected file in the host test process.
@visibleForTesting
Future<PickedImportFile?> pickAndroidImportFile({
  required XTypeGroup type,
  required int maxBytes,
}) async {
  if (maxBytes <= 0 || maxBytes > 4 * 1024 * 1024 * 1024) {
    throw ArgumentError.value(maxBytes, 'maxBytes');
  }
  final result = await const MethodChannel('work.nextline.number_memo/files')
      .invokeMapMethod<String, dynamic>('pickFile', {
        'maxBytes': maxBytes,
        'mimeTypes': type.mimeTypes ?? const <String>[],
      });
  if (result == null) return null;
  final path = result['path'];
  final directory = result['directory'];
  final name = result['name'];
  final size = result['size'];
  if (path is! String ||
      directory is! String ||
      name is! String ||
      size is! int ||
      size < 0 ||
      size > maxBytes ||
      File(path).parent.path != directory) {
    throw const FormatException('선택한 파일을 준비하지 못했습니다. 다시 선택해 주세요.');
  }
  return PickedImportFile._(XFile(path), name, directory: Directory(directory));
}
