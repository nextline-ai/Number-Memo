import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:number_memo/data/library_store.dart';
import 'package:number_memo/data/models.dart';
import 'package:number_memo/main.dart';
import 'package:number_memo/ui/settings_page.dart';
import 'package:number_memo/services/catalog_service.dart';
import 'package:number_memo/ui/common.dart';

const _book = CatalogItem(
  id: 'hitomi:1234567',
  mode: LibraryMode.books,
  title: 'A neutral catalog title',
  sourceUrl: 'https://example.com/galleries/1234567.html',
  remoteId: 1234567,
);

class _CatalogStub extends CatalogService {
  int galleryRequests = 0;
  bool failSearch = false;
  final List<String> bookQueries = [];
  final List<String> bookSorts = [];
  final List<String> imageRequests = [];
  Future<CatalogPage> Function(BooruServer server, int page)? imageResponse;

  @override
  Future<CatalogItem> gallery(
    int id, {
    String baseUrl = 'https://hitomi.la',
    bool refresh = false,
  }) async {
    galleryRequests++;
    return _book;
  }

  @override
  Future<List<CatalogItem>> searchBooks({
    String query = '',
    int page = 0,
    String baseUrl = 'https://hitomi.la',
    String language = 'korean',
    String sort = 'latest',
  }) async {
    bookQueries.add(query);
    bookSorts.add(sort);
    if (failSearch) throw const CatalogException('테스트 서버에 연결할 수 없습니다.');
    if (!{'latest', 'today', 'week', 'month', 'year'}.contains(sort)) {
      throw const CatalogException('지원하지 않는 정렬입니다.');
    }
    return page == 0 ? [_book] : [];
  }

  @override
  Future<CatalogPage> imagePage({
    required BooruServer server,
    String query = '',
    int page = 0,
    String rating = 'safe',
    bool popular = false,
  }) async {
    imageRequests.add('${server.id}:$page');
    return imageResponse == null
        ? const CatalogPage(items: [], hasMore: false)
        : imageResponse!(server, page);
  }
}

void main() {
  Future<void> showApp(
    WidgetTester tester,
    LibraryStore store,
    _CatalogStub catalog, {
    Size size = const Size(1280, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(store.dispose);
    addTearDown(catalog.dispose);
    await tester.pumpWidget(NumberMemoApp(store: store, catalog: catalog));
    await tester.pumpAndSettle();
  }

  Future<void> navigate(WidgetTester tester, String label) async {
    await tester.tap(find.text(label).first);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'desktop onboarding and offline save retain edits and folder membership',
    (tester) async {
      final store = LibraryStore.memory();
      final catalog = _CatalogStub();
      await showApp(tester, store, catalog);

      await tester.ensureVisible(find.text('내 보관함 시작하기'));
      await tester.tap(find.text('내 보관함 시작하기'));
      await tester.pumpAndSettle();
      expect(store.preferences.onboardingComplete, isTrue);
      expect(find.byType(NavigationBar), findsNothing);

      await navigate(tester, '폴더');
      await tester.tap(find.text('새 폴더'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '읽을 목록');
      await tester.tap(find.text('저장'));
      await tester.pumpAndSettle();
      final folderId = store.folders.single.id;

      await navigate(tester, '보관함');
      await tester.tap(find.text('작품 추가').first);
      await tester.pumpAndSettle();
      final addFields = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(addFields.at(0), '1234567');
      await tester.enterText(addFields.at(1), '처음 적은 메모');
      await tester.tap(find.text('읽을 목록'));
      await tester.tap(find.text('제목과 표지 불러오기'));
      await tester.tap(find.text('저장'));
      await tester.pumpAndSettle();

      expect(catalog.galleryRequests, 0);
      expect(store.find(_book.id)?.note, '처음 적은 메모');
      expect(store.find(_book.id)?.folderIds, [folderId]);
      await tester.tap(find.text('작품 #1234567'));
      await tester.pumpAndSettle();
      final editFields = find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(editFields.at(0), '내가 붙인 제목');
      await tester.enterText(editFields.at(1), '기억할 장면을 메모했어요.');
      await tester.tap(find.text('변경사항 저장'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('닫기'));
      await tester.pumpAndSettle();

      expect(store.find(_book.id)?.item.title, '내가 붙인 제목');
      expect(store.find(_book.id)?.note, '기억할 장면을 메모했어요.');
      await navigate(tester, '폴더');
      await tester.tap(find.text('읽을 목록'));
      await tester.pumpAndSettle();
      expect(find.text('내가 붙인 제목'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('native imported group opens a group search on a phone', (
    tester,
  ) async {
    final store = LibraryStore.memory();
    await store.importBackup(
      jsonEncode({
        'version': 2,
        'exported_at': '2026-10-05T00:00:00Z',
        'folders': [],
        'works': [],
        'artists': [
          {'name': 'Example Studio', 'kind': 1},
        ],
      }),
    );
    await store.setPreferences(
      store.preferences.copyWith(onboardingComplete: true),
    );
    final catalog = _CatalogStub();
    await showApp(tester, store, catalog, size: const Size(390, 844));

    expect(find.byType(NavigationBar), findsOneWidget);
    await navigate(tester, '작가');
    await tester.tap(find.textContaining('Example Studio'));
    await tester.pumpAndSettle();

    expect(catalog.bookQueries.last, 'group:Example_Studio');
    expect(tester.takeException(), isNull);
  });

  testWidgets('book popular control requests a supported popularity period', (
    tester,
  ) async {
    final store = LibraryStore.memory();
    await store.setPreferences(
      store.preferences.copyWith(onboardingComplete: true),
    );
    final catalog = _CatalogStub();
    await showApp(tester, store, catalog);
    await navigate(tester, '탐색');
    await tester.tap(find.text('인기순'));
    await tester.pumpAndSettle();

    expect(catalog.bookSorts.last, isIn(['today', 'week', 'month', 'year']));
    expect(find.text('지원하지 않는 정렬입니다.'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'saving an existing exploration result preserves a custom title',
    (tester) async {
      final store = LibraryStore.memory();
      await store.setPreferences(
        store.preferences.copyWith(onboardingComplete: true),
      );
      await store.save(
        _book.copyWith(title: 'My saved title'),
        note: 'Keep this note',
      );
      final catalog = _CatalogStub();
      await showApp(tester, store, catalog);
      await navigate(tester, '탐색');
      await tester.tap(find.byTooltip('저장됨'));
      await tester.pumpAndSettle();

      expect(store.find(_book.id)?.item.title, 'My saved title');
      expect(store.find(_book.id)?.note, 'Keep this note');
      await tester.tap(find.text('A neutral catalog title'));
      await tester.pumpAndSettle();
      final editFields = find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(TextField),
      );
      expect(
        tester.widget<TextField>(editFields.at(0)).controller?.text,
        'My saved title',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('connection errors and retry remain usable on a small phone', (
    tester,
  ) async {
    final store = LibraryStore.memory();
    await store.setPreferences(
      store.preferences.copyWith(onboardingComplete: true),
    );
    final catalog = _CatalogStub()..failSearch = true;
    await showApp(tester, store, catalog, size: const Size(360, 800));
    await navigate(tester, '탐색');
    expect(find.text('테스트 서버에 연결할 수 없습니다.'), findsOneWidget);
    expect(tester.takeException(), isNull);

    catalog.failSearch = false;
    await tester.ensureVisible(find.text('다시 시도'));
    await tester.tap(find.text('다시 시도'));
    await tester.pumpAndSettle();
    expect(find.text('A neutral catalog title'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('short desktop windows can scroll to settings', (tester) async {
    final store = LibraryStore.memory();
    await store.setPreferences(
      store.preferences.copyWith(onboardingComplete: true),
    );
    await showApp(tester, store, _CatalogStub(), size: const Size(1000, 480));
    final settings = find.widgetWithText(ListTile, '설정');
    await tester.ensureVisible(settings);
    await tester.tap(settings);
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('short viewer error surfaces can scroll to recovery actions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 260);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var retried = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox.expand(
            child: EmptyState(
              icon: Icons.broken_image_outlined,
              title: '이미지를 불러올 수 없습니다',
              message: '연결을 확인한 뒤 다시 시도해 주세요.',
              action: FilledButton(
                onPressed: () => retried = true,
                child: const Text('다시 시도'),
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('다시 시도'));
    await tester.tap(find.text('다시 시도'));
    expect(retried, isTrue);
  });

  testWidgets(
    'Android shared links wait for onboarding and open an editable dialog',
    (tester) async {
      const channel = MethodChannel('work.nextline.number_memo/share');
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        return call.method == 'initialText'
            ? 'https://hitomi.la/galleries/7654321.html'
            : null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      try {
        final store = LibraryStore.memory();
        await showApp(
          tester,
          store,
          _CatalogStub(),
          size: const Size(390, 844),
        );
        expect(find.byType(AlertDialog), findsNothing);
        expect(store.items, isEmpty);
        await tester.ensureVisible(find.text('내 보관함 시작하기'));
        await tester.tap(find.text('내 보관함 시작하기'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        final fields = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        );
        expect(
          tester.widget<TextField>(fields.first).controller?.text,
          'https://hitomi.la/galleries/7654321.html',
        );
        expect(store.items, isEmpty);
        await tester.tap(find.text('취소'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'multi-server loading retries a failed server without skipping its page',
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
          name: 'Other gallery',
          baseUrl: 'https://other.example',
          engine: BooruEngine.danbooru,
        ),
      );
      var failOther = true;
      final catalog = _CatalogStub();
      catalog.imageResponse = (server, page) async {
        if (server.id == 'other' && failOther) {
          failOther = false;
          throw const CatalogException('Temporary outage');
        }
        return CatalogPage(
          items: page == 0
              ? [
                  CatalogItem(
                    id: '${server.id}:100',
                    mode: LibraryMode.images,
                    title: '${server.name} image',
                    sourceUrl: '${server.baseUrl}/posts/100',
                    remoteId: 100,
                    serverId: server.id,
                  ),
                ]
              : [],
          hasMore: server.id == 'safebooru' && page == 0,
        );
      };
      await showApp(tester, store, catalog);
      await navigate(tester, '탐색');
      expect(
        catalog.imageRequests.where((request) => request.startsWith('other:')),
        ['other:0'],
      );
      await tester.scrollUntilVisible(
        find.text('더 불러오기'),
        300,
        scrollable: find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('더 불러오기'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('더 불러오기'));
      await tester.pumpAndSettle();
      expect(
        catalog.imageRequests.where((request) => request.startsWith('other:')),
        ['other:0', 'other:0'],
      );
      expect(
        catalog.imageRequests.where(
          (request) => request.startsWith('safebooru:'),
        ),
        ['safebooru:0', 'safebooru:1'],
      );
      expect(find.textContaining('Temporary outage'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a filtered empty image page can still load the next page', (
    tester,
  ) async {
    final store = LibraryStore.memory();
    await store.setPreferences(
      store.preferences.copyWith(
        onboardingComplete: true,
        mode: LibraryMode.images,
      ),
    );
    final catalog = _CatalogStub();
    catalog.imageResponse = (server, page) async => CatalogPage(
      items: page == 0
          ? []
          : [
              CatalogItem(
                id: '${server.id}:200',
                mode: LibraryMode.images,
                title: 'Visible image',
                sourceUrl: '${server.baseUrl}/posts/200',
                remoteId: 200,
                serverId: server.id,
              ),
            ],
      hasMore: page == 0,
    );
    await showApp(tester, store, catalog);
    await navigate(tester, '탐색');
    await tester.scrollUntilVisible(
      find.text('더 불러오기'),
      300,
      scrollable: find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.text('더 불러오기'));
    await tester.pumpAndSettle();
    expect(catalog.imageRequests, ['safebooru:0', 'safebooru:1']);
    expect(tester.takeException(), isNull);
  });
}
