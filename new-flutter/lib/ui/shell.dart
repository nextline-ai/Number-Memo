import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/library_store.dart';
import '../data/models.dart';
import '../services/catalog_service.dart';
import '../services/share_intake.dart';
import 'common.dart';
import 'entry_detail.dart';
import 'explore_page.dart';
import 'library_page.dart';
import 'settings_page.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.store, required this.catalog});
  final LibraryStore store;
  final CatalogService catalog;
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _destination = 1;
  String? _folderId;
  String _exploreQuery = '';
  int _queryRevision = 0;
  final _searchFocus = FocusNode();
  final _shellFocus = FocusNode(debugLabel: 'App navigation');
  final List<String> _pendingShares = [];
  late final ShareIntake _shareIntake;
  bool _addDialogOpen = false;
  bool _shareDrainScheduled = false;

  @override
  void initState() {
    super.initState();
    _shareIntake = ShareIntake((text) {
      if (!mounted || text.trim().isEmpty) return;
      _pendingShares.add(text);
      _drainSharedText();
    });
    unawaited(
      _shareIntake.start().catchError((Object error) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) showMessage(context, '공유한 내용을 읽지 못했어요. 다시 공유해 주세요.');
        });
      }),
    );
  }

  @override
  void didUpdateWidget(covariant AppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    _drainSharedText();
  }

  void _drainSharedText() {
    if (!mounted ||
        !widget.store.preferences.onboardingComplete ||
        _pendingShares.isEmpty ||
        _addDialogOpen ||
        _shareDrainScheduled) {
      return;
    }
    _shareDrainScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _shareDrainScheduled = false;
      if (!mounted ||
          !widget.store.preferences.onboardingComplete ||
          _pendingShares.isEmpty ||
          _addDialogOpen) {
        return;
      }
      unawaited(_showAdd(initialText: _pendingShares.removeAt(0)));
    });
  }

  @override
  void dispose() {
    _shareIntake.dispose();
    _searchFocus.dispose();
    _shellFocus.dispose();
    super.dispose();
  }

  void _searchFor(String query) => setState(() {
    _destination = 0;
    _exploreQuery = query;
    _queryRevision++;
  });

  Future<void> _add() async {
    if (widget.store.preferences.mode == LibraryMode.images) {
      _navigate(0);
      _focusSearch();
      return;
    }
    await _showAdd();
  }

  void _navigate(int destination) {
    _shellFocus.requestFocus();
    setState(() {
      _destination = destination;
      if (destination == 1) _folderId = null;
    });
  }

  void _focusSearch() {
    final hasItems = widget.store.items.any(
      (entry) => entry.item.mode == widget.store.preferences.mode,
    );
    setState(() {
      if (_destination != 0 && !hasItems) {
        _destination = 0;
      } else if (_destination > 1) {
        _destination = 1;
        _folderId = null;
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  Future<void> _setMode(LibraryMode mode) => attempt(context, () async {
    await widget.store.setPreferences(
      widget.store.preferences.copyWith(mode: mode),
    );
    if (mounted) {
      _shellFocus.requestFocus();
      setState(() {
        _folderId = null;
        _exploreQuery = '';
        _queryRevision++;
      });
    }
  });

  void _toggleMode() => unawaited(
    _setMode(
      widget.store.preferences.mode == LibraryMode.books
          ? LibraryMode.images
          : LibraryMode.books,
    ),
  );

  void _showShortcuts() {
    final modifier = Theme.of(context).platform == TargetPlatform.macOS
        ? '⌘'
        : 'Ctrl';
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('키보드 단축키'),
        content: SizedBox(
          width: 380,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final shortcut in [
                  ('$modifier + K', '검색창으로 이동'),
                  ('$modifier + N', '작품 추가 / 이미지 찾기'),
                  ('$modifier + 1', '탐색'),
                  ('$modifier + 2', '보관함'),
                  ('$modifier + 3', '폴더'),
                  ('$modifier + 4', '작가'),
                  ('$modifier + 5', '설정'),
                  ('$modifier + Shift + M', '책 / 이미지 모드 전환'),
                  ('F1', '단축키 안내'),
                ])
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            shortcut.$1,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        Expanded(child: Text(shortcut.$2)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('닫기'),
          ),
        ],
      ),
    );
  }

  Future<void> _showAdd({String? initialText}) async {
    if (!mounted || _addDialogOpen) return;
    _addDialogOpen = true;
    try {
      if (initialText != null) {
        await widget.store.setPreferences(
          widget.store.preferences.copyWith(mode: LibraryMode.books),
        );
        if (!mounted) return;
        setState(() {
          _destination = 1;
          _folderId = null;
        });
      }
      await showAddBooks(
        context,
        widget.store,
        widget.catalog,
        initialText: initialText,
      );
    } catch (error) {
      if (mounted) showMessage(context, '작품 추가를 열지 못했어요. $error');
    } finally {
      _addDialogOpen = false;
      _drainSharedText();
    }
  }

  Widget _modeSwitch() => SegmentedButton<LibraryMode>(
    showSelectedIcon: false,
    segments: const [
      ButtonSegment(
        value: LibraryMode.books,
        icon: Icon(Icons.menu_book_outlined),
        label: Text('책'),
      ),
      ButtonSegment(
        value: LibraryMode.images,
        icon: Icon(Icons.image_outlined),
        label: Text('이미지'),
      ),
    ],
    selected: {widget.store.preferences.mode},
    onSelectionChanged: (selection) => _setMode(selection.first),
  );

  @override
  Widget build(BuildContext context) {
    if (!widget.store.preferences.onboardingComplete) {
      return _WelcomePage(store: widget.store);
    }
    final mode = widget.store.preferences.mode;
    final color = Theme.of(context).colorScheme;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): _add,
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true): _add,
        const SingleActivator(LogicalKeyboardKey.keyK, control: true):
            _focusSearch,
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
            _focusSearch,
        for (final (index, key) in [
          LogicalKeyboardKey.digit1,
          LogicalKeyboardKey.digit2,
          LogicalKeyboardKey.digit3,
          LogicalKeyboardKey.digit4,
          LogicalKeyboardKey.digit5,
        ].indexed) ...{
          SingleActivator(key, control: true): () => _navigate(index),
          SingleActivator(key, meta: true): () => _navigate(index),
        },
        const SingleActivator(
          LogicalKeyboardKey.keyM,
          control: true,
          shift: true,
        ): _toggleMode,
        const SingleActivator(LogicalKeyboardKey.keyM, meta: true, shift: true):
            _toggleMode,
        const SingleActivator(LogicalKeyboardKey.f1): _showShortcuts,
      },
      child: Focus(
        focusNode: _shellFocus,
        autofocus: true,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final desktop = constraints.maxWidth >= 850;
            final body = switch (_destination) {
              0 => ExplorePage(
                key: ValueKey('explore-${mode.name}-$_queryRevision'),
                store: widget.store,
                catalog: widget.catalog,
                initialQuery: _exploreQuery,
                searchFocus: _searchFocus,
                onSearchTag: _searchFor,
              ),
              1 => LibraryPage(
                key: ValueKey('library-${mode.name}'),
                store: widget.store,
                catalog: widget.catalog,
                folderId: _folderId,
                searchFocus: _searchFocus,
                onAdd: _add,
                onExplore: () => setState(() => _destination = 0),
                onSearchTag: _searchFor,
                onClearFolder: () => setState(() => _folderId = null),
              ),
              2 => FoldersPage(
                store: widget.store,
                onOpen: (id) => setState(() {
                  _folderId = id;
                  _destination = 1;
                }),
              ),
              3 => ArtistsPage(store: widget.store, onSearch: _searchFor),
              _ => SettingsPage(store: widget.store),
            };
            return Scaffold(
              appBar: desktop
                  ? null
                  : AppBar(
                      title: const Text(
                        '품번메모',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 20,
                        ),
                      ),
                      actions: [
                        Padding(
                          padding: const EdgeInsets.only(right: 16),
                          child: _modeSwitch(),
                        ),
                      ],
                    ),
              body: SafeArea(
                child: Row(
                  children: [
                    if (desktop)
                      Container(
                        width: 244,
                        decoration: BoxDecoration(
                          border: Border(
                            right: BorderSide(
                              color: color.outlineVariant.withValues(
                                alpha: .45,
                              ),
                            ),
                          ),
                        ),
                        child: Material(
                          color: color.surfaceContainerLow,
                          child: LayoutBuilder(
                            builder: (context, sidebarConstraints) =>
                                SingleChildScrollView(
                                  child: ConstrainedBox(
                                    constraints: BoxConstraints(
                                      minHeight: sidebarConstraints.maxHeight,
                                    ),
                                    child: IntrinsicHeight(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          Padding(
                                            padding: const EdgeInsets.fromLTRB(
                                              24,
                                              32,
                                              20,
                                              30,
                                            ),
                                            child: Row(
                                              children: [
                                                Container(
                                                  width: 40,
                                                  height: 40,
                                                  decoration: BoxDecoration(
                                                    color: color.primary,
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          13,
                                                        ),
                                                  ),
                                                  child: Icon(
                                                    Icons.bookmarks_rounded,
                                                    color: color.onPrimary,
                                                    size: 23,
                                                  ),
                                                ),
                                                const SizedBox(width: 12),
                                                const Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      '품번메모',
                                                      style: TextStyle(
                                                        fontSize: 21,
                                                        fontWeight:
                                                            FontWeight.w800,
                                                        letterSpacing: -.5,
                                                      ),
                                                    ),
                                                    Text(
                                                      'NUMBER MEMO',
                                                      style: TextStyle(
                                                        fontSize: 9,
                                                        letterSpacing: 1.7,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ],
                                            ),
                                          ),
                                          Padding(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 20,
                                            ),
                                            child: _modeSwitch(),
                                          ),
                                          const SizedBox(height: 30),
                                          Padding(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 14,
                                            ),
                                            child: FilledButton.icon(
                                              onPressed:
                                                  mode == LibraryMode.books
                                                  ? _add
                                                  : () => setState(
                                                      () => _destination = 0,
                                                    ),
                                              style: FilledButton.styleFrom(
                                                padding: const EdgeInsets.all(
                                                  20,
                                                ),
                                              ),
                                              icon: Icon(
                                                mode == LibraryMode.books
                                                    ? Icons.add
                                                    : Icons.travel_explore,
                                              ),
                                              label: Text(
                                                mode == LibraryMode.books
                                                    ? '작품 추가'
                                                    : '이미지 찾기',
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 20),
                                          ...List.generate(
                                            5,
                                            (index) => Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 12,
                                                    vertical: 3,
                                                  ),
                                              child: ListTile(
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(28),
                                                ),
                                                selected: _destination == index,
                                                selectedTileColor:
                                                    color.secondaryContainer,
                                                selectedColor:
                                                    color.onSecondaryContainer,
                                                leading: Icon(
                                                  _destination == index
                                                      ? _selectedIcons[index]
                                                      : _icons[index],
                                                ),
                                                title: Text(
                                                  _labels[index],
                                                  style: TextStyle(
                                                    fontWeight:
                                                        _destination == index
                                                        ? FontWeight.w700
                                                        : FontWeight.w500,
                                                  ),
                                                ),
                                                onTap: () => _navigate(index),
                                              ),
                                            ),
                                          ),
                                          const Spacer(),
                                          Padding(
                                            padding: const EdgeInsets.fromLTRB(
                                              14,
                                              20,
                                              14,
                                              0,
                                            ),
                                            child: TextButton.icon(
                                              onPressed: _showShortcuts,
                                              icon: const Icon(
                                                Icons.keyboard_outlined,
                                                size: 18,
                                              ),
                                              label: const Text('키보드 단축키'),
                                            ),
                                          ),
                                          Padding(
                                            padding: const EdgeInsets.all(24),
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Row(
                                                  children: [
                                                    Icon(
                                                      Icons
                                                          .offline_pin_outlined,
                                                      size: 16,
                                                      color: color.primary,
                                                    ),
                                                    const SizedBox(width: 8),
                                                    Text(
                                                      '나만의 로컬 보관함',
                                                      style: TextStyle(
                                                        fontSize: 12,
                                                        color: color
                                                            .onSurfaceVariant,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                                const SizedBox(height: 8),
                                                Text(
                                                  '좋아하는 순간을, 오래도록.',
                                                  style: TextStyle(
                                                    fontSize: 11,
                                                    color:
                                                        color.onSurfaceVariant,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                          ),
                        ),
                      ),
                    Expanded(child: body),
                  ],
                ),
              ),
              bottomNavigationBar: desktop
                  ? null
                  : NavigationBar(
                      selectedIndex: _destination,
                      onDestinationSelected: _navigate,
                      destinations: List.generate(
                        5,
                        (index) => NavigationDestination(
                          icon: Icon(_icons[index]),
                          selectedIcon: Icon(_selectedIcons[index]),
                          label: _labels[index],
                        ),
                      ),
                    ),
              floatingActionButton:
                  !desktop && mode == LibraryMode.books && _destination == 1
                  ? FloatingActionButton.extended(
                      onPressed: _add,
                      icon: const Icon(Icons.add),
                      label: const Text('작품 추가'),
                    )
                  : null,
            );
          },
        ),
      ),
    );
  }
}

const _labels = ['탐색', '보관함', '폴더', '작가', '설정'];
const _icons = [
  Icons.explore_outlined,
  Icons.bookmarks_outlined,
  Icons.folder_outlined,
  Icons.people_outline,
  Icons.tune,
];
const _selectedIcons = [
  Icons.explore,
  Icons.bookmarks,
  Icons.folder,
  Icons.people,
  Icons.tune,
];

class _WelcomePage extends StatefulWidget {
  const _WelcomePage({required this.store});
  final LibraryStore store;
  @override
  State<_WelcomePage> createState() => _WelcomePageState();
}

class _WelcomePageState extends State<_WelcomePage> {
  late final _address = TextEditingController(
    text: widget.store.preferences.hitomiBaseUrl,
  );
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final uri = Uri.tryParse(_address.text.trim());
    if (uri == null ||
        !['https', 'http'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      setState(() => _error = 'https://로 시작하는 사이트 주소를 입력해 주세요.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.store.setPreferences(
        widget.store.preferences.copyWith(
          onboardingComplete: true,
          hitomiBaseUrl: uri.origin,
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: colors.primaryContainer,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Icon(
                      Icons.bookmarks_rounded,
                      size: 40,
                      color: colors.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(height: 32),
                  Text(
                    '취향이 모이는 곳,\n품번메모',
                    style: Theme.of(context).textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      height: 1.3,
                      letterSpacing: -1.5,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    '책과 이미지를 발견하고, 폴더에 담고,\n다시 보고 싶은 순간을 기록하세요.',
                    style: TextStyle(
                      fontSize: 17,
                      height: 1.7,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 36),
                  TextField(
                    controller: _address,
                    decoration: InputDecoration(
                      labelText: '책 사이트 주소',
                      helperText: '나중에 설정에서 변경할 수 있습니다.',
                      errorText: _error,
                    ),
                    keyboardType: TextInputType.url,
                  ),
                  const SizedBox(height: 24),
                  const ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.image_outlined),
                    title: Text('이미지는 Safebooru로 시작해요'),
                    subtitle: Text('설정에서 원하는 Booru 서버를 추가할 수 있어요.'),
                  ),
                  const ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.folder_copy_outlined),
                    title: Text('기존 보관함도 함께'),
                    subtitle: Text('설정에서 품번메모 JSON 백업을 가져오세요.'),
                  ),
                  const SizedBox(height: 28),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _start,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.all(20),
                      ),
                      icon: _busy
                          ? const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.arrow_forward),
                      label: const Text('내 보관함 시작하기'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
