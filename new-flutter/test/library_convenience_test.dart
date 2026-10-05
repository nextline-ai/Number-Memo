import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:number_memo/data/library_store.dart';
import 'package:number_memo/data/models.dart';
import 'package:number_memo/main.dart';
import 'package:number_memo/services/catalog_service.dart';
import 'package:number_memo/ui/common.dart';
import 'package:number_memo/ui/reader_page.dart';

const _first = CatalogItem(
  id: 'hitomi:100',
  remoteId: 100,
  mode: LibraryMode.books,
  title: 'Selected first book',
  sourceUrl: 'https://example.test/galleries/100.html',
);
const _second = CatalogItem(
  id: 'hitomi:200',
  remoteId: 200,
  mode: LibraryMode.books,
  title: 'Selected second book',
  sourceUrl: 'https://example.test/galleries/200.html',
);
const _other = CatalogItem(
  id: 'hitomi:300',
  remoteId: 300,
  mode: LibraryMode.books,
  title: 'Other book',
  sourceUrl: 'https://example.test/galleries/300.html',
);

class _LibraryCatalog extends CatalogService {
  final List<int> openedBooks = [];

  @override
  Future<List<String>> galleryPages(
    int id, {
    String baseUrl = 'https://hitomi.la',
    bool refresh = false,
  }) async {
    openedBooks.add(id);
    return [
      for (var page = 1; page <= 3; page++)
        'https://example.test/$id/$page.png',
    ];
  }
}

void main() {
  Future<LibraryStore> seed() async {
    final store = LibraryStore.memory();
    addTearDown(store.dispose);
    await store.setPreferences(
      store.preferences.copyWith(onboardingComplete: true),
    );
    await store.addFolder('기존 폴더', LibraryMode.books);
    await store.addFolder('추가 폴더', LibraryMode.books);
    await store.save(
      _first,
      note: 'Important first note',
      folderIds: [store.folders.first.id],
    );
    await store.save(_second, note: 'Important second note');
    await store.save(_other, folderIds: [store.folders.first.id]);
    return store;
  }

  Future<_LibraryCatalog> showApp(
    WidgetTester tester,
    LibraryStore store, {
    Size size = const Size(1280, 1000),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final catalog = _LibraryCatalog();
    addTearDown(catalog.dispose);
    await tester.pumpWidget(NumberMemoApp(store: store, catalog: catalog));
    await tester.pumpAndSettle();
    return catalog;
  }

  Finder card(CatalogItem item) => find.byWidgetPredicate(
    (widget) => widget is CatalogCard && widget.item.id == item.id,
  );

  Future<void> tapText(WidgetTester tester, String label) async {
    final target = find.text(label);
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  Future<void> selectAll(WidgetTester tester) async {
    await tapText(tester, '여러 항목 선택');
    await tapText(tester, '전체 선택');
  }

  Future<void> deleteSelected(WidgetTester tester) async {
    final menu = find.byTooltip('선택한 항목 작업');
    await tester.ensureVisible(menu);
    await tester.pumpAndSettle();
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tapText(tester, '선택 항목 삭제');
  }

  testWidgets('unfiled and recent filters compose with the library search', (
    tester,
  ) async {
    final store = await seed();
    await store.recordReadingProgress(
      _first.id,
      1,
      openedAt: DateTime.utc(2026, 10, 1),
    );
    await showApp(tester, store);
    await tapText(tester, '미분류');
    expect(card(_second), findsOneWidget);
    expect(card(_first), findsNothing);
    expect(card(_other), findsNothing);

    await tester.enterText(find.byType(TextField), 'first');
    await tester.pumpAndSettle();
    expect(find.text('조건에 맞는 항목이 없습니다'), findsOneWidget);
    expect(find.byType(CatalogCard), findsNothing);

    await tester.enterText(find.byType(TextField), '');
    await tapText(tester, '최근 읽은 작품');
    expect(card(_first), findsOneWidget);
    expect(card(_second), findsNothing);
    expect(card(_other), findsNothing);
    await tapText(tester, '전체');
    expect(find.byType(CatalogCard), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'long press and selection add a folder without losing membership',
    (tester) async {
      final store = await seed();
      await showApp(tester, store);
      await tester.longPress(find.text(_first.title));
      await tester.pumpAndSettle();
      expect(find.text('1개 선택'), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      await tester.tap(find.text(_second.title));
      await tester.pumpAndSettle();
      expect(find.text('2개 선택'), findsOneWidget);
      await tapText(tester, '폴더 지정');
      await tapText(tester, '추가 폴더');
      await tapText(tester, '적용');

      expect(store.find(_first.id)!.folderIds, [
        store.folders.first.id,
        store.folders.last.id,
      ]);
      expect(store.find(_second.id)!.folderIds, [store.folders.last.id]);
      expect(store.find(_other.id)!.folderIds, [store.folders.first.id]);
      expect(store.find(_first.id)!.note, 'Important first note');
      expect(store.find(_second.id)!.note, 'Important second note');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('phone bulk replacement can move all selected books to unfiled', (
    tester,
  ) async {
    final store = await seed();
    await showApp(tester, store, size: const Size(390, 844));
    await selectAll(tester);
    await tapText(tester, '폴더 지정');
    final apply = find.widgetWithText(FilledButton, '적용');
    expect(tester.widget<FilledButton>(apply).onPressed, isNull);
    await tapText(tester, '기존 폴더 지정 바꾸기');
    expect(tester.widget<FilledButton>(apply).onPressed, isNotNull);
    await tapText(tester, '적용');
    expect(store.items.every((item) => item.folderIds.isEmpty), isTrue);
    await tapText(tester, '선택 종료');
    expect(find.text('여러 항목 선택'), findsOneWidget);
    await tapText(tester, '미분류');
    expect(
      tester
          .widget<FilterChip>(find.widgetWithText(FilterChip, '미분류'))
          .selected,
      isTrue,
    );
    expect(find.text('3개'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('filtered bulk deletion can be cancelled and undone losslessly', (
    tester,
  ) async {
    final store = await seed();
    await store.recordReadingProgress(
      _first.id,
      2,
      openedAt: DateTime.utc(2026, 10, 1),
    );
    final before = {
      for (final entry in store.items) entry.item.id: entry.toJson(),
    };
    await showApp(tester, store);
    await tester.enterText(find.byType(TextField), 'Selected');
    await tester.pumpAndSettle();
    await selectAll(tester);
    expect(find.text('2개 선택'), findsOneWidget);
    await deleteSelected(tester);
    await tapText(tester, '취소');
    expect(store.items.length, 3);

    await deleteSelected(tester);
    await tapText(tester, '삭제');
    expect(store.items.map((item) => item.item.id), [_other.id]);
    expect(find.text('조건에 맞는 항목이 없습니다'), findsOneWidget);
    await tapText(tester, '실행 취소');
    expect(store.items.length, 3);
    for (final item in [_first, _second, _other]) {
      expect(store.find(item.id)!.toJson(), before[item.id]);
    }
    expect(card(_first), findsOneWidget);
    expect(card(_second), findsOneWidget);
    expect(card(_other), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('continue reading opens the latest book at its saved page', (
    tester,
  ) async {
    final store = await seed();
    await store.recordReadingProgress(
      _first.id,
      0,
      openedAt: DateTime.utc(2026, 10, 1),
    );
    await store.recordReadingProgress(
      _second.id,
      1,
      openedAt: DateTime.utc(2026, 10, 2),
    );
    final catalog = await showApp(tester, store);
    expect(find.text('${_second.title} · 2페이지'), findsOneWidget);
    await tapText(tester, '이어서 읽기');
    expect(find.byType(ReaderPage), findsOneWidget);
    expect(catalog.openedBooks, [200]);
    expect(find.text('2 / 3'), findsOneWidget);
    expect(store.find(_second.id)!.readingPage, 1);
    await tester.tap(find.byTooltip('뷰어 닫기'));
    await tester.pumpAndSettle();
    expect(find.text('이어서 읽기'), findsOneWidget);
    expect(store.find(_second.id)!.note, 'Important second note');
    expect(tester.takeException(), isNull);
  });
}
