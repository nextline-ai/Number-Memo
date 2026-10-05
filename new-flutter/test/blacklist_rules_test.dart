import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:number_memo/data/models.dart';
import 'package:number_memo/services/booru_blacklist.dart';
import 'package:number_memo/services/catalog_service.dart';

CatalogItem _post({
  List<String> tags = const ['mountain', 'scenery', 'sample_artist'],
  String rating = 'general',
  int? id = 101,
}) => CatalogItem(
  id: 'example:$id',
  mode: LibraryMode.images,
  title: 'Landscape fixture',
  sourceUrl: 'https://example.test/posts/$id',
  tags: tags,
  rating: rating,
  remoteId: id,
);

void main() {
  test('Native blacklist lines are OR and terms within a line are AND', () {
    final post = _post();
    expect(BooruBlacklist(['mountain\ncity']).contains(post), isTrue);
    expect(BooruBlacklist(['mountain', 'city']).contains(post), isTrue);
    expect(BooruBlacklist(['mountain city']).contains(post), isFalse);
    expect(BooruBlacklist(['mountain scenery']).contains(post), isTrue);
    expect(BooruBlacklist(['MOUNTAIN\tSCENERY']).contains(post), isTrue);
    expect(BooruBlacklist(['city\rmountain']).contains(post), isTrue);
    expect(BooruBlacklist(['city\u2028mountain']).contains(post), isTrue);
    expect(BooruBlacklist(['\n  # comment\n', '']).contains(post), isFalse);
    expect(BooruBlacklist(['mountain # inline']).contains(post), isFalse);
    expect(
      BooruBlacklist(['  MOUNTAIN  ']).contains(_post(tags: ['Mountain'])),
      isTrue,
    );
  });

  test('Minus negates one term rather than changing it to an excluded tag', () {
    final post = _post();
    expect(BooruBlacklist(['mountain -city']).contains(post), isTrue);
    expect(BooruBlacklist(['mountain -scenery']).contains(post), isFalse);
    expect(BooruBlacklist(['-mountain']).contains(post), isFalse);
    expect(BooruBlacklist(['-city']).contains(post), isTrue);
    expect(BooruBlacklist(['-sample_*']).contains(post), isFalse);
    expect(BooruBlacklist(['-*']).contains(_post(tags: [])), isTrue);
    expect(
      BooruBlacklist(['mountain -rating:general']).contains(post),
      isFalse,
    );
    expect(BooruBlacklist(['mountain -id:102']).contains(post), isTrue);
  });

  test('Only star is a wildcard and the whole tag must match', () {
    expect(BooruBlacklist(['sample_*']).contains(_post()), isTrue);
    expect(BooruBlacklist(['*artist']).contains(_post()), isTrue);
    expect(BooruBlacklist(['s*e_a*t']).contains(_post()), isTrue);
    expect(
      BooruBlacklist(['sample_*']).contains(_post(tags: ['sample_'])),
      isTrue,
    );
    expect(
      BooruBlacklist(['sample_*'])
          .contains(_post(tags: ['prefix_sample_artist'])),
      isFalse,
    );
    expect(BooruBlacklist(['sample_*']).contains(_post(tags: [])), isFalse);
    expect(
      BooruBlacklist(['tag_(x)*']).contains(_post(tags: ['tag_(x)_detail'])),
      isTrue,
    );
    expect(
      BooruBlacklist(['tag_(x)*']).contains(_post(tags: ['tag_x_detail'])),
      isFalse,
    );
    expect(
      BooruBlacklist(['a.b*']).contains(_post(tags: ['a.b_detail'])),
      isTrue,
    );
    expect(
      BooruBlacklist(['a.b*']).contains(_post(tags: ['a_b_detail'])),
      isFalse,
    );
    expect(
      BooruBlacklist(['sample_?']).contains(_post(tags: ['sample_a'])),
      isFalse,
    );
    expect(BooruBlacklist(['a**a*b']).contains(_post(tags: ['aaaab'])), isTrue);
    expect(BooruBlacklist(['a**a*b']).contains(_post(tags: ['aaaa'])), isFalse);
    // Imported rules must not cause regex backtracking explosions.
    expect(
      BooruBlacklist(['${List.filled(100, '*a').join()}b'])
          .contains(_post(tags: ['a' * 1000])),
      isFalse,
    );
  });

  test('Rating aliases and exact IDs match native behavior', () {
    for (final aliases in [
      ['general', 'safe', 'g'],
      ['sensitive', 's'],
      ['questionable', 'q'],
      ['explicit', 'e'],
    ]) {
      for (final rule in aliases) {
        for (final rating in aliases) {
          expect(
            BooruBlacklist(['rating:$rule']).contains(_post(rating: rating)),
            isTrue,
          );
        }
      }
    }
    expect(
      BooruBlacklist(['rating:s']).contains(_post(rating: 'general')),
      isFalse,
    );
    expect(BooruBlacklist(['rating:q']).contains(_post(rating: '')), isFalse);
    expect(BooruBlacklist(['id:101']).contains(_post()), isTrue);
    expect(BooruBlacklist(['id:0101']).contains(_post()), isFalse);
    expect(BooruBlacklist(['id:101']).contains(_post(id: null)), isFalse);
    expect(
      BooruBlacklist(['id:101 mountain -rating:e']).contains(_post()),
      isTrue,
    );
  });

  test('Only standalone plain positive tag rules are sent to servers', () {
    final blacklist = BooruBlacklist([
      'SKETCH\nlandscape',
      'sketch',
      'cat dog',
      '-cat',
      'cat -dog',
      'sample_*',
      'rating:general',
      'id:101',
      '# ignore',
      'sort:score',
      '~mountain',
      '{mountain}',
      'tag_(series)',
    ]);
    expect(blacklist.queryExclusions, [
      '-sketch',
      '-landscape',
      '-tag_(series)',
    ]);
  });

  test(
    'Booru search keeps query semantics and filters compound rules locally',
    () async {
      const server = BooruServer(
        id: 'example',
        name: 'Example',
        baseUrl: 'https://example.test',
        engine: BooruEngine.danbooru,
        excludedTags: [
          'SKETCH',
          'cat dog',
          'cat -garden',
          'sample_*',
          'rating:explicit',
          'id:7',
          '# comment',
        ],
      );
      final service = CatalogService(
        client: MockClient((request) async {
          expect(
            request.url.queryParameters['tags'],
            'landscape order:score -sketch',
          );
          return http.Response(
            jsonEncode([
              {'id': 1, 'tag_string': 'cat dog garden', 'rating': 'g'},
              {'id': 2, 'tag_string': 'cat garden', 'rating': 'g'},
              {'id': 3, 'tag_string': 'cat', 'rating': 'g'},
              {'id': 4, 'tag_string': 'sample_artist', 'rating': 'g'},
              {'id': 5, 'tag_string': 'garden', 'rating': 'e'},
              {'id': 6, 'tag_string': 'garden', 'rating': 'g'},
              {'id': 7, 'tag_string': 'garden', 'rating': 'g'},
              {'id': 8, 'tag_string': 'Sketch', 'rating': 'g'},
            ]),
            200,
          );
        }),
      );
      addTearDown(service.dispose);
      final items = await service.searchImages(
        server: server,
        query: 'landscape',
        popular: true,
        rating: 'all',
      );
      expect(items.map((item) => item.remoteId), [2, 6]);
    },
  );

  test('Negative-only rules never produce reversed server filters', () async {
    const server = BooruServer(
      id: 'example',
      name: 'Example',
      baseUrl: 'https://example.test',
      engine: BooruEngine.gelbooru,
      excludedTags: ['-garden'],
    );
    final service = CatalogService(
      client: MockClient((request) async {
        expect(request.url.queryParameters['tags'], 'landscape rating:safe');
        return http.Response(
          jsonEncode([
            {'id': 1, 'tags': 'garden', 'rating': 's'},
            {'id': 2, 'tags': 'mountain', 'rating': 's'},
          ]),
          200,
        );
      }),
    );
    addTearDown(service.dispose);
    expect(
      (await service.searchImages(
        server: server,
        query: 'landscape',
      )).single.remoteId,
      1,
    );
  });

  test('Legacy safe ratings normalize before blacklist matching', () async {
    for (final engine in BooruEngine.values) {
      final server = BooruServer(
        id: 'example',
        name: 'Example',
        baseUrl: 'https://example.test',
        engine: engine,
        excludedTags: const ['rating:general'],
      );
      final service = CatalogService(
        client: MockClient(
          (request) async =>
              http.Response('[{"id":1,"rating":"s","tags":"garden"}]', 200),
        ),
      );
      addTearDown(service.dispose);
      final result = await service.searchImages(server: server, rating: 'all');
      expect(result.isEmpty, engine != BooruEngine.danbooru);
    }
  });

  test('Unfamiliar rating tokens remain matchable without changing output normalization', () async {
    const server = BooruServer(
      id: 'example',
      name: 'Example',
      baseUrl: 'https://example.test',
      engine: BooruEngine.danbooru,
      excludedTags: ['rating:custom'],
    );
    final service = CatalogService(
      client: MockClient(
        (request) async => http.Response(
          '[{"id":1,"rating":"custom"},{"id":2,"rating":"unrated"}]',
          200,
        ),
      ),
    );
    addTearDown(service.dispose);
    final items = await service.searchImages(server: server, rating: 'all');
    expect(items.single.remoteId, 2);
    expect(items.single.rating, isEmpty);
  });

  test(
    'A full page hidden by compound rules still allows loading next page',
    () async {
      const server = BooruServer(
        id: 'example',
        name: 'Example',
        baseUrl: 'https://example.test',
        engine: BooruEngine.danbooru,
        excludedTags: ['mountain -garden'],
      );
      final service = CatalogService(
        client: MockClient(
          (request) async => http.Response(
            jsonEncode(
              List.generate(
                CatalogService.imagePageSize,
                (index) => {
                  'id': index + 1,
                  'rating': 'g',
                  'tag_string': 'mountain',
                },
              ),
            ),
            200,
          ),
        ),
      );
      addTearDown(service.dispose);
      final result = await service.imagePage(server: server);
      expect(result.items, isEmpty);
      expect(result.hasMore, isTrue);
    },
  );
}
