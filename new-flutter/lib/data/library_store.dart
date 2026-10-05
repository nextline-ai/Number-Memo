import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'models.dart';

const _backupFormat = 'number-memo-flutter';
const _backupVersion = 1;

/// A single UTF-8 byte limit for persisted libraries and imported/exported JSON.
const maxBackupBytes = 50 * 1024 * 1024;
const _defaultServers = [
  BooruServer(
    id: 'safebooru',
    name: 'Safebooru',
    baseUrl: 'https://safebooru.org',
    engine: BooruEngine.gelbooru,
  ),
];

/// Owns local user data. Changes become visible only after their atomic write
/// succeeds, and concurrent callers are applied in invocation order.
class LibraryStore extends ChangeNotifier {
  LibraryStore._(this._state, this._file);

  factory LibraryStore.memory() => LibraryStore._(_LibraryState.empty(), null);

  static Future<LibraryStore> open({Directory? directory}) async {
    final support = directory ?? await getApplicationSupportDirectory();
    final storage = directory == null
        ? Directory('${support.path}${Platform.pathSeparator}number_memo')
        : support;
    await storage.create(recursive: true);
    final file = File('${storage.path}${Platform.pathSeparator}library.json');
    if (!await file.exists()) {
      return LibraryStore._(_LibraryState.empty(), file);
    }
    if (await file.length() > maxBackupBytes) {
      throw const FormatException('The library file is too large to load.');
    }
    final data = _decodeObject(await file.readAsString());
    final state = _LibraryState.fromJson(data);
    return LibraryStore._(state, file);
  }

  _LibraryState _state;
  final File? _file;
  Future<void> _writeQueue = Future<void>.value();
  bool _disposed = false;
  static int _idCounter = 0;

  List<SavedItem> get items => _state.items;
  List<MemoFolder> get folders => _state.folders;
  List<SavedArtist> get artists => _state.artists;
  List<BooruServer> get servers => _state.servers;
  AppPreferences get preferences => _state.preferences;
  List<String> get searchHistory => _state.searchHistory;

  SavedItem? find(String id) {
    for (final saved in _state.items) {
      if (saved.item.id == id) return saved;
    }
    return null;
  }

  Future<void> save(CatalogItem item, {String? note, List<String>? folderIds}) {
    // Snapshot caller-owned lists before this operation waits in the queue.
    final frozen = CatalogItem.fromJson(item.toJson());
    final selectedFolders = folderIds == null
        ? null
        : List<String>.unmodifiable(folderIds);
    return _change((state) {
      final previous = _findIn(state.items, frozen.id);
      if (previous != null && previous.item.mode != frozen.mode) {
        throw const FormatException('An item ID cannot belong to two modes.');
      }
      final saved = SavedItem(
        item: frozen,
        note: note ?? previous?.note ?? '',
        folderIds: selectedFolders ?? previous?.folderIds ?? const [],
        savedAt: previous?.savedAt ?? DateTime.now().toUtc(),
        readingPage: previous?.readingPage ?? 0,
        lastOpenedAt: previous?.lastOpenedAt,
      );
      return state.copyWith(
        items: [
          if (previous == null) saved,
          for (final existing in state.items)
            if (existing.item.id == frozen.id) saved else existing,
        ],
      );
    });
  }

  Future<void> removeMany(Iterable<String> ids) {
    final selected = ids.toSet();
    return _change(
      (state) => state.copyWith(
        items: state.items
            .where((entry) => !selected.contains(entry.item.id))
            .toList(),
      ),
    );
  }

  /// Applies folder changes in one disk transaction. Validation rejects mixed
  /// modes or missing folders before any item is modified.
  Future<void> assignFolders(
    Iterable<String> ids,
    List<String> folderIds, {
    bool replace = false,
  }) {
    final selected = ids.toSet();
    final folders = folderIds.toSet();
    return _change((state) {
      final targets = state.items.where(
        (entry) => selected.contains(entry.item.id),
      );
      for (final entry in targets) {
        for (final id in folders) {
          if (!state.folders.any(
            (folder) => folder.id == id && folder.mode == entry.item.mode,
          )) {
            throw const FormatException('선택한 항목에 사용할 수 없는 폴더입니다.');
          }
        }
      }
      return state.copyWith(
        items: [
          for (final entry in state.items)
            if (selected.contains(entry.item.id))
              entry.copyWith(
                folderIds:
                    (replace ? folders : {...entry.folderIds, ...folders})
                        .toList(),
              )
            else
              entry,
        ],
      );
    });
  }

  Future<void> restoreItems(Iterable<SavedItem> entries) {
    final snapshots = entries
        .map((entry) => SavedItem.fromJson(entry.toJson()))
        .toList();
    return _change((state) {
      final existing = state.items.map((entry) => entry.item.id).toSet();
      return state.copyWith(
        items: [
          ...state.items,
          for (final entry in snapshots)
            if (existing.add(entry.item.id))
              entry.copyWith(
                folderIds: entry.folderIds
                    .where(
                      (id) => state.folders.any(
                        (folder) =>
                            folder.id == id && folder.mode == entry.item.mode,
                      ),
                    )
                    .toList(),
              ),
        ],
      );
    });
  }

  Future<void> recordReadingProgress(
    String id,
    int page, {
    DateTime? openedAt,
  }) => _change((state) {
    if (page < 0) throw const FormatException('페이지 번호가 올바르지 않습니다.');
    return state.copyWith(
      items: [
        for (final entry in state.items)
          if (entry.item.id == id)
            entry.copyWith(
              readingPage: page,
              lastOpenedAt: (openedAt ?? DateTime.now()).toUtc(),
            )
          else
            entry,
      ],
    );
  });

  /// Refreshes server metadata without changing a title the user chose.
  Future<void> refreshMetadata(CatalogItem item) {
    final frozen = CatalogItem.fromJson(item.toJson());
    return _change(
      (state) => state.copyWith(
        items: [
          for (final entry in state.items)
            if (entry.item.id == frozen.id)
              entry.copyWith(
                item: frozen.copyWith(
                  title:
                      entry.item.title == '작품 #${entry.item.remoteId}' ||
                          entry.item.title.trim().isEmpty
                      ? frozen.title
                      : entry.item.title,
                ),
              )
            else
              entry,
        ],
      ),
    );
  }

  Future<void> clearSearchHistory() =>
      _change((state) => state.copyWith(searchHistory: []));

  Future<void> remove(String id) => _change(
    (state) => state.copyWith(
      items: state.items.where((saved) => saved.item.id != id).toList(),
    ),
  );

  Future<void> updateSaved(SavedItem item) {
    final frozen = SavedItem.fromJson(item.toJson());
    return _change((state) {
      final previous = _findIn(state.items, frozen.item.id);
      if (previous == null) throw StateError('This item is no longer saved.');
      if (previous.item.mode != frozen.item.mode) {
        throw const FormatException('The mode of a saved item cannot change.');
      }
      return state.copyWith(
        items: [
          for (final existing in state.items)
            if (existing.item.id == frozen.item.id) frozen else existing,
        ],
      );
    });
  }

  Future<void> addFolder(
    String name,
    LibraryMode mode, {
    int color = 0xff2563eb,
  }) => _change((state) {
    final trimmed = _requireName(name);
    if (state.folders.any(
      (folder) => folder.mode == mode && _sameName(folder.name, trimmed),
    )) {
      throw const FormatException('A folder with this name already exists.');
    }
    final folder = MemoFolder.fromJson(
      MemoFolder(
        id: _newId('folder'),
        name: trimmed,
        mode: mode,
        color: color,
      ).toJson(),
    );
    return state.copyWith(folders: [...state.folders, folder]);
  });

  Future<void> updateFolder(MemoFolder folder) {
    final frozen = MemoFolder.fromJson(
      folder.copyWith(name: _requireName(folder.name)).toJson(),
    );
    return _change((state) {
      final previous = state.folders.where((entry) => entry.id == frozen.id);
      if (previous.isEmpty) throw StateError('This folder no longer exists.');
      if (previous.first.mode != frozen.mode) {
        throw const FormatException('The mode of a folder cannot change.');
      }
      if (state.folders.any(
        (entry) =>
            entry.id != frozen.id &&
            entry.mode == frozen.mode &&
            _sameName(entry.name, frozen.name),
      )) {
        throw const FormatException('A folder with this name already exists.');
      }
      return state.copyWith(
        folders: [
          for (final existing in state.folders)
            if (existing.id == frozen.id) frozen else existing,
        ],
      );
    });
  }

  Future<void> deleteFolder(String id) => _change(
    (state) => state.copyWith(
      folders: state.folders.where((folder) => folder.id != id).toList(),
      items: [
        for (final saved in state.items)
          if (saved.folderIds.contains(id))
            saved.copyWith(
              folderIds: List.unmodifiable(
                saved.folderIds.where((folderId) => folderId != id),
              ),
            )
          else
            saved,
      ],
    ),
  );

  Future<void> addArtist(String name, LibraryMode mode) => _change((state) {
    final trimmed = _requireName(name);
    if (state.artists.any(
      (artist) => artist.mode == mode && _sameName(artist.name, trimmed),
    )) {
      return state;
    }
    return state.copyWith(
      artists: [
        ...state.artists,
        SavedArtist(id: _newId('artist'), name: trimmed, mode: mode),
      ],
    );
  });

  Future<void> removeArtist(String id) => _change(
    (state) => state.copyWith(
      artists: state.artists.where((artist) => artist.id != id).toList(),
    ),
  );

  Future<void> upsertServer(BooruServer server) {
    final frozen = BooruServer.fromJson(server.toJson());
    return _change((state) {
      final exists = state.servers.any((entry) => entry.id == frozen.id);
      return state.copyWith(
        servers: [
          for (final existing in state.servers)
            if (existing.id == frozen.id) frozen else existing,
          if (!exists) frozen,
        ],
      );
    });
  }

  /// Removing a server never deletes favorites obtained from that server.
  Future<void> removeServer(String id) => _change(
    (state) => state.copyWith(
      servers: state.servers.where((server) => server.id != id).toList(),
    ),
  );

  Future<void> setPreferences(AppPreferences preferences) {
    final frozen = AppPreferences.fromJson(preferences.toJson());
    return _change((state) => state.copyWith(preferences: frozen));
  }

  Future<void> recordSearch(String query) => _change((state) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return state;
    return state.copyWith(
      searchHistory: [
        trimmed,
        ...state.searchHistory.where((entry) => entry != trimmed),
      ].take(30).toList(),
    );
  });

  // Export exactly the persisted representation. Pretty printing or extra
  // metadata could make an otherwise valid near-limit library unrestorable.
  String exportBackup() => _encodeState(_state);

  /// Accepts Flutter v1 and native iOS v2 JSON. The complete input is validated
  /// before writing. Existing records, notes, and reading progress are retained;
  /// default settings are restored only into an otherwise untouched library.
  /// Returns the number of newly added favorites.
  Future<int> importBackup(String source) {
    final json = _decodeObject(source);
    final incoming = json['format'] == _backupFormat
        ? _LibraryState.fromJson(json)
        : _nativeBackup(json);
    return _enqueue(() async {
      final merged = _merge(_state, incoming);
      final added = merged.items.length - _state.items.length;
      await _commit(merged);
      return added;
    });
  }

  Future<void> _change(_LibraryState Function(_LibraryState state) apply) =>
      _enqueue(() async {
        final next = apply(_state);
        if (!identical(next, _state)) await _commit(next);
      });

  Future<T> _enqueue<T>(Future<T> Function() action) {
    if (_disposed) return Future<T>.error(StateError('The library is closed.'));
    final operation = _writeQueue.then((_) => action());
    // A failed write must not poison later saves.
    _writeQueue = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> _commit(_LibraryState next) async {
    next.validate();
    final source = _encodeState(next);
    final file = _file;
    if (file != null) {
      final temporary = File('${file.path}.${_newId('write')}.tmp');
      try {
        await temporary.writeAsString(source, flush: true);
        // Rename in the same directory atomically replaces the old file.
        await temporary.rename(file.path);
      } finally {
        if (await temporary.exists()) {
          try {
            await temporary.delete();
          } on FileSystemException {
            // Preserve the original write failure if cleanup also fails.
          }
        }
      }
    }
    _state = next;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class _LibraryState {
  _LibraryState({
    required List<SavedItem> items,
    required List<MemoFolder> folders,
    required List<SavedArtist> artists,
    required List<BooruServer> servers,
    required this.preferences,
    required List<String> searchHistory,
  }) : items = List.unmodifiable(items),
       folders = List.unmodifiable(folders),
       artists = List.unmodifiable(artists),
       servers = List.unmodifiable(servers),
       searchHistory = List.unmodifiable(searchHistory);

  factory _LibraryState.empty() => _LibraryState(
    items: [],
    folders: [],
    artists: [],
    servers: _defaultServers,
    preferences: const AppPreferences(),
    searchHistory: [],
  );

  final List<SavedItem> items;
  final List<MemoFolder> folders;
  final List<SavedArtist> artists;
  final List<BooruServer> servers;
  final AppPreferences preferences;
  final List<String> searchHistory;

  _LibraryState copyWith({
    List<SavedItem>? items,
    List<MemoFolder>? folders,
    List<SavedArtist>? artists,
    List<BooruServer>? servers,
    AppPreferences? preferences,
    List<String>? searchHistory,
  }) => _LibraryState(
    items: items ?? this.items,
    folders: folders ?? this.folders,
    artists: artists ?? this.artists,
    servers: servers ?? this.servers,
    preferences: preferences ?? this.preferences,
    searchHistory: searchHistory ?? this.searchHistory,
  );

  Map<String, dynamic> toJson() => {
    'format': _backupFormat,
    'version': _backupVersion,
    'items': items.map((saved) => saved.toJson()).toList(),
    'folders': folders.map((folder) => folder.toJson()).toList(),
    'artists': artists.map((artist) => artist.toJson()).toList(),
    'servers': servers.map((server) => server.toJson()).toList(),
    'preferences': preferences.toJson(),
    'searchHistory': searchHistory,
  };

  factory _LibraryState.fromJson(Map<String, dynamic> json) {
    if (json['format'] != _backupFormat || json['version'] != _backupVersion) {
      throw const FormatException('Unsupported library format or version.');
    }
    final state = _LibraryState(
      items: _jsonObjects(json, 'items').map(SavedItem.fromJson).toList(),
      folders: _jsonObjects(json, 'folders').map(MemoFolder.fromJson).toList(),
      artists: _jsonObjects(json, 'artists').map(SavedArtist.fromJson).toList(),
      servers: _jsonObjects(json, 'servers').map(BooruServer.fromJson).toList(),
      preferences: AppPreferences.fromJson(
        jsonObject(json['preferences'], 'preferences'),
      ),
      searchHistory: jsonStrings(json, 'searchHistory'),
    );
    state.validate();
    return state;
  }

  void validate() {
    if ([
      items.length,
      folders.length,
      artists.length,
      servers.length,
    ].any((count) => count > 100000)) {
      throw const FormatException(
        'A library collection may contain at most 100,000 entries.',
      );
    }
    _uniqueIds(items.map((entry) => entry.item.id), 'item');
    _uniqueIds(folders.map((entry) => entry.id), 'folder');
    _uniqueIds(artists.map((entry) => entry.id), 'artist');
    _uniqueIds(servers.map((entry) => entry.id), 'server');
    final folderById = {for (final folder in folders) folder.id: folder};
    for (final saved in items) {
      _uniqueIds(saved.folderIds, 'folder reference');
      for (final id in saved.folderIds) {
        final folder = folderById[id];
        if (folder == null || folder.mode != saved.item.mode) {
          throw const FormatException(
            'An item refers to a missing or incompatible folder.',
          );
        }
      }
    }
    if (searchHistory.length > 30) {
      throw const FormatException(
        'Search history may contain at most 30 entries.',
      );
    }
  }
}

_LibraryState _merge(_LibraryState current, _LibraryState incoming) {
  final restorePreferences =
      jsonEncode(current.toJson()) ==
      jsonEncode(_LibraryState.empty().toJson());
  final folders = [...current.folders];
  final folderIds = <String, String>{};
  for (final imported in incoming.folders) {
    final matchingName = folders.where(
      (folder) =>
          folder.mode == imported.mode && _sameName(folder.name, imported.name),
    );
    if (matchingName.isNotEmpty) {
      folderIds[imported.id] = matchingName.first.id;
      continue;
    }
    final idCollision = folders.any((folder) => folder.id == imported.id);
    final folder = idCollision
        ? imported.copyWith(id: _newId('folder'))
        : imported;
    folders.add(folder);
    folderIds[imported.id] = folder.id;
  }

  String serverAddress(String value) {
    final uri = Uri.parse(value);
    return uri
        .replace(
          host: uri.host.toLowerCase(),
          path: uri.path.replaceFirst(RegExp(r'/+$'), ''),
          fragment: '',
        )
        .toString();
  }

  final servers = [...current.servers];
  final serverIds = <String, String>{};
  for (final imported in incoming.servers) {
    final byAddress = servers
        .where(
          (entry) =>
              serverAddress(entry.baseUrl) == serverAddress(imported.baseUrl),
        )
        .firstOrNull;
    if (byAddress != null) {
      serverIds[imported.id] = byAddress.id;
      final index = servers.indexOf(byAddress);
      servers[index] = byAddress.copyWith(
        excludedTags: {
          ...byAddress.excludedTags,
          ...imported.excludedTags,
        }.toList(),
      );
      continue;
    }
    final id = servers.any((entry) => entry.id == imported.id)
        ? _newId('server')
        : imported.id;
    servers.add(imported.copyWith(id: id));
    serverIds[imported.id] = id;
  }
  final items = {for (final item in current.items) item.item.id: item};
  for (final incomingItem in incoming.items) {
    final mappedServer = serverIds[incomingItem.item.serverId];
    final imported =
        mappedServer != null && mappedServer != incomingItem.item.serverId
        ? incomingItem.copyWith(
            item: incomingItem.item.copyWith(
              serverId: mappedServer,
              id: incomingItem.item.remoteId != null
                  ? '$mappedServer:${incomingItem.item.remoteId}'
                  : '$mappedServer:${incomingItem.item.id}',
            ),
          )
        : incomingItem;
    final previous = items[imported.item.id];
    final importedFolders = imported.folderIds.map((id) => folderIds[id]!);
    if (previous == null) {
      items[imported.item.id] = imported.copyWith(
        folderIds: List.unmodifiable(importedFolders.toSet()),
      );
      continue;
    }
    if (previous.item.mode != imported.item.mode) {
      throw const FormatException(
        'An imported item ID conflicts with another mode.',
      );
    }
    // Keep both independently written notes without multiplying them on reimport.
    final previousNote = previous.note.trim();
    final importedNote = imported.note.trim();
    final note = previousNote.isEmpty
        ? imported.note
        : importedNote.isEmpty || previous.note.contains(importedNote)
        ? previous.note
        : '${previous.note}\n\n${imported.note}';
    items[imported.item.id] = previous.copyWith(
      note: note,
      folderIds: List.unmodifiable({...previous.folderIds, ...importedFolders}),
      readingPage:
          previous.lastOpenedAt != null && imported.lastOpenedAt != null
          ? imported.lastOpenedAt!.isAfter(previous.lastOpenedAt!)
                ? imported.readingPage
                : previous.readingPage
          : max(previous.readingPage, imported.readingPage),
      lastOpenedAt: previous.lastOpenedAt == null
          ? imported.lastOpenedAt
          : imported.lastOpenedAt == null
          ? previous.lastOpenedAt
          : previous.lastOpenedAt!.isAfter(imported.lastOpenedAt!)
          ? previous.lastOpenedAt
          : imported.lastOpenedAt,
      savedAt: previous.savedAt.isBefore(imported.savedAt)
          ? previous.savedAt
          : imported.savedAt,
    );
  }

  final artists = [...current.artists];
  for (final imported in incoming.artists) {
    if (artists.any(
      (artist) =>
          artist.mode == imported.mode && _sameName(artist.name, imported.name),
    )) {
      continue;
    }
    artists.add(
      artists.any((artist) => artist.id == imported.id)
          ? imported.copyWith(id: _newId('artist'))
          : imported,
    );
  }
  return current.copyWith(
    items: items.values.toList(),
    folders: folders,
    artists: artists,
    servers: servers,
    preferences: restorePreferences
        ? incoming.preferences
        : current.preferences,
    searchHistory: {
      ...current.searchHistory,
      ...incoming.searchHistory,
    }.take(30).toList(),
  );
}

_LibraryState _nativeBackup(Map<String, dynamic> json) {
  if (json.containsKey('format') || json['version'] != 2) {
    throw const FormatException(
      'Choose a Flutter backup or a native iOS version 2 backup.',
    );
  }
  jsonDate(json, 'exported_at');
  final folders = <MemoFolder>[];
  final nativeFolderIds = <int>{};
  for (final entry in _jsonObjects(json, 'folders')) {
    if (entry['id'] is! int) {
      throw const FormatException('Native folder ID must be an integer.');
    }
    final nativeId = jsonInt(entry, 'id');
    if (!nativeFolderIds.add(nativeId)) {
      throw const FormatException('Duplicate native folder ID.');
    }
    final name = jsonString(entry, 'name', required: true, nonEmpty: true);
    final color = jsonInt(
      entry,
      'color',
      fallback: 0xff7986cb,
      minimum: 0,
      maximum: 0xffffffff,
    );
    if (folders.any((folder) => _sameName(folder.name, name))) continue;
    folders.add(
      MemoFolder(
        id: 'native-folder:$nativeId',
        name: name,
        mode: LibraryMode.books,
        color: color,
      ),
    );
  }

  final items = <SavedItem>[];
  for (final entry in _jsonObjects(json, 'works')) {
    if (entry['gallery_id'] is! int) {
      throw const FormatException('Native gallery ID must be an integer.');
    }
    final remoteId = jsonInt(entry, 'gallery_id', minimum: 1);
    final names = jsonStrings(entry, 'folders');
    final folderIds = <String>[];
    for (final name in names) {
      _requireName(name);
      final matches = folders.where((folder) => _sameName(folder.name, name));
      final MemoFolder folder;
      if (matches.isNotEmpty) {
        folder = matches.first;
      } else {
        folder = MemoFolder(
          id: _newId('folder'),
          name: name.trim(),
          mode: LibraryMode.books,
        );
        folders.add(folder);
      }
      folderIds.add(folder.id);
    }
    final artistNames = jsonString(entry, 'artists');
    final tags = _nativeTags(entry['tags']);
    final language = jsonNullableString(entry, 'language') ?? '';
    final description = jsonNullableString(entry, 'type') ?? '';
    items.add(
      SavedItem(
        item: CatalogItem(
          id: 'hitomi:$remoteId',
          mode: LibraryMode.books,
          title: jsonString(entry, 'title', required: true),
          sourceUrl: 'https://hitomi.la/reader/$remoteId.html',
          remoteId: remoteId,
          artists: List.unmodifiable(
            artistNames
                .split(',')
                .map((name) => name.trim())
                .where((name) => name.isNotEmpty),
          ),
          tags: tags,
          language: language,
          description: description,
        ),
        note: jsonString(entry, 'note'),
        folderIds: List.unmodifiable(folderIds.toSet()),
        savedAt: jsonDate(entry, 'bookmarked_at'),
      ),
    );
  }

  final artists = <SavedArtist>[];
  for (final entry in _jsonObjects(json, 'artists')) {
    final name = jsonString(entry, 'name', required: true, nonEmpty: true);
    final kind = jsonInt(entry, 'kind', minimum: 0, maximum: 1);
    final savedName = kind == 1 ? 'group:$name' : name;
    if (artists.any((artist) => _sameName(artist.name, savedName))) continue;
    artists.add(
      SavedArtist(
        id: _newId('artist'),
        name: savedName,
        mode: LibraryMode.books,
      ),
    );
  }
  final state = _LibraryState(
    items: items,
    folders: folders,
    artists: artists,
    servers: [],
    preferences: const AppPreferences(),
    searchHistory: [],
  );
  state.validate();
  return state;
}

List<String> _nativeTags(Object? value) {
  if (value == null) return const [];
  if (value is String) {
    return List.unmodifiable(
      value.split(',').map((tag) => tag.trim()).where((tag) => tag.isNotEmpty),
    );
  }
  if (value is List && value.every((tag) => tag is String)) {
    return List<String>.unmodifiable(value.cast<String>());
  }
  throw const FormatException(
    'Native tags must be a string or an array of strings.',
  );
}

Map<String, dynamic> _decodeObject(String source) {
  _validateJsonSize(source);
  return jsonObject(jsonDecode(source), 'backup');
}

String _encodeState(_LibraryState state) {
  final source = jsonEncode(state.toJson());
  _validateJsonSize(source);
  return source;
}

void _validateJsonSize(String source) {
  if (source.length > maxBackupBytes ||
      utf8.encode(source).length > maxBackupBytes) {
    throw const FormatException('Backup files may not exceed 50 MB.');
  }
}

List<Map<String, dynamic>> _jsonObjects(
  Map<String, dynamic> json,
  String field,
) {
  final value = json[field];
  if (value is! List || value.length > 100000) {
    throw FormatException(
      '$field must be an array with at most 100,000 entries.',
    );
  }
  return value.map((entry) => jsonObject(entry, field)).toList();
}

void _uniqueIds(Iterable<String> ids, String kind) {
  final seen = <String>{};
  for (final id in ids) {
    if (!seen.add(id)) throw FormatException('Duplicate $kind ID: $id.');
  }
}

SavedItem? _findIn(List<SavedItem> items, String id) {
  for (final saved in items) {
    if (saved.item.id == id) return saved;
  }
  return null;
}

String _newId(String prefix) =>
    '$prefix-${DateTime.now().microsecondsSinceEpoch}-${LibraryStore._idCounter++}';

String _requireName(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) throw const FormatException('Please enter a name.');
  return trimmed;
}

bool _sameName(String a, String b) =>
    a.trim().toLowerCase() == b.trim().toLowerCase();
