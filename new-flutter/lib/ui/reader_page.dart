import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/library_store.dart';
import '../data/models.dart';
import '../services/catalog_service.dart';
import '../services/media_export.dart';
import 'app_theme.dart';
import 'common.dart';

class ReaderPage extends StatefulWidget {
  const ReaderPage({
    super.key,
    required this.item,
    required this.store,
    required this.catalog,
  });
  final CatalogItem item;
  final LibraryStore store;
  final CatalogService catalog;
  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  List<String> _pages = [];
  bool _loading = true, _controls = true, _zoomed = false;
  bool _restoringPosition = false;
  int _navigationGeneration = 0;
  String? _error;
  late bool _continuous = widget.store.preferences.readerContinuous;
  late bool _rtl = widget.store.preferences.readerRtl;
  late bool _fitWidth = widget.store.preferences.readerFitWidth;
  late bool _pageNumber = widget.store.preferences.readerShowPageNumber;
  late bool _tapNavigation = widget.store.preferences.readerTapNavigation;
  late int _page = widget.store.find(widget.item.id)?.readingPage ?? 0;
  final DateTime _openedAt = DateTime.now().toUtc();
  PageController? _controller;
  final _scroll = ScrollController();
  final Map<int, double> _ratios = {};
  Timer? _progressTimer;
  Size _viewport = const Size(400, 600);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool refresh = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final pages =
          widget.item.mode == LibraryMode.books && widget.item.remoteId != null
          ? await widget.catalog.galleryPages(
              widget.item.remoteId!,
              baseUrl: widget.store.preferences.hitomiBaseUrl,
              refresh: refresh,
            )
          : widget.item.mediaUrls.isNotEmpty
          ? widget.item.mediaUrls
          : [if (widget.item.thumbnailUrl.isNotEmpty) widget.item.thumbnailUrl];
      if (pages.isEmpty) {
        throw const FormatException('표시할 이미지가 없습니다. 작품 정보를 다시 불러와 주세요.');
      }
      if (!mounted) return;
      setState(() {
        _pages = pages;
        _page = _page.clamp(0, pages.length - 1);
        _controller?.dispose();
        _controller = PageController(initialPage: _page);
        _loading = false;
        _zoomed = false;
        _ratios.clear();
      });
      if (_continuous) _restorePosition();
      unawaited(_persistProgress());
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '$error';
          _loading = false;
        });
      }
    }
  }

  Future<void> _persistProgress() async {
    if (_pages.isEmpty) return;
    final current = widget.store.find(widget.item.id);
    if (current == null ||
        (current.readingPage == _page && current.lastOpenedAt == _openedAt)) {
      return;
    }
    try {
      await widget.store.recordReadingProgress(
        widget.item.id,
        _page,
        openedAt: _openedAt,
      );
    } catch (e) {
      if (mounted) showMessage(context, '읽던 위치를 저장하지 못했습니다: $e');
    }
  }

  void _changed(int page) {
    if (_page != page) {
      setState(() {
        _page = page;
        _zoomed = false;
      });
    }
    _progressTimer?.cancel();
    _progressTimer = Timer(const Duration(milliseconds: 400), _persistProgress);
  }

  double _pageHeight(int index) => _fitWidth && _ratios.containsKey(index)
      ? math.max(1, _viewport.width * _ratios[index]!)
      : _viewport.height;

  double _offsetForPage(int page) {
    if (!_fitWidth) return page * _viewport.height;
    var offset = 0.0;
    for (var i = 0; i < page; i++) {
      offset += _pageHeight(i);
    }
    return offset;
  }

  int _pageForOffset(double offset) {
    var start = 0.0;
    // Track the page crossing the upper third, so tall pages remain current
    // until the reader has actually scrolled through them.
    final focus = offset + math.min(_viewport.height / 3, 120);
    for (var i = 0; i < _pages.length; i++) {
      start += _pageHeight(i);
      if (focus < start) return i;
    }
    return _pages.length - 1;
  }

  void _restorePosition({double fraction = 0}) {
    if (!_continuous) return;
    final generation = ++_navigationGeneration;
    _restoringPosition = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _navigationGeneration) return;
      if (_scroll.hasClients) {
        final offset = _offsetForPage(_page) + _pageHeight(_page) * fraction;
        _scroll.jumpTo(offset.clamp(0, _scroll.position.maxScrollExtent));
      }
      _restoringPosition = false;
    });
  }

  double get _pageFraction => _continuous && _scroll.hasClients
      ? ((_scroll.offset - _offsetForPage(_page)) / _pageHeight(_page)).clamp(
          0,
          1,
        )
      : 0;

  void _imageRatio(int index, double ratio) {
    if (!mounted || (_ratios[index] ?? 0) == ratio) return;
    final fraction = _pageFraction;
    setState(() => _ratios[index] = ratio);
    if (_continuous && _fitWidth) _restorePosition(fraction: fraction);
  }

  Future<void> _go(int page) async {
    if (_pages.isEmpty) return;
    final target = page.clamp(0, _pages.length - 1);
    final generation = ++_navigationGeneration;
    _changed(target);
    if (_continuous && _scroll.hasClients) {
      _restoringPosition = true;
      await _scroll.animateTo(
        _offsetForPage(target).clamp(0, _scroll.position.maxScrollExtent),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
      if (mounted && generation == _navigationGeneration) {
        _restoringPosition = false;
      }
    } else if (_controller?.hasClients ?? false) {
      await _controller!.animateToPage(
        target,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    }
  }

  void _setContinuous(bool value) {
    setState(() {
      _continuous = value;
      _zoomed = false;
    });
    if (value) {
      _restorePosition();
    } else {
      _navigationGeneration++;
      _restoringPosition = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && (_controller?.hasClients ?? false)) {
          _controller!.jumpToPage(_page);
        }
      });
    }
    _savePreferences();
  }

  void _savePreferences() => attempt(
    context,
    () => widget.store.setPreferences(
      widget.store.preferences.copyWith(
        readerContinuous: _continuous,
        readerRtl: _rtl,
        readerFitWidth: _fitWidth,
        readerShowPageNumber: _pageNumber,
        readerTapNavigation: _tapNavigation,
      ),
    ),
  );

  void _tapped(double fraction) {
    if (_zoomed || !_tapNavigation || (fraction >= .3 && fraction <= .7)) {
      setState(() => _controls = !_controls);
    } else {
      _go(_page + (fraction < .3 ? -1 : 1) * (_rtl ? -1 : 1));
    }
  }

  Future<void> _bookmark() async {
    await attempt(context, () async {
      if (widget.store.find(widget.item.id) == null) {
        await widget.store.save(widget.item);
      }
      await _persistProgress();
      if (mounted) {
        setState(() {});
        showMessage(context, '보관함에 읽던 위치를 저장했습니다');
      }
    });
  }

  Future<void> _exportCurrentPage({bool share = false}) async {
    if (_pages.isEmpty) return;
    final url = _pages[_page];
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    final extension =
        RegExp(r'\.(png|jpe?g|webp|gif|avif|mp4|webm)$')
            .firstMatch(path)
            ?.group(1) ??
        'jpg';
    await exportMedia(
      context,
      url: url,
      filename: '${widget.item.title}-${_page + 1}.$extension',
      headers: imageHeaders(widget.item),
      share: share,
    );
  }

  Future<void> _jumpToPage() async {
    if (_pages.isEmpty) return;
    final input = TextEditingController(text: '${_page + 1}');
    input.selection = TextSelection(
      baseOffset: 0,
      extentOffset: input.text.length,
    );
    String? error;
    final target = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          void submit() {
            final value = int.tryParse(input.text.trim());
            if (value == null || value < 1 || value > _pages.length) {
              setDialogState(
                () => error = '1~${_pages.length} 사이의 페이지를 입력해 주세요',
              );
              return;
            }
            Navigator.pop(context, value - 1);
          }

          return AlertDialog(
            title: const Text('페이지로 이동'),
            content: TextField(
              key: const ValueKey('reader-page-input'),
              controller: input,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: '페이지 번호',
                helperText: '전체 ${_pages.length}페이지',
                errorText: error,
              ),
              onSubmitted: (_) => submit(),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('취소'),
              ),
              FilledButton(onPressed: submit, child: const Text('이동')),
            ],
          );
        },
      ),
    );
    // The closing route still owns its TextField during the reverse transition.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    input.dispose();
    if (mounted && target != null) _go(target);
  }

  Future<void> _showThumbnails() async {
    final target = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .78,
          child: Column(
            children: [
              ListTile(
                title: Text('페이지 목록 · ${_pages.length}페이지'),
                trailing: IconButton(
                  tooltip: '닫기',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 180,
                    childAspectRatio: .65,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  itemCount: _pages.length,
                  itemBuilder: (context, index) => InkWell(
                    key: ValueKey('reader-thumbnail-$index'),
                    onTap: () => Navigator.pop(context, index),
                    child: Column(
                      children: [
                        Expanded(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: index == _page
                                    ? Theme.of(context).colorScheme.primary
                                    : Colors.grey,
                                width: index == _page ? 3 : 1,
                              ),
                            ),
                            child: Image.network(
                              _pages[index],
                              headers: imageHeaders(widget.item),
                              fit: BoxFit.contain,
                              width: double.infinity,
                              cacheWidth: 240,
                              errorBuilder: (_, _, _) => const Center(
                                child: Icon(Icons.image_outlined),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text('${index + 1}${index == _page ? ' · 현재' : ''}'),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (mounted && target != null) _go(target);
  }

  void _help() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('뷰어 사용법'),
      content: const SingleChildScrollView(
        child: Text(
          '화면 양쪽 탭: 이전·다음 페이지\n가운데 탭: 메뉴 표시·숨기기\n길게 누르기: 보관함에 저장\n두 번 탭·핀치: 확대·축소\n확대 중 드래그: 이미지 이동\n페이지 번호: 원하는 페이지로 이동\n\n가로 맞춤에서는 긴 이미지를 위아래로 스크롤할 수 있습니다.\n\n키보드\n← → / Page Up·Down: 페이지 이동\nHome / End: 처음·마지막 페이지\nG: 페이지로 이동\nM: 메뉴 표시·숨기기\nEsc: 뷰어 닫기',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('확인'),
        ),
      ],
    ),
  );

  @override
  void dispose() {
    _progressTimer?.cancel();
    unawaited(_persistProgress());
    _controller?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Widget _image(int index) => _ReaderImage(
    key: ValueKey('reader-image-$index-$_continuous-$_fitWidth'),
    url: _pages[index],
    item: widget.item,
    fitWidth: _fitWidth,
    continuous: _continuous,
    onTap: _tapped,
    onBookmark: _bookmark,
    onRatio: (ratio) => _imageRatio(index, ratio),
    onZoom: (zoomed) {
      if (mounted && index == _page && _zoomed != zoomed) {
        setState(() => _zoomed = zoomed);
      }
    },
    onRefresh: () => _load(refresh: true),
  );

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.escape): () =>
          Navigator.maybePop(context),
      const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
          _go(_page + (_rtl ? -1 : 1)),
      const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
          _go(_page + (_rtl ? 1 : -1)),
      const SingleActivator(LogicalKeyboardKey.arrowDown): () => _go(_page + 1),
      const SingleActivator(LogicalKeyboardKey.arrowUp): () => _go(_page - 1),
      const SingleActivator(LogicalKeyboardKey.space): () => _go(_page + 1),
      const SingleActivator(LogicalKeyboardKey.pageDown): () => _go(_page + 1),
      const SingleActivator(LogicalKeyboardKey.pageUp): () => _go(_page - 1),
      const SingleActivator(LogicalKeyboardKey.home): () => _go(0),
      const SingleActivator(LogicalKeyboardKey.end): () =>
          _go(_pages.length - 1),
      const SingleActivator(LogicalKeyboardKey.keyG): _jumpToPage,
      const SingleActivator(LogicalKeyboardKey.keyM): () =>
          setState(() => _controls = !_controls),
    },
    child: Focus(
      autofocus: true,
      child: Theme(
        data: buildMonochromeTheme(Brightness.dark),
        child: Scaffold(
          backgroundColor: Colors.black,
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final nextSize = Size(
                  constraints.maxWidth,
                  constraints.maxHeight,
                );
                if (nextSize != _viewport) {
                  final fraction = _pageFraction;
                  _viewport = nextSize;
                  if (_continuous) _restorePosition(fraction: fraction);
                }
                return Stack(
                  children: [
                    Positioned.fill(
                      child: _loading
                          ? const Center(child: CircularProgressIndicator())
                          : _error != null
                          ? EmptyState(
                              icon: Icons.broken_image_outlined,
                              title: '이미지를 불러올 수 없습니다',
                              message: _error!,
                              action: FilledButton.icon(
                                onPressed: () => _load(refresh: true),
                                icon: const Icon(Icons.refresh),
                                label: const Text('다시 시도'),
                              ),
                            )
                          : _continuous
                          ? NotificationListener<ScrollNotification>(
                              onNotification: (notification) {
                                if (!_restoringPosition &&
                                    notification.depth == 0 &&
                                    notification is ScrollUpdateNotification &&
                                    _pages.isNotEmpty) {
                                  _changed(
                                    _pageForOffset(notification.metrics.pixels),
                                  );
                                }
                                return false;
                              },
                              child: ListView.builder(
                                key: const ValueKey('reader-continuous'),
                                controller: _scroll,
                                physics: _zoomed
                                    ? const NeverScrollableScrollPhysics()
                                    : null,
                                itemExtentBuilder: (index, _) =>
                                    _pageHeight(index),
                                itemCount: _pages.length,
                                itemBuilder: (_, index) => _image(index),
                              ),
                            )
                          : PageView.builder(
                              key: const ValueKey('reader-paged'),
                              controller: _controller,
                              reverse: _rtl,
                              physics: _zoomed
                                  ? const NeverScrollableScrollPhysics()
                                  : null,
                              itemCount: _pages.length,
                              onPageChanged: _changed,
                              itemBuilder: (_, index) => _image(index),
                            ),
                    ),
                    if (_controls)
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: ColoredBox(
                          color: Colors.black.withValues(alpha: .85),
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: Row(
                              children: [
                                IconButton(
                                  tooltip: '뷰어 닫기',
                                  onPressed: () => Navigator.pop(context),
                                  icon: const Icon(Icons.arrow_back),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    widget.item.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                IconButton(
                                  tooltip: '보관함에 저장',
                                  onPressed: _bookmark,
                                  icon: Icon(
                                    widget.store.find(widget.item.id) == null
                                        ? Icons.bookmark_add_outlined
                                        : Icons.bookmark,
                                  ),
                                ),
                                PopupMenuButton<String>(
                                  tooltip: '읽기 설정',
                                  onSelected: (value) {
                                    if (value == 'scroll') {
                                      _setContinuous(!_continuous);
                                    }
                                    if (value == 'rtl') {
                                      setState(() => _rtl = !_rtl);
                                      _savePreferences();
                                    }
                                    if (value == 'fit') {
                                      setState(() {
                                        _fitWidth = !_fitWidth;
                                        _zoomed = false;
                                      });
                                      _restorePosition();
                                      _savePreferences();
                                    }
                                    if (value == 'number') {
                                      setState(
                                        () => _pageNumber = !_pageNumber,
                                      );
                                      _savePreferences();
                                    }
                                    if (value == 'tap') {
                                      setState(
                                        () => _tapNavigation = !_tapNavigation,
                                      );
                                      _savePreferences();
                                    }
                                    if (value == 'pages') _showThumbnails();
                                    if (value == 'save') _exportCurrentPage();
                                    if (value == 'share') {
                                      _exportCurrentPage(share: true);
                                    }
                                    if (value == 'help') _help();
                                    if (value == 'browser') {
                                      openWebsite(
                                        context,
                                        widget.item.sourceUrl,
                                      );
                                    }
                                  },
                                  itemBuilder: (_) => [
                                    CheckedPopupMenuItem(
                                      value: 'scroll',
                                      checked: _continuous,
                                      child: const Text('세로 연속 보기'),
                                    ),
                                    CheckedPopupMenuItem(
                                      value: 'rtl',
                                      checked: _rtl,
                                      child: const Text('오른쪽에서 왼쪽으로'),
                                    ),
                                    CheckedPopupMenuItem(
                                      value: 'fit',
                                      checked: _fitWidth,
                                      child: const Text('가로 맞춤'),
                                    ),
                                    CheckedPopupMenuItem(
                                      value: 'number',
                                      checked: _pageNumber,
                                      child: const Text('메뉴를 숨겨도 페이지 번호 표시'),
                                    ),
                                    CheckedPopupMenuItem(
                                      value: 'tap',
                                      checked: _tapNavigation,
                                      child: const Text('양쪽 탭으로 페이지 이동'),
                                    ),
                                    const PopupMenuDivider(),
                                    PopupMenuItem(
                                      value: 'pages',
                                      enabled: _pages.isNotEmpty,
                                      child: const Text('페이지 목록'),
                                    ),
                                    PopupMenuItem(
                                      value: 'save',
                                      enabled: _pages.isNotEmpty,
                                      child: const Text('현재 이미지 저장'),
                                    ),
                                    if (supportsMediaSharing)
                                      PopupMenuItem(
                                        value: 'share',
                                        enabled: _pages.isNotEmpty,
                                        child: const Text('현재 이미지 공유'),
                                      ),
                                    const PopupMenuItem(
                                      value: 'help',
                                      child: Text('뷰어 사용법'),
                                    ),
                                    const PopupMenuItem(
                                      value: 'browser',
                                      child: Text('브라우저에서 열기'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    if (_controls && !_loading && _pages.isNotEmpty)
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: ColoredBox(
                          color: Colors.black.withValues(alpha: .85),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 12,
                            ),
                            child: Row(
                              children: [
                                IconButton(
                                  tooltip: '이전 페이지',
                                  onPressed: _page > 0
                                      ? () => _go(_page - 1)
                                      : null,
                                  icon: const Icon(Icons.chevron_left),
                                ),
                                Expanded(
                                  child: Slider(
                                    value: _page.toDouble(),
                                    min: 0,
                                    max: math
                                        .max(1, _pages.length - 1)
                                        .toDouble(),
                                    divisions: _pages.length > 1
                                        ? _pages.length - 1
                                        : null,
                                    label: '${_page + 1}',
                                    onChanged: _pages.length > 1
                                        ? (v) => _go(v.round())
                                        : null,
                                  ),
                                ),
                                TextButton(
                                  onPressed: _jumpToPage,
                                  child: Text(
                                    '${_page + 1} / ${_pages.length}',
                                    style: const TextStyle(
                                      fontFeatures: [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: '다음 페이지',
                                  onPressed: _page < _pages.length - 1
                                      ? () => _go(_page + 1)
                                      : null,
                                  icon: const Icon(Icons.chevron_right),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    if (!_controls &&
                        _pageNumber &&
                        !_loading &&
                        _pages.isNotEmpty)
                      Positioned(
                        bottom: 12,
                        right: 16,
                        child: Material(
                          color: Colors.black.withValues(alpha: .7),
                          borderRadius: BorderRadius.circular(16),
                          child: TextButton(
                            onPressed: _jumpToPage,
                            child: Text(
                              '${_page + 1} / ${_pages.length}',
                              style: const TextStyle(
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
}

class _ReaderImage extends StatefulWidget {
  const _ReaderImage({
    super.key,
    required this.url,
    required this.item,
    required this.fitWidth,
    required this.continuous,
    required this.onTap,
    required this.onBookmark,
    required this.onRatio,
    required this.onZoom,
    required this.onRefresh,
  });
  final String url;
  final CatalogItem item;
  final bool fitWidth, continuous;
  final ValueChanged<double> onTap, onRatio;
  final ValueChanged<bool> onZoom;
  final VoidCallback onBookmark, onRefresh;
  @override
  State<_ReaderImage> createState() => _ReaderImageState();
}

class _ReaderImageState extends State<_ReaderImage> {
  final _transform = TransformationController();
  Offset _doubleTapPosition = Offset.zero;
  ImageStream? _imageStream;
  ImageStreamListener? _imageListener;
  int _retry = 0;
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _transform.addListener(_zoomChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveImage();
  }

  @override
  void didUpdateWidget(_ReaderImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) _resolveImage();
  }

  void _resolveImage() {
    if (_imageListener != null) _imageStream?.removeListener(_imageListener!);
    _imageStream = NetworkImage(
      widget.url,
      headers: imageHeaders(widget.item),
    ).resolve(createLocalImageConfiguration(context));
    _imageListener = ImageStreamListener((info, _) {
      final ratio = info.image.height / info.image.width;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onRatio(ratio);
      });
      info.dispose();
    }, onError: (_, _) {});
    _imageStream!.addListener(_imageListener!);
  }

  void _zoomChanged() {
    final next = _transform.value.getMaxScaleOnAxis() > 1.01;
    if (_zoomed == next) return;
    setState(() => _zoomed = next);
    widget.onZoom(next);
  }

  @override
  void dispose() {
    if (_imageListener != null) _imageStream?.removeListener(_imageListener!);
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final path = Uri.tryParse(widget.url)?.path.toLowerCase() ?? '';
    if (RegExp(r'\.(mp4|webm|mov|mkv)$').hasMatch(path)) {
      return EmptyState(
        icon: Icons.play_circle_outline,
        title: '동영상 콘텐츠',
        message: '이 형식은 기본 브라우저에서 재생할 수 있습니다.',
        action: FilledButton.icon(
          onPressed: () => openWebsite(context, widget.url),
          icon: const Icon(Icons.open_in_new),
          label: const Text('동영상 열기'),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final image = Image.network(
          widget.url,
          key: ValueKey('${widget.url}-$_retry'),
          headers: imageHeaders(widget.item),
          width: constraints.maxWidth,
          fit: widget.fitWidth ? BoxFit.fitWidth : BoxFit.contain,
          loadingBuilder: (_, child, progress) => progress == null
              ? child
              : SizedBox(
                  height: math.min(constraints.maxHeight, 200),
                  child: Center(
                    child: CircularProgressIndicator(
                      value: progress.expectedTotalBytes == null
                          ? null
                          : progress.cumulativeBytesLoaded /
                                progress.expectedTotalBytes!,
                    ),
                  ),
                ),
          errorBuilder: (_, _, _) => SizedBox(
            height: math.min(constraints.maxHeight, 360),
            child: EmptyState(
              icon: Icons.broken_image_outlined,
              title: '이미지를 불러오지 못했습니다',
              message: '네트워크 연결이나 원본 이미지 주소를 확인해 주세요.',
              action: Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: () {
                      setState(() => _retry++);
                      _resolveImage();
                    },
                    icon: const Icon(Icons.refresh),
                    label: const Text('다시 시도'),
                  ),
                  if (widget.item.mode == LibraryMode.books)
                    TextButton(
                      onPressed: widget.onRefresh,
                      child: const Text('주소 새로 받기'),
                    ),
                  TextButton(
                    onPressed: () =>
                        openWebsite(context, widget.item.sourceUrl),
                    child: const Text('원본 열기'),
                  ),
                ],
              ),
            ),
          ),
        );
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) => widget.onTap(
            _zoomed ? .5 : details.localPosition.dx / constraints.maxWidth,
          ),
          onLongPress: widget.onBookmark,
          onDoubleTapDown: (details) =>
              _doubleTapPosition = details.localPosition,
          onDoubleTap: () {
            _transform.value = _zoomed
                ? Matrix4.identity()
                : (Matrix4.identity()
                    ..setEntry(0, 0, 2.5)
                    ..setEntry(1, 1, 2.5)
                    ..setEntry(0, 3, -_doubleTapPosition.dx * 1.5)
                    ..setEntry(1, 3, -_doubleTapPosition.dy * 1.5));
          },
          child: InteractiveViewer(
            transformationController: _transform,
            panEnabled: _zoomed,
            minScale: 1,
            maxScale: 5,
            child: widget.fitWidth && !widget.continuous
                ? SingleChildScrollView(
                    physics: _zoomed
                        ? const NeverScrollableScrollPhysics()
                        : null,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight,
                      ),
                      child: Center(child: image),
                    ),
                  )
                : SizedBox.expand(child: image),
          ),
        );
      },
    );
  }
}
