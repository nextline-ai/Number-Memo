part of 'catalog_service.dart';

extension _HitomiCatalog on CatalogService {
  static final _publicData = Uri.parse(
    'https://ltn.gold-usergeneratedcontent.net/',
  );

  Uri _dataBase(Uri website) =>
      {'hitomi.la', 'www.hitomi.la'}.contains(website.host)
      ? _publicData
      : website;

  Map<String, String> _bookHeaders(Uri base, [int? id]) => {
    'Referer': id == null
        ? base.toString()
        : base.resolve('reader/$id.html').toString(),
  };

  Future<_GalleryDocument> _galleryDocument(
    int id,
    Uri base, {
    bool refresh = false,
  }) async {
    if (id <= 0 || id > 9999999999) {
      throw const CatalogException('작품 번호가 올바르지 않습니다.');
    }
    final key = '$base|$id';
    final cached = _documents[key];
    if (!refresh &&
        cached != null &&
        cached.fresh(const Duration(minutes: 10))) {
      return cached.value;
    }
    final response = await _get(
      _dataBase(base).resolve('galleries/$id.js'),
      headers: _bookHeaders(base, id),
      limit: 4000000,
    );
    final document = _GalleryDocument.parse(response.bodyBytes, id);
    CatalogService._put(_documents, key, document);
    return document;
  }

  Future<_CdnRouting> _currentRouting(Uri base, {bool refresh = false}) async {
    final dataBase = _dataBase(base);
    final key = dataBase.toString();
    final cached = _routing[key];
    if (!refresh &&
        cached != null &&
        cached.fresh(const Duration(minutes: 5))) {
      return cached.value;
    }
    final existing = _routingRequests[key];
    if (existing != null) return existing;
    final task = (() async {
      final response = await _get(
        dataBase.resolve('gg.js'),
        headers: _bookHeaders(base),
        limit: 100000,
      );
      final routing = _CdnRouting.parse(
        utf8.decode(response.bodyBytes, allowMalformed: true),
      );
      CatalogService._put(_routing, key, routing, limit: 8);
      return routing;
    })();
    _routingRequests[key] = task;
    try {
      return await task;
    } finally {
      _routingRequests.remove(key);
    }
  }

  Future<List<CatalogItem>> _loadGalleries(List<int> ids, Uri base) async {
    if (ids.isEmpty) return [];
    // Four at a time avoids hammering the catalog when scrolling quickly.
    final documents = <_GalleryDocument>[];
    for (var start = 0; start < ids.length; start += 4) {
      final batch = ids.skip(start).take(4);
      final items = await Future.wait(
        batch.map((id) async {
          try {
            return await _galleryDocument(id, base);
          } on CatalogException catch (error) {
            // Deleted entries can remain in the index until the next publication.
            if (error.statusCode == 404) return null;
            rethrow;
          }
        }),
      );
      documents.addAll(items.whereType<_GalleryDocument>());
    }
    if (documents.isEmpty) {
      throw const CatalogException(
        '목록의 작품 정보를 찾을 수 없습니다. 작품이 삭제되었거나 서버의 목록이 오래되었을 수 있습니다.',
      );
    }
    final routing = await _currentRouting(base);
    return documents.map((document) => document.item(base, routing)).toList();
  }

  Future<List<int>> _feedPage(Uri base, String path, int offset) async {
    final start = offset * 4;
    final response = await _get(
      _dataBase(base).resolve(path),
      headers: {
        ..._bookHeaders(base),
        'Range': 'bytes=$start-${start + CatalogService.bookPageSize * 4 - 1}',
      },
      limit: CatalogService.bookPageSize * 4,
      allowRangeEnd: true,
    );
    if (response.statusCode == 416) return [];
    _validateRange(response, start);
    return _BinaryReader.ids(response.bodyBytes);
  }

  Future<List<int>> _fullList(Uri base, String path) async {
    try {
      final response = await _get(
        _dataBase(base).resolve(path),
        headers: _bookHeaders(base),
        limit: 8000000,
      );
      return _BinaryReader.ids(response.bodyBytes);
    } on CatalogException catch (error) {
      if (error.statusCode == 404) return [];
      rethrow;
    }
  }

  Future<List<int>> _searchBookIds(
    Uri base,
    String query,
    String language,
  ) async {
    final tokens = query.toLowerCase().split(RegExp(r'\s+'));
    if (tokens.length > 8 ||
        tokens.any((token) => token.length > 120 || token.contains('"'))) {
      throw const CatalogException(
        '검색어는 8개 이하로 입력하고, 태그 안의 공백은 밑줄(_)로 연결해 주세요.',
      );
    }
    Set<int>? included;
    final excluded = <int>{};
    String? version;
    var explicitLanguage = false;
    for (final token in tokens) {
      final isExcluded = token.startsWith('-');
      final term = (isExcluded ? token.substring(1) : token).replaceAll(
        '_',
        ' ',
      );
      if (term.isEmpty) throw const CatalogException('검색어를 확인해 주세요.');
      final List<int> ids;
      final colon = term.indexOf(':');
      if (colon >= 0) {
        final field = term.substring(0, colon);
        final value = term.substring(colon + 1);
        if (!{
              'artist',
              'group',
              'series',
              'character',
              'tag',
              'type',
              'female',
              'male',
              'language',
            }.contains(field) ||
            value.isEmpty) {
          throw const CatalogException(
            '지원하는 검색 조건: artist, group, series, character, tag, type, female, male, language',
          );
        }
        final String path;
        if (field == 'language') {
          explicitLanguage = !isExcluded || explicitLanguage;
          path = 'index-${Uri.encodeComponent(value)}.nozomi';
        } else if (field == 'female' || field == 'male') {
          path = 'tag/${Uri.encodeComponent(term)}-all.nozomi';
        } else {
          path = '$field/${Uri.encodeComponent(value)}-all.nozomi';
        }
        ids = await _fullList(base, path);
      } else {
        version ??= await _indexVersion(base);
        ids = await _keyword(base, term, version);
      }
      if (isExcluded) {
        excluded.addAll(ids);
      } else {
        final matches = ids.toSet();
        included = included == null ? matches : included.intersection(matches);
      }
    }
    if ((!explicitLanguage && language != 'all') || included == null) {
      final matches = (await _fullList(base, 'index-$language.nozomi')).toSet();
      included = included == null ? matches : included.intersection(matches);
    }
    return included.difference(excluded).toList()
      ..sort((a, b) => b.compareTo(a));
  }

  Future<String> _indexVersion(Uri base) async {
    final response = await _get(
      _dataBase(base).resolve('galleriesindex/version'),
      headers: _bookHeaders(base),
      limit: 64,
    );
    final version = utf8
        .decode(response.bodyBytes, allowMalformed: true)
        .trim();
    if (!RegExp(r'^\d{1,20}$').hasMatch(version)) {
      throw const CatalogException('검색 색인의 형식이 변경되었습니다.');
    }
    return version;
  }

  Future<List<int>> _keyword(Uri base, String term, String version) async {
    final key = sha256.convert(utf8.encode(term)).bytes.take(4).toList();
    var address = 0;
    final visited = <int>{};
    for (var depth = 0; depth < 32; depth++) {
      if (!visited.add(address) || address < 0) {
        throw const CatalogException('검색 색인이 올바르지 않습니다.');
      }
      final data = await _readRange(
        base,
        'galleriesindex/galleries.$version.index',
        address,
        464,
      );
      final node = _SearchNode(_BinaryReader(data));
      if (node.keys.isEmpty) return [];
      var position = 0;
      while (position < node.keys.length &&
          _compareBytes(node.keys[position], key) < 0) {
        position++;
      }
      if (position < node.keys.length &&
          _compareBytes(node.keys[position], key) == 0) {
        final location = node.locations[position];
        if (location.length < 4 || location.length > 8000000) {
          throw const CatalogException('검색 결과가 너무 큽니다. 검색 조건을 좁혀 주세요.');
        }
        final data = await _readRange(
          base,
          'galleriesindex/galleries.$version.data',
          location.offset,
          location.length,
        );
        final reader = _BinaryReader(data);
        final count = reader.u32();
        if (count > 2000000 || data.length != 4 + count * 4) {
          throw const CatalogException('검색 결과를 읽을 수 없습니다.');
        }
        return _BinaryReader.ids(data.sublist(4));
      }
      address = node.children[position];
      if (address == 0) return [];
    }
    throw const CatalogException('검색 색인의 깊이가 지원 범위를 초과했습니다.');
  }

  Future<Uint8List> _readRange(
    Uri base,
    String path,
    int start,
    int length,
  ) async {
    final response = await _get(
      _dataBase(base).resolve(path),
      headers: {
        ..._bookHeaders(base),
        'Range': 'bytes=$start-${start + length - 1}',
      },
      limit: length,
    );
    _validateRange(response, start);
    if (response.bodyBytes.length != length) {
      throw const CatalogException('검색 데이터의 일부가 누락되었습니다. 다시 시도해 주세요.');
    }
    return response.bodyBytes;
  }

  static void _validateRange(http.Response response, int start) {
    final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$')
        .firstMatch(response.headers['content-range'] ?? '');
    if (response.statusCode != 206 ||
        match == null ||
        int.parse(match[1]!) != start ||
        int.parse(match[2]!) < start ||
        int.parse(match[2]!) >= int.parse(match[3]!) ||
        int.parse(match[2]!) - start + 1 != response.bodyBytes.length) {
      throw const CatalogException('서버에서 부분 다운로드를 지원하지 않거나 응답이 올바르지 않습니다.');
    }
  }

  static int _compareBytes(List<int> a, List<int> b) {
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return a[index].compareTo(b[index]);
    }
    return 0;
  }
}

class _GalleryDocument {
  _GalleryDocument(
    this.id,
    this.title,
    this.artists,
    this.language,
    this.type,
    this.tags,
    this.hashes,
  );

  final int id;
  final String title;
  final List<String> artists;
  final String language;
  final String type;
  final List<String> tags;
  final List<String> hashes;

  factory _GalleryDocument.parse(Uint8List bytes, int id) {
    var text = utf8.decode(bytes, allowMalformed: true).trim();
    final assignment = RegExp(r'^var\s+galleryinfo\s*=\s*').firstMatch(text);
    if (assignment == null) throw const CatalogException('작품 정보의 형식이 변경되었습니다.');
    text = text.substring(assignment.end).replaceFirst(RegExp(r';\s*$'), '');
    try {
      final json = jsonDecode(text);
      if (json is! Map ||
          json['files'] is! List ||
          (json['files'] as List).isEmpty ||
          (json['files'] as List).length > 10000) {
        throw const FormatException('Invalid gallery');
      }
      final hashes = <String>[];
      for (final file in json['files'] as List) {
        if (file is! Map ||
            file['hash'] is! String ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(file['hash'] as String)) {
          throw const FormatException('Invalid image hash');
        }
        hashes.add(file['hash'] as String);
      }
      var title = CatalogService._string(json['japanese_title']).trim();
      if (title.isEmpty) title = CatalogService._string(json['title']).trim();
      if (title.isEmpty) title = '작품 #$id';
      final artists =
          (json['artists'] is List ? json['artists'] as List : const [])
              .whereType<Map>()
              .map((artist) => CatalogService._string(artist['artist']))
              .where((name) => name.isNotEmpty)
              .toList();
      final tags = <String>[];
      for (final tag
          in (json['tags'] is List ? json['tags'] as List : const [])
              .whereType<Map>()) {
        final value = CatalogService._string(tag['tag']);
        if (value.isEmpty) continue;
        final namespaces = [
          'female',
          'male',
        ].where((name) => {true, 1, '1', 'true'}.contains(tag[name])).toList();
        tags.addAll(
          (namespaces.isEmpty ? ['tag'] : namespaces).map(
            (namespace) => '$namespace:$value',
          ),
        );
      }
      return _GalleryDocument(
        id,
        html.parseFragment(title).text ?? title,
        artists,
        CatalogService._string(json['language']),
        CatalogService._string(json['type']),
        tags,
        hashes,
      );
    } on FormatException {
      throw const CatalogException('작품 정보를 읽을 수 없습니다. 다시 시도해 주세요.');
    }
  }

  CatalogItem item(Uri base, _CdnRouting routing) => CatalogItem(
    id: 'hitomi:$id',
    mode: LibraryMode.books,
    title: title,
    sourceUrl: base.resolve('galleries/$id.html').toString(),
    thumbnailUrl: routing.url(hashes.first, thumbnail: true),
    mediaUrls: hashes.map((hash) => routing.url(hash)).toList(),
    tags: tags,
    artists: artists,
    description: type,
    language: language,
    pageCount: hashes.length,
    remoteId: id,
  );
}

class _CdnRouting {
  _CdnRouting(
    this.prefix,
    this.defaultValue,
    this.alternateValue,
    this.buckets,
  );
  final String prefix;
  final int defaultValue;
  final int alternateValue;
  final Set<int> buckets;

  factory _CdnRouting.parse(String source) {
    // Recognize the routing data, never execute downloaded JavaScript.
    final function = RegExp(
      r'm:\s*function\(g\)\s*\{\s*var o\s*=\s*([01]);\s*switch\s*\(g\)\s*\{\s*((?:case\s+\d+:\s*)+)o\s*=\s*([01]);\s*break;\s*\}\s*return o;\s*\}',
      dotAll: true,
    ).firstMatch(source);
    final prefix = RegExp("\\bb:\\s*['\"]([0-9]+/)['\"]").firstMatch(source);
    if (function == null || prefix == null) {
      throw const CatalogException('이미지 서버의 주소 형식이 변경되었습니다. 원본 사이트에서 확인해 주세요.');
    }
    final buckets = RegExp(r'case\s+(\d+):')
        .allMatches(function[2]!)
        .map((match) => int.parse(match[1]!))
        .toSet();
    if (buckets.any((bucket) => bucket < 0 || bucket > 4095)) {
      throw const CatalogException('이미지 서버의 설정이 올바르지 않습니다.');
    }
    return _CdnRouting(
      prefix[1]!,
      int.parse(function[1]!),
      int.parse(function[3]!),
      buckets,
    );
  }

  String url(String hash, {bool thumbnail = false}) {
    final last = hash.substring(hash.length - 1);
    final previous = hash.substring(hash.length - 3, hash.length - 1);
    final bucket = int.parse('$last$previous', radix: 16);
    final alternate = buckets.contains(bucket) ? alternateValue : defaultValue;
    final host = thumbnail
        ? (alternate == 0 ? 'atn' : 'btn')
        : 'w${1 + alternate}';
    final path = thumbnail
        ? 'webpsmalltn/$last/$previous/$hash.webp'
        : '$prefix$bucket/$hash.webp';
    return 'https://$host.gold-usergeneratedcontent.net/$path';
  }
}

class _BinaryReader {
  _BinaryReader(this.data);
  final Uint8List data;
  var offset = 0;

  List<int> bytes(int count) {
    if (count < 0 || offset + count > data.length) {
      throw const CatalogException('검색 데이터가 손상되었습니다.');
    }
    final result = data.sublist(offset, offset + count);
    offset += count;
    return result;
  }

  int u32() => bytes(4).fold(0, (value, byte) => (value << 8) | byte);
  int u64() {
    final high = u32();
    final low = u32();
    // JS targets use a 53-bit integer; corrupt offsets must never wrap around.
    if (high > 0x1fffff) throw const CatalogException('검색 주소가 지원 범위를 초과했습니다.');
    return high * 0x100000000 + low;
  }

  static List<int> ids(Uint8List data) {
    if (data.length % 4 != 0) throw const CatalogException('작품 목록을 읽을 수 없습니다.');
    final reader = _BinaryReader(data);
    return List.generate(data.length ~/ 4, (_) {
      final id = reader.u32();
      if (id <= 0) throw const CatalogException('작품 번호가 올바르지 않습니다.');
      return id;
    });
  }
}

class _SearchNode {
  _SearchNode(_BinaryReader reader) {
    final count = reader.u32();
    if (count > 16) throw const CatalogException('검색 색인의 형식이 변경되었습니다.');
    for (var index = 0; index < count; index++) {
      if (reader.u32() != 4) throw const CatalogException('검색 키 형식이 변경되었습니다.');
      keys.add(reader.bytes(4));
    }
    if (reader.u32() != count) {
      throw const CatalogException('검색 색인이 올바르지 않습니다.');
    }
    for (var index = 0; index < count; index++) {
      locations.add((offset: reader.u64(), length: reader.u32()));
    }
    for (var index = 0; index < 17; index++) {
      children.add(reader.u64());
    }
  }

  final List<List<int>> keys = [];
  final List<({int offset, int length})> locations = [];
  final List<int> children = [];
}
