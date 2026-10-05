import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:number_memo/data/library_store.dart';
import 'package:number_memo/data/models.dart';
import 'package:number_memo/main.dart';
import 'package:number_memo/services/catalog_service.dart';

const _taggedBook = CatalogItem(
  id: 'hitomi:1234',
  remoteId: 1234,
  mode: LibraryMode.books,
  title: 'A tagged book',
  sourceUrl: 'https://example.test/galleries/1234.html',
  tags: ['series:quiet days', 'female:long hair'],
);
const _taggedImage = CatalogItem(
  id: 'safebooru:1234',
  remoteId: 1234,
  serverId: 'safebooru',
  mode: LibraryMode.images,
  title: 'A tagged image',
  sourceUrl: 'https://safebooru.org/index.php?page=post&s=view&id=1234',
  tags: ['long hair'],
);

class _TagCatalog extends CatalogService {
  final List<String> bookQueries = [];
  final List<({String id, List<String> excluded})> imageRequests = [];

  @override
  Future<List<CatalogItem>> searchBooks({
    String query = '',
    int page = 0,
    String baseUrl = 'https://hitomi.la',
    String language = 'korean',
    String sort = 'latest',
  }) async {
    bookQueries.add(query);
    return query.contains('-female:long_hair') ? [] : [_taggedBook];
  }

  @override
  Future<CatalogPage> imagePage({
    required BooruServer server,
    String query = '',
    int page = 0,
    String rating = 'safe',
    bool popular = false,
  }) async {
    imageRequests.add((id: server.id, excluded: [...server.excludedTags]));
    return CatalogPage(
      items:
          server.id == 'safebooru' && !server.excludedTags.contains('long_hair')
          ? [_taggedImage]
          : [],
      hasMore: false,
    );
  }
}

void main() {
  Future<void> showApp(
    WidgetTester tester,
    LibraryStore store,
    _TagCatalog catalog,
  ) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(store.dispose);
    addTearDown(catalog.dispose);
    await tester.pumpWidget(NumberMemoApp(store: store, catalog: catalog));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, '탐색'));
    await tester.pumpAndSettle();
  }

  Future<void> tagAction(WidgetTester tester, String tag, String action) async {
    final option = find.descendant(
      of: find.widgetWithText(InputChip, tag),
      matching: find.byTooltip('태그 옵션'),
    );
    await tester.ensureVisible(option);
    await tester.pumpAndSettle();
    await tester.tap(option);
    await tester.pumpAndSettle();
    expect(find.byType(SimpleDialog), findsOneWidget);
    await tester.tap(find.text(action));
    await tester.pumpAndSettle();
    expect(find.byType(SimpleDialog), findsNothing);
    expect(find.byType(Dialog), findsOneWidget);
  }

  testWidgets(
    'book tag actions normalize spaces and refresh exploration behind detail',
    (tester) async {
      final store = LibraryStore.memory();
      await store.setPreferences(
        store.preferences.copyWith(onboardingComplete: true),
      );
      final catalog = _TagCatalog();
      await showApp(tester, store, catalog);
      expect(catalog.bookQueries, ['']);
      await tester.tap(find.text(_taggedBook.title));
      await tester.pumpAndSettle();

      await tagAction(tester, 'series:quiet days', '기본 검색 태그에 추가');
      expect(store.preferences.defaultTags, ['series:quiet_days']);
      expect(catalog.bookQueries, ['', 'series:quiet_days']);

      await tagAction(tester, 'female:long hair', '이 태그를 검색에서 제외');
      expect(store.preferences.excludedTags, ['female:long_hair']);
      expect(catalog.bookQueries, [
        '',
        'series:quiet_days',
        'series:quiet_days -female:long_hair',
      ]);

      await tagAction(tester, 'female:long hair', '제외 태그에서 제거');
      expect(store.preferences.excludedTags, isEmpty);
      expect(catalog.bookQueries.length, 4);
      expect(catalog.bookQueries.last, 'series:quiet_days');

      await tagAction(tester, 'series:quiet days', '기본 검색 태그에 추가');
      expect(store.preferences.defaultTags, ['series:quiet_days']);
      expect(catalog.bookQueries.length, 4);
      await tester.tap(find.byTooltip('닫기'));
      await tester.pumpAndSettle();
      expect(find.text(_taggedBook.title), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'image exclusion toggles only the source server and refreshes behind detail',
    (tester) async {
      final store = LibraryStore.memory();
      await store.setPreferences(
        store.preferences.copyWith(
          onboardingComplete: true,
          mode: LibraryMode.images,
        ),
      );
      await store.upsertServer(
        const BooruServer(
          id: 'other',
          name: 'Other server',
          baseUrl: 'https://other.example.test',
          engine: BooruEngine.danbooru,
          excludedTags: ['existing_tag'],
        ),
      );
      final catalog = _TagCatalog();
      await showApp(tester, store, catalog);
      await tester.tap(find.text(_taggedImage.title));
      await tester.pumpAndSettle();

      await tagAction(tester, 'long hair', '이 태그를 검색에서 제외');
      expect(
        store.servers
            .singleWhere((server) => server.id == 'safebooru')
            .excludedTags,
        ['long_hair'],
      );
      expect(
        catalog.imageRequests
            .where((request) => request.id == 'safebooru')
            .map((request) => request.excluded),
        [
          <String>[],
          ['long_hair'],
        ],
      );
      expect(
        store.servers
            .singleWhere((server) => server.id == 'other')
            .excludedTags,
        ['existing_tag'],
      );
      expect(store.preferences.excludedTags, isEmpty);

      await tagAction(tester, 'long hair', '제외 태그에서 제거');
      expect(
        store.servers
            .singleWhere((server) => server.id == 'safebooru')
            .excludedTags,
        isEmpty,
      );
      expect(
        catalog.imageRequests
            .where((request) => request.id == 'safebooru')
            .map((request) => request.excluded),
        [
          <String>[],
          ['long_hair'],
          <String>[],
        ],
      );
      expect(
        store.servers
            .singleWhere((server) => server.id == 'other')
            .excludedTags,
        ['existing_tag'],
      );
      await tester.tap(find.byTooltip('닫기'));
      await tester.pumpAndSettle();
      expect(find.text(_taggedImage.title), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
