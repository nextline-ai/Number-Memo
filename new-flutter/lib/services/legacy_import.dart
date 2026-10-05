import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:html/parser.dart' as html;
import 'package:sqlite3/sqlite3.dart';

import '../data/library_store.dart';
import '../data/models.dart';

/// Converts other apps' backups without touching the current library. The
/// caller commits the returned, validated backup with LibraryStore.importBackup.
/// Parsing and SQLite reads run away from the UI isolate.
class LegacyImportService {
  static const maxAnimeBoxesBytes = 64 * 1024 * 1024;
  static const maxVioletUserBytes = 256 * 1024 * 1024;
  static const maxVioletMetadataBytes = 4 * 1024 * 1024 * 1024;

  static Future<String> animeBoxes(Uint8List bytes) {
    if (bytes.length > maxAnimeBoxesBytes) {
      return Future.error(
        const FormatException('Anime Boxes 백업은 64 MB 이하여야 합니다.'),
      );
    }
    return Isolate.run(() => _animeBoxes(bytes));
  }

  static Future<String> violet({
    required String userDatabasePath,
    String? metadataDatabasePath,
  }) => Isolate.run(() => _violet(userDatabasePath, metadataDatabasePath));
}

const _maxEntries = 100000;
final _epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

Future<String> _animeBoxes(Uint8List bytes) async {
  final Map<String, dynamic> root;
  try {
    root = jsonObject(jsonDecode(utf8.decode(bytes)), 'backup');
  } on FormatException {
    throw const FormatException('Anime Boxes의 올바른 .abbj 백업 파일을 선택해 주세요.');
  }
  if (root['backupVersion'] != '1.0') {
    throw const FormatException('Anime Boxes 1.0 형식의 .abbj 백업만 지원합니다.');
  }
  final rawServers = _objects(root, 'servers');
  final rawFavorites = _objects(root, 'favorites');
  final rules = _rules(root['bannedTags']);
  final serversByUrl = <String, BooruServer>{};
  for (final row in rawServers) {
    final base = _baseUrl(row['url']);
    if (base == null) continue;
    final engine = switch (_integer(row['type'])) {
      1 || 4 => BooruEngine.gelbooru,
      3 => BooruEngine.danbooru,
      _
          when const [
            'yande.re',
            'konachan.com',
            'konachan.net',
          ].contains(base.host) =>
        BooruEngine.moebooru,
      _ => null,
    };
    if (engine == null) continue;
    final url = base.toString();
    final existing = serversByUrl[url];
    if (existing != null) {
      if (row['isSelected'] == true) {
        serversByUrl[url] = existing.copyWith(enabled: true);
      }
      continue;
    }
    serversByUrl[url] = BooruServer(
      id: 'anime-boxes:${sha256.convert(utf8.encode(url))}',
      name: _string(row['serverName']).trim().isEmpty
          ? base.host
          : _string(row['serverName']).trim(),
      baseUrl: url,
      engine: engine,
      enabled: row['isSelected'] == true,
      excludedTags: rules,
    );
  }
  if (serversByUrl.isEmpty) {
    throw const FormatException('백업에 지원하는 Booru 서버가 없습니다.');
  }
  var servers = serversByUrl.values.toList();
  // An old backup may omit selection; keep its servers usable in that case.
  if (!servers.any((server) => server.enabled)) {
    servers = servers.map((server) => server.copyWith(enabled: true)).toList();
  }
  final orderedServers = [...servers]
    ..sort((a, b) => b.baseUrl.length.compareTo(a.baseUrl.length));
  final items = <String, SavedItem>{};
  for (final row in rawFavorites) {
    final id = _integer(row['ppostId']);
    final page = _httpUrl(row['ppostUrl']);
    if (id == null || id <= 0 || page == null) continue;
    BooruServer? server;
    for (final candidate in orderedServers) {
      final base = Uri.parse(candidate.baseUrl);
      if (page.host == base.host &&
          page.port == base.port &&
          (page.path == base.path || page.path.startsWith('${base.path}/'))) {
        server = candidate;
        break;
      }
    }
    if (server == null) continue;
    final base = Uri.parse('${server.baseUrl}/');
    final file = _media(row['file'], base);
    final sample = _media(row['sample'], base) ?? _media(row['jpeg'], base);
    final preview = _media(row['preview'], base);
    final media = file ?? sample;
    final item = CatalogItem(
      id: '${server.id}:$id',
      mode: LibraryMode.images,
      title: '${server.name} #$id',
      sourceUrl: page.toString(),
      thumbnailUrl: (preview ?? sample ?? file)?.toString() ?? '',
      mediaUrls: media == null ? [] : [media.toString()],
      tags: _tokens(row['tags']),
      artists: _tokens(row['tag_artist']),
      rating: _rating(row['rating'], server),
      score: _integer(row['score']) ?? 0,
      pageCount: 1,
      serverId: server.id,
      remoteId: id,
    );
    items.putIfAbsent(
      item.id,
      () => SavedItem(
        item: item,
        savedAt: _date(row['dateAdded']),
        folderIds: const ['anime-boxes'],
      ),
    );
  }
  if (rawFavorites.isNotEmpty && items.isEmpty) {
    throw const FormatException('백업에서 가져올 수 있는 즐겨찾기를 찾지 못했습니다.');
  }
  final history = _objects(root, 'searchHistory', optional: true)
    ..sort((a, b) => _date(b['searchDate']).compareTo(_date(a['searchDate'])));
  final queries = <String>{
    for (final row in history)
      if (_string(row['searchText']).trim().isNotEmpty)
        _string(row['searchText']).trim(),
  };
  return _backup(
    items: items.values.toList(),
    folders: const [
      MemoFolder(
        id: 'anime-boxes',
        name: 'Anime Boxes',
        mode: LibraryMode.images,
        color: 0xff757575,
      ),
    ],
    servers: servers,
    history: queries.take(30).toList(),
  );
}

Future<String> _violet(String userPath, String? metadataPath) async {
  Database? user;
  Database? metadata;
  try {
    user = _openDatabase(userPath, LegacyImportService.maxVioletUserBytes);
    _requireTable(user, 'BookmarkArticle', 'Violet user.db');
    final folders = <MemoFolder>[];
    final groupMap = <int, String>{};
    if (_hasTable(user, 'BookmarkGroup')) {
      final groups = _rows(user, 'BookmarkGroup')
        ..sort((a, b) {
          final order = (_integer(a['gorder']) ?? 0).compareTo(
            _integer(b['gorder']) ?? 0,
          );
          return order != 0
              ? order
              : (_integer(a['id']) ?? 0).compareTo(_integer(b['id']) ?? 0);
        });
      for (final row in groups) {
        final id = _integer(row['id']);
        if (id == null) continue;
        final rawName = _string(row['name']).trim();
        final name = rawName == 'violet_default' || rawName.isEmpty
            ? '미분류'
            : rawName;
        final existing = folders.where(
          (folder) => folder.name.toLowerCase() == name.toLowerCase(),
        );
        if (existing.isNotEmpty) {
          groupMap[id] = existing.first.id;
          continue;
        }
        final folder = MemoFolder(
          id: 'violet-group:$id',
          name: name,
          mode: LibraryMode.books,
          color: 0xff757575,
        );
        folders.add(folder);
        groupMap[id] = folder.id;
      }
    }
    final defaultMatches = folders.where((folder) => folder.name == '미분류');
    final defaultFolder = defaultMatches.isNotEmpty
        ? defaultMatches.first
        : const MemoFolder(
            id: 'violet-default',
            name: '미분류',
            mode: LibraryMode.books,
            color: 0xff757575,
          );
    groupMap.putIfAbsent(0, () => defaultFolder.id);
    groupMap.putIfAbsent(1, () => defaultFolder.id);
    final articles = _rows(user, 'BookmarkArticle');
    final items = <int, SavedItem>{};
    for (final row in articles) {
      final id =
          _integer(row['article']) ??
          _integer(row['galleryid']) ??
          _integer(row['id']);
      if (id == null || id <= 0) continue;
      final groupId =
          _integer(row['groupid']) ??
          _integer(row['group_id']) ??
          _integer(row['group']);
      final folderId = groupMap[groupId] ?? defaultFolder.id;
      final previous = items[id];
      final date = _date(row['datetime']);
      items[id] = SavedItem(
        item: CatalogItem(
          id: 'hitomi:$id',
          mode: LibraryMode.books,
          title: '작품 #$id',
          sourceUrl: 'https://hitomi.la/reader/$id.html',
          remoteId: id,
        ),
        folderIds: {...?previous?.folderIds, folderId}.toList(),
        savedAt: previous != null && previous.savedAt.isBefore(date)
            ? previous.savedAt
            : date,
      );
    }
    for (final id in items.keys.toList()) {
      final item = items[id]!;
      if (item.folderIds.length > 1 &&
          item.folderIds.contains(defaultFolder.id)) {
        items[id] = item.copyWith(
          folderIds: item.folderIds
              .where((id) => id != defaultFolder.id)
              .toList(),
        );
      }
    }
    if (items.values.any((item) => item.folderIds.contains(defaultFolder.id)) &&
        !folders.any((folder) => folder.id == defaultFolder.id)) {
      folders.add(defaultFolder);
    }
    final artists = <String, SavedArtist>{};
    if (_hasTable(user, 'BookmarkArtist')) {
      for (final row in _rows(user, 'BookmarkArtist')) {
        final raw = _string(row['artist']).trim();
        if (raw.isEmpty) continue;
        final name = _integer(row['isgroup']) == 1 ? 'group:$raw' : raw;
        artists.putIfAbsent(
          name.toLowerCase(),
          () => SavedArtist(
            id: 'violet-artist:${sha256.convert(utf8.encode(name.toLowerCase()))}',
            name: name,
            mode: LibraryMode.books,
          ),
        );
      }
    }
    if (items.isEmpty && folders.isEmpty && artists.isEmpty) {
      throw const FormatException('Violet 백업에 가져올 작품, 폴더 또는 작가가 없습니다.');
    }
    if (metadataPath != null) {
      metadata = _openDatabase(
        metadataPath,
        LegacyImportService.maxVioletMetadataBytes,
      );
      _requireTable(metadata, 'HitomiColumnModel', 'Violet data.db');
      final columns = metadata
          .select('SELECT name FROM pragma_table_info(?)', [
            'HitomiColumnModel',
          ])
          .map((row) => _string(row['name']).toLowerCase())
          .toSet();
      if (!columns.contains('id')) {
        throw const FormatException('Violet data.db에 작품 번호 열이 없습니다.');
      }
      // Read only supported scalar metadata, bounded per field. SELECT * could
      // accidentally materialize a huge thumbnail/blob from a different schema.
      const metadataFields = [
        'Title',
        'Type',
        'Artists',
        'Characters',
        'Groups',
        'Language',
        'Series',
        'Tags',
        'Published',
      ];
      const maxFieldCharacters = 32768;
      final projection = [
        'Id',
        for (final name in metadataFields)
          columns.contains(name.toLowerCase())
              ? 'substr(CAST("$name" AS TEXT), 1, ${maxFieldCharacters + 1}) AS "$name"'
              : 'NULL AS "$name"',
      ].join(', ');
      final ids = items.keys.toList();
      var metadataBytes = 0;
      for (var offset = 0; offset < ids.length; offset += 400) {
        final batch = ids.skip(offset).take(400).toList();
        final placeholders = List.filled(batch.length, '?').join(',');
        final rows = metadata.select(
          'SELECT $projection FROM HitomiColumnModel WHERE Id IN ($placeholders) LIMIT 401',
          batch,
        );
        if (rows.length > batch.length) {
          throw const FormatException('Violet data.db에 중복된 작품 번호가 있습니다.');
        }
        for (final raw in rows) {
          final row = _lowerKeys(raw);
          for (final value in row.values.whereType<String>()) {
            metadataBytes += utf8.encode(value).length;
            if (value.length > maxFieldCharacters ||
                metadataBytes > maxBackupBytes) {
              throw const FormatException('Violet 작품 정보가 가져오기 용량 제한을 초과합니다.');
            }
          }
          final id = _integer(row['id']);
          final existing = items[id];
          if (existing == null) continue;
          final title =
              html.parseFragment(_string(row['title'])).text?.trim() ?? '';
          final published = _published(row['published']);
          final description = [
            _string(row['type']).trim(),
            if (published.isNotEmpty) published,
          ].where((part) => part.isNotEmpty).join(' · ');
          items[id!] = existing.copyWith(
            item: existing.item.copyWith(
              title: title.isEmpty ? existing.item.title : title,
              artists: _piped(row['artists']),
              language: _string(row['language']),
              description: description,
              tags: {
                ..._piped(row['tags']),
                ..._piped(row['groups']).map((name) => 'group:$name'),
                ..._piped(row['series']).map((name) => 'series:$name'),
                ..._piped(row['characters']).map((name) => 'character:$name'),
              }.toList(),
            ),
          );
        }
      }
    }
    return await _backup(
      items: items.values.toList()
        ..sort((a, b) => b.savedAt.compareTo(a.savedAt)),
      folders: folders,
      artists: artists.values.toList(),
    );
  } on SqliteException {
    throw const FormatException(
      'Violet 데이터베이스를 읽을 수 없습니다. 손상되지 않은 user.db와 data.db를 선택해 주세요.',
    );
  } on FileSystemException {
    throw const FormatException('선택한 데이터베이스 파일에 접근할 수 없습니다. 파일을 다시 선택해 주세요.');
  } finally {
    metadata?.close();
    user?.close();
  }
}

Future<String> _backup({
  List<SavedItem> items = const [],
  List<MemoFolder> folders = const [],
  List<SavedArtist> artists = const [],
  List<BooruServer> servers = const [],
  List<String> history = const [],
}) async {
  final source = jsonEncode({
    'format': 'number-memo-flutter',
    'version': 1,
    'items': items.map((item) => item.toJson()).toList(),
    'folders': folders.map((folder) => folder.toJson()).toList(),
    'artists': artists.map((artist) => artist.toJson()).toList(),
    'servers': servers.map((server) => server.toJson()).toList(),
    'preferences': const AppPreferences().toJson(),
    'searchHistory': history,
  });
  if (source.length > maxBackupBytes ||
      utf8.encode(source).length > maxBackupBytes) {
    throw const FormatException('변환한 보관함이 50 MB를 초과합니다. 원본 앱에서 백업 크기를 줄여 주세요.');
  }
  // Reuse the actual import validator once, not once per item (large imports
  // otherwise repeatedly serialize and validate every preceding item).
  final validator = LibraryStore.memory();
  try {
    await validator.importBackup(source);
  } finally {
    validator.dispose();
  }
  return source;
}

Database _openDatabase(String path, int maxBytes) {
  final file = File(path);
  final size = file.lengthSync();
  if (size > maxBytes) {
    throw FormatException('데이터베이스가 ${maxBytes ~/ (1024 * 1024)} MB 제한을 초과합니다.');
  }
  final handle = file.openSync();
  try {
    if (size < 100 ||
        ascii.decode(handle.readSync(16), allowInvalid: true) !=
            'SQLite format 3\x00') {
      throw const FormatException('올바른 SQLite 데이터베이스 파일이 아닙니다.');
    }
  } finally {
    handle.closeSync();
  }
  // immutable=1 prevents SQLite from creating journal or shared-memory files
  // beside a selected backup. Reject live DBs instead of ignoring their WAL.
  for (final suffix in ['-wal', '-journal']) {
    final sidecar = File('$path$suffix');
    if (sidecar.existsSync() && sidecar.lengthSync() > 0) {
      throw const FormatException(
        '사용 중인 데이터베이스입니다. Violet을 종료하고 내보낸 백업 파일을 선택해 주세요.',
      );
    }
  }
  final uri = file.absolute.uri.replace(queryParameters: {'immutable': '1'});
  final database = sqlite3.open(
    uri.toString(),
    mode: OpenMode.readOnly,
    uri: true,
  );
  try {
    database.execute('PRAGMA trusted_schema = OFF');
    database.execute('PRAGMA query_only = ON');
    return database;
  } catch (_) {
    database.close();
    rethrow;
  }
}

bool _hasTable(Database database, String name) => database.select(
  "SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = ? COLLATE NOCASE LIMIT 1",
  [name],
).isNotEmpty;

void _requireTable(Database database, String name, String label) {
  if (!_hasTable(database, name)) {
    throw FormatException('$label 형식이 아닙니다. $name 테이블을 찾을 수 없습니다.');
  }
}

List<Map<String, Object?>> _rows(Database database, String table) {
  // Identifiers are from these hard-coded schema names, never from backup data.
  if (!const [
    'BookmarkGroup',
    'BookmarkArticle',
    'BookmarkArtist',
  ].contains(table)) {
    throw ArgumentError.value(table);
  }
  final result = database.select(
    'SELECT * FROM "$table" LIMIT ${_maxEntries + 1}',
  );
  if (result.length > _maxEntries) {
    throw const FormatException('각 가져오기 목록은 100,000개 이하여야 합니다.');
  }
  return result.map(_lowerKeys).toList();
}

Map<String, Object?> _lowerKeys(Map<String, Object?> row) => {
  for (final entry in row.entries) entry.key.toLowerCase(): entry.value,
};

List<Map<String, dynamic>> _objects(
  Map<String, dynamic> root,
  String key, {
  bool optional = false,
}) {
  final value = root[key];
  if (value == null && optional) return [];
  if (value is! List ||
      value.length > _maxEntries ||
      value.any((entry) => entry is! Map<String, dynamic>)) {
    throw FormatException('백업의 $key 목록이 올바르지 않습니다.');
  }
  return value.cast<Map<String, dynamic>>().toList();
}

String _string(Object? value) => switch (value) {
  String text => text,
  num number => number.toString(),
  _ => '',
};

int? _integer(Object? value) => switch (value) {
  int number => number,
  double number when number.isFinite && number == number.truncateToDouble() =>
    number.toInt(),
  String text => int.tryParse(text.trim()),
  _ => null,
};

List<String> _tokens(Object? value) => {
  if (value is String)
    ...value.split(RegExp(r'\s+')).where((tag) => tag.isNotEmpty),
  if (value is List)
    ...value
        .whereType<String>()
        .map((tag) => tag.trim())
        .where((tag) => tag.isNotEmpty),
}.toList();

List<String> _piped(Object? value) =>
    _string(value)
        .split('|')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty && part != 'N/A')
        .toSet()
        .toList();

List<String> _rules(Object? value) {
  if (value == null) return [];
  if (value is! List || value.length > _maxEntries) {
    throw const FormatException('백업의 제외 태그 목록이 올바르지 않습니다.');
  }
  return {
    for (final entry in value)
      if (entry is String && entry.trim().isNotEmpty)
        entry.trim()
      else if (entry is Map &&
          _string(entry['tag'] ?? entry['name']).trim().isNotEmpty)
        _string(entry['tag'] ?? entry['name']).trim(),
  }.toList();
}

Uri? _httpUrl(Object? value, [Uri? base]) {
  if (value is! String || value.trim().isEmpty) return null;
  try {
    final parsed = Uri.parse(value.trim());
    final uri = base == null ? parsed : base.resolveUri(parsed);
    if (!['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    return uri.replace(scheme: 'https');
  } on FormatException {
    return null;
  }
}

Uri? _baseUrl(Object? value) {
  final uri = _httpUrl(value);
  if (uri == null || uri.hasQuery || uri.hasFragment) return null;
  return uri.replace(path: uri.path.replaceFirst(RegExp(r'/+$'), ''));
}

Uri? _media(Object? value, Uri base) =>
    value is Map ? _httpUrl(value['url'], base) : null;

String _rating(Object? value, BooruServer server) {
  final modern =
      server.engine == BooruEngine.danbooru ||
      const [
        'gelbooru.com',
        'www.gelbooru.com',
      ].contains(Uri.parse(server.baseUrl).host);
  return switch (_string(value).toLowerCase()) {
    'g' || 'general' || 'safe' => 'general',
    's' => modern ? 'sensitive' : 'general',
    'sensitive' => 'sensitive',
    'q' || 'questionable' => 'questionable',
    'e' || 'explicit' => 'explicit',
    _ => '',
  };
}

DateTime _date(Object? value) {
  final ticks = _integer(value);
  if (ticks != null &&
      ticks >= 621355968000000000 &&
      ticks <= 3155378975999999999) {
    return DateTime.fromMicrosecondsSinceEpoch(
      (ticks - 621355968000000000) ~/ 10,
      isUtc: true,
    );
  }
  return DateTime.tryParse(_string(value))?.toUtc() ?? _epoch;
}

String _published(Object? value) {
  final parsed = _date(value);
  return parsed != _epoch
      ? parsed.toIso8601String().split('T').first
      : _string(value);
}
