import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:number_memo/data/models.dart';
import 'package:number_memo/services/catalog_service.dart';

const _hash =
    '0000000000000000000000000000000000000000000000000000000000000abc';
const _routing = '''
'use strict';
gg = {
  m: function(g) { var o = 0; switch (g) { case 3243: o = 1; break; } return o; },
  s: function(h) { var m = /(..)(.)\$/.exec(h); return parseInt(m[2]+m[1], 16).toString(10); },
  b: '20261005/'
};
''';
const _safeServer = BooruServer(
  id: 'safe',
  name: 'Example',
  baseUrl: 'https://images.example',
  engine: BooruEngine.gelbooru,
);

String _gallery(int id) =>
    'var galleryinfo = ${jsonEncode({
      'id': id,
      'title': 'A &amp; B',
      'language': 'korean',
      'type': 'illustration',
      'artists': [
        {'artist': 'example_artist'},
      ],
      'tags': [
        {'tag': 'landscape'},
        {'tag': 'portrait', 'female': '1'},
      ],
      'files': [
        {'name': 'page.webp', 'hash': _hash, 'width': 800, 'height': 1200, 'hasavif': 1},
      ],
    })};';

Uint8List _ids(List<int> ids) {
  final data = ByteData(ids.length * 4);
  for (var index = 0; index < ids.length; index++) {
    data.setUint32(index * 4, ids[index], Endian.big);
  }
  return data.buffer.asUint8List();
}

http.Response _range(
  Uint8List bytes, {
  int start = 0,
  int? total,
}) => http.Response.bytes(
  bytes,
  206,
  headers: {
    'content-range':
        'bytes $start-${start + bytes.length - 1}/${total ?? start + bytes.length}',
  },
);

void main() {
  group('gallery number import', () {
    test(
      'keeps input order and deduplicates numbers, reader and named URLs',
      () {
        expect(
          CatalogService.parseGalleryIds(
            '1234; https://hitomi.la/reader/5678.html#4\nhttps://hitomi.la/galleries/1234.html https://hitomi.la/manga/sample-title-9012.html',
          ),
          [1234, 5678, 9012],
        );
      },
    );

    test('unwraps supported translated URLs', () {
      expect(
        CatalogService.parseGalleryIds(
          'https://translate.google.com/translate?u=https%3A%2F%2Fhitomi.la%2Fgalleries%2F12345.html https://hitomi-la.translate.goog/reader/45678.html?_x_tr_tl=ko',
        ),
        [12345, 45678],
      );
    });

    test('rejects lookalike domains, credentials, unrelated embedded digits and oversized ids', () {
      expect(
        CatalogService.parseGalleryIds(
          'https://evilhitomi.la/galleries/1234.html https://hitomi.la.evil.test/reader/1234.html https://hitomi.la@evil.test/reader/1234.html https://user@hitomi.la/reader/1234.html file://hitomi.la/reader/1234.html a1234 123456789012 123 https://other.test/1234',
        ),
        isEmpty,
      );
    });
  });

  group('Hitomi catalog', () {
    test('decodes metadata and live CDN routing, with cached document and routing', () async {
      final calls = <String>[];
      final service = CatalogService(
        client: MockClient((request) async {
          calls.add(request.url.path);
          expect(request.url.host, 'ltn.gold-usergeneratedcontent.net');
          expect(request.headers['referer'], startsWith('https://hitomi.la/'));
          if (request.url.path == '/gg.js') return http.Response(_routing, 200);
          return http.Response(_gallery(1234), 200);
        }),
      );
      addTearDown(service.dispose);

      final item = await service.gallery(1234);
      expect(item.id, 'hitomi:1234');
      expect(item.title, 'A & B');
      expect(item.artists, ['example_artist']);
      expect(item.tags, ['tag:landscape', 'female:portrait']);
      expect(item.pageCount, 1);
      expect(item.sourceUrl, 'https://hitomi.la/galleries/1234.html');
      expect(
        item.thumbnailUrl,
        'https://btn.gold-usergeneratedcontent.net/webpsmalltn/c/ab/$_hash.webp',
      );
      expect(item.mediaUrls, [
        'https://w2.gold-usergeneratedcontent.net/20261005/3243/$_hash.webp',
      ]);
      expect(await service.galleryPages(1234), item.mediaUrls);
      expect(calls, ['/galleries/1234.js', '/gg.js']);

      await service.galleryPages(1234, refresh: true);
      expect(calls.where((path) => path == '/gg.js'), hasLength(2));
      expect(calls.where((path) => path == '/galleries/1234.js'), hasLength(2));
    });

    test(
      'uses byte ranges for latest pages and shares one routing request',
      () async {
        var routingCalls = 0;
        final service = CatalogService(
          client: MockClient((request) async {
            switch (request.url.path) {
              case '/index-korean.nozomi':
                expect(request.headers['range'], 'bytes=96-191');
                return _range(_ids([2222, 1111]), start: 96, total: 104);
              case '/gg.js':
                routingCalls++;
                return http.Response(_routing, 200);
              case '/galleries/2222.js':
                return http.Response(_gallery(2222), 200);
              case '/galleries/1111.js':
                return http.Response(_gallery(1111), 200);
            }
            fail('Unexpected request ${request.url}');
          }),
        );
        addTearDown(service.dispose);
        final items = await service.searchBooks(page: 1);
        expect(items.map((item) => item.remoteId), [2222, 1111]);
        expect(routingCalls, 1);
      },
    );

    test(
      'end of range returns an empty page without metadata requests',
      () async {
        final service = CatalogService(
          client: MockClient((request) async => http.Response('', 416)),
        );
        addTearDown(service.dispose);
        expect(await service.searchBooks(page: 999), isEmpty);
      },
    );

    test(
      'all deleted indexed galleries report a loading error, not no results',
      () async {
        final service = CatalogService(
          client: MockClient((request) async {
            if (request.url.path.endsWith('.nozomi')) {
              return _range(_ids([1234, 5678]));
            }
            return http.Response('', 404);
          }),
        );
        addTearDown(service.dispose);
        await expectLater(
          service.searchBooks(),
          throwsA(
            isA<CatalogException>().having(
              (error) => error.message,
              'message',
              contains('목록의 작품'),
            ),
          ),
        );
      },
    );

    test('a missing CDN route is not treated as a deleted gallery', () async {
      final service = CatalogService(
        client: MockClient((request) async {
          if (request.url.path.endsWith('.nozomi')) return _range(_ids([1234]));
          if (request.url.path.endsWith('/gg.js')) {
            return http.Response('', 404);
          }
          return http.Response(_gallery(1234), 200);
        }),
      );
      addTearDown(service.dispose);
      await expectLater(
        service.searchBooks(),
        throwsA(
          isA<CatalogException>().having(
            (error) => error.statusCode,
            'status',
            404,
          ),
        ),
      );
    });

    test(
      'explicit gallery refresh fetches new metadata and CDN routing',
      () async {
        var metadataCalls = 0;
        var routingCalls = 0;
        final service = CatalogService(
          client: MockClient((request) async {
            if (request.url.path.endsWith('/gg.js')) {
              routingCalls++;
              return http.Response(_routing, 200);
            }
            metadataCalls++;
            return http.Response(
              _gallery(1234)
                  .replaceFirst('A &amp; B', 'Version $metadataCalls'),
              200,
            );
          }),
        );
        addTearDown(service.dispose);
        expect((await service.gallery(1234)).title, 'Version 1');
        expect((await service.gallery(1234)).title, 'Version 1');
        expect((await service.gallery(1234, refresh: true)).title, 'Version 2');
        expect(metadataCalls, 2);
        expect(routingCalls, 2);
      },
    );

    test(
      'explicit search language chooses the corresponding popular ranking',
      () async {
        final service = CatalogService(
          client: MockClient((request) async {
            switch (request.url.path) {
              case '/index-english.nozomi':
              case '/popular/week-english.nozomi':
                return http.Response.bytes(_ids([1234]), 200);
              case '/galleries/1234.js':
                return http.Response(_gallery(1234), 200);
              case '/gg.js':
                return http.Response(_routing, 200);
            }
            fail('Unexpected default-language request ${request.url}');
          }),
        );
        addTearDown(service.dispose);
        expect(
          (await service.searchBooks(
            query: 'language:english',
            sort: 'week',
          )).single.remoteId,
          1234,
        );
      },
    );

    test('combines artist/tag inclusion and exclusions and honors explicit language', () async {
      final paths = <String>[];
      final service = CatalogService(
        client: MockClient((request) async {
          paths.add(request.url.path);
          switch (request.url.path) {
            case '/artist/example%20artist-all.nozomi':
              return http.Response.bytes(_ids([3333, 2222, 1111]), 200);
            case '/tag/landscape-all.nozomi':
              return http.Response.bytes(_ids([3333, 2222]), 200);
            case '/tag/sketch-all.nozomi':
              return http.Response.bytes(_ids([2222]), 200);
            case '/index-english.nozomi':
              return http.Response.bytes(_ids([3333]), 200);
            case '/galleries/3333.js':
              return http.Response(_gallery(3333), 200);
            case '/gg.js':
              return http.Response(_routing, 200);
          }
          fail('Unexpected request ${request.url}');
        }),
      );
      addTearDown(service.dispose);
      final items = await service.searchBooks(
        query:
            'artist:example_artist tag:landscape -tag:sketch language:english',
      );
      expect(items.map((item) => item.remoteId), [3333]);
      expect(paths, isNot(contains('/index-korean.nozomi')));
    });

    test('keyword lookup follows the SHA-256 binary index', () async {
      final node = ByteData(464);
      final key = sha256
          .convert(utf8.encode('landscape'))
          .bytes
          .take(4)
          .toList();
      node.setUint32(0, 1, Endian.big); // key count
      node.setUint32(4, 4, Endian.big); // key length
      for (var i = 0; i < 4; i++) {
        node.setUint8(8 + i, key[i]);
      }
      node.setUint32(12, 1, Endian.big); // location count
      node.setUint64(16, 512, Endian.big); // data offset
      node.setUint32(24, 8, Endian.big); // data length
      final service = CatalogService(
        client: MockClient((request) async {
          switch (request.url.path) {
            case '/galleriesindex/version':
              return http.Response('123456', 200);
            case '/galleriesindex/galleries.123456.index':
              expect(request.headers['range'], 'bytes=0-463');
              return _range(node.buffer.asUint8List());
            case '/galleriesindex/galleries.123456.data':
              expect(request.headers['range'], 'bytes=512-519');
              return _range(_ids([1, 1234]), start: 512, total: 1000);
            case '/galleries/1234.js':
              return http.Response(_gallery(1234), 200);
            case '/gg.js':
              return http.Response(_routing, 200);
          }
          fail('Unexpected request ${request.url}');
        }),
      );
      addTearDown(service.dispose);
      expect(
        (await service.searchBooks(
          query: 'landscape',
          language: 'all',
        )).single.remoteId,
        1234,
      );
    });

    test(
      'rejects corrupt ranges rather than showing an empty catalog',
      () async {
        final service = CatalogService(
          client: MockClient(
            (_) async => http.Response.bytes(
              _ids([1234]),
              206,
              headers: {'content-range': 'bytes 8-11/12'},
            ),
          ),
        );
        addTearDown(service.dispose);
        await expectLater(
          service.searchBooks(),
          throwsA(isA<CatalogException>()),
        );
      },
    );

    test(
      'does not evaluate modified or malformed metadata JavaScript',
      () async {
        final service = CatalogService(
          client: MockClient(
            (_) async => http.Response('${_gallery(1234)}alert(1);', 200),
          ),
        );
        addTearDown(service.dispose);
        await expectLater(
          service.gallery(1234),
          throwsA(isA<CatalogException>()),
        );
      },
    );
  });

  group('Booru catalogs', () {
    test(
      'legacy safe ratings, pagination, sort, URLs and duplicate IDs',
      () async {
        final service = CatalogService(
          client: MockClient((request) async {
            expect(request.url.path, '/index.php');
            expect(request.url.queryParameters['pid'], '2');
            expect(
              request.url.queryParameters['tags'],
              'landscape rating:safe sort:score:desc',
            );
            final row = {
              'id': '42',
              'tags': 'landscape blue_sky',
              'rating': 's',
              'score': '12',
              'file_url': '//cdn.example/full.png',
              'preview_url': '/thumb.png',
            };
            return http.Response(jsonEncode([row, row]), 200);
          }),
        );
        addTearDown(service.dispose);
        final item = (await service.searchImages(
          server: _safeServer,
          query: 'landscape rating:questionable',
          page: 2,
          popular: true,
        )).single;
        expect(item.rating, 'general');
        expect(item.id, 'safe:42');
        expect(item.tags, ['landscape', 'blue_sky']);
        expect(item.score, 12);
        expect(item.mediaUrls, ['https://cdn.example/full.png']);
        expect(item.thumbnailUrl, 'https://images.example/thumb.png');
        expect(
          item.sourceUrl,
          'https://images.example/index.php?page=post&s=view&id=42',
        );
      },
    );

    test('Danbooru uses one-based pages and modern general filter', () async {
      const server = BooruServer(
        id: 'dan',
        name: 'Dan',
        baseUrl: 'https://dan.example',
        engine: BooruEngine.danbooru,
      );
      final service = CatalogService(
        client: MockClient((request) async {
          expect(request.url.path, '/posts.json');
          expect(request.url.queryParameters['page'], '1');
          expect(
            request.url.queryParameters['tags'],
            'rating:general order:score',
          );
          return http.Response(
            jsonEncode([
              {
                'id': 1,
                'rating': 'g',
                'tag_string': 'landscape',
                'tag_string_artist': 'artist_one',
                'file_url': 'https://cdn.example/a.png',
              },
              {'id': 2, 'rating': 's', 'tag_string': 'landscape'},
            ]),
            200,
          );
        }),
      );
      addTearDown(service.dispose);
      final items = await service.searchImages(server: server, popular: true);
      expect(items, hasLength(1));
      expect(items.single.artists, ['artist_one']);
      expect(items.single.sourceUrl, 'https://dan.example/posts/1');
    });

    test('Gelbooru website uses modern rating semantics', () async {
      const server = BooruServer(
        id: 'gel',
        name: 'Gel',
        baseUrl: 'https://gelbooru.com',
        engine: BooruEngine.gelbooru,
      );
      final service = CatalogService(
        client: MockClient((request) async {
          expect(request.url.queryParameters['tags'], 'rating:sensitive');
          return http.Response(
            '{"post":[{"id":5,"rating":"s","file_url":"/image.png"}]}',
            200,
          );
        }),
      );
      addTearDown(service.dispose);
      expect(
        (await service.searchImages(
          server: server,
          rating: 'sensitive',
        )).single.rating,
        'sensitive',
      );
    });

    test('Moebooru one-based posts and tag API', () async {
      const server = BooruServer(
        id: 'moe',
        name: 'Moe',
        baseUrl: 'https://moe.example/base',
        engine: BooruEngine.moebooru,
      );
      final service = CatalogService(
        client: MockClient((request) async {
          if (request.url.path == '/base/tag.json') {
            expect(request.url.queryParameters['name'], 'land*');
            return http.Response('[{"name":"landscape"}]', 200);
          }
          expect(request.url.path, '/base/post.json');
          expect(request.url.queryParameters['page'], '3');
          return http.Response(
            '[{"id":42,"rating":"s","tags":"landscape","sample_url":"/sample.png"}]',
            200,
          );
        }),
      );
      addTearDown(service.dispose);
      expect(
        (await service.searchImages(server: server, page: 2)).single.sourceUrl,
        'https://moe.example/base/post/show/42',
      );
      expect(await service.suggestTags(server: server, query: 'land'), [
        'landscape',
      ]);
    });

    test('legacy XML attributes and path-based media are supported', () async {
      final service = CatalogService(
        client: MockClient(
          (_) async => http.Response(
            '<?xml version="1.0"?><posts count="1"><post id="42" rating="s" tags="landscape blue_sky" directory="12" image="abc.png" score="4"/></posts>',
            200,
          ),
        ),
      );
      addTearDown(service.dispose);
      final item = (await service.searchImages(server: _safeServer)).single;
      expect(item.mediaUrls, ['https://images.example/images/12/abc.png']);
      expect(
        item.thumbnailUrl,
        'https://images.example/thumbnails/12/thumbnail_abc.jpg',
      );
    });

    test('missing/restricted files remain honest and unsafe URL schemes are rejected', () async {
      final service = CatalogService(
        client: MockClient(
          (_) async => http.Response(
            '[{"id":42,"rating":"s","file_url":"javascript:alert(1)","preview_url":"https://user:pass@cdn.example/a.png"}]',
            200,
          ),
        ),
      );
      addTearDown(service.dispose);
      final item = (await service.searchImages(server: _safeServer)).single;
      expect(item.mediaUrls, isEmpty);
      expect(item.thumbnailUrl, isEmpty);
    });

    test('excluded tags filter results even if server ignores query', () async {
      const server = BooruServer(
        id: 'safe',
        name: 'Safe',
        baseUrl: 'https://images.example',
        engine: BooruEngine.gelbooru,
        excludedTags: ['sketch'],
      );
      final service = CatalogService(
        client: MockClient((request) async {
          expect(request.url.queryParameters['tags'], contains('-sketch'));
          return http.Response(
            '[{"id":1,"rating":"s","tags":"sketch"},{"id":2,"rating":"s","tags":"landscape"}]',
            200,
          );
        }),
      );
      addTearDown(service.dispose);
      expect((await service.searchImages(server: server)).single.remoteId, 2);
    });

    test(
      'filtered-out full image pages still have another server page',
      () async {
        const server = BooruServer(
          id: 'safe',
          name: 'Safe',
          baseUrl: 'https://images.example',
          engine: BooruEngine.gelbooru,
          excludedTags: ['sketch'],
        );
        final service = CatalogService(
          client: MockClient((request) async {
            final rows = request.url.queryParameters['pid'] == '0'
                ? List.generate(
                    CatalogService.imagePageSize,
                    (index) => {
                      'id': index + 1,
                      'rating': 's',
                      'tags': 'sketch',
                    },
                  )
                : <Map<String, Object>>[];
            return http.Response(jsonEncode(rows), 200);
          }),
        );
        addTearDown(service.dispose);
        final first = await service.imagePage(server: server);
        expect(first.items, isEmpty);
        expect(first.hasMore, isTrue);
        final last = await service.imagePage(server: server, page: 1);
        expect(last.items, isEmpty);
        expect(last.hasMore, isFalse);
      },
    );

    test('server error, browser challenges and malformed JSON are not empty results', () async {
      for (final response in [
        http.Response('busy', 429),
        http.Response('<html>Just a moment...</html>', 200),
        http.Response('{"success":false}', 200),
        http.Response('not json', 200),
      ]) {
        final service = CatalogService(
          client: MockClient((_) async => response),
        );
        await expectLater(
          service.searchImages(server: _safeServer),
          throwsA(isA<CatalogException>()),
        );
        service.dispose();
      }
    });

    test('rejects invalid configured URLs before contacting server', () async {
      final service = CatalogService(
        client: MockClient((_) async {
          fail('Must not send');
        }),
      );
      addTearDown(service.dispose);
      for (final baseUrl in [
        'file:///etc/test',
        'https://user:pass@images.example',
        'https://images.example?key=bad',
        'not-a-url',
      ]) {
        final server = BooruServer(
          id: 'test',
          name: 'Test',
          baseUrl: baseUrl,
          engine: BooruEngine.danbooru,
        );
        await expectLater(
          service.searchImages(server: server),
          throwsA(isA<CatalogException>()),
        );
      }
    });
  });
}
