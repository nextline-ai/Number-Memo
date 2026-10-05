import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:number_memo/data/library_store.dart';
import 'package:number_memo/data/models.dart';
import 'package:number_memo/services/legacy_import.dart';
import 'package:sqlite3/sqlite3.dart';

Uint8List _bytes(Map<String, Object?> value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));

Map<String, Object?> _animeBackup({
  List<Map<String, Object?>>? servers,
  List<Map<String, Object?>>? favorites,
}) => {
  'backupVersion': '1.0',
  'servers':
      servers ??
      [
        {
          'url': 'http://images.example.test/',
          'type': '3',
          'serverName': 'Images',
          'isSelected': true,
        },
      ],
  'favorites':
      favorites ??
      [
        {
          'ppostId': '27',
          'ppostUrl': 'http://images.example.test/posts/27',
          'file': {'url': '//cdn.example.test/original.png', 'ext': 'png'},
          'preview': {'url': '/preview/27.jpg'},
          'sample': {'url': 'sample/27.jpg'},
          'tags': 'cat blue_eyes cat',
          'tag_artist': ['artist_name'],
          'rating': 's',
          'score': '42',
          'dateAdded': '2024-01-02T03:04:05Z',
        },
      ],
  'bannedTags': [
    'hidden',
    {'tag': 'blocked'},
    {'name': 'hidden'},
  ],
  'searchHistory': [
    {
      'searchText': 'cat',
      'searchDate': '2024-01-01T00:00:00Z',
      'starred': true,
    },
    {'searchText': 'dog', 'searchDate': '2024-02-01T00:00:00Z'},
    {'searchText': 'cat', 'searchDate': '2024-01-03T00:00:00Z'},
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Anime Boxes import', () {
    test(
      'preserves media, folders, tags, selected servers and saved date',
      () async {
        final store = LibraryStore.memory();
        addTearDown(store.dispose);
        final converted = await LegacyImportService.animeBoxes(
          _bytes(_animeBackup()),
        );
        expect(await store.importBackup(converted), 1);
        final item = store.items.single;
        final server = store.servers.last;
        expect(server.baseUrl, 'https://images.example.test');
        expect(server.enabled, isTrue);
        expect(server.excludedTags, ['hidden', 'blocked']);
        expect(item.item.serverId, server.id);
        expect(item.item.id, '${server.id}:27');
        expect(item.item.mediaUrls, ['https://cdn.example.test/original.png']);
        expect(
          item.item.thumbnailUrl,
          'https://images.example.test/preview/27.jpg',
        );
        expect(item.item.tags, ['cat', 'blue_eyes']);
        expect(item.item.artists, ['artist_name']);
        expect(item.item.rating, 'sensitive');
        expect(item.item.score, 42);
        expect(item.savedAt, DateTime.utc(2024, 1, 2, 3, 4, 5));
        expect(item.folderIds, [store.folders.single.id]);
        expect(store.folders.single.name, 'Anime Boxes');
        expect(store.searchHistory, ['dog', 'cat']);
        await store.updateSaved(
          item.copyWith(note: 'local note', readingPage: 4),
        );
        expect(await store.importBackup(converted), 0);
        expect(store.items.single.note, 'local note');
        expect(store.items.single.readingPage, 4);
      },
    );

    test(
      'deduplicates servers and posts, matches longest path with boundaries',
      () async {
        final source = _animeBackup(
          servers: [
            {
              'url': 'https://images.example.test',
              'type': 1,
              'isSelected': true,
            },
            {'url': 'https://images.example.test/', 'type': 1},
            {'url': 'https://images.example.test/booru/', 'type': 4},
            {'url': 'https://unsupported.example.test', 'type': 99},
          ],
          favorites: [
            {
              'ppostId': 1,
              'ppostUrl': 'https://images.example.test/booru/index.php?id=1',
              'rating': 's',
            },
            {
              'ppostId': 1,
              'ppostUrl': 'https://images.example.test/booru/index.php?id=1',
            },
            {
              'ppostId': 2,
              'ppostUrl': 'https://images.example.test/boorux/posts/2',
            },
            {
              'ppostId': 3,
              'ppostUrl': 'https://unrelated.example.test/posts/3',
            },
          ],
        );
        final store = LibraryStore.memory();
        addTearDown(store.dispose);
        await store.importBackup(
          await LegacyImportService.animeBoxes(_bytes(source)),
        );
        expect(store.items.length, 2);
        final child = store.servers.firstWhere(
          (server) => server.baseUrl.endsWith('/booru'),
        );
        expect(store.items.first.item.serverId, child.id);
        expect(store.items.first.item.rating, 'general');
        expect(store.items.last.item.serverId, isNot(child.id));
        expect(child.enabled, isFalse);
        expect(store.servers.length, 3); // Existing Safebooru plus two imports.
      },
    );

    test(
      'rejects invalid formats and unsupported sources before merging',
      () async {
        final store = LibraryStore.memory();
        addTearDown(store.dispose);
        final original = store.exportBackup();
        for (final bytes in [
          Uint8List.fromList(utf8.encode('{')),
          _bytes({'backupVersion': '2.0', 'servers': [], 'favorites': []}),
          _bytes(
            _animeBackup(
              servers: [
                {'url': 'https://example.test', 'type': 99},
              ],
            ),
          ),
          _bytes(
            _animeBackup(
              favorites: [
                {'ppostId': -1, 'ppostUrl': 'file:///etc/passwd'},
              ],
            ),
          ),
        ]) {
          await expectLater(
            LegacyImportService.animeBoxes(bytes).then(store.importBackup),
            throwsA(isA<FormatException>()),
          );
          expect(store.exportBackup(), original);
        }
      },
    );

    test(
      'rejects credential URLs and executable media; supports Moebooru',
      () async {
        final source = _animeBackup(
          servers: [
            {'url': 'https://user:password@bad.example.test', 'type': 3},
            {'url': 'https://yande.re/', 'type': 2},
          ],
          favorites: [
            {
              'ppostId': 123,
              'ppostUrl': 'https://yande.re/post/show/123',
              'file': {'url': 'javascript:alert(1)'},
              'sample': {
                'url': 'https://user:password@bad.example.test/image.jpg',
              },
              'preview': {'url': 'file:///secret'},
              'rating': 's',
            },
          ],
        );
        final store = LibraryStore.memory();
        addTearDown(store.dispose);
        await store.importBackup(
          await LegacyImportService.animeBoxes(_bytes(source)),
        );
        expect(store.servers.last.engine, BooruEngine.moebooru);
        expect(store.servers.last.enabled, isTrue);
        expect(store.items.single.item.mediaUrls, isEmpty);
        expect(store.items.single.item.thumbnailUrl, isEmpty);
        expect(store.items.single.item.rating, 'general');
      },
    );

    test('bounds and deduplicates recent searches', () async {
      final source = _animeBackup();
      source['searchHistory'] = [
        for (var i = 0; i < 60; i++)
          {
            'searchText': 'query$i',
            'searchDate': '2024-01-01T00:00:${i.toString().padLeft(2, '0')}Z',
          },
      ];
      final store = LibraryStore.memory();
      addTearDown(store.dispose);
      await store.importBackup(
        await LegacyImportService.animeBoxes(_bytes(source)),
      );
      expect(store.searchHistory.length, 30);
      expect(store.searchHistory.first, 'query59');
      expect(store.searchHistory.last, 'query30');
    });
  });

  group('Violet import', () {
    late Directory directory;
    late String userPath;
    late String metadataPath;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('violet-import-');
      userPath = '${directory.path}${Platform.pathSeparator}user.db';
      metadataPath = '${directory.path}${Platform.pathSeparator}data.db';
    });
    tearDown(() async => directory.delete(recursive: true));

    void createUser() {
      final db = sqlite3.open(userPath);
      try {
        db.execute(
          'CREATE TABLE BookmarkGroup (Id INTEGER, Name TEXT, Color INTEGER, Gorder INTEGER)',
        );
        db.execute(
          'INSERT INTO BookmarkGroup VALUES (1, ?, 0, 0), (2, ?, 0, 1), (3, ?, 0, 2)',
          ['violet_default', '읽을 책', '다음 책'],
        );
        db.execute(
          'CREATE TABLE BookmarkArticle (Id INTEGER, Article, GroupId, DateTime)',
        );
        db.execute(
          'INSERT INTO BookmarkArticle VALUES (1, ?, 1, ?), (2, ?, 2, ?), (3, ?, 3, ?), (4, 9876, 999, ?)',
          [
            '1234',
            '2024-01-02T00:00:00Z',
            1234,
            '2024-01-03T00:00:00Z',
            1234,
            '2024-01-04T00:00:00Z',
            638397504000000000,
          ],
        );
        db.execute('CREATE TABLE BookmarkArtist (Artist TEXT, IsGroup)');
        db.execute('INSERT INTO BookmarkArtist VALUES (?, 0), (?, 0), (?, 1)', [
          'an_artist',
          'AN_ARTIST',
          'a_group',
        ]);
      } finally {
        db.close();
      }
    }

    test(
      'imports folder membership, mixed IDs, .NET dates and favorite artists',
      () async {
        createUser();
        final before = await File(userPath).readAsBytes();
        final store = LibraryStore.memory();
        addTearDown(store.dispose);
        final source = await LegacyImportService.violet(
          userDatabasePath: userPath,
        );
        expect(await store.importBackup(source), 2);
        expect(store.folders.map((folder) => folder.name), [
          '미분류',
          '읽을 책',
          '다음 책',
        ]);
        final item = store.find('hitomi:1234')!;
        expect(item.folderIds.toSet(), {'violet-group:2', 'violet-group:3'});
        expect(item.savedAt, DateTime.utc(2024, 1, 2));
        expect(store.find('hitomi:9876')!.folderIds, ['violet-group:1']);
        expect(store.find('hitomi:9876')!.savedAt, DateTime.utc(2024, 1, 2));
        expect(store.artists.map((artist) => artist.name), [
          'an_artist',
          'group:a_group',
        ]);
        expect(await store.importBackup(source), 0);
        expect(await File(userPath).readAsBytes(), before);
        expect(await directory.list().map((entry) => entry.path).toList(), [
          userPath,
        ]);
      },
    );

    test('matches only bookmarked metadata and decodes title and piped values', () async {
      createUser();
      final db = sqlite3.open(metadataPath);
      try {
        db.execute(
          'CREATE TABLE HitomiColumnModel (Id INTEGER PRIMARY KEY, Title, Type, Artists, Characters, Groups, Language, Series, Tags, Published)',
        );
        db.execute(
          'INSERT INTO HitomiColumnModel VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          [
            1234,
            'A &amp; B &#39;book&#39;',
            'manga',
            '|alice|N/A|bob|',
            '|character a|',
            '|group a|',
            'korean',
            '|series a|',
            '|tag1|tag2|',
            638397504000000000,
          ],
        );
        db.execute(
          'INSERT INTO HitomiColumnModel (Id, Title) VALUES (7777, ?)',
          ['Unrelated'],
        );
      } finally {
        db.close();
      }
      final before = await File(metadataPath).readAsBytes();
      final store = LibraryStore.memory();
      addTearDown(store.dispose);
      await store.importBackup(
        await LegacyImportService.violet(
          userDatabasePath: userPath,
          metadataDatabasePath: metadataPath,
        ),
      );
      final item = store.find('hitomi:1234')!.item;
      expect(item.title, "A & B 'book'");
      expect(item.artists, ['alice', 'bob']);
      expect(item.language, 'korean');
      expect(item.tags, [
        'tag1',
        'tag2',
        'group:group a',
        'series:series a',
        'character:character a',
      ]);
      expect(item.description, 'manga · 2024-01-02');
      expect(store.find('hitomi:7777'), isNull);
      expect(store.find('hitomi:9876')!.item.title, '작품 #9876');
      expect(await File(metadataPath).readAsBytes(), before);
      expect(await directory.list().length, 2);
    });

    test(
      'supports minimal older schema and creates a default folder',
      () async {
        final db = sqlite3.open(userPath);
        try {
          db.execute(
            'CREATE TABLE BookmarkArticle (GalleryId TEXT, group_id TEXT)',
          );
          db.execute('INSERT INTO BookmarkArticle VALUES (?, ?)', [
            '5555',
            '9',
          ]);
        } finally {
          db.close();
        }
        final store = LibraryStore.memory();
        addTearDown(store.dispose);
        await store.importBackup(
          await LegacyImportService.violet(userDatabasePath: userPath),
        );
        expect(store.items.single.item.remoteId, 5555);
        expect(store.items.single.folderIds, ['violet-default']);
        expect(store.folders.single.name, '미분류');
      },
    );

    test(
      'rejects incorrect DBs and truncated files without altering the library',
      () async {
        final store = LibraryStore.memory();
        addTearDown(store.dispose);
        final original = store.exportBackup();
        await File(userPath).writeAsString('SQLite format 3\x00');
        await expectLater(
          LegacyImportService.violet(userDatabasePath: userPath)
              .then(store.importBackup),
          throwsA(isA<FormatException>()),
        );
        await File(userPath).delete();
        final db = sqlite3.open(userPath);
        db.execute('CREATE TABLE Unrelated (Id INTEGER)');
        db.close();
        await expectLater(
          LegacyImportService.violet(userDatabasePath: userPath)
              .then(store.importBackup),
          throwsA(isA<FormatException>()),
        );
        expect(store.exportBackup(), original);
      },
    );

    test(
      'rejects active WAL and invalid optional metadata atomically',
      () async {
        createUser();
        final store = LibraryStore.memory();
        addTearDown(store.dispose);
        final original = store.exportBackup();
        final wal = File('$userPath-wal');
        await wal.writeAsString('active WAL');
        await expectLater(
          LegacyImportService.violet(userDatabasePath: userPath)
              .then(store.importBackup),
          throwsA(isA<FormatException>()),
        );
        await wal.delete();
        final db = sqlite3.open(metadataPath);
        db.execute('CREATE TABLE WrongData (Id INTEGER)');
        db.close();
        await expectLater(
          LegacyImportService.violet(
            userDatabasePath: userPath,
            metadataDatabasePath: metadataPath,
          ).then(store.importBackup),
          throwsA(isA<FormatException>()),
        );
        expect(store.exportBackup(), original);
      },
    );

    test('rejects an empty user backup', () async {
      final db = sqlite3.open(userPath);
      db.execute('CREATE TABLE BookmarkArticle (Article INTEGER)');
      db.close();
      await expectLater(
        LegacyImportService.violet(userDatabasePath: userPath),
        throwsA(isA<FormatException>()),
      );
    });

    test('bounds metadata text before merging the user library', () async {
      createUser();
      final db = sqlite3.open(metadataPath);
      try {
        db.execute('CREATE TABLE HitomiColumnModel (Id INTEGER, Title TEXT)');
        db.execute('INSERT INTO HitomiColumnModel VALUES (?, ?)', [
          1234,
          'x' * 32769,
        ]);
      } finally {
        db.close();
      }
      final store = LibraryStore.memory();
      addTearDown(store.dispose);
      final original = store.exportBackup();
      await expectLater(
        LegacyImportService.violet(
          userDatabasePath: userPath,
          metadataDatabasePath: metadataPath,
        ).then(store.importBackup),
        throwsA(isA<FormatException>()),
      );
      expect(store.exportBackup(), original);
    });
  });
}
