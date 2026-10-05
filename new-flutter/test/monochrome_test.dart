import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:number_memo/data/library_store.dart';
import 'package:number_memo/data/models.dart';
import 'package:number_memo/main.dart';
import 'package:number_memo/services/catalog_service.dart';
import 'package:number_memo/ui/app_theme.dart';
import 'package:number_memo/ui/common.dart';

class _EmptyCatalog extends CatalogService {
  @override
  Future<List<CatalogItem>> searchBooks({
    String query = '',
    int page = 0,
    String baseUrl = 'https://hitomi.la',
    String language = 'korean',
    String sort = 'latest',
  }) async => [];

  @override
  Future<CatalogPage> imagePage({
    required BooruServer server,
    String query = '',
    int page = 0,
    String rating = 'safe',
    bool popular = false,
  }) async => const CatalogPage(items: [], hasMore: false);
}

void main() {
  for (final brightness in Brightness.values) {
    test('$brightness uses neutral roles with legible text contrast', () {
      final colors = buildMonochromeTheme(brightness).colorScheme;
      for (final color in [
        colors.primary,
        colors.onPrimary,
        colors.primaryContainer,
        colors.onPrimaryContainer,
        colors.primaryFixed,
        colors.primaryFixedDim,
        colors.onPrimaryFixed,
        colors.onPrimaryFixedVariant,
        colors.secondary,
        colors.onSecondary,
        colors.secondaryContainer,
        colors.onSecondaryContainer,
        colors.secondaryFixed,
        colors.secondaryFixedDim,
        colors.onSecondaryFixed,
        colors.onSecondaryFixedVariant,
        colors.tertiary,
        colors.onTertiary,
        colors.tertiaryContainer,
        colors.onTertiaryContainer,
        colors.tertiaryFixed,
        colors.tertiaryFixedDim,
        colors.onTertiaryFixed,
        colors.onTertiaryFixedVariant,
        colors.error,
        colors.onError,
        colors.errorContainer,
        colors.onErrorContainer,
        colors.surface,
        colors.onSurface,
        colors.onSurfaceVariant,
        colors.surfaceDim,
        colors.surfaceBright,
        colors.surfaceContainerLowest,
        colors.surfaceContainerLow,
        colors.surfaceContainer,
        colors.surfaceContainerHigh,
        colors.surfaceContainerHighest,
        colors.outline,
        colors.outlineVariant,
        colors.inverseSurface,
        colors.onInverseSurface,
        colors.inversePrimary,
        colors.shadow,
        colors.scrim,
        colors.surfaceTint,
      ]) {
        expect(color.r, color.g, reason: '$color should have no tint');
        expect(color.g, color.b, reason: '$color should have no tint');
      }
      for (final pair in [
        (colors.primary, colors.onPrimary),
        (colors.primaryContainer, colors.onPrimaryContainer),
        (colors.secondary, colors.onSecondary),
        (colors.secondaryContainer, colors.onSecondaryContainer),
        (colors.tertiary, colors.onTertiary),
        (colors.tertiaryContainer, colors.onTertiaryContainer),
        (colors.error, colors.onError),
        (colors.errorContainer, colors.onErrorContainer),
        (colors.surface, colors.onSurface),
        (colors.surface, colors.onSurfaceVariant),
        (colors.surfaceContainerHighest, colors.onSurfaceVariant),
        (colors.inverseSurface, colors.onInverseSurface),
      ]) {
        final luminance = [
          pair.$1.computeLuminance(),
          pair.$2.computeLuminance(),
        ]..sort();
        final contrast = (luminance.last + .05) / (luminance.first + .05);
        expect(contrast, greaterThanOrEqualTo(4.5));
      }
    });
  }

  Future<void> shortcut(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool meta = false,
    bool shift = false,
  }) async {
    final modifier = meta
        ? LogicalKeyboardKey.metaLeft
        : LogicalKeyboardKey.controlLeft;
    await tester.sendKeyDownEvent(modifier);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(modifier);
    await tester.pumpAndSettle();
  }

  Future<LibraryStore> showApp(
    WidgetTester tester, {
    bool withSavedBook = false,
  }) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = LibraryStore.memory();
    final catalog = _EmptyCatalog();
    addTearDown(store.dispose);
    addTearDown(catalog.dispose);
    await store.setPreferences(
      store.preferences.copyWith(onboardingComplete: true),
    );
    if (withSavedBook) {
      await store.save(
        const CatalogItem(
          id: 'hitomi:1',
          mode: LibraryMode.books,
          title: 'Saved work',
          sourceUrl: 'https://example.test/galleries/1.html',
        ),
      );
    }
    await tester.pumpWidget(NumberMemoApp(store: store, catalog: catalog));
    await tester.pumpAndSettle();
    return store;
  }

  testWidgets('PC search shortcut opens and focuses library from settings', (
    tester,
  ) async {
    await showApp(tester, withSavedBook: true);
    await shortcut(tester, LogicalKeyboardKey.digit5);
    expect(find.text('내 방식대로'), findsOneWidget);
    await shortcut(tester, LogicalKeyboardKey.keyK);
    expect(find.text('나의 보관함'), findsOneWidget);
    final search = tester.widget<TextField>(find.byType(TextField).first);
    expect(search.focusNode?.hasFocus, isTrue);

    await shortcut(tester, LogicalKeyboardKey.digit3, meta: true);
    expect(find.text('나의 보관함'), findsNothing);
    await shortcut(tester, LogicalKeyboardKey.keyK, meta: true);
    expect(find.text('나의 보관함'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byType(TextField).first)
          .focusNode
          ?.hasFocus,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('search shortcut opens exploration for an empty library', (
    tester,
  ) async {
    await showApp(tester);
    await shortcut(tester, LogicalKeyboardKey.keyK);
    expect(find.text('나의 보관함'), findsNothing);
    expect(
      tester
          .widget<TextField>(find.byType(TextField).first)
          .focusNode
          ?.hasFocus,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('mode shortcut persists and image add focuses exploration', (
    tester,
  ) async {
    final store = await showApp(tester);
    await shortcut(tester, LogicalKeyboardKey.keyM, shift: true);
    expect(store.preferences.mode, LibraryMode.images);
    await shortcut(tester, LogicalKeyboardKey.keyN);
    expect(find.byType(AlertDialog), findsNothing);
    expect(
      tester
          .widget<TextField>(find.byType(TextField).first)
          .focusNode
          ?.hasFocus,
      isTrue,
    );
    await shortcut(tester, LogicalKeyboardKey.keyM, meta: true, shift: true);
    expect(store.preferences.mode, LibraryMode.books);
    expect(tester.takeException(), isNull);
  });

  testWidgets('F1 opens a discoverable shortcut legend', (tester) async {
    await showApp(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.f1);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('검색창으로 이동'), findsOneWidget);
    await tester.tap(find.text('닫기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('키보드 단축키'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('card selection never opens or saves an item', (tester) async {
    var selected = 0;
    var opened = 0;
    var saved = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildMonochromeTheme(Brightness.light),
        home: Scaffold(
          body: SizedBox(
            width: 200,
            height: 320,
            child: CatalogCard(
              item: const CatalogItem(
                id: 'hitomi:1',
                mode: LibraryMode.books,
                title: 'Selected work',
                sourceUrl: 'https://example.test/galleries/1.html',
              ),
              saved: true,
              selectionMode: true,
              selected: true,
              onSelect: () => selected++,
              onTap: () => opened++,
              onSave: () => saved++,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Selected work'));
    await tester.tap(find.byTooltip('선택 해제'));
    expect(selected, 2);
    expect(opened, 0);
    expect(saved, 0);
    expect(tester.takeException(), isNull);
  });
}
