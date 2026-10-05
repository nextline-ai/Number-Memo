import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:number_memo/data/library_store.dart';
import 'package:number_memo/ui/settings_page.dart';

void main() {
  Future<void> showSettings(WidgetTester tester, LibraryStore store) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SettingsPage(store: store)),
      ),
    );
  }

  testWidgets('theme selection persists on a phone without overflow', (
    tester,
  ) async {
    final store = LibraryStore.memory();
    addTearDown(store.dispose);
    await showSettings(tester, store);

    await tester.tap(find.text('어둡게'));
    await tester.pumpAndSettle();

    expect(store.preferences.theme, 'dark');
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid Hitomi URL leaves preferences unchanged', (
    tester,
  ) async {
    final store = LibraryStore.memory();
    addTearDown(store.dispose);
    await showSettings(tester, store);
    await tester.ensureVisible(find.text('Hitomi 사이트 주소'));
    await tester.tap(find.text('Hitomi 사이트 주소'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField), 'javascript:alert(1)');
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();
    expect(store.preferences.hitomiBaseUrl, 'https://hitomi.la');
    expect(find.byType(AlertDialog), findsOneWidget);

    await tester.enterText(
      find.byType(TextFormField),
      'https://example.com/library/',
    );
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();
    expect(store.preferences.hitomiBaseUrl, 'https://example.com/library');
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('server dialog preserves compound and negated exclusion rules', (
    tester,
  ) async {
    final store = LibraryStore.memory();
    addTearDown(store.dispose);
    await showSettings(tester, store);
    await tester.ensureVisible(find.text('서버 추가'));
    await tester.tap(find.text('서버 추가'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).at(0), 'My gallery');
    await tester.enterText(
      find.byType(TextFormField).at(1),
      'https://gallery.example/',
    );
    await tester.enterText(
      find.byType(TextFormField).at(2),
      'tag_one\ntag_two -tag_three\ntag_one\nrating:explicit',
    );
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();

    final server = store.servers.singleWhere(
      (entry) => entry.name == 'My gallery',
    );
    expect(server.baseUrl, 'https://gallery.example');
    expect(server.excludedTags, [
      'tag_one',
      'tag_two -tag_three',
      'rating:explicit',
    ]);
    expect(server.enabled, isTrue);
    expect(tester.takeException(), isNull);
  });
}
