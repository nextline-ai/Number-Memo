import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:number_memo/data/models.dart';
import 'package:number_memo/ui/common.dart';

void main() {
  testWidgets(
    'large catalog builds viewport cards and exposes the final row on scroll',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = ScrollController();
      addTearDown(controller.dispose);
      final items = List.generate(
        2000,
        (index) => CatalogItem(
          id: 'item:$index',
          mode: LibraryMode.books,
          title: 'Item $index',
          sourceUrl: 'https://example.test/galleries/$index',
        ),
      );
      final built = <String>{};
      String? opened;
      String? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              controller: controller,
              slivers: [
                const SliverToBoxAdapter(child: SizedBox(height: 80)),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  sliver: CatalogSliverGrid(
                    items: items,
                    columns: 5,
                    isSaved: (item) {
                      built.add(item.id);
                      return false;
                    },
                    onOpen: (item) => opened = item.id,
                    onSave: (item) => saved = item.id,
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 100)),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(built, contains('item:0'));
      expect(
        built.length,
        lessThan(80),
        reason: 'A finite viewport must not build the entire 2,000-card collection.',
      );
      expect(find.text('Item 1999'), findsNothing);

      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.text('Item 1999'), findsOneWidget);
      expect(
        built.length,
        lessThan(100),
        reason: 'Jumping directly to the last row must skip offscreen cards.',
      );
      expect(find.byType(CatalogCard).evaluate().length, lessThan(80));

      await tester.tap(find.text('Item 1999'));
      expect(opened, 'item:1999');
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('item:1999')),
          matching: find.byTooltip('보관함에 저장'),
        ),
      );
      expect(saved, 'item:1999');
      expect(tester.takeException(), isNull);
    },
  );
}
