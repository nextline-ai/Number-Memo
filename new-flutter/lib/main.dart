import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'data/library_store.dart';
import 'services/catalog_service.dart';
import 'ui/app_theme.dart';
import 'ui/shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final store = await LibraryStore.open();
    runApp(NumberMemoApp(store: store));
  } catch (error) {
    runApp(
      MaterialApp(
        theme: buildMonochromeTheme(Brightness.light),
        darkTheme: buildMonochromeTheme(Brightness.dark),
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.folder_off_outlined, size: 48),
                  const SizedBox(height: 20),
                  const Text('보관함을 열 수 없습니다', style: TextStyle(fontSize: 24)),
                  const SizedBox(height: 12),
                  const Text(
                    '저장된 데이터를 보호하기 위해 앱을 시작하지 않았습니다.\n저장 공간과 파일 접근 권한을 확인한 뒤 다시 실행해 주세요.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  SelectableText('$error'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class NumberMemoApp extends StatefulWidget {
  const NumberMemoApp({super.key, required this.store, this.catalog});
  final LibraryStore store;
  final CatalogService? catalog;

  @override
  State<NumberMemoApp> createState() => _NumberMemoAppState();
}

class _NumberMemoAppState extends State<NumberMemoApp> {
  late final CatalogService _catalog = widget.catalog ?? CatalogService();

  @override
  void dispose() {
    if (widget.catalog == null) _catalog.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) => MaterialApp(
      title: '품번메모',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ko'),
      supportedLocales: const [Locale('ko'), Locale('en'), Locale('ja')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: buildMonochromeTheme(Brightness.light),
      darkTheme: buildMonochromeTheme(Brightness.dark),
      themeMode: switch (widget.store.preferences.theme) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      },
      home: AppShell(store: widget.store, catalog: _catalog),
    ),
  );
}
