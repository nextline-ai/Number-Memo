import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:number_memo/data/library_store.dart';
import 'package:number_memo/data/models.dart';
import 'package:number_memo/main.dart';
import 'package:number_memo/services/catalog_service.dart';
import 'package:number_memo/ui/reader_page.dart';

class _ReaderCatalog extends CatalogService {
  @override
  Future<List<String>> galleryPages(
    int id, {
    String baseUrl = 'https://hitomi.la',
    bool refresh = false,
  }) async => [
    'https://example.test/1.png',
    'https://example.test/2.png',
    'https://example.test/3.png',
  ];
}

void main() {
  testWidgets('Onboarding persists and returns to the library', (tester) async {
    tester.view.reset();
    tester.view.physicalSize = const Size(1100, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = LibraryStore.memory();
    await tester.pumpWidget(NumberMemoApp(store: store));
    expect(find.text('내 보관함 시작하기'), findsOneWidget);
    await tester.tap(find.text('내 보관함 시작하기'));
    await tester.pumpAndSettle();
    expect(store.preferences.onboardingComplete, isTrue);
    expect(find.text('나의 보관함'), findsOneWidget);
    expect(find.text('첫 번째 취향을 담아 보세요'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Reader restores page, handles keyboard navigation and saves progress',
    (tester) async {
      final store = LibraryStore.memory();
      const item = CatalogItem(
        id: 'hitomi:12345',
        mode: LibraryMode.books,
        title: 'Reader fixture',
        sourceUrl: 'https://example.test/galleries/12345.html',
        remoteId: 12345,
      );
      await store.save(item);
      await store.updateSaved(store.find(item.id)!.copyWith(readingPage: 1));
      final catalog = _ReaderCatalog();
      addTearDown(catalog.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderPage(item: item, store: store, catalog: catalog),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('2 / 3'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 450));
      expect(find.text('3 / 3'), findsOneWidget);
      expect(store.find(item.id)!.readingPage, 2);
      expect(tester.takeException(), isNull);
    },
  );
}
