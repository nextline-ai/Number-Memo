import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../data/library_store.dart';
import '../data/models.dart';
import '../services/catalog_service.dart';
import '../services/media_export.dart';
import 'common.dart';
import 'library_page.dart';
import 'reader_page.dart';

Future<void> showAddBooks(
  BuildContext context,
  LibraryStore store,
  CatalogService catalog, {
  String? initialText,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) =>
      _AddBooksDialog(store: store, catalog: catalog, initialText: initialText),
);

class _AddBooksDialog extends StatefulWidget {
  const _AddBooksDialog({
    required this.store,
    required this.catalog,
    this.initialText,
  });
  final String? initialText;
  final LibraryStore store;
  final CatalogService catalog;
  @override
  State<_AddBooksDialog> createState() => _AddBooksDialogState();
}

class _AddBooksDialogState extends State<_AddBooksDialog> {
  late final _input = TextEditingController(text: widget.initialText);
  final _note = TextEditingController();
  final Set<String> _folders = {};
  bool _fetch = true, _busy = false;
  String? _error;
  int _completed = 0, _total = 0;
  @override
  void dispose() {
    _input.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final ids = CatalogService.parseGalleryIds(_input.text);
    if (ids.isEmpty) {
      setState(() => _error = '작품 번호 또는 작품 링크를 입력해 주세요.');
      return;
    }
    if (ids.length > 100) {
      setState(() => _error = '한 번에 최대 100개까지 추가할 수 있습니다.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _completed = 0;
      _total = ids.length;
    });
    var failedMetadata = 0;
    final metadataIds = ids.where((id) {
      final existing = widget.store.find('hitomi:$id');
      return existing == null || existing.item.title == '작품 #$id';
    }).toList();
    try {
      final base = widget.store.preferences.hitomiBaseUrl;
      // Persist the IDs first so network failure never loses the user's input.
      for (final id in ids) {
        final old = widget.store.find('hitomi:$id');
        await widget.store.save(
          old?.item ??
              CatalogItem(
                id: 'hitomi:$id',
                mode: LibraryMode.books,
                remoteId: id,
                title: '작품 #$id',
                sourceUrl: '$base/galleries/$id.html',
              ),
          note: _note.text.trim().isEmpty ? null : _note.text.trim(),
          folderIds: {...?old?.folderIds, ..._folders}.toList(),
        );
      }
      if (_fetch) {
        for (var offset = 0; offset < metadataIds.length; offset += 4) {
          await Future.wait(
            metadataIds.skip(offset).take(4).map((id) async {
              CatalogItem? metadata;
              try {
                metadata = await widget.catalog.gallery(id, baseUrl: base);
              } catch (_) {
                failedMetadata++;
              }
              if (metadata != null) await widget.store.save(metadata);
              if (mounted) setState(() => _completed++);
            }),
          );
        }
      }
      if (mounted) {
        Navigator.pop(context);
        showMessage(
          context,
          '${ids.length}개를 저장했습니다.${failedMetadata > 0 ? ' $failedMetadata개는 상세 화면에서 정보를 다시 불러올 수 있습니다.' : ''}',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '일부 항목이 저장되었을 수 있습니다. $e';
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final folders = widget.store.folders
        .where((f) => f.mode == LibraryMode.books)
        .toList();
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: const Text('작품 추가'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('작품 번호나 링크를 붙여 넣으세요.\n여러 개를 한 번에 추가할 수 있습니다.'),
                const SizedBox(height: 20),
                TextField(
                  controller: _input,
                  autofocus: true,
                  enabled: !_busy,
                  minLines: 3,
                  maxLines: 5,
                  decoration: InputDecoration(
                    labelText: '작품 번호 또는 링크',
                    hintText: '1234567\nhttps://…/galleries/1234567.html',
                    errorText: _error,
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _note,
                  enabled: !_busy,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: '메모 (선택)'),
                ),
                if (folders.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Text('폴더에 함께 저장'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: folders
                        .map(
                          (f) => FilterChip(
                            label: Text(f.name),
                            selected: _folders.contains(f.id),
                            onSelected: _busy
                                ? null
                                : (v) => setState(() {
                                    if (v) {
                                      _folders.add(f.id);
                                    } else {
                                      _folders.remove(f.id);
                                    }
                                  }),
                          ),
                        )
                        .toList(),
                  ),
                ],
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _fetch,
                  onChanged: _busy ? null : (v) => setState(() => _fetch = v),
                  title: const Text('제목과 표지 불러오기'),
                  subtitle: const Text('꺼 두면 인터넷 없이 번호만 저장합니다.'),
                ),
                if (_busy) ...[
                  const SizedBox(height: 12),
                  LinearProgressIndicator(
                    value: _total > 0 ? _completed / _total : null,
                  ),
                  const SizedBox(height: 8),
                  Text('저장 중 · $_completed / $_total'),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          FilledButton.icon(
            onPressed: _busy ? null : _save,
            icon: const Icon(Icons.bookmark_add_outlined),
            label: const Text('저장'),
          ),
        ],
      ),
    );
  }
}

Future<void> showEntryDetail(
  BuildContext context, {
  required CatalogItem item,
  required LibraryStore store,
  required CatalogService catalog,
  required ValueChanged<String> onSearchTag,
}) => showDialog<void>(
  context: context,
  builder: (_) => _EntryDetail(
    item: item,
    store: store,
    catalog: catalog,
    onSearchTag: onSearchTag,
  ),
);

class _EntryDetail extends StatefulWidget {
  const _EntryDetail({
    required this.item,
    required this.store,
    required this.catalog,
    required this.onSearchTag,
  });
  final CatalogItem item;
  final LibraryStore store;
  final CatalogService catalog;
  final ValueChanged<String> onSearchTag;
  @override
  State<_EntryDetail> createState() => _EntryDetailState();
}

class _EntryDetailState extends State<_EntryDetail> {
  late CatalogItem _item =
      widget.store.find(widget.item.id)?.item ?? widget.item;
  late final _title = TextEditingController(text: _item.title);
  late final _note = TextEditingController(
    text: widget.store.find(_item.id)?.note ?? '',
  );
  late final Set<String> _folderIds = {
    ...?widget.store.find(_item.id)?.folderIds,
  };
  bool _busy = false;
  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_title.text.trim().isEmpty) {
      showMessage(context, '제목을 입력해 주세요.');
      return;
    }
    setState(() => _busy = true);
    await attempt(context, () async {
      _item = _item.copyWith(title: _title.text.trim());
      await widget.store.save(
        _item,
        note: _note.text,
        folderIds: _folderIds.toList(),
      );
    }, success: '보관함에 저장했습니다.');
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _refresh() async {
    if (_item.remoteId == null) return;
    setState(() => _busy = true);
    await attempt(context, () async {
      final item = await widget.catalog.gallery(
        _item.remoteId!,
        refresh: true,
        baseUrl: widget.store.preferences.hitomiBaseUrl,
      );
      if (!mounted) return;
      setState(() {
        _item = item;
        _title.text = item.title;
      });
      if (widget.store.find(item.id) != null) await widget.store.save(item);
    });
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _tagActions(String rawTag) async {
    final tag = rawTag.replaceAll(RegExp(r'\s+'), '_');
    final books = _item.mode == LibraryMode.books;
    final server = widget.store.servers
        .where((entry) => entry.id == _item.serverId)
        .firstOrNull;
    final excluded = books
        ? widget.store.preferences.excludedTags
        : server?.excludedTags ?? <String>[];
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(rawTag),
        children: [
          SimpleDialogOption(
            child: const Text('태그 복사'),
            onPressed: () {
              Navigator.pop(dialogContext);
              attempt(
                context,
                () => Clipboard.setData(ClipboardData(text: tag)),
                success: '태그를 복사했습니다.',
              );
            },
          ),
          if (books)
            SimpleDialogOption(
              child: const Text('기본 검색 태그에 추가'),
              onPressed: () {
                Navigator.pop(dialogContext);
                attempt(
                  context,
                  () => widget.store.setPreferences(
                    widget.store.preferences.copyWith(
                      defaultTags: {
                        ...widget.store.preferences.defaultTags,
                        tag,
                      }.toList(),
                    ),
                  ),
                  success: '기본 검색 태그에 추가했습니다.',
                );
              },
            ),
          if (books || server != null)
            SimpleDialogOption(
              child: Text(
                excluded.contains(tag) ? '제외 태그에서 제거' : '이 태그를 검색에서 제외',
              ),
              onPressed: () {
                Navigator.pop(dialogContext);
                final tags = excluded.toSet();
                if (!tags.add(tag)) tags.remove(tag);
                attempt(
                  context,
                  () => books
                      ? widget.store.setPreferences(
                          widget.store.preferences.copyWith(
                            excludedTags: tags.toList(),
                          ),
                        )
                      : widget.store.upsertServer(
                          server!.copyWith(excludedTags: tags.toList()),
                        ),
                  success: '제외 태그를 변경했습니다.',
                );
              },
            ),
        ],
      ),
    );
  }

  Future<void> _exportImage() async {
    final url = _item.mode == LibraryMode.images
        ? _item.mediaUrls.firstOrNull ?? _item.thumbnailUrl
        : _item.thumbnailUrl;
    if (url.isEmpty) {
      showMessage(context, '저장할 이미지가 없습니다. 정보를 다시 불러와 주세요.');
      return;
    }
    final extension =
        Uri.tryParse(url)?.path.split('.').last.toLowerCase() ?? 'jpg';
    await exportMedia(
      context,
      url: url,
      filename:
          'number-memo-${_item.remoteId ?? 'image'}.${RegExp(r'^(jpg|jpeg|png|webp|avif|gif|mp4|webm)$').hasMatch(extension) ? extension : 'jpg'}',
      headers: imageHeaders(_item),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) {
      final saved = widget.store.find(_item.id);
      final colors = Theme.of(context).colorScheme;
      final folders = widget.store.folders
          .where((f) => f.mode == _item.mode)
          .toList();
      return Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 8, 0),
                child: Row(
                  children: [
                    Icon(
                      _item.mode == LibraryMode.books
                          ? Icons.menu_book
                          : Icons.image_outlined,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '#${_item.remoteId ?? _item.id}',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ),
                    if (saved != null)
                      Chip(
                        label: const Text('저장됨'),
                        avatar: Icon(
                          Icons.check,
                          size: 16,
                          color: colors.primary,
                        ),
                        side: BorderSide.none,
                      ),
                    IconButton(
                      tooltip: '닫기',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 100,
                            height: 138,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: CatalogArtwork(item: _item),
                            ),
                          ),
                          const SizedBox(width: 20),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _item.title,
                                  style: Theme.of(context).textTheme.titleLarge
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  _item.artists.isEmpty
                                      ? '작가 정보 없음'
                                      : _item.artists.join(', '),
                                  style: TextStyle(
                                    color: colors.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  [
                                    if (_item.language.isNotEmpty)
                                      _item.language,
                                    if (_item.pageCount > 0)
                                      '${_item.pageCount}페이지',
                                    if (_item.rating.isNotEmpty) _item.rating,
                                  ].join(' · '),
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => ReaderPage(
                                  item: _item,
                                  store: widget.store,
                                  catalog: widget.catalog,
                                ),
                              ),
                            ),
                            icon: const Icon(Icons.chrome_reader_mode_outlined),
                            label: Text(
                              _item.mode == LibraryMode.books ? '읽기' : '이미지 보기',
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: () =>
                                openWebsite(context, _item.sourceUrl),
                            icon: const Icon(Icons.open_in_new),
                            label: const Text('원본 사이트'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _exportImage,
                            icon: const Icon(Icons.download_outlined),
                            label: Text(
                              _item.mode == LibraryMode.books
                                  ? '표지 저장'
                                  : '이미지 저장',
                            ),
                          ),
                          IconButton(
                            tooltip: '작품 링크 공유',
                            icon: const Icon(Icons.share_outlined),
                            onPressed: () => attempt(context, () async {
                              final box =
                                  context.findRenderObject() as RenderBox?;
                              await SharePlus.instance.share(
                                ShareParams(
                                  text: '${_item.title}\n${_item.sourceUrl}',
                                  sharePositionOrigin: box == null
                                      ? null
                                      : box.localToGlobal(Offset.zero) &
                                            box.size,
                                ),
                              );
                            }),
                          ),
                          IconButton(
                            tooltip: '링크 복사',
                            onPressed: () => attempt(
                              context,
                              () => Clipboard.setData(
                                ClipboardData(text: _item.sourceUrl),
                              ),
                              success: '링크를 복사했습니다.',
                            ),
                            icon: const Icon(Icons.link),
                          ),
                          if (_item.mode == LibraryMode.books)
                            IconButton(
                              tooltip: '작품 정보 다시 불러오기',
                              onPressed: _busy ? null : _refresh,
                              icon: const Icon(Icons.refresh),
                            ),
                        ],
                      ),
                      if (_busy)
                        const Padding(
                          padding: EdgeInsets.only(top: 12),
                          child: LinearProgressIndicator(),
                        ),
                      const SizedBox(height: 24),
                      TextField(
                        controller: _title,
                        decoration: const InputDecoration(labelText: '제목'),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _note,
                        minLines: 2,
                        maxLines: 5,
                        decoration: const InputDecoration(
                          labelText: '나의 메모',
                          hintText: '다시 보고 싶은 이유를 남겨 보세요.',
                        ),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Text(
                            '폴더',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const Spacer(),
                          TextButton.icon(
                            onPressed: () => editFolder(context, widget.store),
                            icon: const Icon(Icons.add, size: 16),
                            label: const Text('새 폴더'),
                          ),
                        ],
                      ),
                      if (folders.isEmpty)
                        Text(
                          '폴더 없이도 보관함에 저장할 수 있어요.',
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: folders
                            .map(
                              (folder) => FilterChip(
                                label: Text(folder.name),
                                selected: _folderIds.contains(folder.id),
                                onSelected: (v) => setState(() {
                                  if (v) {
                                    _folderIds.add(folder.id);
                                  } else {
                                    _folderIds.remove(folder.id);
                                  }
                                }),
                              ),
                            )
                            .toList(),
                      ),
                      if (_item.artists.isNotEmpty) ...[
                        const SizedBox(height: 20),
                        Text(
                          '작가',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: _item.artists
                              .map(
                                (name) => ActionChip(
                                  avatar: const Icon(
                                    Icons.person_add_outlined,
                                    size: 16,
                                  ),
                                  label: Text(name),
                                  onPressed: () => attempt(
                                    context,
                                    () => widget.store.addArtist(
                                      name,
                                      _item.mode,
                                    ),
                                    success: '작가를 저장했습니다.',
                                  ),
                                ),
                              )
                              .toList(),
                        ),
                      ],
                      if (_item.tags.isNotEmpty) ...[
                        const SizedBox(height: 20),
                        Text(
                          '태그',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: _item.tags
                              .map(
                                (tag) => InputChip(
                                  deleteIcon: const Icon(
                                    Icons.more_horiz,
                                    size: 16,
                                  ),
                                  deleteButtonTooltipMessage: '태그 옵션',
                                  onDeleted: () => _tagActions(tag),
                                  label: Text(
                                    tag,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                  onPressed: () {
                                    Navigator.pop(context);
                                    widget.onSearchTag(
                                      tag.replaceAll(RegExp(r'\s+'), '_'),
                                    );
                                  },
                                ),
                              )
                              .toList(),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 24, 20),
                child: Row(
                  children: [
                    if (saved != null)
                      IconButton(
                        tooltip: '보관함에서 삭제',
                        onPressed: _busy
                            ? null
                            : () async {
                                if (await confirm(
                                      context,
                                      title: '저장한 항목을 삭제할까요?',
                                      message: '메모와 폴더 연결도 함께 삭제됩니다.',
                                    ) &&
                                    context.mounted) {
                                  try {
                                    await widget.store.remove(_item.id);
                                    if (context.mounted) Navigator.pop(context);
                                  } catch (e) {
                                    if (context.mounted) {
                                      showMessage(context, '$e');
                                    }
                                  }
                                }
                              },
                        icon: Icon(Icons.delete_outline, color: colors.error),
                      ),
                    const Spacer(),
                    FilledButton.icon(
                      onPressed: _busy ? null : _save,
                      icon: const Icon(Icons.bookmark_add_outlined),
                      label: Text(saved == null ? '보관함에 저장' : '변경사항 저장'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
