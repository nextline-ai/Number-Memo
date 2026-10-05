import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../data/models.dart';
import 'booru_blacklist.dart';

part 'hitomi_catalog.dart';

/// A message that can be displayed directly next to the retry action.
class CatalogException implements Exception {
  const CatalogException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class CatalogPage {
  const CatalogPage({required this.items, required this.hasMore});

  final List<CatalogItem> items;
  final bool hasMore;
}

/// Public, unauthenticated catalog access. No remote script is evaluated.
class CatalogService {
  CatalogService({http.Client? client}) : _client = client ?? http.Client();

  static const bookPageSize = 24;
  static const imagePageSize = 40;
  static const userAgent = 'NumberMemo/1.0 (Flutter; Android and Desktop)';
  static const _timeout = Duration(seconds: 25);

  final http.Client _client;
  final Map<String, _Cached<_GalleryDocument>> _documents = {};
  final Map<String, _Cached<_CdnRouting>> _routing = {};
  final Map<String, Future<_CdnRouting>> _routingRequests = {};
  final Map<String, _Cached<List<int>>> _searches = {};

  void dispose() => _client.close();

  /// Extract only complete numeric tokens or URLs on the actual Hitomi hosts.
  /// Translation links are unwrapped without accepting lookalike domains.
  static List<int> parseGalleryIds(String text) {
    final result = <int>{};
    void parseToken(String input, [int depth = 0]) {
      if (depth > 3) return;
      final token = input.replaceAll(RegExp(r'^[\[<(]+|[\])>.]+$'), '');
      if (RegExp(r'^\d{4,10}$').hasMatch(token)) {
        final id = int.tryParse(token);
        if (id != null && id >= 1000 && id <= 9999999999) result.add(id);
        return;
      }
      final uri = Uri.tryParse(
        token.startsWith('hitomi.la/') ||
                token.startsWith('www.hitomi.la/') ||
                token.startsWith('hitomi-la.translate.goog/')
            ? 'https://$token'
            : token,
      );
      if (uri == null ||
          !['https', 'http'].contains(uri.scheme) ||
          uri.userInfo.isNotEmpty) {
        return;
      }
      final host = uri.host.toLowerCase();
      if (host == 'translate.google.com' || host == 'translate.google.co.kr') {
        final nested = uri.queryParameters['u'];
        if (nested != null) parseToken(nested, depth + 1);
        return;
      }
      if (!{
        'hitomi.la',
        'www.hitomi.la',
        'hitomi-la.translate.goog',
      }.contains(host)) {
        return;
      }
      final direct = RegExp(r'^/(?:galleries|reader)/(\d{4,10})(?:\.html)?/?$')
          .firstMatch(uri.path);
      final named = RegExp(r'^/[^/]+/[^/]+-(\d{4,10})\.html$')
          .firstMatch(uri.path);
      final digits = direct?.group(1) ?? named?.group(1);
      if (digits != null) parseToken(digits, depth + 1);
    }

    for (final token in text.trim().split(RegExp(r'[\s,;]+'))) {
      parseToken(token);
    }
    return result.toList();
  }

  Future<CatalogItem> gallery(
    int id, {
    String baseUrl = 'https://hitomi.la',
    bool refresh = false,
  }) async {
    final base = _baseUri(baseUrl);
    final document = await _galleryDocument(id, base, refresh: refresh);
    final routing = await _currentRouting(base, refresh: refresh);
    return document.item(base, routing);
  }

  Future<List<String>> galleryPages(
    int id, {
    String baseUrl = 'https://hitomi.la',
    bool refresh = false,
  }) async {
    final base = _baseUri(baseUrl);
    final document = await _galleryDocument(id, base, refresh: refresh);
    final routing = await _currentRouting(base, refresh: refresh);
    return document.hashes.map((hash) => routing.url(hash)).toList();
  }

  /// Terms support keyword, artist:name, tag:name, language:korean and -term.
  /// The compact binary index is also used by the native application.
  Future<List<CatalogItem>> searchBooks({
    String query = '',
    int page = 0,
    String baseUrl = 'https://hitomi.la',
    String language = 'korean',
    String sort = 'latest',
  }) async {
    if (page < 0 ||
        page > 100000 ||
        !RegExp(r'^[a-z]{2,24}$').hasMatch(language) ||
        !{'latest', 'today', 'week', 'month', 'year'}.contains(sort)) {
      throw const CatalogException('검색 조건을 확인해 주세요.');
    }
    final base = _baseUri(baseUrl);
    final typed = query.trim();
    final directIds = parseGalleryIds(typed);
    if (directIds.isNotEmpty) {
      return _loadGalleries(
        directIds.skip(page * bookPageSize).take(bookPageSize).toList(),
        base,
      );
    }
    final offset = page * bookPageSize;
    final List<int> ids;
    if (typed.isEmpty) {
      final path = sort == 'latest'
          ? 'index-$language.nozomi'
          : 'popular/$sort-$language.nozomi';
      ids = await _feedPage(base, path, offset);
    } else {
      final cacheKey = '$base|$language|$sort|$typed';
      final cached = _searches[cacheKey];
      List<int> all;
      if (cached != null && cached.fresh(const Duration(minutes: 5))) {
        all = cached.value;
      } else {
        all = await _searchBookIds(base, typed, language);
        if (sort != 'latest' && all.isNotEmpty) {
          final requestedLanguage = typed
              .toLowerCase()
              .split(RegExp(r'\s+'))
              .where((term) => term.startsWith('language:'))
              .map((term) => term.substring('language:'.length))
              .lastOrNull;
          final rankingLanguage = requestedLanguage ?? language;
          final allowed = all.toSet();
          all = (await _fullList(
            base,
            'popular/$sort-${Uri.encodeComponent(rankingLanguage)}.nozomi',
          )).where(allowed.contains).toList();
        }
        _put(_searches, cacheKey, all, limit: 8);
      }
      ids = all.skip(offset).take(bookPageSize).toList();
    }
    return _loadGalleries(ids, base);
  }

  Future<List<CatalogItem>> searchImages({
    required BooruServer server,
    String query = '',
    int page = 0,
    String rating = 'safe',
    bool popular = false,
  }) async => (await imagePage(
    server: server,
    query: query,
    page: page,
    rating: rating,
    popular: popular,
  )).items;

  /// Pagination follows the server's raw page, even if every returned item is
  /// removed by local rating or tag filters.
  Future<CatalogPage> imagePage({
    required BooruServer server,
    String query = '',
    int page = 0,
    String rating = 'safe',
    bool popular = false,
  }) async {
    if (page < 0 || page > 100000) {
      throw const CatalogException('페이지 번호가 올바르지 않습니다.');
    }
    final base = _baseUri(server.baseUrl);
    final terms = query
        .trim()
        .split(RegExp(r'\s+'))
        .where((term) => term.isNotEmpty)
        .toList();
    final normalizedRating = _normalizeRequestedRating(rating);
    if (normalizedRating != 'all') {
      terms.removeWhere(
        (term) => term.startsWith('rating:') || term.startsWith('-rating:'),
      );
      final ratingValue =
          normalizedRating == 'general' && !_modernRatings(server)
          ? 'safe'
          : normalizedRating;
      terms.add('rating:$ratingValue');
    }
    if (popular) {
      terms.removeWhere(
        (term) => term.startsWith('order:') || term.startsWith('sort:'),
      );
      terms.add(
        server.engine == BooruEngine.gelbooru
            ? 'sort:score:desc'
            : 'order:score',
      );
    }
    final blacklist = BooruBlacklist(server.excludedTags);
    for (final exclusion in blacklist.queryExclusions) {
      if (!terms.contains(exclusion)) terms.add(exclusion);
    }
    final params = <String, String>{
      'limit': '$imagePageSize',
      'tags': terms.join(' '),
    };
    final String path;
    switch (server.engine) {
      case BooruEngine.danbooru:
        path = 'posts.json';
        params['page'] = '${page + 1}';
      case BooruEngine.gelbooru:
        path = 'index.php';
        params.addAll({
          'page': 'dapi',
          's': 'post',
          'q': 'index',
          'json': '1',
          'pid': '$page',
        });
      case BooruEngine.moebooru:
        path = 'post.json';
        params['page'] = '${page + 1}';
    }
    final response = await _get(_endpoint(base, path, params));
    final rows = _rows(response, 'post');
    final result = <CatalogItem>[];
    final seen = <int>{};
    for (final row in rows) {
      final item = _imageItem(row, server, base);
      if (!seen.add(item.remoteId!)) continue;
      if (normalizedRating != 'all' && item.rating != normalizedRating) {
        continue;
      }
      // Preserve native matching for an unfamiliar rating token, without
      // changing the normalized public rating used by existing search filters.
      final filterItem = item.rating.isEmpty
          ? item.copyWith(rating: _string(row['rating']))
          : item;
      if (blacklist.contains(filterItem)) {
        continue;
      }
      result.add(item);
    }
    return CatalogPage(items: result, hasMore: rows.length >= imagePageSize);
  }

  Future<List<String>> suggestTags({
    required BooruServer server,
    required String query,
  }) async {
    final token = query.trim().toLowerCase();
    if (token.length < 2 ||
        token.length > 120 ||
        token.contains(RegExp(r'\s'))) {
      return [];
    }
    final base = _baseUri(server.baseUrl);
    final Map<String, String> params;
    final String path;
    switch (server.engine) {
      case BooruEngine.danbooru:
        path = 'tags.json';
        params = {
          'search[name_matches]': '$token*',
          'search[order]': 'count',
          'limit': '12',
        };
      case BooruEngine.gelbooru:
        path = 'index.php';
        params = {
          'page': 'dapi',
          's': 'tag',
          'q': 'index',
          'json': '1',
          'name_pattern': '$token%',
          'orderby': 'count',
          'order': 'DESC',
          'limit': '12',
        };
      case BooruEngine.moebooru:
        path = 'tag.json';
        params = {'name': '$token*', 'order': 'count', 'limit': '12'};
    }
    final rows = _rows(await _get(_endpoint(base, path, params)), 'tag');
    return rows
        .map((row) => _string(row['name']))
        .where((name) => name.isNotEmpty)
        .toSet()
        .take(12)
        .toList();
  }

  CatalogItem _imageItem(
    Map<String, dynamic> row,
    BooruServer server,
    Uri base,
  ) {
    final id = _integer(row['id']);
    if (id <= 0) throw const CatalogException('이미지 목록의 형식이 변경되었습니다.');
    final tags = _words(row['tag_string'] ?? row['tags']);
    final artists = _words(row['tag_string_artist']);
    final original = _mediaUrl(row['file_url'], base);
    final sample = _mediaUrl(
      row['large_file_url'] ?? row['sample_url'] ?? row['jpeg_url'],
      base,
    );
    var thumbnail = _mediaUrl(
      row['preview_file_url'] ?? row['preview_url'],
      base,
    );
    // Some legacy Gelbooru instances return only directory + image fields.
    final legacyImage = _string(row['image']);
    final directory = _string(row['directory']);
    var file = original;
    if (file.isEmpty &&
        legacyImage.isNotEmpty &&
        directory.isNotEmpty &&
        !legacyImage.contains('/') &&
        !directory.contains('/')) {
      file = _endpoint(base, 'images/$directory/$legacyImage').toString();
      final stem = legacyImage.replaceFirst(RegExp(r'\.[^.]+$'), '');
      thumbnail = thumbnail.isNotEmpty
          ? thumbnail
          : _endpoint(
              base,
              'thumbnails/$directory/thumbnail_$stem.jpg',
            ).toString();
    }
    final media = file.isNotEmpty ? file : sample;
    final source = switch (server.engine) {
      BooruEngine.danbooru => _endpoint(base, 'posts/$id'),
      BooruEngine.moebooru => _endpoint(base, 'post/show/$id'),
      BooruEngine.gelbooru => _endpoint(base, 'index.php', {
        'page': 'post',
        's': 'view',
        'id': '$id',
      }),
    };
    final rawRating = _string(row['rating']).toLowerCase();
    final rating = switch (rawRating) {
      'g' || 'general' || 'safe' => 'general',
      's' => _modernRatings(server) ? 'sensitive' : 'general',
      'sensitive' => 'sensitive',
      'q' || 'questionable' => 'questionable',
      'e' || 'explicit' => 'explicit',
      _ => '',
    };
    return CatalogItem(
      id: '${server.id}:$id',
      mode: LibraryMode.images,
      title: '${server.name} #$id',
      sourceUrl: source.toString(),
      thumbnailUrl: thumbnail.isNotEmpty
          ? thumbnail
          : (sample.isNotEmpty ? sample : file),
      mediaUrls: media.isEmpty ? [] : [media],
      tags: tags,
      artists: artists,
      description: _string(row['source']),
      rating: rating,
      pageCount: 1,
      score: _integer(row['score']),
      serverId: server.id,
      remoteId: id,
    );
  }

  Future<http.Response> _get(
    Uri uri, {
    Map<String, String> headers = const {},
    int limit = 12000000,
    bool allowRangeEnd = false,
  }) async {
    try {
      return await (() async {
        final request = http.Request('GET', uri)
          ..headers.addAll({
            'User-Agent': userAgent,
            'Accept': 'application/json, application/xml;q=0.9, */*;q=0.8',
            ...headers,
          });
        final streamed = await _client.send(request);
        if (streamed.statusCode == 416 && allowRangeEnd) {
          await streamed.stream.drain<void>();
          return http.Response.bytes([], 416, headers: streamed.headers);
        }
        if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
          await streamed.stream.listen((_) {}).cancel();
          throw _httpError(streamed.statusCode);
        }
        if (streamed.contentLength != null && streamed.contentLength! > limit) {
          await streamed.stream.listen((_) {}).cancel();
          throw const CatalogException('응답이 너무 큽니다. 검색 조건을 좁혀 주세요.');
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in streamed.stream) {
          if (bytes.length + chunk.length > limit) {
            throw const CatalogException('응답이 너무 큽니다. 검색 조건을 좁혀 주세요.');
          }
          bytes.add(chunk);
        }
        return http.Response.bytes(
          bytes.takeBytes(),
          streamed.statusCode,
          headers: streamed.headers,
          request: request,
        );
      })().timeout(_timeout);
    } on CatalogException {
      rethrow;
    } on TimeoutException {
      throw const CatalogException('서버 응답이 늦어지고 있습니다. 잠시 후 다시 시도해 주세요.');
    } on http.ClientException {
      throw const CatalogException('서버에 연결할 수 없습니다. 인터넷 연결과 서버 주소를 확인해 주세요.');
    } on FormatException {
      throw const CatalogException('서버 응답을 읽을 수 없습니다. 서버 주소를 확인해 주세요.');
    }
  }

  static CatalogException _httpError(int status) =>
      CatalogException(switch (status) {
        401 => '이 서버는 로그인이 필요합니다. 공개 API를 제공하는 서버를 선택해 주세요.',
        403 => '서버에서 접근을 제한했습니다. 원본 사이트에서 상태를 확인해 주세요.',
        404 => '요청한 작품이나 API를 찾을 수 없습니다.',
        429 => '요청이 너무 많습니다. 잠시 기다린 뒤 다시 시도해 주세요.',
        _ => '서버에서 오류가 발생했습니다. (HTTP $status)',
      }, statusCode: status);

  static Uri _baseUri(String input) {
    final uri = Uri.tryParse(input.trim());
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.host.contains(RegExp(r'\s')) ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const CatalogException(
        'http:// 또는 https://로 시작하는 올바른 서버 주소를 입력해 주세요.',
      );
    }
    var path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    if (path.endsWith('/index.php')) path = path.substring(0, path.length - 10);
    return uri.replace(path: '$path/');
  }

  static Uri _endpoint(Uri base, String path, [Map<String, String>? params]) =>
      base.resolve(path).replace(queryParameters: params);

  static String _mediaUrl(dynamic value, Uri base) {
    final raw = _string(value).trim();
    if (raw.isEmpty) return '';
    final uri = Uri.tryParse(raw);
    if (uri == null) return '';
    final resolved = base.resolveUri(uri);
    return {'https', 'http'}.contains(resolved.scheme) &&
            resolved.host.isNotEmpty &&
            resolved.userInfo.isEmpty
        ? resolved.toString()
        : '';
  }

  static bool _modernRatings(BooruServer server) =>
      server.engine == BooruEngine.danbooru ||
      (server.engine == BooruEngine.gelbooru &&
          {
            'gelbooru.com',
            'www.gelbooru.com',
          }.contains(Uri.tryParse(server.baseUrl)?.host));

  static String _normalizeRequestedRating(String rating) => switch (rating) {
    'safe' || 'general' || 'g' => 'general',
    'sensitive' || 's' => 'sensitive',
    'questionable' || 'q' => 'questionable',
    'explicit' || 'e' => 'explicit',
    'all' || '' => 'all',
    _ => throw const CatalogException('지원하지 않는 등급 필터입니다.'),
  };

  static String _string(dynamic value) => value is String ? value : '';
  static int _integer(dynamic value) =>
      value is num ? value.toInt() : int.tryParse('$value') ?? 0;
  static List<String> _words(dynamic value) =>
      _string(value)
          .split(RegExp(r'\s+'))
          .where((word) => word.isNotEmpty)
          .toList();

  static List<Map<String, dynamic>> _rows(http.Response response, String key) {
    final text = utf8.decode(response.bodyBytes, allowMalformed: true).trim();
    final prefix = text.substring(0, text.length.clamp(0, 4096)).toLowerCase();
    if (prefix.contains('<html') ||
        prefix.contains('<!doctype html') ||
        prefix.contains('cf-chl-') ||
        prefix.contains('just a moment')) {
      throw const CatalogException(
        '서버에서 웹 브라우저 확인을 요청했습니다. 다른 서버를 선택하거나 원본 사이트를 열어 주세요.',
      );
    }
    try {
      if (text.startsWith('<')) {
        final document = XmlDocument.parse(text);
        if (document.rootElement.name.local != '${key}s') {
          throw const FormatException('Invalid XML root');
        }
        return document.rootElement
            .findElements(key)
            .map(
              (element) => <String, dynamic>{
                for (final attribute in element.attributes)
                  attribute.name.local: attribute.value,
                for (final child in element.childElements)
                  child.name.local: child.innerText,
              },
            )
            .toList();
      }
      dynamic json = jsonDecode(text);
      if (json is Map) {
        if (json['success'] == false || json['error'] != null) {
          throw const CatalogException(
            '서버에서 API 요청을 거절했습니다. 검색 조건과 서버 상태를 확인해 주세요.',
          );
        }
        if (json.containsKey(key)) {
          json = json[key];
          if (json is Map) json = [json];
        } else if (json['@attributes'] is Map &&
            _integer(json['@attributes']['count']) == 0) {
          return [];
        }
      }
      if (json is! List || json.any((row) => row is! Map)) {
        throw const FormatException('Invalid catalog rows');
      }
      return json.map((row) => Map<String, dynamic>.from(row as Map)).toList();
    } on CatalogException {
      rethrow;
    } on FormatException {
      throw const CatalogException('서버의 응답 형식이 지원되지 않습니다. 서버 종류를 확인해 주세요.');
    } on XmlException {
      throw const CatalogException('서버의 XML 응답을 읽을 수 없습니다.');
    }
  }

  static void _put<T>(
    Map<String, _Cached<T>> cache,
    String key,
    T value, {
    int limit = 64,
  }) {
    if (cache.length >= limit && !cache.containsKey(key)) {
      cache.remove(cache.keys.first);
    }
    cache[key] = _Cached(value);
  }
}

class _Cached<T> {
  _Cached(this.value) : createdAt = DateTime.now();
  final T value;
  final DateTime createdAt;
  bool fresh(Duration ttl) => DateTime.now().difference(createdAt) < ttl;
}
