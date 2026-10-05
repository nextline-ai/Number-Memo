import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../data/library_store.dart';
import '../services/import_file.dart';
import '../services/legacy_import.dart';
import 'common.dart';

const _animeType = XTypeGroup(
  label: 'Anime Boxes 백업',
  extensions: ['abbj', 'json'],
  mimeTypes: ['application/json', 'application/octet-stream'],
  uniformTypeIdentifiers: ['public.data'],
);
const _databaseType = XTypeGroup(
  label: 'Violet 데이터베이스',
  extensions: ['db', 'sqlite', 'sqlite3'],
  mimeTypes: [
    'application/octet-stream',
    'application/x-sqlite3',
    'application/vnd.sqlite3',
  ],
  uniformTypeIdentifiers: ['public.data'],
);

Future<void> importAnimeBoxes(BuildContext context, LibraryStore store) async {
  final picked = await pickImportFile(
    type: _animeType,
    maxBytes: LegacyImportService.maxAnimeBoxesBytes,
  );
  if (picked == null) return;
  try {
    if (await picked.file.length() > LegacyImportService.maxAnimeBoxesBytes) {
      throw const FormatException('Anime Boxes 백업은 64 MB 이하여야 합니다.');
    }
    final backup = await LegacyImportService.animeBoxes(
      await picked.file.readAsBytes(),
    );
    if (context.mounted) {
      await _previewImport(
        context,
        store,
        backup,
        picked.name,
        '지원하는 Booru 서버의 즐겨찾기와 제외 태그를 가져옵니다. 지원하지 않는 서버나 잘못된 항목은 제외될 수 있습니다. 검색 즐겨찾기는 검색 기록으로 가져옵니다.',
      );
    }
  } finally {
    await picked.release();
  }
}

Future<void> importViolet(BuildContext context, LibraryStore store) async {
  final files = await showDialog<(PickedImportFile, PickedImportFile?)>(
    context: context,
    builder: (_) => const _VioletFilesDialog(),
  );
  if (files == null) return;
  Directory? temporary;
  try {
    Future<String> copy(
      PickedImportFile picked,
      String name,
      int maxBytes,
    ) async {
      final file = picked.file;
      if (await file.length() > maxBytes) {
        throw FormatException('$name 파일이 너무 큽니다.');
      }
      // The Android bridge has already made a capped private copy; avoid
      // doubling disk usage for a multi-gigabyte metadata database.
      if (picked.directory != null) return file.path;
      // A running database needs its WAL; require a complete exported snapshot.
      for (final suffix in ['-wal', '-journal']) {
        final sidecar = File('${file.path}$suffix');
        if (await sidecar.exists() && await sidecar.length() > 0) {
          throw const FormatException(
            '사용 중인 데이터베이스입니다. Violet에서 백업을 내보낸 뒤 선택해 주세요.',
          );
        }
      }
      temporary ??= await (await getTemporaryDirectory()).createTemp(
        'number-memo-violet-',
      );
      final destination = File('${temporary!.path}/$name');
      final sink = destination.openWrite();
      var size = 0;
      try {
        await sink.addStream(
          file.openRead().map((bytes) {
            size += bytes.length;
            if (size > maxBytes) throw FormatException('$name 파일이 너무 큽니다.');
            return bytes;
          }),
        );
        await sink.flush();
        await sink.close();
      } catch (_) {
        try {
          await sink.close();
        } catch (_) {
          // Preserve the original size or copy error; addStream can close an
          // already-failed sink before cleanup reaches this point.
        }
        rethrow;
      }
      return destination.path;
    }

    final user = await copy(
      files.$1,
      'user.db',
      LegacyImportService.maxVioletUserBytes,
    );
    final metadata = files.$2 == null
        ? null
        : await copy(
            files.$2!,
            'data.db',
            LegacyImportService.maxVioletMetadataBytes,
          );
    final backup = await LegacyImportService.violet(
      userDatabasePath: user,
      metadataDatabasePath: metadata,
    );
    if (context.mounted) {
      await _previewImport(
        context,
        store,
        backup,
        'Violet 백업',
        '저장한 작품, 폴더, 작가를 가져옵니다. data.db를 함께 선택하면 작품 제목과 태그도 가져옵니다. 선택한 원본 파일은 변경하지 않습니다.',
      );
    }
  } finally {
    await files.$1.release();
    await files.$2?.release();
    if (temporary != null && await temporary!.exists()) {
      await temporary!.delete(recursive: true);
    }
  }
}

Future<void> _previewImport(
  BuildContext context,
  LibraryStore store,
  String backup,
  String name,
  String detail,
) async {
  final data = jsonDecode(backup) as Map<String, dynamic>;
  final items = (data['items'] as List).length;
  final folders = (data['folders'] as List).length;
  final artists = (data['artists'] as List).length;
  final accepted = await confirm(
    context,
    title: '$name 가져오기',
    message:
        '작품 $items개 · 폴더 $folders개 · 작가 $artists개\n\n$detail\n\n기존 보관함을 유지하면서 병합하며, 이미 저장한 항목은 중복으로 추가하지 않습니다.',
    action: '가져오기',
  );
  if (!accepted || !context.mounted) return;
  final added = await store.importBackup(backup);
  if (context.mounted) showMessage(context, '$added개 항목을 추가했습니다.');
}

class _VioletFilesDialog extends StatefulWidget {
  const _VioletFilesDialog();
  @override
  State<_VioletFilesDialog> createState() => _VioletFilesDialogState();
}

class _VioletFilesDialogState extends State<_VioletFilesDialog> {
  PickedImportFile? _user, _metadata;
  bool _selecting = false, _submitted = false;

  @override
  void dispose() {
    if (!_submitted) {
      unawaited(_user?.release());
      unawaited(_metadata?.release());
    }
    super.dispose();
  }

  Future<void> _pick(bool user) async {
    setState(() => _selecting = true);
    try {
      final file = await pickImportFile(
        type: _databaseType,
        maxBytes: user
            ? LegacyImportService.maxVioletUserBytes
            : LegacyImportService.maxVioletMetadataBytes,
      );
      if (!mounted) {
        await file?.release();
      } else if (file != null) {
        final previous = user ? _user : _metadata;
        setState(() {
          if (user) {
            _user = file;
          } else {
            _metadata = file;
          }
        });
        await previous?.release();
      }
    } catch (error) {
      if (mounted) showMessage(context, '$error');
    } finally {
      if (mounted) setState(() => _selecting = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Violet 백업 가져오기'),
    content: SizedBox(
      width: 440,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Violet에서 내보낸 user.db를 선택하세요. 같은 백업의 data.db가 있으면 제목과 태그도 함께 가져올 수 있습니다.',
          ),
          const SizedBox(height: 20),
          if (_selecting) const LinearProgressIndicator(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.folder_open),
            title: const Text('user.db · 필수'),
            subtitle: Text(_user?.name ?? '파일 선택 · 최대 256 MB'),
            onTap: _selecting ? null : () => _pick(true),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.description_outlined),
            title: const Text('data.db · 선택'),
            subtitle: Text(_metadata?.name ?? '작품 정보 파일 · 최대 4 GB'),
            onTap: _selecting ? null : () => _pick(false),
            trailing: _metadata == null
                ? null
                : IconButton(
                    tooltip: '작품 정보 파일 제외',
                    icon: const Icon(Icons.close),
                    onPressed: _selecting
                        ? null
                        : () {
                            final previous = _metadata;
                            setState(() => _metadata = null);
                            unawaited(previous?.release());
                          },
                  ),
          ),
          const SizedBox(height: 12),
          const Text(
            '파일 크기에 따라 준비에 시간이 걸릴 수 있습니다. 가져올 내용을 확인한 뒤 최종 적용합니다.',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _selecting ? null : () => Navigator.pop(context),
        child: const Text('취소'),
      ),
      FilledButton(
        onPressed: _user == null || _selecting
            ? null
            : () {
                _submitted = true;
                Navigator.pop(context, (_user!, _metadata));
              },
        child: const Text('가져올 내용 확인'),
      ),
    ],
  );
}
