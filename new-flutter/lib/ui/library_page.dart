import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/library_store.dart';
import '../data/models.dart';
import '../services/catalog_service.dart';
import 'common.dart';
import 'entry_detail.dart';
import 'library_actions.dart';
import 'reader_page.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.store,
    required this.catalog,
    required this.searchFocus,
    required this.onAdd,
    required this.onExplore,
    required this.onSearchTag,
    required this.onClearFolder,
    this.folderId,
  });
  final LibraryStore store;
  final CatalogService catalog;
  final FocusNode searchFocus;
  final VoidCallback onAdd, onExplore, onClearFolder;
  final ValueChanged<String> onSearchTag;
  final String? folderId;
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  String _query = '', _sort = 'recent', _filter = 'all';
  bool _selecting = false, _busy = false;
  final Set<String> _selected = {};

  @override
  void didUpdateWidget(covariant LibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.folderId != widget.folderId) {
      _selected.clear();
      _selecting = false;
    }
  }

  void _toggle(CatalogItem item) => setState(() {
    _selecting = true;
    if (!_selected.add(item.id)) _selected.remove(item.id);
  });

  Future<void> _deleteSelection(List<SavedItem> items) async {
    if (!await confirm(
      context,
      title: '${items.length}개 항목을 삭제할까요?',
      message: '선택한 항목의 메모와 폴더 지정도 함께 삭제됩니다.',
    )) {
      return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      await widget.store.removeMany(items.map((entry) => entry.item.id));
      if (!mounted) return;
      setState(() {
        _selected.clear();
        _selecting = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${items.length}개를 삭제했습니다.'),
          action: SnackBarAction(
            label: '실행 취소',
            onPressed: () {
              attempt(
                context,
                () => widget.store.restoreItems(items),
                success: '삭제한 항목을 복원했습니다.',
              );
            },
          ),
        ),
      );
    } catch (error) {
      if (mounted) showMessage(context, '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _batch(String action, List<SavedItem> selected) async {
    if (selected.isEmpty || _busy) return;
    switch (action) {
      case 'folders':
        await assignSelectionToFolders(context, widget.store, selected);
      case 'delete':
        await _deleteSelection(selected);
      case 'refresh':
        await refreshSelectionMetadata(
          context,
          widget.store,
          widget.catalog,
          selected,
        );
      case 'links':
      case 'ids':
        final content = selected
            .map(
              (entry) => action == 'ids'
                  ? '${entry.item.remoteId ?? entry.item.id}'
                  : entry.item.sourceUrl,
            )
            .join('\n');
        if (mounted) {
          await attempt(
            context,
            () => Clipboard.setData(ClipboardData(text: content)),
            success: '${selected.length}개를 복사했습니다.',
          );
        }
    }
  }

  void _read(SavedItem entry) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ReaderPage(
        item: entry.item,
        store: widget.store,
        catalog: widget.catalog,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final mode = widget.store.preferences.mode;
    final all = widget.store.items
        .where((entry) => entry.item.mode == mode)
        .toList();
    final query = _query.toLowerCase().trim();
    final items = all
        .where(
          (entry) =>
              (widget.folderId == null ||
                  entry.folderIds.contains(widget.folderId)) &&
              (_filter != 'unfiled' || entry.folderIds.isEmpty) &&
              (_filter != 'reading' || entry.lastOpenedAt != null) &&
              (query.isEmpty ||
                  '${entry.item.title} ${entry.item.remoteId} ${entry.item.artists.join(' ')} ${entry.item.tags.join(' ')} ${entry.note}'
                      .toLowerCase()
                      .contains(query)),
        )
        .toList();
    items.sort(
      (a, b) => switch (_sort) {
        'title' => a.item.title.compareTo(b.item.title),
        'oldest' => a.savedAt.compareTo(b.savedAt),
        'opened' => (b.lastOpenedAt ?? DateTime(1970)).compareTo(
          a.lastOpenedAt ?? DateTime(1970),
        ),
        _ => b.savedAt.compareTo(a.savedAt),
      },
    );
    final selected = items
        .where((entry) => _selected.contains(entry.item.id))
        .toList();
    final folders = widget.store.folders
        .where((folder) => folder.mode == mode)
        .toList();
    final folder = folders
        .where((folder) => folder.id == widget.folderId)
        .firstOrNull;
    final read = all.where((entry) => entry.lastOpenedAt != null).toList()
      ..sort((a, b) => b.lastOpenedAt!.compareTo(a.lastOpenedAt!));
    final resume = read.firstOrNull;
    return CustomScrollView(
      key: PageStorageKey('library-${mode.name}'),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 0),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                PageHeading(
                  eyebrow: mode == LibraryMode.books ? 'MY BOOKS' : 'MY IMAGES',
                  title: folder?.name ?? '나의 보관함',
                  subtitle:
                      '${all.length}개의 ${mode == LibraryMode.books ? '작품' : '이미지'} · ${folders.length}개의 폴더',
                  action: IconButton(
                    tooltip: '탐색 열기',
                    onPressed: widget.onExplore,
                    icon: const Icon(Icons.travel_explore),
                  ),
                ),
                const SizedBox(height: 24),
                if (all.isNotEmpty) ...[
                  TextField(
                    focusNode: widget.searchFocus,
                    onChanged: (value) => setState(() {
                      _query = value;
                      _selected.clear();
                    }),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: '제목, 번호, 작가, 태그, 메모 검색',
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (!_selecting &&
                      resume != null &&
                      query.isEmpty &&
                      widget.folderId == null &&
                      _filter == 'all' &&
                      mode == LibraryMode.books)
                    Card(
                      margin: const EdgeInsets.only(bottom: 16),
                      child: ListTile(
                        leading: const Icon(Icons.play_circle_outline),
                        title: const Text('이어서 읽기'),
                        subtitle: Text(
                          '${resume.item.title} · ${resume.readingPage + 1}페이지',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _read(resume),
                      ),
                    ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      for (final option in <String, String>{
                        'all': '전체',
                        'unfiled': '미분류',
                        if (mode == LibraryMode.books) 'reading': '최근 읽은 작품',
                      }.entries)
                        FilterChip(
                          label: Text(option.value),
                          selected: _filter == option.key,
                          onSelected: (_) => setState(() {
                            _filter = option.key;
                            _selected.clear();
                          }),
                        ),
                      if (folder != null)
                        InputChip(
                          label: Text(folder.name),
                          onDeleted: widget.onClearFolder,
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        '${items.length}개',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      DropdownButton<String>(
                        value: _sort,
                        underline: const SizedBox.shrink(),
                        items: const [
                          DropdownMenuItem(
                            value: 'recent',
                            child: Text('최근 저장순'),
                          ),
                          DropdownMenuItem(
                            value: 'opened',
                            child: Text('최근 읽은순'),
                          ),
                          DropdownMenuItem(
                            value: 'oldest',
                            child: Text('오래된순'),
                          ),
                          DropdownMenuItem(value: 'title', child: Text('이름순')),
                        ],
                        onChanged: (value) => setState(() => _sort = value!),
                      ),
                      OutlinedButton.icon(
                        onPressed: _busy
                            ? null
                            : () => setState(() {
                                _selecting = !_selecting;
                                _selected.clear();
                              }),
                        icon: Icon(_selecting ? Icons.close : Icons.checklist),
                        label: Text(_selecting ? '선택 종료' : '여러 항목 선택'),
                      ),
                    ],
                  ),
                  if (_selecting)
                    Card(
                      margin: const EdgeInsets.symmetric(vertical: 12),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              '${selected.length}개 선택',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            TextButton(
                              onPressed: _busy
                                  ? null
                                  : () => setState(() {
                                      if (selected.length == items.length) {
                                        _selected.clear();
                                      } else {
                                        _selected.addAll(
                                          items.map((entry) => entry.item.id),
                                        );
                                      }
                                    }),
                              child: Text(
                                selected.length == items.length &&
                                        items.isNotEmpty
                                    ? '전체 선택 해제'
                                    : '전체 선택',
                              ),
                            ),
                            FilledButton.tonalIcon(
                              onPressed: selected.isEmpty || _busy
                                  ? null
                                  : () => _batch('folders', selected),
                              icon: const Icon(Icons.drive_file_move_outline),
                              label: const Text('폴더 지정'),
                            ),
                            PopupMenuButton<String>(
                              tooltip: '선택한 항목 작업',
                              enabled: selected.isNotEmpty && !_busy,
                              onSelected: (action) => _batch(action, selected),
                              itemBuilder: (_) => [
                                const PopupMenuItem(
                                  value: 'links',
                                  child: Text('링크 복사'),
                                ),
                                const PopupMenuItem(
                                  value: 'ids',
                                  child: Text('번호 복사'),
                                ),
                                if (mode == LibraryMode.books)
                                  const PopupMenuItem(
                                    value: 'refresh',
                                    child: Text('정보 새로고침'),
                                  ),
                                const PopupMenuItem(
                                  value: 'delete',
                                  child: Text('선택 항목 삭제'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: 20),
                ],
                if (items.isEmpty)
                  EmptyState(
                    icon: query.isNotEmpty || _filter != 'all'
                        ? Icons.search_off
                        : Icons.bookmarks_outlined,
                    title: query.isNotEmpty || _filter != 'all'
                        ? '조건에 맞는 항목이 없습니다'
                        : folder != null
                        ? '아직 비어 있는 폴더예요'
                        : '첫 번째 취향을 담아 보세요',
                    message: query.isNotEmpty || _filter != 'all'
                        ? '검색어나 분류 조건을 바꿔 보세요.'
                        : mode == LibraryMode.books
                        ? '작품 번호나 링크를 붙여 넣어 저장하세요.\n폴더와 메모로 나만의 책장을 만들 수 있어요.'
                        : '탐색에서 마음에 드는 이미지를 저장하세요.',
                    action: FilledButton.icon(
                      onPressed: mode == LibraryMode.books
                          ? widget.onAdd
                          : widget.onExplore,
                      icon: Icon(
                        mode == LibraryMode.books
                            ? Icons.add
                            : Icons.explore_outlined,
                      ),
                      label: Text(
                        mode == LibraryMode.books ? '작품 추가하기' : '이미지 탐색하기',
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (items.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            sliver: CatalogSliverGrid(
              items: items.map((entry) => entry.item).toList(),
              columns: widget.store.preferences.columns,
              isSaved: (_) => true,
              selectionMode: _selecting,
              isSelected: (item) => _selected.contains(item.id),
              onSelect: _toggle,
              onOpen: (item) => showEntryDetail(
                context,
                item: item,
                store: widget.store,
                catalog: widget.catalog,
                onSearchTag: widget.onSearchTag,
              ),
              onSave: (item) => showEntryDetail(
                context,
                item: item,
                store: widget.store,
                catalog: widget.catalog,
                onSearchTag: widget.onSearchTag,
              ),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 100)),
      ],
    );
  }
}

class PageHeading extends StatelessWidget {
  const PageHeading({
    super.key,
    required this.eyebrow,
    required this.title,
    required this.subtitle,
    this.action,
  });
  final String eyebrow, title, subtitle;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              eyebrow,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 2,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              title,
              style: Theme.of(context).textTheme.headlineMedium
                  ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -1),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
      if (action != null) ...[const SizedBox(width: 12), action!],
    ],
  );
}

class FoldersPage extends StatelessWidget {
  const FoldersPage({super.key, required this.store, required this.onOpen});
  final LibraryStore store;
  final ValueChanged<String> onOpen;
  @override
  Widget build(BuildContext context) {
    final folders = store.folders
        .where((f) => f.mode == store.preferences.mode)
        .toList();
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        PageHeading(
          eyebrow: 'COLLECTIONS',
          title: '폴더',
          subtitle: '취향대로 나누고, 한눈에 찾아보세요.',
          action: FilledButton.tonalIcon(
            onPressed: () => editFolder(context, store),
            icon: const Icon(Icons.create_new_folder_outlined),
            label: const Text('새 폴더'),
          ),
        ),
        const SizedBox(height: 28),
        if (folders.isEmpty)
          EmptyState(
            icon: Icons.folder_outlined,
            title: '취향에도 자리를 만들어 주세요',
            message: '작가별, 분위기별, 다시 보고 싶은 작품별로\n여러 폴더에 자유롭게 정리할 수 있어요.',
            action: FilledButton.icon(
              onPressed: () => editFolder(context, store),
              icon: const Icon(Icons.add),
              label: const Text('첫 폴더 만들기'),
            ),
          ),
        ...folders.map((folder) {
          final count = store.items
              .where((e) => e.folderIds.contains(folder.id))
              .length;
          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 12,
              ),
              leading: Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: folderDisplayColor(folder.color)
                      .withValues(alpha: .15),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  Icons.folder_rounded,
                  color: folderDisplayColor(folder.color),
                  size: 30,
                ),
              ),
              title: Text(
                folder.name,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text('$count개 저장됨'),
              onTap: () => onOpen(folder.id),
              trailing: PopupMenuButton<String>(
                tooltip: '폴더 메뉴',
                onSelected: (value) async {
                  if (value == 'edit') {
                    await editFolder(context, store, folder: folder);
                  } else if (await confirm(
                    context,
                    title: '폴더를 삭제할까요?',
                    message: '폴더만 삭제되며 저장된 작품은 보관함에 남습니다.',
                  )) {
                    if (context.mounted) {
                      await attempt(
                        context,
                        () => store.deleteFolder(folder.id),
                      );
                    }
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('이름과 색상 변경')),
                  PopupMenuItem(value: 'delete', child: Text('폴더 삭제')),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }
}

Future<void> editFolder(
  BuildContext context,
  LibraryStore store, {
  MemoFolder? folder,
}) async {
  final name = TextEditingController(text: folder?.name);
  var color = folder?.color ?? folderColors.first;
  var busy = false;
  String? error;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(folder == null ? '새 폴더' : '폴더 수정'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: name,
                autofocus: true,
                maxLength: 80,
                decoration: InputDecoration(
                  labelText: '폴더 이름',
                  errorText: error,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: folderColors
                    .map(
                      (value) => IconButton(
                        tooltip: '폴더 색상 ${folderColors.indexOf(value) + 1}',
                        onPressed: () => setState(() => color = value),
                        style: IconButton.styleFrom(
                          backgroundColor: Color(value).withValues(alpha: .2),
                        ),
                        icon: Icon(
                          color == value ? Icons.check_circle : Icons.circle,
                          color: Color(value),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    if (name.text.trim().isEmpty) {
                      setState(() => error = '폴더 이름을 입력해 주세요.');
                      return;
                    }
                    setState(() {
                      busy = true;
                      error = null;
                    });
                    try {
                      if (folder == null) {
                        await store.addFolder(
                          name.text.trim(),
                          store.preferences.mode,
                          color: color,
                        );
                      } else {
                        await store.updateFolder(
                          folder.copyWith(name: name.text.trim(), color: color),
                        );
                      }
                      if (context.mounted) Navigator.pop(context);
                    } catch (e) {
                      if (context.mounted) {
                        setState(() {
                          error = '$e';
                          busy = false;
                        });
                      }
                    }
                  },
            child: const Text('저장'),
          ),
        ],
      ),
    ),
  );
  // Dialog route may animate out after its future completes.
}

class ArtistsPage extends StatelessWidget {
  const ArtistsPage({super.key, required this.store, required this.onSearch});
  final LibraryStore store;
  final ValueChanged<String> onSearch;
  Future<void> _add(BuildContext context) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('작가 추가'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '작가 이름 또는 태그'),
          onSubmitted: (v) {
            if (v.trim().isNotEmpty) Navigator.pop(context, v.trim());
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                Navigator.pop(context, controller.text.trim());
              }
            },
            child: const Text('저장'),
          ),
        ],
      ),
    );
    if (name != null && context.mounted) {
      await attempt(
        context,
        () => store.addArtist(name, store.preferences.mode),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final artists = store.artists
        .where((a) => a.mode == store.preferences.mode)
        .toList();
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        PageHeading(
          eyebrow: 'FAVORITE ARTISTS',
          title: '작가',
          subtitle: '다시 만나고 싶은 작가를 모아 두세요.',
          action: FilledButton.tonalIcon(
            onPressed: () => _add(context),
            icon: const Icon(Icons.person_add_outlined),
            label: const Text('추가'),
          ),
        ),
        const SizedBox(height: 28),
        if (artists.isEmpty)
          EmptyState(
            icon: Icons.people_outline,
            title: '좋아하는 작가가 있나요?',
            message: '작가 이름을 저장하면 작품을 빠르게 찾아볼 수 있어요.',
            action: FilledButton.icon(
              onPressed: () => _add(context),
              icon: const Icon(Icons.person_add_outlined),
              label: const Text('작가 추가하기'),
            ),
          ),
        ...artists.map(
          (artist) => Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 8,
              ),
              leading: CircleAvatar(
                child: Text(artist.name.characters.first.toUpperCase()),
              ),
              title: Text(artist.name),
              subtitle: const Text('작품 찾아보기'),
              onTap: () => onSearch(
                artist.mode == LibraryMode.books
                    ? (artist.name.startsWith('group:') ||
                              artist.name.startsWith('artist:')
                          ? artist.name.replaceAll(' ', '_')
                          : 'artist:${artist.name.replaceAll(' ', '_')}')
                    : artist.name.replaceAll(' ', '_'),
              ),
              trailing: IconButton(
                tooltip: '작가 삭제',
                icon: const Icon(Icons.close),
                onPressed: () async {
                  if (await confirm(
                        context,
                        title: '작가를 삭제할까요?',
                        message: '저장한 작품에는 영향을 주지 않습니다.',
                      ) &&
                      context.mounted) {
                    await attempt(context, () => store.removeArtist(artist.id));
                  }
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}
