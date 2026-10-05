import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../ui/common.dart';

const maxMediaExportBytes = 100 * 1024 * 1024;

bool get supportsMediaSharing => !Platform.isLinux;

String safeExportName(String name) {
  var safe = name
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
      .replaceFirst(RegExp(r'^\.+'), '')
      .trim()
      .replaceFirst(RegExp(r'[. ]+$'), '');
  if (safe.isEmpty) return 'number-memo-image.jpg';
  // Filename limits count UTF-8 bytes on Unix, rather than Dart code units.
  final dot = safe.lastIndexOf('.');
  final extension = dot > 0 && safe.length - dot <= 12
      ? safe.substring(dot)
      : '';
  final base = extension.isEmpty ? safe : safe.substring(0, dot);
  final output = StringBuffer();
  var bytes = utf8.encode(extension).length;
  for (final rune in base.runes) {
    final character = String.fromCharCode(rune);
    final count = utf8.encode(character).length;
    if (bytes + count > 220) break;
    output.write(character);
    bytes += count;
  }
  safe = '$output$extension';
  if (RegExp(
    r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
    caseSensitive: false,
  ).hasMatch(safe)) {
    safe = '_$safe';
  }
  return safe;
}

/// Streams to a private temporary file with a hard byte limit. HTML challenge
/// pages and error documents must not be offered to the user as image files.
Future<File> downloadMedia(
  http.Client client,
  String address, {
  required Directory directory,
  required String filename,
  Map<String, String> headers = const {},
  void Function(int received, int? total)? onProgress,
  int maxBytes = maxMediaExportBytes,
}) async {
  final uri = Uri.tryParse(address);
  if (uri == null ||
      !['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    throw const FormatException('이미지 주소가 올바르지 않습니다.');
  }
  final response = await client
      .send(http.Request('GET', uri)..headers.addAll(headers))
      .timeout(const Duration(seconds: 25));
  if (response.statusCode < 200 || response.statusCode >= 300) {
    await response.stream.listen((_) {}).cancel();
    throw HttpException('원본을 내려받지 못했습니다. HTTP ${response.statusCode}');
  }
  final mime = response.headers['content-type']
      ?.split(';')
      .first
      .trim()
      .toLowerCase();
  if (mime != null &&
      !mime.startsWith('image/') &&
      !mime.startsWith('video/') &&
      mime != 'application/octet-stream') {
    await response.stream.listen((_) {}).cancel();
    throw const FormatException('서버가 이미지 대신 다른 문서를 반환했습니다.');
  }
  if ((response.contentLength ?? 0) > maxBytes) {
    await response.stream.listen((_) {}).cancel();
    throw const FormatException('한 번에 100 MB 이하의 파일만 저장할 수 있습니다.');
  }
  final file = File(
    '${directory.path}${Platform.pathSeparator}${safeExportName(filename)}',
  );
  final sink = file.openWrite();
  var received = 0;
  try {
    // addStream applies backpressure while writing; a fast connection cannot
    // queue an entire image in memory behind the filesystem.
    await sink.addStream(
      response.stream.timeout(const Duration(seconds: 30)).map((chunk) {
        received += chunk.length;
        if (received > maxBytes) throw const FormatException('이미지 파일이 너무 큽니다.');
        onProgress?.call(received, response.contentLength);
        return chunk;
      }),
    );
    if (received == 0 ||
        (response.contentLength != null &&
            (response.headers['content-encoding'] == null ||
                response.headers['content-encoding'] == 'identity') &&
            received != response.contentLength)) {
      throw const FormatException('파일이 완전히 내려받아지지 않았습니다.');
    }
    await sink.flush();
    await sink.close();
    final input = await file.open();
    late String prefix;
    try {
      prefix = latin1.decode(await input.read(512)).trimLeft().toLowerCase();
    } finally {
      await input.close();
    }
    if (RegExp(r'^(?:<!doctype\s+html|<html|<head|<body|\{|\[)')
        .hasMatch(prefix)) {
      throw const FormatException('서버가 이미지 대신 다른 문서를 반환했습니다.');
    }
    return file;
  } catch (_) {
    // addStream can already have closed the sink after a stream error.
    // Preserve the download error while still removing any partial output.
    try {
      await sink.close();
    } catch (_) {
      // The original exception below is the useful one for the caller.
    }
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // The enclosing temporary directory is also cleaned by the UI.
    }
    rethrow;
  }
}

Future<void> cleanExpiredMediaExports(Directory cache) async {
  final cutoff = DateTime.now().subtract(const Duration(days: 1));
  await for (final entry in cache.list(followLinks: false)) {
    if (entry is! Directory ||
        !entry.path
            .split(Platform.pathSeparator)
            .last
            .startsWith('number-memo-export-')) {
      continue;
    }
    try {
      if ((await entry.stat()).modified.isBefore(cutoff)) {
        await entry.delete(recursive: true);
      }
    } on FileSystemException {
      // An old cache failure must not prevent saving a new image.
    }
  }
}

Future<bool> saveOrShareFile(
  BuildContext context,
  XFile file, {
  required String filename,
  String mimeType = 'application/octet-stream',
  bool share = false,
}) async {
  final safeName = safeExportName(filename);
  if (share && !supportsMediaSharing) {
    throw UnsupportedError('이 플랫폼에서는 이미지 저장을 이용해 주세요.');
  }
  if (share || Platform.isIOS) {
    final box = context.findRenderObject() as RenderBox?;
    final result = await SharePlus.instance.share(
      ShareParams(
        files: [file],
        fileNameOverrides: [safeName],
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
    return result.status == ShareResultStatus.success;
  }
  if (Platform.isAndroid) {
    // Storage Access Framework: the user chooses the destination. No broad
    // storage permissions and no silent writes to the photo library.
    final result = await const MethodChannel('work.nextline.number_memo/files')
        .invokeMethod<String>('saveFile', {
          'sourcePath': file.path,
          'filename': safeName,
          'mimeType': mimeType,
        });
    return result != null;
  }
  final destination = await getSaveLocation(suggestedName: safeName);
  if (destination == null) return false;
  await file.saveTo(destination.path);
  return true;
}

Future<void> exportMedia(
  BuildContext context, {
  required String url,
  required String filename,
  required Map<String, String> headers,
  bool share = false,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _MediaExport(
    url: url,
    filename: filename,
    headers: headers,
    share: share,
  ),
);

class _MediaExport extends StatefulWidget {
  const _MediaExport({
    required this.url,
    required this.filename,
    required this.headers,
    required this.share,
  });
  final String url, filename;
  final Map<String, String> headers;
  final bool share;
  @override
  State<_MediaExport> createState() => _MediaExportState();
}

class _MediaExportState extends State<_MediaExport> {
  final _client = http.Client();
  bool _cancelled = false, _choosing = false;
  double? _progress;
  String? _error;
  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  Future<void> _run() async {
    Directory? temporary;
    var retainForShare = false;
    try {
      final cache = await getTemporaryDirectory();
      await cleanExpiredMediaExports(cache);
      temporary = await cache.createTemp('number-memo-export-');
      final file = await downloadMedia(
        _client,
        widget.url,
        directory: temporary,
        filename: widget.filename,
        headers: widget.headers,
        onProgress: (received, total) {
          if (mounted && !_cancelled) {
            setState(
              () => _progress = total == null || total <= 0
                  ? null
                  : received / total,
            );
          }
        },
      );
      if (!mounted || _cancelled) return;
      setState(() => _choosing = true);
      final ext = file.path.split('.').last.toLowerCase();
      final mime = switch (ext) {
        'png' => 'image/png',
        'webp' => 'image/webp',
        'gif' => 'image/gif',
        'avif' => 'image/avif',
        'mp4' => 'video/mp4',
        'webm' => 'video/webm',
        _ => 'image/jpeg',
      };
      // Desktop sharing services may consume the URL after the chooser closes.
      // Retain the private cache for 24 hours, cleaned on the next export.
      retainForShare = widget.share || Platform.isIOS;
      final saved = await saveOrShareFile(
        context,
        XFile(file.path, mimeType: mime),
        filename: widget.filename,
        mimeType: mime,
        share: widget.share,
      );
      if (mounted) {
        Navigator.pop(context);
        if (saved) {
          showMessage(
            context,
            widget.share ? '공유 화면으로 이미지를 전달했습니다.' : '이미지를 저장했습니다.',
          );
        }
      }
    } catch (error) {
      if (mounted && !_cancelled) {
        setState(() {
          _error = '$error';
          _choosing = false;
        });
      }
    } finally {
      if (!retainForShare && temporary != null && await temporary.exists()) {
        try {
          await temporary.delete(recursive: true);
        } on FileSystemException {
          /* OS can clear its temporary cache later. */
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_choosing,
    child: AlertDialog(
      title: Text(widget.share ? '이미지 공유' : '이미지 저장'),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _error ??
                  (_choosing
                      ? '저장할 위치나 공유할 앱을 선택해 주세요.'
                      : '원본 이미지를 내려받고 있습니다.'),
            ),
            if (_error == null) ...[
              const SizedBox(height: 20),
              LinearProgressIndicator(value: _choosing ? null : _progress),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _choosing
              ? null
              : () {
                  _cancelled = true;
                  _client.close();
                  Navigator.pop(context);
                },
          child: Text(_error == null ? '취소' : '닫기'),
        ),
      ],
    ),
  );
}
