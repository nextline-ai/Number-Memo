import 'package:flutter_test/flutter_test.dart';
import 'package:number_memo/data/library_store.dart';
import 'package:number_memo/data/models.dart';

CatalogItem book(int id, {String? title}) => CatalogItem(
  id: 'hitomi:$id',
  mode: LibraryMode.books,
  title: title ?? '작품 #$id',
  remoteId: id,
  sourceUrl: 'https://example.test/reader/$id.html',
);
CatalogItem image(String server, int id) => CatalogItem(
  id: '$server:$id',
  mode: LibraryMode.images,
  title: 'Image $id',
  remoteId: id,
  serverId: server,
  sourceUrl: 'https://example.test/posts/$id',
);

void main() {
  late LibraryStore store;
  setUp(() => store = LibraryStore.memory());
  tearDown(() => store.dispose());

  test('batch folders add, replace, clear and reject incompatible modes atomically', () async {
    await store.addFolder('One', LibraryMode.books);
    await store.addFolder('Two', LibraryMode.books);
    await store.addFolder('Images', LibraryMode.images);
    final one = store.folders[0].id, two = store.folders[1].id;
    await store.save(book(1), folderIds: [one]);
    await store.save(book(2));
    final ids = ['hitomi:1', 'hitomi:2'];
    await store.assignFolders(ids, [two, two]);
    expect(store.find(ids[0])!.folderIds, [one, two]);
    expect(store.find(ids[1])!.folderIds, [two]);
    final before = store.exportBackup();
    await expectLater(
      store.assignFolders(ids, [store.folders[2].id]),
      throwsFormatException,
    );
    expect(store.exportBackup(), before);
    await store.assignFolders(ids, [one], replace: true);
    expect(store.find(ids[1])!.folderIds, [one]);
    await store.assignFolders(ids, [], replace: true);
    expect(store.items.every((entry) => entry.folderIds.isEmpty), isTrue);
  });

  test(
    'delete undo preserves progress but never overwrites a re-added record',
    () async {
      await store.addFolder('Soon deleted', LibraryMode.books);
      await store.save(
        book(1),
        note: 'Original note',
        folderIds: [store.folders.single.id],
      );
      await store.save(book(2), note: 'Keep me');
      final opened = DateTime.utc(2026, 10, 5);
      await store.recordReadingProgress('hitomi:1', 7, openedAt: opened);
      final snapshots = store.items.toList();
      await store.removeMany(['hitomi:1', 'hitomi:2', 'absent']);
      await store.deleteFolder(store.folders.single.id);
      await store.save(book(2, title: 'New title'), note: 'New note');
      await store.restoreItems([...snapshots, ...snapshots]);
      expect(store.items.length, 2);
      expect(store.find('hitomi:1')!.note, 'Original note');
      expect(store.find('hitomi:1')!.readingPage, 7);
      expect(store.find('hitomi:1')!.lastOpenedAt, opened);
      expect(store.find('hitomi:1')!.folderIds, isEmpty);
      expect(store.find('hitomi:2')!.note, 'New note');
      expect(store.find('hitomi:2')!.item.title, 'New title');
    },
  );

  test('queued metadata and reading updates preserve notes, title and latest progress', () async {
    await store.save(book(1), note: 'Note');
    await store.save(book(2, title: 'Custom title'));
    final opened = DateTime.utc(2026, 10, 5);
    await Future.wait([
      store.refreshMetadata(
        book(1, title: 'Fetched title').copyWith(pageCount: 33),
      ),
      store.recordReadingProgress('hitomi:1', 12, openedAt: opened),
      store.refreshMetadata(book(2, title: 'Server title')),
    ]);
    expect(store.find('hitomi:1')!.item.title, 'Fetched title');
    expect(store.find('hitomi:1')!.item.pageCount, 33);
    expect(store.find('hitomi:1')!.readingPage, 12);
    expect(store.find('hitomi:1')!.note, 'Note');
    expect(store.find('hitomi:2')!.item.title, 'Custom title');
    final restored = LibraryStore.memory();
    addTearDown(restored.dispose);
    await restored.importBackup(store.exportBackup());
    expect(restored.find('hitomi:1')!.lastOpenedAt, opened);
    await store.recordReadingProgress('hitomi:1', 2);
    expect(store.find('hitomi:1')!.readingPage, 2);
    await expectLater(
      store.recordReadingProgress('hitomi:1', -1),
      throwsFormatException,
    );
  });

  test('import deduplicates normalized server URLs and remaps image IDs idempotently', () async {
    await store.upsertServer(
      const BooruServer(
        id: 'local',
        name: 'Local',
        baseUrl: 'https://example.test/booru',
        engine: BooruEngine.danbooru,
        enabled: false,
        excludedTags: ['existing'],
      ),
    );
    await store.save(image('local', 42), note: 'Local note');
    final imported = LibraryStore.memory();
    addTearDown(imported.dispose);
    await imported.upsertServer(
      const BooruServer(
        id: 'anime-boxes',
        name: 'Imported',
        baseUrl: 'https://EXAMPLE.test/booru/',
        engine: BooruEngine.danbooru,
        excludedTags: ['existing', 'cat dog'],
      ),
    );
    await imported.save(image('anime-boxes', 42), note: 'Imported note');
    await imported.save(image('anime-boxes', 43));
    expect(await store.importBackup(imported.exportBackup()), 1);
    expect(await store.importBackup(imported.exportBackup()), 0);
    expect(store.items.length, 2);
    expect(store.find('local:42')!.note, 'Local note\n\nImported note');
    expect(store.find('local:43')!.item.serverId, 'local');
    final server = store.servers.firstWhere((server) => server.id == 'local');
    expect(server.name, 'Local');
    expect(server.enabled, isFalse);
    expect(server.excludedTags, ['existing', 'cat dog']);
  });

  test(
    'server ID collision assigns independent source and remains repeatable',
    () async {
      await store.save(image('safebooru', 1));
      final imported = LibraryStore.memory();
      addTearDown(imported.dispose);
      await imported.upsertServer(
        const BooruServer(
          id: 'safebooru',
          name: 'Different',
          baseUrl: 'https://different.test',
          engine: BooruEngine.moebooru,
        ),
      );
      await imported.save(image('safebooru', 1));
      expect(await store.importBackup(imported.exportBackup()), 1);
      final assigned = store.servers.singleWhere(
        (server) => server.name == 'Different',
      );
      expect(assigned.id, isNot('safebooru'));
      expect(store.find('${assigned.id}:1')!.item.serverId, assigned.id);
      expect(await store.importBackup(imported.exportBackup()), 0);
      expect(store.find('safebooru:1'), isNotNull);
    },
  );

  test('backup merge preserves the newest rereading position instead of an old maximum', () async {
    await store.save(book(1));
    await store.recordReadingProgress(
      'hitomi:1',
      4,
      openedAt: DateTime.utc(2026, 10, 5),
    );
    final older = LibraryStore.memory();
    addTearDown(older.dispose);
    await older.save(book(1));
    await older.recordReadingProgress(
      'hitomi:1',
      80,
      openedAt: DateTime.utc(2026, 9, 1),
    );
    await store.importBackup(older.exportBackup());
    expect(store.items.single.readingPage, 4);
    expect(store.items.single.lastOpenedAt, DateTime.utc(2026, 10, 5));
    await older.importBackup(store.exportBackup());
    expect(older.items.single.readingPage, 4);
    expect(older.items.single.lastOpenedAt, DateTime.utc(2026, 10, 5));
  });

  test('clear history preserves favorites and preferences', () async {
    await store.recordSearch('example');
    await store.save(book(1));
    await store.setPreferences(
      store.preferences.copyWith(
        readerFitWidth: true,
        readerShowPageNumber: false,
        readerTapNavigation: false,
      ),
    );
    await store.clearSearchHistory();
    expect(store.searchHistory, isEmpty);
    final restored = LibraryStore.memory();
    addTearDown(restored.dispose);
    await restored.importBackup(store.exportBackup());
    expect(restored.items.length, 1);
    expect(restored.preferences.readerFitWidth, isTrue);
    expect(restored.preferences.readerShowPageNumber, isFalse);
    expect(restored.preferences.readerTapNavigation, isFalse);
  });
}
