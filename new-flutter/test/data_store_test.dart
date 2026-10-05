import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:number_memo/data/library_store.dart';
import 'package:number_memo/data/models.dart';

CatalogItem book(int id, {List<String> tags = const []}) => CatalogItem(
  id: 'hitomi:$id',
  mode: LibraryMode.books,
  title: 'Book $id',
  sourceUrl: 'https://example.test/reader/$id.html',
  remoteId: id,
  tags: tags,
  pageCount: 20,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('durable library', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('number-memo-test-');
    });

    tearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    test('concurrent writes survive reopen without lost updates', () async {
      final store = await LibraryStore.open(directory: directory);
      addTearDown(store.dispose);
      await Future.wait([
        for (var id = 1; id <= 30; id++) store.save(book(id), note: 'Note $id'),
      ]);
      final restored = await LibraryStore.open(directory: directory);
      addTearDown(restored.dispose);
      expect(restored.items.length, 30);
      expect(restored.find('hitomi:1')?.note, 'Note 1');
      expect(restored.find('hitomi:30')?.item.remoteId, 30);
      expect(await directory.list().map((entry) => entry.path).toList(), [
        '${directory.path}${Platform.pathSeparator}library.json',
      ]);
    });

    test('a failed write rolls back memory and later writes recover', () async {
      final storage = Directory(
        '${directory.path}${Platform.pathSeparator}storage',
      );
      final store = await LibraryStore.open(directory: storage);
      addTearDown(store.dispose);
      await store.save(book(1));
      var notifications = 0;
      store.addListener(() => notifications++);
      await storage.delete(recursive: true);
      final blocker = File(storage.path);
      await blocker.writeAsString('Simulated unavailable storage');

      await expectLater(
        store.save(book(2)),
        throwsA(isA<FileSystemException>()),
      );
      expect(store.items.map((saved) => saved.item.id), ['hitomi:1']);
      expect(notifications, 0);

      await blocker.delete();
      await storage.create();
      await store.save(book(3));
      expect(notifications, 1);
      final restored = await LibraryStore.open(directory: storage);
      addTearDown(restored.dispose);
      expect(restored.items.map((saved) => saved.item.id), [
        'hitomi:3',
        'hitomi:1',
      ]);
    });

    test('a corrupt library is reported and never overwritten', () async {
      final file = File(
        '${directory.path}${Platform.pathSeparator}library.json',
      );
      await file.writeAsString('{ broken data');
      await expectLater(
        LibraryStore.open(directory: directory),
        throwsA(isA<FormatException>()),
      );
      expect(await file.readAsString(), '{ broken data');
    });

    test(
      'export has exactly the same compact UTF-8 size as the persisted library',
      () async {
        final store = await LibraryStore.open(directory: directory);
        addTearDown(store.dispose);
        await store.save(
          book(1, tags: ['한국어', 'line\nbreak']),
          note: '메모\nSecond line',
        );
        final exported = store.exportBackup();
        final persisted = await File(
          '${directory.path}${Platform.pathSeparator}library.json',
        ).readAsBytes();
        expect(utf8.encode(exported), persisted);
        expect(exported, jsonEncode(jsonDecode(exported)));
        expect(utf8.encode(exported).length, greaterThan(exported.length));
        expect(maxBackupBytes, 50 * 1024 * 1024);

        final restored = LibraryStore.memory();
        addTearDown(restored.dispose);
        expect(await restored.importBackup(exported), 1);
        expect(restored.items.single.note, '메모\nSecond line');
      },
    );

    test('notes, progress, folders, preferences and servers persist', () async {
      final store = await LibraryStore.open(directory: directory);
      addTearDown(store.dispose);
      await store.addFolder('Reading', LibraryMode.books);
      final folderId = store.folders.single.id;
      await store.save(book(1), note: 'Remember this', folderIds: [folderId]);
      await store.updateSaved(store.items.single.copyWith(readingPage: 12));
      await store.addArtist('sample_artist', LibraryMode.books);
      await store.recordSearch('artist:sample_artist');
      await store.setPreferences(
        store.preferences.copyWith(
          theme: 'dark',
          readerRtl: true,
          onboardingComplete: true,
        ),
      );
      await store.upsertServer(
        const BooruServer(
          id: 'custom',
          name: 'Custom',
          baseUrl: 'https://example.test',
          engine: BooruEngine.danbooru,
        ),
      );

      final restored = await LibraryStore.open(directory: directory);
      addTearDown(restored.dispose);
      expect(restored.items.single.note, 'Remember this');
      expect(restored.items.single.readingPage, 12);
      expect(restored.items.single.folderIds, [folderId]);
      expect(restored.artists.single.name, 'sample_artist');
      expect(restored.preferences.theme, 'dark');
      expect(restored.preferences.readerRtl, isTrue);
      expect(restored.preferences.onboardingComplete, isTrue);
      expect(restored.servers.last.id, 'custom');
      expect(restored.searchHistory, ['artist:sample_artist']);
    });
  });

  group('library operations', () {
    late LibraryStore store;

    setUp(() => store = LibraryStore.memory());
    tearDown(() => store.dispose());

    test(
      'saving the same item refreshes metadata and retains user data',
      () async {
        await store.save(book(1), note: 'Saved note');
        final savedAt = store.items.single.savedAt;
        await store.updateSaved(store.items.single.copyWith(readingPage: 4));
        await store.save(book(1).copyWith(title: 'Updated title'));
        expect(store.items.length, 1);
        expect(store.items.single.item.title, 'Updated title');
        expect(store.items.single.note, 'Saved note');
        expect(store.items.single.readingPage, 4);
        expect(store.items.single.savedAt, savedAt);
      },
    );

    test('caller mutations cannot alter stored data', () async {
      final tags = ['first'];
      final saving = store.save(book(1, tags: tags));
      tags.add('late');
      await saving;
      expect(store.items.single.item.tags, ['first']);
      expect(() => store.items.clear(), throwsUnsupportedError);
      expect(
        () => store.items.single.item.tags.add('change'),
        throwsUnsupportedError,
      );
    });

    test(
      'deleting folders removes membership without deleting works',
      () async {
        await store.addFolder('Reading', LibraryMode.books);
        final folder = store.folders.single;
        await store.save(book(1), note: 'Keep me', folderIds: [folder.id]);
        await store.deleteFolder(folder.id);
        expect(store.folders, isEmpty);
        expect(store.items.single.folderIds, isEmpty);
        expect(store.items.single.note, 'Keep me');
      },
    );

    test(
      'cross-mode folder assignment fails without changing the library',
      () async {
        await store.addFolder('Images', LibraryMode.images);
        await expectLater(
          store.save(book(1), folderIds: [store.folders.single.id]),
          throwsA(isA<FormatException>()),
        );
        expect(store.items, isEmpty);
        await store.save(book(2));
        expect(store.items.single.item.id, 'hitomi:2');
      },
    );

    test('search history is bounded, recent first and deduplicated', () async {
      for (var index = 0; index < 35; index++) {
        await store.recordSearch('query $index');
      }
      await store.recordSearch('  query 10  ');
      await store.recordSearch('   ');
      expect(store.searchHistory.length, 30);
      expect(store.searchHistory.first, 'query 10');
      expect(
        store.searchHistory.where((entry) => entry == 'query 10').length,
        1,
      );
      expect(store.searchHistory.contains('query 0'), isFalse);
    });

    test('deleting a server preserves saved images', () async {
      await store.save(
        const CatalogItem(
          id: 'safebooru:123',
          mode: LibraryMode.images,
          title: 'Image',
          sourceUrl: 'https://example.test/123',
          serverId: 'safebooru',
          remoteId: 123,
        ),
      );
      await store.removeServer('safebooru');
      expect(store.servers, isEmpty);
      expect(store.items.single.item.id, 'safebooru:123');
    });
  });

  group('backup import', () {
    late LibraryStore store;

    setUp(() => store = LibraryStore.memory());
    tearDown(() => store.dispose());

    test(
      'additive import merges notes, folders and progress idempotently',
      () async {
        await store.addFolder('Reading', LibraryMode.books);
        final currentFolder = store.folders.single.id;
        await store.save(
          book(1),
          note: 'Local note',
          folderIds: [currentFolder],
        );
        await store.updateSaved(store.items.single.copyWith(readingPage: 4));

        final incoming = LibraryStore.memory();
        addTearDown(incoming.dispose);
        await incoming.addFolder('Reading', LibraryMode.books);
        await incoming.addFolder('Imported', LibraryMode.books);
        await incoming.save(
          book(1),
          note: 'Imported note',
          folderIds: incoming.folders.map((folder) => folder.id).toList(),
        );
        await incoming.updateSaved(
          incoming.items.single.copyWith(readingPage: 8),
        );
        await incoming.save(book(2));

        expect(await store.importBackup(incoming.exportBackup()), 1);
        expect(store.items.length, 2);
        expect(store.folders.length, 2);
        expect(store.find('hitomi:1')!.folderIds, contains(currentFolder));
        expect(store.find('hitomi:1')!.folderIds.length, 2);
        expect(store.find('hitomi:1')!.readingPage, 8);
        expect(store.find('hitomi:1')!.note, 'Local note\n\nImported note');
        expect(await store.importBackup(incoming.exportBackup()), 0);
        expect(store.find('hitomi:1')!.note, 'Local note\n\nImported note');
      },
    );

    test(
      'rejects an invalid record without partially importing valid ones',
      () async {
        await store.save(book(1), note: 'Keep');
        final backup = jsonDecode(store.exportBackup()) as Map<String, dynamic>;
        backup['items'] = [
          SavedItem(item: book(2), savedAt: DateTime.utc(2026)).toJson(),
          {
            'item': {'id': 'bad'},
          },
        ];
        expect(
          () => store.importBackup(jsonEncode(backup)),
          throwsA(isA<FormatException>()),
        );
        expect(store.items.single.item.id, 'hitomi:1');
        expect(store.items.single.note, 'Keep');
      },
    );

    test('rejects duplicate IDs and unsupported format versions', () async {
      await store.save(book(1));
      final backup = jsonDecode(store.exportBackup()) as Map<String, dynamic>;
      (backup['items'] as List).add((backup['items'] as List).first);
      expect(
        () => store.importBackup(jsonEncode(backup)),
        throwsA(isA<FormatException>()),
      );
      backup['version'] = 999;
      expect(
        () => store.importBackup(jsonEncode(backup)),
        throwsA(isA<FormatException>()),
      );
      expect(store.items.length, 1);
    });

    test('rejects missing or incompatible folder references', () async {
      final backup = jsonDecode(store.exportBackup()) as Map<String, dynamic>;
      backup['items'] = [
        SavedItem(
          item: book(1),
          savedAt: DateTime.utc(2026),
          folderIds: ['missing'],
        ).toJson(),
      ];
      expect(
        () => store.importBackup(jsonEncode(backup)),
        throwsA(isA<FormatException>()),
      );
      expect(store.items, isEmpty);
    });

    test('restores preferences into a new library and preserves customized settings', () async {
      final incoming = LibraryStore.memory();
      addTearDown(incoming.dispose);
      await incoming.setPreferences(
        incoming.preferences.copyWith(theme: 'dark', readerRtl: true),
      );
      await store.importBackup(incoming.exportBackup());
      expect(store.preferences.theme, 'dark');
      expect(store.preferences.readerRtl, isTrue);
      await store.setPreferences(store.preferences.copyWith(theme: 'light'));
      await store.importBackup(incoming.exportBackup());
      expect(store.preferences.theme, 'light');
    });

    test(
      'imports native iOS version 2 works, folders, notes and artists',
      () async {
        final backup = {
          'version': 2,
          'exported_at': '2026-10-01T12:00:00Z',
          'folders': [
            {
              'id': 7,
              'name': 'Native books',
              'color': 0xff123456,
              'sort_order': 0,
            },
          ],
          'works': [
            {
              'gallery_id': 123,
              'title': 'Imported book',
              'artists': 'first_artist, second_artist',
              'note': 'Native memo',
              'bookmarked_at': '2026-09-30T12:30:00Z',
              'language': 'korean',
              'tags': 'tag one, tag two',
              'folders': ['Native books'],
              'thumb_page': 3,
            },
          ],
          'artists': [
            {'name': 'first_artist', 'kind': 0, 'note': ''},
            {'name': 'sample_group', 'kind': 1, 'note': ''},
          ],
        };
        expect(await store.importBackup(jsonEncode(backup)), 1);
        final saved = store.items.single;
        expect(saved.item.id, 'hitomi:123');
        expect(saved.item.artists, ['first_artist', 'second_artist']);
        expect(saved.item.tags, ['tag one', 'tag two']);
        expect(saved.item.language, 'korean');
        expect(saved.note, 'Native memo');
        expect(saved.folderIds, [store.folders.single.id]);
        expect(saved.savedAt, DateTime.utc(2026, 9, 30, 12, 30));
        expect(store.artists.map((artist) => artist.name), [
          'first_artist',
          'group:sample_group',
        ]);
        expect(await store.importBackup(jsonEncode(backup)), 0);
        expect(store.items.length, 1);
      },
    );

    test('remaps folder ID collisions without mixing modes', () async {
      await store.addFolder('Local', LibraryMode.books);
      final currentId = store.folders.single.id;
      await store.save(book(1), folderIds: [currentId]);
      final backup = jsonDecode(
        LibraryStore.memory().exportBackup(),
      ) as Map<String, dynamic>;
      backup['folders'] = [
        MemoFolder(
          id: currentId,
          name: 'Images',
          mode: LibraryMode.images,
        ).toJson(),
      ];
      backup['items'] = [
        SavedItem(
          item: const CatalogItem(
            id: 'remote:1',
            mode: LibraryMode.images,
            title: 'Image',
            sourceUrl: 'https://example.test',
          ),
          savedAt: DateTime.utc(2026),
          folderIds: [currentId],
        ).toJson(),
      ];
      expect(await store.importBackup(jsonEncode(backup)), 1);
      expect(store.folders.length, 2);
      expect(store.find('hitomi:1')!.folderIds, [currentId]);
      expect(store.find('remote:1')!.folderIds.single, isNot(currentId));
    });
  });
}
