import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../data/library_store.dart';
import '../data/models.dart';
import '../services/import_file.dart';
import 'common.dart';
import 'legacy_import_dialog.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.store});

  final LibraryStore store;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const _backupType = XTypeGroup(
    label: 'JSON 백업',
    extensions: ['json'],
    mimeTypes: ['application/json'],
    uniformTypeIdentifiers: ['public.json'],
  );

  bool _busy = false;
  int? _pendingColumns;

  Future<void> _run(Future<void> Function() action, {String? success}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (mounted && success != null) showMessage(context, success);
    } on FormatException catch (error) {
      if (mounted) {
        showMessage(context, '입력한 내용이나 파일 형식을 확인해 주세요. ${error.message}');
      }
    } on FileSystemException {
      if (mounted) {
        showMessage(context, '파일을 저장하거나 읽지 못했어요. 저장 공간과 접근 권한을 확인해 주세요.');
      }
    } catch (error) {
      if (mounted) showMessage(context, '변경 사항을 적용하지 못했어요. $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setPreferences(AppPreferences preferences) =>
      _run(() => widget.store.setPreferences(preferences));

  Future<void> _editHitomiAddress() async {
    final value = await showDialog<String>(
      context: context,
      builder: (_) => _TextSettingDialog(
        title: 'Hitomi 사이트 주소',
        label: '사이트 주소',
        initialValue: widget.store.preferences.hitomiBaseUrl,
        helper: 'http:// 또는 https://로 시작하는 주소를 입력해 주세요.',
        keyboardType: TextInputType.url,
        validator: _baseUrlError,
      ),
    );
    if (!mounted || value == null) return;
    await _setPreferences(
      widget.store.preferences.copyWith(
        hitomiBaseUrl: _normalizeBaseUrl(value),
      ),
    );
  }

  Future<void> _editTags({required bool excluded}) async {
    final preferences = widget.store.preferences;
    final value = await showDialog<String>(
      context: context,
      builder: (_) => _TextSettingDialog(
        title: excluded ? '기본 제외 태그' : '기본 검색 태그',
        label: '태그',
        initialValue:
            (excluded ? preferences.excludedTags : preferences.defaultTags)
                .join(' '),
        helper: '태그는 공백으로 구분하고, 태그 안의 공백은 밑줄(_)로 이어 주세요.',
        hint: excluded ? 'tag:example' : 'language:korean artist:example',
        multiline: true,
      ),
    );
    if (!mounted || value == null) return;
    final tags = _splitTags(value, removeMinus: excluded);
    await _setPreferences(
      excluded
          ? widget.store.preferences.copyWith(excludedTags: tags)
          : widget.store.preferences.copyWith(defaultTags: tags),
    );
  }

  Future<void> _editServer([BooruServer? server]) async {
    final result = await showDialog<BooruServer>(
      context: context,
      builder: (_) => _ServerDialog(server: server),
    );
    if (!mounted || result == null) return;
    final duplicate = widget.store.servers.any(
      (entry) =>
          entry.id != result.id &&
          _normalizeBaseUrl(entry.baseUrl) == result.baseUrl,
    );
    if (duplicate) {
      showMessage(context, '이미 등록한 서버 주소예요. 기존 서버를 수정해 주세요.');
      return;
    }
    await _run(
      () => widget.store.upsertServer(result),
      success: server == null ? '서버를 추가했어요.' : '서버 설정을 저장했어요.',
    );
  }

  Future<void> _deleteServer(BooruServer server) async {
    final approved = await confirm(
      context,
      title: '${server.name} 서버 삭제',
      message: '탐색에 사용할 서버 목록에서 삭제합니다. 이미 보관함에 저장한 이미지는 유지됩니다.',
    );
    if (!mounted || !approved) return;
    await _run(
      () => widget.store.removeServer(server.id),
      success: '서버를 삭제했어요.',
    );
  }

  Future<void> _exportBackup() => _run(() async {
    final date = DateTime.now().toIso8601String().split('T').first;
    final name = 'number-memo-$date.json';
    final bytes = Uint8List.fromList(utf8.encode(widget.store.exportBackup()));
    final file = XFile.fromData(
      bytes,
      name: name,
      mimeType: 'application/json',
    );

    if (Platform.isAndroid || Platform.isIOS) {
      final box = context.findRenderObject() as RenderBox?;
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [file],
          fileNameOverrides: [name],
          subject: '품번메모 백업',
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
      if (mounted && result.status == ShareResultStatus.success) {
        showMessage(context, '백업 파일을 공유했어요. 선택한 앱에서 저장을 완료해 주세요.');
      }
      return;
    }

    final location = await getSaveLocation(
      suggestedName: name,
      acceptedTypeGroups: const [_backupType],
    );
    if (location == null) return;
    await file.saveTo(location.path);
    if (mounted) showMessage(context, '백업 파일을 저장했어요.');
  });

  Future<void> _importBackup() => _run(() async {
    final picked = await pickImportFile(
      type: _backupType,
      maxBytes: maxBackupBytes,
    );
    if (picked == null) return;
    try {
      final file = picked.file;
      if (await file.length() > maxBackupBytes) {
        if (mounted) showMessage(context, '50 MB 이하의 백업 파일을 선택해 주세요.');
        return;
      }
      final bytes = await file.readAsBytes();
      if (bytes.length > maxBackupBytes) {
        if (mounted) showMessage(context, '50 MB 이하의 백업 파일을 선택해 주세요.');
        return;
      }
      final contents = utf8.decode(bytes);
      if (!mounted) return;
      final approved = await confirm(
        context,
        title: '백업을 가져올까요?',
        message:
            '${picked.name}\n\n현재 보관함을 유지하면서 백업의 작품, 폴더, 작가를 추가합니다. '
            '이미 저장된 항목은 중복으로 추가하지 않습니다.\n\n'
            '이 앱의 JSON 백업과 기존 iOS 앱의 JSON 백업을 가져올 수 있어요.',
        action: '가져오기',
      );
      if (!mounted || !approved) return;
      final count = await widget.store.importBackup(contents);
      if (mounted) showMessage(context, '백업을 가져왔어요. 보관함에 $count개 항목을 추가했어요.');
    } finally {
      await picked.release();
    }
  });

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) {
      final preferences = widget.store.preferences;
      final colors = Theme.of(context).colorScheme;
      final columns = _pendingColumns ?? preferences.columns.clamp(2, 6);
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 48),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 4,
                  child: _busy ? const LinearProgressIndicator() : null,
                ),
                const SizedBox(height: 16),
                _SettingsSection(
                  title: '화면',
                  children: [
                    const ListTile(
                      leading: Icon(Icons.palette_outlined),
                      title: Text('테마'),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                      child: SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(
                            value: 'system',
                            icon: Icon(Icons.brightness_auto_outlined),
                            label: Text('시스템'),
                          ),
                          ButtonSegment(
                            value: 'light',
                            icon: Icon(Icons.light_mode_outlined),
                            label: Text('밝게'),
                          ),
                          ButtonSegment(
                            value: 'dark',
                            icon: Icon(Icons.dark_mode_outlined),
                            label: Text('어둡게'),
                          ),
                        ],
                        showSelectedIcon: false,
                        selected: {preferences.theme},
                        onSelectionChanged: _busy
                            ? null
                            : (selection) => _setPreferences(
                                preferences.copyWith(theme: selection.first),
                              ),
                      ),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.grid_view_rounded),
                      title: const Text('그리드 크기'),
                      subtitle: const Text(
                        '넓은 화면의 열 수를 조절해요. 작은 화면에서는 자동으로 맞춥니다.',
                      ),
                      trailing: Text(
                        '$columns열',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                      child: Slider(
                        value: columns.toDouble(),
                        min: 2,
                        max: 6,
                        divisions: 4,
                        label: '$columns열',
                        semanticFormatterCallback: (value) =>
                            '${value.round()}열',
                        onChanged: _busy
                            ? null
                            : (value) => setState(
                                () => _pendingColumns = value.round(),
                              ),
                        onChangeEnd: _busy
                            ? null
                            : (value) async {
                                await _setPreferences(
                                  widget.store.preferences.copyWith(
                                    columns: value.round(),
                                  ),
                                );
                                if (mounted) {
                                  setState(() => _pendingColumns = null);
                                }
                              },
                      ),
                    ),
                  ],
                ),
                _SettingsSection(
                  title: '책 탐색',
                  children: [
                    _SettingTile(
                      icon: Icons.language_rounded,
                      title: 'Hitomi 사이트 주소',
                      subtitle: preferences.hitomiBaseUrl,
                      onTap: _busy ? null : _editHitomiAddress,
                    ),
                    const Divider(height: 1),
                    _SettingTile(
                      icon: Icons.tag_rounded,
                      title: '기본 검색 태그',
                      subtitle: preferences.defaultTags.isEmpty
                          ? '검색할 때 항상 포함할 태그'
                          : preferences.defaultTags.join(' '),
                      onTap: _busy ? null : () => _editTags(excluded: false),
                    ),
                    const Divider(height: 1),
                    _SettingTile(
                      icon: Icons.filter_alt_off_outlined,
                      title: '기본 제외 태그',
                      subtitle: preferences.excludedTags.isEmpty
                          ? '검색 결과에서 제외할 태그'
                          : preferences.excludedTags.join(' '),
                      onTap: _busy ? null : () => _editTags(excluded: true),
                    ),
                  ],
                ),
                _SettingsSection(
                  title: '뷰어',
                  children: [
                    SwitchListTile(
                      secondary: const Icon(Icons.view_day_outlined),
                      title: const Text('연속 스크롤'),
                      subtitle: const Text('책의 페이지를 위아래로 이어서 읽어요.'),
                      value: preferences.readerContinuous,
                      onChanged: _busy
                          ? null
                          : (value) => _setPreferences(
                              preferences.copyWith(readerContinuous: value),
                            ),
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      secondary: const Icon(Icons.swipe_left_outlined),
                      title: const Text('오른쪽에서 왼쪽으로'),
                      subtitle: const Text('페이지를 한 장씩 넘길 때 적용돼요.'),
                      value: preferences.readerRtl,
                      onChanged: _busy
                          ? null
                          : (value) => _setPreferences(
                              preferences.copyWith(readerRtl: value),
                            ),
                    ),
                  ],
                ),
                _SettingsSection(
                  title: '읽기 편의 기능',
                  children: [
                    SwitchListTile(
                      secondary: const Icon(Icons.fit_screen),
                      title: const Text('너비에 맞춰 보기'),
                      subtitle: const Text('긴 페이지를 화면 너비에 맞추고 위아래로 움직여 읽습니다.'),
                      value: preferences.readerFitWidth,
                      onChanged: _busy
                          ? null
                          : (value) => _setPreferences(
                              preferences.copyWith(readerFitWidth: value),
                            ),
                    ),
                    SwitchListTile(
                      secondary: const Icon(Icons.touch_app_outlined),
                      title: const Text('가장자리 탭으로 넘기기'),
                      value: preferences.readerTapNavigation,
                      onChanged: _busy
                          ? null
                          : (value) => _setPreferences(
                              preferences.copyWith(readerTapNavigation: value),
                            ),
                    ),
                    SwitchListTile(
                      secondary: const Icon(Icons.pin_outlined),
                      title: const Text('페이지 번호 표시'),
                      value: preferences.readerShowPageNumber,
                      onChanged: _busy
                          ? null
                          : (value) => _setPreferences(
                              preferences.copyWith(readerShowPageNumber: value),
                            ),
                    ),
                  ],
                ),
                _SettingsSection(
                  title: '이미지 서버',
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Text(
                        '사용할 서버를 켜 두면 이미지 탐색에서 함께 검색할 수 있어요.',
                        style: TextStyle(
                          color: colors.onSurfaceVariant,
                          height: 1.5,
                        ),
                      ),
                    ),
                    if (widget.store.servers.isEmpty)
                      const ListTile(
                        leading: Icon(Icons.dns_outlined),
                        title: Text('등록한 서버가 없어요'),
                        subtitle: Text('서버를 추가해 이미지 탐색을 시작하세요.'),
                      ),
                    for (final server in widget.store.servers) ...[
                      ListTile(
                        leading: Switch(
                          value: server.enabled,
                          onChanged: _busy
                              ? null
                              : (value) => _run(
                                  () => widget.store.upsertServer(
                                    server.copyWith(enabled: value),
                                  ),
                                ),
                        ),
                        title: Text(server.name),
                        subtitle: Text(
                          '${_engineLabel(server.engine)} · ${server.baseUrl}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: _busy ? null : () => _editServer(server),
                        trailing: PopupMenuButton<String>(
                          enabled: !_busy,
                          tooltip: '${server.name} 관리',
                          onSelected: (value) => value == 'edit'
                              ? _editServer(server)
                              : _deleteServer(server),
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'edit', child: Text('서버 수정')),
                            PopupMenuItem(
                              value: 'delete',
                              child: Text('서버 삭제'),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1, indent: 16, endIndent: 16),
                    ],
                    ListTile(
                      leading: Icon(
                        Icons.add_circle_outline_rounded,
                        color: colors.primary,
                      ),
                      title: Text(
                        '서버 추가',
                        style: TextStyle(color: colors.primary),
                      ),
                      onTap: _busy ? null : () => _editServer(),
                    ),
                  ],
                ),
                _SettingsSection(
                  title: '백업과 복원',
                  children: [
                    _SettingTile(
                      icon: Icons.file_upload_outlined,
                      title: 'JSON 백업 내보내기',
                      subtitle: '보관함을 파일로 보관하거나 다른 기기로 옮겨요.',
                      onTap: _busy ? null : _exportBackup,
                    ),
                    const Divider(height: 1),
                    _SettingTile(
                      icon: Icons.file_download_outlined,
                      title: 'JSON 백업 가져오기',
                      subtitle: '이 앱과 기존 iOS 앱의 백업을 가져와요. 최대 50 MB.',
                      onTap: _busy ? null : _importBackup,
                    ),
                    const Divider(height: 1),
                    _SettingTile(
                      icon: Icons.auto_stories_outlined,
                      title: 'Violet 백업 가져오기',
                      subtitle: 'user.db와 선택적으로 data.db에서 작품·폴더·작가를 가져와요.',
                      onTap: _busy
                          ? null
                          : () =>
                                _run(() => importViolet(context, widget.store)),
                    ),
                    const Divider(height: 1),
                    _SettingTile(
                      icon: Icons.photo_library_outlined,
                      title: 'Anime Boxes 백업 가져오기',
                      subtitle: '.abbj 파일의 이미지·서버·제외 태그를 가져와요.',
                      onTap: _busy
                          ? null
                          : () => _run(
                              () => importAnimeBoxes(context, widget.store),
                            ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                      child: Text(
                        '이미지 원본은 백업에 포함되지 않아요. iOS 앱의 JSON 백업에서는 책 보관함을 가져옵니다.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                          height: 1.6,
                        ),
                      ),
                    ),
                  ],
                ),
                _SettingsSection(
                  title: '검색 기록',
                  children: [
                    _SettingTile(
                      icon: Icons.history,
                      title: '검색 기록 지우기',
                      subtitle: '${widget.store.searchHistory.length}개의 검색 기록',
                      onTap: _busy || widget.store.searchHistory.isEmpty
                          ? null
                          : () async {
                              if (await confirm(
                                    context,
                                    title: '검색 기록을 지울까요?',
                                    message: '보관함과 메모에는 영향을 주지 않습니다.',
                                  ) &&
                                  mounted) {
                                await _run(
                                  widget.store.clearSearchHistory,
                                  success: '검색 기록을 지웠습니다.',
                                );
                              }
                            },
                    ),
                  ],
                ),
                _SettingsSection(
                  title: '앱 정보',
                  children: [
                    const ListTile(
                      leading: Icon(Icons.bookmarks_outlined),
                      title: Text('품번메모'),
                    ),
                    const Divider(height: 1),
                    _SettingTile(
                      icon: Icons.open_in_new_rounded,
                      title: '개발자 NextLine',
                      subtitle: 'nextline.work',
                      onTap: () =>
                          openWebsite(context, 'https://nextline.work'),
                    ),
                    const Divider(height: 1),
                    _SettingTile(
                      icon: Icons.chat_bubble_outline_rounded,
                      title: '문의 및 오류 제보',
                      subtitle: 'Discord 커뮤니티',
                      onTap: () =>
                          openWebsite(context, 'https://discord.gg/vUTGZNMaMB'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text('지원 범위', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                Text(
                  'Android와 PC의 탐색, 보관함, 뷰어를 중심으로 만들고 있어요. '
                  'iOS 앱의 텍스트 인식·번역, 내장 브라우저와 앱 내 동영상 재생은 아직 지원하지 않습니다.',
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: colors.onSurfaceVariant, height: 1.7),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 28),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 12),
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleSmall
                ?.copyWith(color: Theme.of(context).colorScheme.primary),
          ),
        ),
        Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          child: Column(children: children),
        ),
      ],
    ),
  );
}

class _SettingTile extends StatelessWidget {
  const _SettingTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon),
    title: Text(title),
    subtitle: Text(subtitle, maxLines: 3, overflow: TextOverflow.ellipsis),
    trailing: const Icon(Icons.chevron_right_rounded),
    enabled: onTap != null,
    onTap: onTap,
  );
}

class _TextSettingDialog extends StatefulWidget {
  const _TextSettingDialog({
    required this.title,
    required this.label,
    required this.initialValue,
    required this.helper,
    this.hint,
    this.multiline = false,
    this.keyboardType,
    this.validator,
  });

  final String title;
  final String label;
  final String initialValue;
  final String helper;
  final String? hint;
  final bool multiline;
  final TextInputType? keyboardType;
  final String? Function(String?)? validator;

  @override
  State<_TextSettingDialog> createState() => _TextSettingDialogState();
}

class _TextSettingDialogState extends State<_TextSettingDialog> {
  final _form = GlobalKey<FormState>();
  late final _controller = TextEditingController(text: widget.initialValue);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    if (_form.currentState!.validate()) {
      Navigator.pop(context, _controller.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    scrollable: true,
    content: SizedBox(
      width: 480,
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextFormField(
              controller: _controller,
              autofocus: true,
              minLines: widget.multiline ? 3 : 1,
              maxLines: widget.multiline ? 5 : 1,
              keyboardType:
                  widget.keyboardType ??
                  (widget.multiline
                      ? TextInputType.multiline
                      : TextInputType.text),
              textInputAction: widget.multiline
                  ? TextInputAction.newline
                  : TextInputAction.done,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: widget.label,
                hintText: widget.hint,
                border: const OutlineInputBorder(),
              ),
              validator: widget.validator,
              onFieldSubmitted: widget.multiline ? null : (_) => _save(),
            ),
            const SizedBox(height: 14),
            Text(
              widget.helper,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(height: 1.5),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('취소'),
      ),
      FilledButton(onPressed: _save, child: const Text('저장')),
    ],
  );
}

class _ServerDialog extends StatefulWidget {
  const _ServerDialog({this.server});

  final BooruServer? server;

  @override
  State<_ServerDialog> createState() => _ServerDialogState();
}

class _ServerDialogState extends State<_ServerDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.server?.name ?? '');
  late final _url = TextEditingController(
    text: widget.server?.baseUrl ?? 'https://',
  );
  late final _excluded = TextEditingController(
    text: widget.server?.excludedTags.join('\n') ?? '',
  );
  late BooruEngine _engine = widget.server?.engine ?? BooruEngine.gelbooru;
  late bool _enabled = widget.server?.enabled ?? true;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _excluded.dispose();
    super.dispose();
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    Navigator.pop(
      context,
      BooruServer(
        id:
            widget.server?.id ??
            'server:${DateTime.now().microsecondsSinceEpoch}',
        name: _name.text.trim(),
        baseUrl: _normalizeBaseUrl(_url.text),
        engine: _engine,
        enabled: _enabled,
        excludedTags: _excluded.text
            .split(RegExp(r'[\r\n]+'))
            .map((line) => line.trim())
            .where((line) => line.isNotEmpty)
            .toSet()
            .toList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.server == null ? '이미지 서버 추가' : '이미지 서버 수정'),
    scrollable: true,
    content: SizedBox(
      width: 480,
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _name,
              autofocus: true,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: '서버 이름',
                hintText: '예: Safebooru',
                border: OutlineInputBorder(),
              ),
              validator: (value) => value == null || value.trim().isEmpty
                  ? '서버 이름을 입력해 주세요.'
                  : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _url,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '사이트 주소',
                hintText: 'https://safebooru.org',
                border: OutlineInputBorder(),
              ),
              validator: _baseUrlError,
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<BooruEngine>(
              isExpanded: true,
              initialValue: _engine,
              decoration: const InputDecoration(
                labelText: '서버 종류',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final engine in BooruEngine.values)
                  DropdownMenuItem(
                    value: engine,
                    child: Text(_engineLabel(engine)),
                  ),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _engine = value);
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _excluded,
              minLines: 2,
              maxLines: 4,
              keyboardType: TextInputType.multiline,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '제외 규칙',
                hintText: 'cat\ndog -outdoors\nrating:explicit',
                helperText: '한 줄에 한 규칙 · 같은 줄의 태그는 모두 일치할 때 제외',
                helperMaxLines: 2,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('탐색에 사용'),
              value: _enabled,
              onChanged: (value) => setState(() => _enabled = value),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('취소'),
      ),
      FilledButton(onPressed: _save, child: const Text('저장')),
    ],
  );
}

String _engineLabel(BooruEngine engine) => switch (engine) {
  BooruEngine.danbooru => 'Danbooru',
  BooruEngine.gelbooru => 'Gelbooru / Safebooru',
  BooruEngine.moebooru => 'Moebooru',
};

String? _baseUrlError(String? value) {
  final uri = Uri.tryParse(value?.trim() ?? '');
  if (uri == null ||
      !const ['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return '검색어나 로그인 정보가 없는 http(s) 사이트 주소를 입력해 주세요.';
  }
  return null;
}

String _normalizeBaseUrl(String value) {
  final uri = Uri.parse(value.trim());
  return uri
      .replace(path: uri.path.replaceFirst(RegExp(r'/+$'), ''))
      .toString();
}

List<String> _splitTags(String value, {bool removeMinus = false}) => value
    .split(RegExp(r'\s+'))
    .map((tag) => removeMinus ? tag.replaceFirst(RegExp(r'^-+'), '') : tag)
    .where((tag) => tag.isNotEmpty)
    .toSet()
    .toList();
