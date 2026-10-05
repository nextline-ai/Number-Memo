import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:number_memo/services/media_export.dart';

void main() {
  late Directory directory;
  setUp(
    () async =>
        directory = await Directory.systemTemp.createTemp('media-export-test-'),
  );
  tearDown(() async => directory.delete(recursive: true));

  test('export names preserve extension and fit UTF-8 filesystem limits', () {
    expect(safeExportName('../unsafe:name.jpg'), '_unsafe_name.jpg');
    expect(safeExportName('...'), 'number-memo-image.jpg');
    expect(safeExportName('CON.jpg'), '_CON.jpg');
    final korean = safeExportName('${List.filled(150, '가😀').join()}.webp');
    expect(utf8.encode(korean).length, lessThanOrEqualTo(220));
    expect(korean.endsWith('.webp'), isTrue);
    expect(korean.contains('\uFFFD'), isFalse);
  });

  test('streams bytes and required headers to a local file', () async {
    final data = [0x89, 0x50, 0x4e, 0x47, 1, 2, 3, 4];
    final client = MockClient.streaming((request, _) async {
      expect(request.headers['referer'], 'https://example.test');
      return http.StreamedResponse(
        Stream.fromIterable([data.sublist(0, 4), data.sublist(4)]),
        200,
        contentLength: data.length,
        headers: {'content-type': 'image/png'},
      );
    });
    addTearDown(client.close);
    final progress = <int>[];
    final file = await downloadMedia(
      client,
      'https://example.test/image.png',
      directory: directory,
      filename: 'image.png',
      headers: {'Referer': 'https://example.test'},
      onProgress: (count, _) => progress.add(count),
    );
    expect(await file.readAsBytes(), data);
    expect(progress, [4, 8]);
  });

  test('rejects error documents including HTML disguised as binary', () async {
    for (final mime in ['text/html', 'application/octet-stream']) {
      final client = MockClient(
        (_) async => http.Response(
          '<!DOCTYPE html><html>Challenge</html>',
          200,
          headers: {'content-type': mime},
        ),
      );
      addTearDown(client.close);
      await expectLater(
        downloadMedia(
          client,
          'https://example.test/image',
          directory: directory,
          filename: 'image.jpg',
        ),
        throwsFormatException,
      );
      expect(await directory.list().toList(), isEmpty);
    }
    final client = MockClient((_) async => http.Response('Denied', 403));
    addTearDown(client.close);
    await expectLater(
      downloadMedia(
        client,
        'https://example.test/image',
        directory: directory,
        filename: 'image.jpg',
      ),
      throwsA(isA<HttpException>()),
    );
  });

  test(
    'stream byte cap removes partial files when content length is absent',
    () async {
      final client = MockClient.streaming(
        (_, _) async => http.StreamedResponse(
          Stream.fromIterable([List.filled(5, 1), List.filled(5, 2)]),
          200,
          headers: {'content-type': 'image/png'},
        ),
      );
      addTearDown(client.close);
      await expectLater(
        downloadMedia(
          client,
          'https://example.test/image',
          directory: directory,
          filename: 'image.png',
          maxBytes: 8,
        ),
        throwsFormatException,
      );
      expect(await directory.list().toList(), isEmpty);
    },
  );

  test('truncated and empty responses never leave a saved file', () async {
    for (final bytes in [
      <int>[],
      [1, 2],
    ]) {
      final client = MockClient.streaming(
        (_, _) async => http.StreamedResponse(
          Stream.value(bytes),
          200,
          contentLength: 4,
          headers: {'content-type': 'image/png'},
        ),
      );
      addTearDown(client.close);
      await expectLater(
        downloadMedia(
          client,
          'https://example.test/image',
          directory: directory,
          filename: 'image.png',
        ),
        throwsFormatException,
      );
      expect(await directory.list().toList(), isEmpty);
    }
  });

  test('invalid source URLs are rejected before making a request', () async {
    final client = MockClient(
      (_) async => throw StateError('Must not request'),
    );
    addTearDown(client.close);
    for (final url in [
      'file:///tmp/local',
      'https://user:password@example.test/image',
    ]) {
      await expectLater(
        downloadMedia(client, url, directory: directory, filename: 'image.jpg'),
        throwsFormatException,
      );
    }
  });
}
