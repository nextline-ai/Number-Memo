import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:number_memo/services/import_file.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('work.nextline.number_memo/files');
  const type = XTypeGroup(
    label: 'Database',
    mimeTypes: ['application/octet-stream'],
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'Android picker sends byte cap and returns a file path without byte arrays',
    () async {
      final cache = await Directory.systemTemp.createTemp('import-channel-');
      addTearDown(() async {
        if (await cache.exists()) await cache.delete(recursive: true);
      });
      final file = File('${cache.path}${Platform.pathSeparator}source');
      await file.writeAsBytes([1, 2, 3]);
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'pickFile');
        expect(call.arguments, {
          'maxBytes': 4 * 1024 * 1024 * 1024,
          'mimeTypes': ['application/octet-stream'],
        });
        return {
          'path': file.path,
          'directory': cache.path,
          'name': '원본 data.db',
          'size': 3,
        };
      });
      final picked = await pickAndroidImportFile(
        type: type,
        maxBytes: 4 * 1024 * 1024 * 1024,
      );
      expect(picked!.name, '원본 data.db');
      expect(picked.file.path, file.path);
      expect(await picked.file.readAsBytes(), [1, 2, 3]);
      await picked.release();
      expect(await cache.exists(), isFalse);
      await picked.release(); // Releasing again is harmless.
    },
  );

  test(
    'Android picker cancellation and native failure remain distinct',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      expect(await pickAndroidImportFile(type: type, maxBytes: 1024), isNull);
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: 'pick_failed', message: '파일이 너무 큽니다.');
      });
      await expectLater(
        pickAndroidImportFile(type: type, maxBytes: 1024),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'pick_failed',
          ),
        ),
      );
    },
  );

  test(
    'Android picker rejects an invalid cache descriptor and limit',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {
          'path': '/different/source',
          'directory': '/cache/import',
          'name': 'user.db',
          'size': 3,
        },
      );
      await expectLater(
        pickAndroidImportFile(type: type, maxBytes: 1024),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        pickAndroidImportFile(type: type, maxBytes: 0),
        throwsA(isA<ArgumentError>()),
      );
    },
  );
}
