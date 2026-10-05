import 'package:flutter/material.dart';

import '../data/library_store.dart';
import '../data/models.dart';
import '../services/catalog_service.dart';
import 'common.dart';

Future<void> assignSelectionToFolders(
  BuildContext context,
  LibraryStore store,
  List<SavedItem> items,
) async {
  final mode = items.first.item.mode;
  final folders = store.folders.where((folder) => folder.mode == mode).toList();
  if (folders.isEmpty) {
    showMessage(context, '폴더 탭에서 먼저 폴더를 만들어 주세요.');
    return;
  }
  final selected = <String>{};
  var replace = false;
  final accepted = await showDialog<bool>(
    context: context,
    builder: (_) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text('${items.length}개 항목의 폴더 지정'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final folder in folders)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(folder.name),
                    value: selected.contains(folder.id),
                    onChanged: (value) => setState(() {
                      if (value == true) {
                        selected.add(folder.id);
                      } else {
                        selected.remove(folder.id);
                      }
                    }),
                  ),
                const Divider(),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('기존 폴더 지정 바꾸기'),
                  subtitle: const Text(
                    '꺼 두면 기존 폴더를 유지하면서 추가합니다. 켜고 아무 폴더도 선택하지 않으면 미분류로 바뀝니다.',
                  ),
                  value: replace,
                  onChanged: (value) => setState(() => replace = value),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: selected.isEmpty && !replace
                ? null
                : () => Navigator.pop(context, true),
            child: const Text('적용'),
          ),
        ],
      ),
    ),
  );
  if (accepted == true && context.mounted) {
    await attempt(
      context,
      () => store.assignFolders(
        items.map((e) => e.item.id),
        selected.toList(),
        replace: replace,
      ),
      success: '폴더를 변경했습니다.',
    );
  }
}

Future<void> refreshSelectionMetadata(
  BuildContext context,
  LibraryStore store,
  CatalogService catalog,
  List<SavedItem> items,
) async {
  final books = items
      .where(
        (entry) =>
            entry.item.mode == LibraryMode.books && entry.item.remoteId != null,
      )
      .toList();
  if (books.isEmpty) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) =>
        _MetadataRefresh(store: store, catalog: catalog, items: books),
  );
}

class _MetadataRefresh extends StatefulWidget {
  const _MetadataRefresh({
    required this.store,
    required this.catalog,
    required this.items,
  });
  final LibraryStore store;
  final CatalogService catalog;
  final List<SavedItem> items;
  @override
  State<_MetadataRefresh> createState() => _MetadataRefreshState();
}

class _MetadataRefreshState extends State<_MetadataRefresh> {
  int _done = 0, _failed = 0;
  bool _cancelled = false, _running = true;
  String? _lastError;
  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    for (
      var start = 0;
      start < widget.items.length && !_cancelled;
      start += 3
    ) {
      await Future.wait(
        widget.items.skip(start).take(3).map((entry) async {
          try {
            final item = await widget.catalog.gallery(
              entry.item.remoteId!,
              baseUrl: widget.store.preferences.hitomiBaseUrl,
              refresh: true,
            );
            await widget.store.refreshMetadata(item);
          } catch (error) {
            _failed++;
            _lastError = '$error';
          }
          if (mounted) setState(() => _done++);
        }),
      );
    }
    if (mounted) setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_running,
    child: AlertDialog(
      title: const Text('작품 정보 새로고침'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('제목을 직접 바꾼 경우에는 그대로 유지합니다. 표지·작가·태그 정보를 다시 불러옵니다.'),
            const SizedBox(height: 20),
            LinearProgressIndicator(value: _done / widget.items.length),
            const SizedBox(height: 12),
            Text('$_done / ${widget.items.length}개 확인 · $_failed개 실패'),
            if (_cancelled && _running)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text('현재 요청을 마친 뒤 중단합니다.'),
              ),
            if (_lastError != null && !_running)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_lastError!),
              ),
          ],
        ),
      ),
      actions: [
        if (_running)
          TextButton(
            onPressed: _cancelled
                ? null
                : () => setState(() => _cancelled = true),
            child: const Text('중단'),
          )
        else
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('닫기'),
          ),
      ],
    ),
  );
}
