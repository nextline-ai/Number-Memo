// Run with: flutter test tool/render_preview.dart
// Writes neutral, in-memory UI previews to ignored build/previews/.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:number_memo/data/library_store.dart';
import 'package:number_memo/data/models.dart';
import 'package:number_memo/main.dart';

void main() {
  testWidgets('render desktop and phone layouts', (tester) async {
    // System Korean font is optional; functional tests do not need this asset.
    final fontFile = File('/System/Library/Fonts/AppleSDGothicNeo.ttc');
    if (fontFile.existsSync()) {
      final bytes = ByteData.sublistView(fontFile.readAsBytesSync());
      for (final family in ['Roboto', '.AppleSystemUIFont']) {
        final loader = FontLoader(family)..addFont(Future.value(bytes));
        await loader.load();
      }
    }
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    final oldHighlight = FocusManager.instance.highlightStrategy;
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTouch;
    addTearDown(() => FocusManager.instance.highlightStrategy = oldHighlight);
    final oldShadows = debugDisableShadows;
    debugDisableShadows = false;
    final store = LibraryStore.memory();
    await store.setPreferences(
      store.preferences.copyWith(onboardingComplete: true),
    );
    await store.addFolder('다시 보고 싶은 작품', LibraryMode.books);
    final titles = [
      '잠시 머무는 풍경',
      '오후의 기록',
      '우리의 작은 여행',
      '여름의 끝에서',
      '어느 조용한 날',
      '기억의 조각들',
    ];
    for (var i = 0; i < titles.length; i++) {
      await store.save(
        CatalogItem(
          id: 'preview:$i',
          mode: LibraryMode.books,
          title: titles[i],
          sourceUrl: 'https://example.com',
          remoteId: 1000000 + i,
          artists: ['미리보기 작가'],
          pageCount: 24 + i * 4,
        ),
      );
    }
    final boundaryKey = GlobalKey();
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final preview in <String, Size>{
      'desktop': const Size(1280, 850),
      'phone': const Size(390, 844),
      'desktop-dark': const Size(1280, 850),
      'phone-dark': const Size(390, 844),
    }.entries) {
      await store.setPreferences(
        store.preferences.copyWith(
          theme: preview.key.endsWith('dark') ? 'dark' : 'light',
        ),
      );
      tester.view.physicalSize = preview.value;
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: NumberMemoApp(store: store),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('build/previews/${preview.key}.png');
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.pumpWidget(const SizedBox.shrink());
    store.dispose();
    debugDisableShadows = oldShadows;
  });
}
