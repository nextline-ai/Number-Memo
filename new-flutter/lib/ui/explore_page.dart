import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../data/library_store.dart';
import '../data/models.dart';
import '../services/catalog_service.dart';
import 'common.dart';
import 'entry_detail.dart';
import 'library_page.dart';

class ExplorePage extends StatefulWidget {
  const ExplorePage({
    super.key,
    required this.store,
    required this.catalog,
    required this.searchFocus,
    required this.onSearchTag,
    this.initialQuery = '',
  });
  final LibraryStore store;
  final CatalogService catalog;
  final FocusNode searchFocus;
  final ValueChanged<String> onSearchTag;
  final String initialQuery;
  @override
  State<ExplorePage> createState() => _ExplorePageState();
}

class _ExplorePageState extends State<ExplorePage> {
  late final _search = TextEditingController(text: widget.initialQuery);
  final List<CatalogItem> _items = [];
  late Set<String> _serverIds;
  late Set<String> _lastEnabledServers;
  late String _settingsSignature;
  final Map<String, int> _imagePages = {};
  final Set<String> _finishedServers = {};
  String _rating = 'safe', _language = 'korean', _sort = 'latest';
  String _activeQuery = '';
  bool _loading = true, _hasMore = true;
  int _page = 0, _generation = 0;
  String? _error;
  List<String> _suggestions = [];
  Timer? _debounce;
  bool get _books => widget.store.preferences.mode == LibraryMode.books;

  @override
  void initState() {
    super.initState();
    _serverIds = widget.store.servers
        .where((s) => s.enabled)
        .map((s) => s.id)
        .toSet();
    _lastEnabledServers = {..._serverIds};
    _settingsSignature = _signature();
    _activeQuery = widget.initialQuery;
    _load(reset: true);
  }

  String _signature() => jsonEncode({
    'base': widget.store.preferences.hitomiBaseUrl,
    'include': widget.store.preferences.defaultTags,
    'exclude': widget.store.preferences.excludedTags,
    'servers': widget.store.servers.map((server) => server.toJson()).toList(),
  });

  @override
  void didUpdateWidget(covariant ExplorePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final signature = _signature();
    if (signature == _settingsSignature) return;
    _settingsSignature = signature;
    final enabled = widget.store.servers
        .where((server) => server.enabled)
        .map((server) => server.id)
        .toSet();
    _serverIds = _serverIds.intersection(enabled)
      ..addAll(enabled.difference(_lastEnabledServers));
    _lastEnabledServers = enabled;
    _load(reset: true);
  }

  @override
  void dispose() {
    _search.dispose();
    _debounce?.cancel();
    _generation++;
    super.dispose();
  }

  Future<void> _load({bool reset = false}) async {
    if (!reset && _loading) return;
    final generation = reset ? ++_generation : _generation;
    if (reset) {
      _page = 0;
      _items.clear();
      _imagePages.clear();
      _finishedServers.clear();
      _hasMore = true;
    }
    setState(() {
      _loading = true;
      _error = null;
      _suggestions = [];
    });
    final results = <CatalogItem>[];
    final errors = <String>[];
    final advancedPages = <String, int>{};
    final finished = <String>{};
    try {
      if (_books) {
        final preferences = widget.store.preferences;
        final query = [
          _activeQuery,
          ...preferences.defaultTags,
          ...preferences.excludedTags.map(
            (tag) => tag.startsWith('-') ? tag : '-$tag',
          ),
        ].where((e) => e.isNotEmpty).join(' ');
        results.addAll(
          await widget.catalog.searchBooks(
            query: query,
            page: _page,
            baseUrl: preferences.hitomiBaseUrl,
            language: _language,
            sort: _sort == 'popular' ? 'week' : _sort,
          ),
        );
      } else {
        final servers = widget.store.servers
            .where((s) => s.enabled && _serverIds.contains(s.id))
            .toList();
        if (servers.isEmpty) {
          throw const FormatException(
            '선택한 서버가 없습니다. 설정에서 서버를 추가하거나 아래에서 선택해 주세요.',
          );
        }
        await Future.wait(
          servers.where((server) => !_finishedServers.contains(server.id)).map((
            server,
          ) async {
            final page = _imagePages[server.id] ?? 0;
            try {
              final batch = await widget.catalog.imagePage(
                server: server,
                query: _activeQuery,
                page: page,
                rating: _rating,
                popular: _sort == 'popular',
              );
              results.addAll(batch.items);
              advancedPages[server.id] = page + 1;
              if (!batch.hasMore) finished.add(server.id);
            } catch (error) {
              errors.add('${server.name}: $error');
            }
          }),
        );
        if (_sort == 'popular') {
          results.sort((a, b) => b.score.compareTo(a.score));
        } else {
          results.sort((a, b) => (b.remoteId ?? 0).compareTo(a.remoteId ?? 0));
        }
      }
      if (!mounted || generation != _generation) return;
      setState(() {
        final ids = _items.map((e) => e.id).toSet();
        _items.addAll(results.where((e) => ids.add(e.id)));
        if (_books) {
          _hasMore = results.isNotEmpty;
          _page++;
        } else {
          _imagePages.addAll(advancedPages);
          _finishedServers.addAll(finished);
          _hasMore = widget.store.servers.any(
            (server) =>
                server.enabled &&
                _serverIds.contains(server.id) &&
                !_finishedServers.contains(server.id),
          );
        }
        _error = errors.isEmpty ? null : errors.join('\n');
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = '$error');
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  void _submit([String? query]) {
    if (query != null) _search.text = query;
    _activeQuery = _search.text.trim();
    if (_activeQuery.isNotEmpty) {
      attempt(context, () => widget.store.recordSearch(_activeQuery));
    }
    _load(reset: true);
  }

  void _suggest(String value) {
    _debounce?.cancel();
    if (_books || value.trim().length < 2) {
      setState(() => _suggestions = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      final server = widget.store.servers
          .where((s) => s.enabled && _serverIds.contains(s.id))
          .firstOrNull;
      if (server == null) return;
      try {
        final suggestions = await widget.catalog.suggestTags(
          server: server,
          query: value.split(' ').last,
        );
        if (mounted && _search.text == value) {
          setState(() => _suggestions = suggestions.take(8).toList());
        }
      } catch (_) {
        /* Suggestions are optional; the submitted query still works. */
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.store.servers.where((s) => s.enabled).toList();
    return RefreshIndicator(
      onRefresh: () => _load(reset: true),
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 0),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PageHeading(
                    eyebrow: 'DISCOVER',
                    title: _books ? '새로운 작품 발견' : '영감이 되는 이미지',
                    subtitle: _books
                        ? '좋아하는 작가와 태그로 다음 작품을 찾아보세요.'
                        : '여러 서버에서 찾고, 나만의 보관함에 모으세요.',
                    action: IconButton(
                      tooltip: '새로고침',
                      onPressed: _loading ? null : () => _load(reset: true),
                      icon: const Icon(Icons.refresh),
                    ),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _search,
                    focusNode: widget.searchFocus,
                    onSubmitted: _submit,
                    onChanged: _suggest,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: _books
                          ? '작품 검색 · artist:작가 · tag:태그'
                          : '태그 검색 · landscape sky',
                      suffixIcon: IconButton(
                        tooltip: '검색',
                        onPressed: _submit,
                        icon: const Icon(Icons.arrow_forward),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_suggestions.isNotEmpty)
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: _suggestions
                          .map(
                            (tag) => ActionChip(
                              label: Text(tag),
                              onPressed: () {
                                final tokens = _search.text.split(' ');
                                tokens[tokens.length - 1] = tag;
                                _submit(tokens.join(' '));
                              },
                            ),
                          )
                          .toList(),
                    ),
                  if (_activeQuery.isEmpty &&
                      _suggestions.isEmpty &&
                      widget.store.searchHistory.isNotEmpty)
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          const Icon(Icons.history, size: 16),
                          const SizedBox(width: 8),
                          ...widget.store.searchHistory
                              .take(5)
                              .map(
                                (q) => Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: ActionChip(
                                    label: Text(q),
                                    onPressed: () => _submit(q),
                                  ),
                                ),
                              ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      SegmentedButton<String>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(
                            value: 'latest',
                            label: Text('최신순'),
                            icon: Icon(Icons.schedule, size: 18),
                          ),
                          ButtonSegment(
                            value: 'popular',
                            label: Text('인기순'),
                            icon: Icon(Icons.trending_up, size: 18),
                          ),
                        ],
                        selected: {_sort},
                        onSelectionChanged: (v) {
                          setState(() => _sort = v.first);
                          _load(reset: true);
                        },
                      ),
                      if (_books)
                        DropdownButton<String>(
                          value: _language,
                          underline: const SizedBox.shrink(),
                          items: const [
                            DropdownMenuItem(
                              value: 'korean',
                              child: Text('한국어'),
                            ),
                            DropdownMenuItem(
                              value: 'japanese',
                              child: Text('일본어'),
                            ),
                            DropdownMenuItem(
                              value: 'english',
                              child: Text('영어'),
                            ),
                            DropdownMenuItem(
                              value: 'all',
                              child: Text('모든 언어'),
                            ),
                          ],
                          onChanged: (v) {
                            setState(() => _language = v!);
                            _load(reset: true);
                          },
                        )
                      else
                        DropdownButton<String>(
                          value: _rating,
                          underline: const SizedBox.shrink(),
                          items: const [
                            DropdownMenuItem(
                              value: 'safe',
                              child: Text('일반 수위'),
                            ),
                            DropdownMenuItem(
                              value: 'sensitive',
                              child: Text('민감'),
                            ),
                            DropdownMenuItem(
                              value: 'questionable',
                              child: Text('선정적'),
                            ),
                            DropdownMenuItem(
                              value: 'explicit',
                              child: Text('성인'),
                            ),
                            DropdownMenuItem(
                              value: 'all',
                              child: Text('전체 수위'),
                            ),
                          ],
                          onChanged: (v) {
                            setState(() => _rating = v!);
                            _load(reset: true);
                          },
                        ),
                    ],
                  ),
                  if (!_books) ...[
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: enabled
                          .map(
                            (server) => FilterChip(
                              label: Text(server.name),
                              selected: _serverIds.contains(server.id),
                              onSelected: (v) {
                                setState(() {
                                  if (v) {
                                    _serverIds.add(server.id);
                                  } else {
                                    _serverIds.remove(server.id);
                                  }
                                });
                                _load(reset: true);
                              },
                            ),
                          )
                          .toList(),
                    ),
                  ],
                  const SizedBox(height: 24),
                  if (_error != null)
                    Card(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.cloud_off_outlined),
                                SizedBox(width: 10),
                                Expanded(child: Text('일부 콘텐츠를 불러오지 못했습니다')),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Text(_error!),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              children: [
                                TextButton.icon(
                                  onPressed: _loading
                                      ? null
                                      : () => _load(reset: true),
                                  icon: const Icon(Icons.refresh),
                                  label: const Text('다시 시도'),
                                ),
                                TextButton.icon(
                                  onPressed: () => openWebsite(
                                    context,
                                    _books
                                        ? widget.store.preferences.hitomiBaseUrl
                                        : enabled.firstOrNull?.baseUrl ??
                                              'https://safebooru.org',
                                  ),
                                  icon: const Icon(Icons.open_in_new),
                                  label: const Text('브라우저에서 열기'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (_items.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              sliver: CatalogSliverGrid(
                items: _items,
                columns: widget.store.preferences.columns,
                isSaved: (item) => widget.store.find(item.id) != null,
                onOpen: (item) => showEntryDetail(
                  context,
                  item: item,
                  store: widget.store,
                  catalog: widget.catalog,
                  onSearchTag: widget.onSearchTag,
                ),
                onSave: (item) => widget.store.find(item.id) != null
                    ? showMessage(context, '이미 보관함에 저장되어 있습니다.')
                    : attempt(
                        context,
                        () => widget.store.save(item),
                        success: '보관함에 저장했습니다.',
                      ),
              ),
            ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.all(48),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  if (!_loading && _error == null && _items.isEmpty)
                    const EmptyState(
                      icon: Icons.search_off,
                      title: '검색 결과가 없습니다',
                      message: '검색어, 언어 또는 수위 필터를 바꿔 보세요.',
                    ),
                  if (!_loading &&
                      _hasMore &&
                      (_items.isNotEmpty || _error == null))
                    Padding(
                      padding: const EdgeInsets.only(top: 24),
                      child: Center(
                        child: OutlinedButton.icon(
                          onPressed: _load,
                          icon: const Icon(Icons.expand_more),
                          label: const Text('더 불러오기'),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
