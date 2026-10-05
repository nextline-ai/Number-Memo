enum LibraryMode { books, images }

enum BooruEngine { danbooru, gelbooru, moebooru }

class CatalogItem {
  const CatalogItem({
    required this.id,
    required this.mode,
    required this.title,
    required this.sourceUrl,
    this.thumbnailUrl = '',
    this.mediaUrls = const [],
    this.tags = const [],
    this.artists = const [],
    this.description = '',
    this.language = '',
    this.rating = '',
    this.pageCount = 0,
    this.score = 0,
    this.serverId,
    this.remoteId,
  });

  final String id;
  final LibraryMode mode;
  final String title;
  final String sourceUrl;
  final String thumbnailUrl;
  final List<String> mediaUrls;
  final List<String> tags;
  final List<String> artists;
  final String description;
  final String language;
  final String rating;
  final int pageCount;
  final int score;
  final String? serverId;
  final int? remoteId;

  CatalogItem copyWith({
    String? id,
    LibraryMode? mode,
    String? title,
    String? sourceUrl,
    String? thumbnailUrl,
    List<String>? mediaUrls,
    List<String>? tags,
    List<String>? artists,
    String? description,
    String? language,
    String? rating,
    int? pageCount,
    int? score,
    String? serverId,
    int? remoteId,
  }) => CatalogItem(
    id: id ?? this.id,
    mode: mode ?? this.mode,
    title: title ?? this.title,
    sourceUrl: sourceUrl ?? this.sourceUrl,
    thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
    mediaUrls: mediaUrls ?? this.mediaUrls,
    tags: tags ?? this.tags,
    artists: artists ?? this.artists,
    description: description ?? this.description,
    language: language ?? this.language,
    rating: rating ?? this.rating,
    pageCount: pageCount ?? this.pageCount,
    score: score ?? this.score,
    serverId: serverId ?? this.serverId,
    remoteId: remoteId ?? this.remoteId,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'mode': mode.name,
    'title': title,
    'sourceUrl': sourceUrl,
    'thumbnailUrl': thumbnailUrl,
    'mediaUrls': mediaUrls,
    'tags': tags,
    'artists': artists,
    'description': description,
    'language': language,
    'rating': rating,
    'pageCount': pageCount,
    'score': score,
    'serverId': serverId,
    'remoteId': remoteId,
  };

  factory CatalogItem.fromJson(Map<String, dynamic> json) => CatalogItem(
    id: jsonString(json, 'id', required: true, nonEmpty: true),
    mode: jsonEnum(json, 'mode', LibraryMode.values),
    title: jsonString(json, 'title', required: true),
    sourceUrl: jsonString(json, 'sourceUrl', required: true),
    thumbnailUrl: jsonString(json, 'thumbnailUrl'),
    mediaUrls: jsonStrings(json, 'mediaUrls'),
    tags: jsonStrings(json, 'tags'),
    artists: jsonStrings(json, 'artists'),
    description: jsonString(json, 'description'),
    language: jsonString(json, 'language'),
    rating: jsonString(json, 'rating'),
    pageCount: jsonInt(json, 'pageCount', minimum: 0),
    score: jsonInt(json, 'score'),
    serverId: jsonNullableString(json, 'serverId'),
    remoteId: jsonNullableInt(json, 'remoteId', minimum: 1),
  );
}

class SavedItem {
  const SavedItem({
    required this.item,
    this.note = '',
    this.folderIds = const [],
    required this.savedAt,
    this.readingPage = 0,
    this.lastOpenedAt,
  });

  final CatalogItem item;
  final String note;
  final List<String> folderIds;
  final DateTime savedAt;
  final int readingPage;
  final DateTime? lastOpenedAt;

  SavedItem copyWith({
    CatalogItem? item,
    String? note,
    List<String>? folderIds,
    DateTime? savedAt,
    int? readingPage,
    DateTime? lastOpenedAt,
  }) => SavedItem(
    item: item ?? this.item,
    note: note ?? this.note,
    folderIds: folderIds ?? this.folderIds,
    savedAt: savedAt ?? this.savedAt,
    readingPage: readingPage ?? this.readingPage,
    lastOpenedAt: lastOpenedAt ?? this.lastOpenedAt,
  );

  Map<String, dynamic> toJson() => {
    'item': item.toJson(),
    'note': note,
    'folderIds': folderIds,
    'savedAt': savedAt.toUtc().toIso8601String(),
    'readingPage': readingPage,
    'lastOpenedAt': lastOpenedAt?.toUtc().toIso8601String(),
  };

  factory SavedItem.fromJson(Map<String, dynamic> json) => SavedItem(
    item: CatalogItem.fromJson(jsonObject(json['item'], 'item')),
    note: jsonString(json, 'note'),
    folderIds: jsonStrings(json, 'folderIds'),
    savedAt: jsonDate(json, 'savedAt'),
    readingPage: jsonInt(json, 'readingPage', minimum: 0),
    lastOpenedAt: json['lastOpenedAt'] == null
        ? null
        : jsonDate(json, 'lastOpenedAt'),
  );
}

class MemoFolder {
  const MemoFolder({
    required this.id,
    required this.name,
    required this.mode,
    this.color = 0xff2563eb,
  });

  final String id;
  final String name;
  final LibraryMode mode;
  final int color;

  MemoFolder copyWith({
    String? id,
    String? name,
    LibraryMode? mode,
    int? color,
  }) => MemoFolder(
    id: id ?? this.id,
    name: name ?? this.name,
    mode: mode ?? this.mode,
    color: color ?? this.color,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'mode': mode.name,
    'color': color,
  };

  factory MemoFolder.fromJson(Map<String, dynamic> json) => MemoFolder(
    id: jsonString(json, 'id', required: true, nonEmpty: true),
    name: jsonString(json, 'name', required: true, nonEmpty: true),
    mode: jsonEnum(json, 'mode', LibraryMode.values),
    color: jsonInt(
      json,
      'color',
      fallback: 0xff2563eb,
      minimum: 0,
      maximum: 0xffffffff,
    ),
  );
}

class SavedArtist {
  const SavedArtist({required this.id, required this.name, required this.mode});

  final String id;
  final String name;
  final LibraryMode mode;

  SavedArtist copyWith({String? id, String? name, LibraryMode? mode}) =>
      SavedArtist(
        id: id ?? this.id,
        name: name ?? this.name,
        mode: mode ?? this.mode,
      );

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'mode': mode.name};

  factory SavedArtist.fromJson(Map<String, dynamic> json) => SavedArtist(
    id: jsonString(json, 'id', required: true, nonEmpty: true),
    name: jsonString(json, 'name', required: true, nonEmpty: true),
    mode: jsonEnum(json, 'mode', LibraryMode.values),
  );
}

class BooruServer {
  const BooruServer({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.engine,
    this.enabled = true,
    this.excludedTags = const [],
  });

  final String id;
  final String name;
  final String baseUrl;
  final BooruEngine engine;
  final bool enabled;
  final List<String> excludedTags;

  BooruServer copyWith({
    String? id,
    String? name,
    String? baseUrl,
    BooruEngine? engine,
    bool? enabled,
    List<String>? excludedTags,
  }) => BooruServer(
    id: id ?? this.id,
    name: name ?? this.name,
    baseUrl: baseUrl ?? this.baseUrl,
    engine: engine ?? this.engine,
    enabled: enabled ?? this.enabled,
    excludedTags: excludedTags ?? this.excludedTags,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'baseUrl': baseUrl,
    'engine': engine.name,
    'enabled': enabled,
    'excludedTags': excludedTags,
  };

  factory BooruServer.fromJson(Map<String, dynamic> json) => BooruServer(
    id: jsonString(json, 'id', required: true, nonEmpty: true),
    name: jsonString(json, 'name', required: true, nonEmpty: true),
    baseUrl: jsonHttpUrl(json, 'baseUrl'),
    engine: jsonEnum(json, 'engine', BooruEngine.values),
    enabled: jsonBool(json, 'enabled', fallback: true),
    excludedTags: jsonStrings(json, 'excludedTags'),
  );
}

class AppPreferences {
  const AppPreferences({
    this.mode = LibraryMode.books,
    this.theme = 'system',
    this.columns = 3,
    this.hitomiBaseUrl = 'https://hitomi.la',
    this.defaultTags = const [],
    this.excludedTags = const [],
    this.readerContinuous = false,
    this.readerRtl = false,
    this.readerFitWidth = false,
    this.readerShowPageNumber = true,
    this.readerTapNavigation = true,
    this.onboardingComplete = false,
  });

  final LibraryMode mode;
  final String theme;
  final int columns;
  final String hitomiBaseUrl;
  final List<String> defaultTags;
  final List<String> excludedTags;
  final bool readerContinuous;
  final bool readerRtl;
  final bool readerFitWidth;
  final bool readerShowPageNumber;
  final bool readerTapNavigation;
  final bool onboardingComplete;

  AppPreferences copyWith({
    LibraryMode? mode,
    String? theme,
    int? columns,
    String? hitomiBaseUrl,
    List<String>? defaultTags,
    List<String>? excludedTags,
    bool? readerContinuous,
    bool? readerRtl,
    bool? readerFitWidth,
    bool? readerShowPageNumber,
    bool? readerTapNavigation,
    bool? onboardingComplete,
  }) => AppPreferences(
    mode: mode ?? this.mode,
    theme: theme ?? this.theme,
    columns: columns ?? this.columns,
    hitomiBaseUrl: hitomiBaseUrl ?? this.hitomiBaseUrl,
    defaultTags: defaultTags ?? this.defaultTags,
    excludedTags: excludedTags ?? this.excludedTags,
    readerContinuous: readerContinuous ?? this.readerContinuous,
    readerRtl: readerRtl ?? this.readerRtl,
    readerFitWidth: readerFitWidth ?? this.readerFitWidth,
    readerShowPageNumber: readerShowPageNumber ?? this.readerShowPageNumber,
    readerTapNavigation: readerTapNavigation ?? this.readerTapNavigation,
    onboardingComplete: onboardingComplete ?? this.onboardingComplete,
  );

  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    'theme': theme,
    'columns': columns,
    'hitomiBaseUrl': hitomiBaseUrl,
    'defaultTags': defaultTags,
    'excludedTags': excludedTags,
    'readerContinuous': readerContinuous,
    'readerRtl': readerRtl,
    'readerFitWidth': readerFitWidth,
    'readerShowPageNumber': readerShowPageNumber,
    'readerTapNavigation': readerTapNavigation,
    'onboardingComplete': onboardingComplete,
  };

  factory AppPreferences.fromJson(Map<String, dynamic> json) {
    final theme = jsonString(json, 'theme', fallback: 'system');
    if (!const ['system', 'light', 'dark'].contains(theme)) {
      throw const FormatException('Unknown theme.');
    }
    return AppPreferences(
      mode: json.containsKey('mode')
          ? jsonEnum(json, 'mode', LibraryMode.values)
          : LibraryMode.books,
      theme: theme,
      columns: jsonInt(json, 'columns', fallback: 3, minimum: 1, maximum: 8),
      hitomiBaseUrl: json.containsKey('hitomiBaseUrl')
          ? jsonHttpUrl(json, 'hitomiBaseUrl')
          : 'https://hitomi.la',
      defaultTags: jsonStrings(json, 'defaultTags'),
      excludedTags: jsonStrings(json, 'excludedTags'),
      readerContinuous: jsonBool(json, 'readerContinuous'),
      readerRtl: jsonBool(json, 'readerRtl'),
      readerFitWidth: jsonBool(json, 'readerFitWidth'),
      readerShowPageNumber: jsonBool(
        json,
        'readerShowPageNumber',
        fallback: true,
      ),
      readerTapNavigation: jsonBool(
        json,
        'readerTapNavigation',
        fallback: true,
      ),
      onboardingComplete: jsonBool(json, 'onboardingComplete'),
    );
  }
}

// Shared strict readers keep corrupt files from silently losing user data.
Map<String, dynamic> jsonObject(Object? value, String field) {
  if (value is! Map<String, dynamic>) {
    throw FormatException('$field must be an object.');
  }
  return value;
}

String jsonString(
  Map<String, dynamic> json,
  String field, {
  String fallback = '',
  bool required = false,
  bool nonEmpty = false,
}) {
  if (!json.containsKey(field) && !required) return fallback;
  final value = json[field];
  if (value is! String || (nonEmpty && value.trim().isEmpty)) {
    throw FormatException(
      '$field must be ${nonEmpty ? 'a non-empty' : 'a'} string.',
    );
  }
  return value;
}

String? jsonNullableString(Map<String, dynamic> json, String field) {
  if (json[field] == null) return null;
  return jsonString(json, field);
}

List<String> jsonStrings(Map<String, dynamic> json, String field) {
  if (!json.containsKey(field)) return const [];
  final value = json[field];
  if (value is! List || value.any((entry) => entry is! String)) {
    throw FormatException('$field must be an array of strings.');
  }
  return List<String>.unmodifiable(value.cast<String>());
}

int jsonInt(
  Map<String, dynamic> json,
  String field, {
  int fallback = 0,
  int? minimum,
  int? maximum,
}) {
  if (!json.containsKey(field)) return fallback;
  final value = json[field];
  if (value is! int ||
      (minimum != null && value < minimum) ||
      (maximum != null && value > maximum)) {
    throw FormatException(
      '$field must be an integer within the supported range.',
    );
  }
  return value;
}

int? jsonNullableInt(Map<String, dynamic> json, String field, {int? minimum}) {
  if (json[field] == null) return null;
  return jsonInt(json, field, minimum: minimum);
}

bool jsonBool(
  Map<String, dynamic> json,
  String field, {
  bool fallback = false,
}) {
  if (!json.containsKey(field)) return fallback;
  final value = json[field];
  if (value is! bool) throw FormatException('$field must be a boolean.');
  return value;
}

T jsonEnum<T extends Enum>(
  Map<String, dynamic> json,
  String field,
  List<T> values,
) {
  final name = jsonString(json, field, required: true);
  for (final value in values) {
    if (value.name == name) return value;
  }
  throw FormatException('Unknown $field: $name.');
}

DateTime jsonDate(Map<String, dynamic> json, String field) {
  final value = jsonString(json, field, required: true);
  final date = DateTime.tryParse(value);
  if (date == null) throw FormatException('$field must be an ISO 8601 date.');
  return date;
}

String jsonHttpUrl(Map<String, dynamic> json, String field) {
  final value = jsonString(json, field, required: true, nonEmpty: true);
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !const ['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      uri.hasQuery) {
    throw FormatException('$field must be an HTTP or HTTPS base URL.');
  }
  return value;
}
