import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:number_memo/data/library_store.dart';
import 'package:number_memo/data/models.dart';
import 'package:number_memo/services/catalog_service.dart';
import 'package:number_memo/ui/app_theme.dart';
import 'package:number_memo/ui/common.dart';
import 'package:number_memo/ui/reader_page.dart';

class _ReaderCatalog extends CatalogService {
  @override
  Future<List<String>> galleryPages(
    int id, {
    String baseUrl = 'https://hitomi.la',
    bool refresh = false,
  }) async =>
      List.generate(6, (i) => 'https://example.test/reader-page-$i.png');
}

const _item = CatalogItem(
  id: 'hitomi:56789',
  mode: LibraryMode.books,
  title: 'Neutral reader fixture',
  sourceUrl: 'https://example.test/gallery/56789',
  remoteId: 56789,
  pageCount: 6,
);

Future<LibraryStore> _openReader(
  WidgetTester tester, {
  AppPreferences preferences = const AppPreferences(),
  int page = 0,
  bool saved = true,
}) async {
  tester.view.physicalSize = const Size(1000, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final catalog = _ReaderCatalog();
  addTearDown(catalog.dispose);
  final store = LibraryStore.memory();
  await store.setPreferences(preferences);
  if (saved) {
    await store.save(_item);
    await store.updateSaved(store.find(_item.id)!.copyWith(readingPage: page));
  }
  await tester.pumpWidget(
    MaterialApp(
      theme: buildMonochromeTheme(Brightness.light),
      home: ReaderPage(item: _item, store: store, catalog: catalog),
    ),
  );
  await tester.pumpAndSettle();
  return store;
}

Future<void> _setting(WidgetTester tester, String label) async {
  await tester.tap(find.byTooltip('읽기 설정'));
  await tester.pumpAndSettle();
  await tester.tap(
    find
        .ancestor(
          of: find.text(label),
          matching: find.byWidgetPredicate(
            (widget) => widget is PopupMenuItem<String>,
          ),
        )
        .first,
  );
  await tester.pumpAndSettle();
}

void main() {
  test('Older backups get safe reader defaults and no fabricated history', () {
    final preferences = AppPreferences.fromJson({});
    expect(preferences.readerFitWidth, isFalse);
    expect(preferences.readerShowPageNumber, isTrue);
    expect(preferences.readerTapNavigation, isTrue);
    final item = SavedItem.fromJson({
      'item': _item.toJson(),
      'savedAt': '2026-10-05T00:00:00Z',
      'readingPage': 2,
    });
    expect(item.lastOpenedAt, isNull);
    final opened = DateTime.utc(2026, 10, 5, 3);
    final roundtrip = SavedItem.fromJson(
      item.copyWith(lastOpenedAt: opened).toJson(),
    );
    expect(roundtrip.lastOpenedAt, opened);
    expect(roundtrip.readingPage, 2);
    final changed = preferences.copyWith(
      readerFitWidth: true,
      readerShowPageNumber: false,
      readerTapNavigation: false,
    );
    final restored = AppPreferences.fromJson(changed.toJson());
    expect(restored.readerFitWidth, isTrue);
    expect(restored.readerShowPageNumber, isFalse);
    expect(restored.readerTapNavigation, isFalse);
    expect(
      () => SavedItem.fromJson({...item.toJson(), 'lastOpenedAt': 'invalid'}),
      throwsFormatException,
    );
  });

  testWidgets(
    'Opening, numeric jump and keyboard endpoints save reading history',
    (tester) async {
      final store = await _openReader(tester, page: 1);
      expect(find.text('2 / 6'), findsOneWidget);
      expect(store.find(_item.id)!.lastOpenedAt, isNotNull);
      await tester.tap(find.text('2 / 6'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('reader-page-input')),
        '8',
      );
      await tester.tap(find.text('이동'));
      await tester.pump();
      expect(find.text('1~6 사이의 페이지를 입력해 주세요'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('reader-page-input')),
        '4',
      );
      await tester.tap(find.text('이동'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('4 / 6'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pumpAndSettle();
      expect(find.text('6 / 6'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 450));
      expect(find.text('1 / 6'), findsOneWidget);
      expect(store.find(_item.id)!.readingPage, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Side taps follow RTL, center toggles controls, zoom locks navigation',
    (tester) async {
      await _openReader(
        tester,
        preferences: const AppPreferences(readerRtl: true),
        page: 2,
      );
      await tester.tapAt(const Offset(50, 450));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.text('4 / 6'), findsOneWidget);
      await tester.tapAt(const Offset(950, 450));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.text('3 / 6'), findsOneWidget);
      await tester.tapAt(const Offset(500, 450));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.byTooltip('읽기 설정'), findsNothing);
      expect(find.text('3 / 6'), findsOneWidget);
      final zoomAt = const Offset(250, 450);
      await tester.tapAt(zoomAt);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(zoomAt);
      await tester.pumpAndSettle();
      final viewer = tester.widget<InteractiveViewer>(
        find.byType(InteractiveViewer).first,
      );
      final matrix = viewer.transformationController!.value;
      expect(matrix.getMaxScaleOnAxis(), 2.5);
      expect(matrix.entry(0, 3), closeTo(-zoomAt.dx * 1.5, 1));
      expect(matrix.entry(1, 3), closeTo(-zoomAt.dy * 1.5, 1));
      final pager = tester.widget<PageView>(find.byType(PageView));
      expect(pager.physics, isA<NeverScrollableScrollPhysics>());
      // A side tap while zoomed opens the menu, without losing the image.
      await tester.tapAt(const Offset(950, 450));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.text('3 / 6'), findsOneWidget);
      expect(find.byTooltip('읽기 설정'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Reader options and resize preserve continuous reading position',
    (tester) async {
      final store = await _openReader(tester, page: 3);
      await _setting(tester, '세로 연속 보기');
      expect(store.preferences.readerContinuous, isTrue);
      expect(find.text('4 / 6'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();
      expect(find.text('5 / 6'), findsOneWidget);
      tester.view.physicalSize = const Size(700, 500);
      await tester.pumpAndSettle();
      expect(find.text('5 / 6'), findsOneWidget);
      final list = tester.widget<ListView>(
        find.byKey(const ValueKey('reader-continuous')),
      );
      expect(list.controller!.offset, closeTo(2000, 1));
      await _setting(tester, '가로 맞춤');
      expect(store.preferences.readerFitWidth, isTrue);
      expect(find.text('5 / 6'), findsOneWidget);
      await _setting(tester, '세로 연속 보기');
      expect(store.preferences.readerContinuous, isFalse);
      expect(find.text('5 / 6'), findsOneWidget);
      final pager = tester.widget<PageView>(find.byType(PageView));
      expect(pager.controller!.page, 4);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Tall images remain scrollable and preserve progress when resized',
    (tester) async {
      final picture = ui.PictureRecorder();
      ui.Canvas(picture).drawRect(
        const Rect.fromLTWH(0, 0, 100, 400),
        Paint()..color = Colors.grey,
      );
      final recording = picture.endRecording();
      final decoded = await tester.runAsync(() => recording.toImage(100, 400));
      recording.dispose();
      for (var i = 0; i < 6; i++) {
        final provider = NetworkImage(
          'https://example.test/reader-page-$i.png',
          headers: imageHeaders(_item),
        );
        PaintingBinding.instance.imageCache.putIfAbsent(
          provider,
          () => OneFrameImageStreamCompleter(
            Future.value(ImageInfo(image: decoded!.clone())),
          ),
        );
      }
      decoded!.dispose();
      await _openReader(
        tester,
        preferences: const AppPreferences(
          readerContinuous: true,
          readerFitWidth: true,
        ),
      );
      expect(
        tester
            .getSize(find.byKey(const ValueKey('reader-image-0-true-true')))
            .height,
        4000,
      );
      var list = tester.widget<ListView>(
        find.byKey(const ValueKey('reader-continuous')),
      );
      list.controller!.jumpTo(2500);
      await tester.pumpAndSettle();
      expect(find.text('1 / 6'), findsOneWidget);
      list.controller!.jumpTo(4200);
      await tester.pumpAndSettle();
      expect(find.text('2 / 6'), findsOneWidget);
      tester.view.physicalSize = const Size(500, 800);
      await tester.pumpAndSettle();
      expect(find.text('2 / 6'), findsOneWidget);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('reader-image-1-true-true')))
            .height,
        2000,
      );
      list = tester.widget<ListView>(
        find.byKey(const ValueKey('reader-continuous')),
      );
      expect(list.controller!.offset, inInclusiveRange(2000, 4000));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Long press saves new work and thumbnails jump to selected page',
    (tester) async {
      final store = await _openReader(tester, saved: false);
      await tester.longPressAt(const Offset(500, 450));
      await tester.pumpAndSettle();
      expect(store.find(_item.id), isNotNull);
      expect(store.find(_item.id)!.lastOpenedAt, isNotNull);
      await _setting(tester, '페이지 목록');
      expect(find.text('페이지 목록 · 6페이지'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('reader-thumbnail-2')));
      await tester.pumpAndSettle();
      expect(find.text('3 / 6'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
