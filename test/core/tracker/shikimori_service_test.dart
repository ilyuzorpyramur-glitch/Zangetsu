import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/tracker/shikimori_service.dart';

/// Shapes taken from the live API on 2026-11-25: `user_rates` (which carries
/// no titles), the `?ids=` catalogue read (50 per call) and the rate write.
/// These pin the mapping that has no compile-time guard — a wrong field name
/// reads as "0 episodes watched" rather than failing.
Map<String, dynamic> _rate({
  required int id,
  required int targetId,
  String type = 'Anime',
  String status = 'watching',
  int episodes = 0,
  int chapters = 0,
  int score = 0,
}) => {
  'id': id,
  'user_id': 7,
  'target_id': targetId,
  'target_type': type,
  'score': score,
  'status': status,
  'rewatches': 0,
  'episodes': episodes,
  'volumes': 0,
  'chapters': chapters,
  'text': null,
  'created_at': '2026-01-01T00:00:00+00:00',
  'updated_at': '2026-02-03T04:05:06+00:00',
};

Map<String, dynamic> _entry({
  required int id,
  required String name,
  String? russian,
  int? episodes,
  int? chapters,
  String kind = 'tv',
}) => {
  'id': id,
  'name': name,
  'russian': russian,
  'image': {'original': '/system/animes/original/$id.jpg?1'},
  'url': '/animes/$id-$name',
  'kind': kind,
  'episodes': episodes,
  'chapters': chapters,
};

void main() {
  // The service listens for the OAuth redirect through app_links, which needs
  // a real binding (it opens a platform EventChannel) even in a unit test.
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late ShikimoriService service;

  /// Requests the service actually sent, in order — the write path is what
  /// this file is mostly about.
  late List<RequestOptions> sent;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('shikimori-test-');
    Hive.init(directory.path);
    final box = await Hive.openBox(ShikimoriService.boxName);
    await box.putAll({
      'accessToken': 'test-token',
      'refreshToken': 'test-refresh',
      // Far enough ahead that no test trips the refresh path (which needs the
      // build-time secret and would fail in a unit test by design).
      'expiresAt':
          DateTime.now().millisecondsSinceEpoch + 3600 * 1000,
      'viewerId': 7,
      'viewerName': 'tester',
    });

    sent = [];
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          sent.add(options);
          final path = options.uri.path;
          Object? data;

          // Note `/v2/user_rates` — the rates live UNDER v2 while the
          // catalogue does not. Getting that wrong is a 404, not a typo.
          if (path == '/api/v2/user_rates') {
            if (options.method == 'GET') {
              final targetType = options.queryParameters['target_type'];
              data = targetType == 'Manga'
                  ? [
                      _rate(
                        id: 90,
                        targetId: 13,
                        type: 'Manga',
                        status: 'completed',
                        chapters: 5,
                        score: 9,
                      ),
                    ]
                  : [
                      _rate(
                        id: 11,
                        targetId: 52991,
                        episodes: 3,
                        score: 8,
                      ),
                      _rate(
                        id: 12,
                        targetId: 20,
                        status: 'planned',
                        episodes: 0,
                      ),
                    ];
            } else {
              data = _rate(id: 11, targetId: 52991, episodes: 4);
            }
          } else if (path == '/api/animes' || path == '/api/mangas') {
            final ids = '${options.queryParameters['ids'] ?? ''}'
                .split(',')
                .where((e) => e.isNotEmpty)
                .map(int.parse)
                .toList();
            data = [
              for (final id in ids)
                if (path == '/api/animes')
                  _entry(
                    id: id,
                    name: 'Anime $id',
                    russian: 'Аниме $id',
                    episodes: id == 52991 ? 28 : 220,
                  )
                else
                  _entry(
                    id: id,
                    name: 'Novel $id',
                    russian: 'Новелла $id',
                    chapters: 120,
                    kind: 'light_novel',
                  ),
            ];
          } else if (path.startsWith('/api/animes/')) {
            // Single-entry read: `_meta`'s fallback when the cache is cold.
            final id = int.tryParse(path.split('/').last) ?? 0;
            data = _entry(
              id: id,
              name: 'Anime $id',
              russian: 'Аниме $id',
              episodes: 28,
            );
          } else if (path.startsWith('/api/v2/user_rates/')) {
            data = _rate(id: 11, targetId: 52991, episodes: 4);
          }

          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: data,
            ),
          );
        },
      ),
    );
    service = ShikimoriService(dio);
  });

  tearDown(() async {
    service.dispose();
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('library read maps rates + catalogue into list items', () async {
    final items = await service.fetchList();

    expect(items, hasLength(3));

    final frieren =
        items.singleWhere((i) => i.item.malId == 52991);
    // The id IS the MAL id — that is the whole reason this tracker is cheap.
    expect(frieren.item.id, 'tracker:shikimori:52991');
    expect(frieren.item.type, ProviderType.anime);
    expect(frieren.progress, 3);
    expect(frieren.totalEpisodes, 28);
    expect(frieren.score, 8);
    expect(frieren.status, WatchStatus.watching);
    // Covers come back site-relative and must be absolute by the time they
    // reach CachedNetworkImage.
    expect(
      frieren.item.cover,
      'https://shikimori.io/system/animes/original/52991.jpg?1',
    );
    expect(frieren.updatedAt, DateTime.parse('2026-02-03T04:05:06+00:00'));

    final planned = items.singleWhere((i) => i.item.malId == 20);
    expect(planned.status, WatchStatus.planning);
    expect(planned.score, isNull); // 0 means "not rated", not "rated zero"

    // Manga entries get their own id namespace, and a light novel is filed as
    // a novel so the reading tabs don't hide it.
    final novel = items.singleWhere((i) => i.item.malId == 13);
    expect(novel.item.id, 'tracker:shikimori:manga:13');
    expect(novel.item.type, ProviderType.novel);
    expect(novel.progress, 5);
    expect(novel.totalEpisodes, 120);
  });

  test('rates are read per kind, each with its own target_type', () async {
    await service.fetchList();
    final rateReads = sent.where(
      (o) => o.uri.path == '/api/v2/user_rates' && o.method == 'GET',
    );
    expect(
      rateReads.map((o) => o.queryParameters['target_type']).toSet(),
      {'Anime', 'Manga'},
    );
    // The user id comes from whoami and is the only filter that can't be
    // omitted — an unfiltered read is a 400 "Missing parameter user_id".
    expect(
      rateReads.every((o) => '${o.queryParameters['user_id']}' == '7'),
      isTrue,
    );
  });

  test('catalogue hydration asks for at most 50 ids per call', () async {
    await service.fetchList();
    final hydration = sent.where(
      (o) =>
          (o.uri.path == '/api/animes' || o.uri.path == '/api/mangas') &&
          o.queryParameters['ids'] != null,
    );
    expect(hydration, isNotEmpty);
    for (final call in hydration) {
      final ids = '${call.queryParameters['ids']}'.split(',');
      expect(ids.length, lessThanOrEqualTo(50));
    }
  });

  test('scrobble writes an absolute episode, not a guess', () async {
    await service.scrobble(malId: 52991, episode: 4);
    final writes = sent.where((o) => o.method != 'GET').toList();
    expect(writes, hasLength(1));
    final body = writes.single.data as Map;
    final rate = body['user_rate'] as Map;
    expect(rate['episodes'], 4);
    // Not the final episode (28), so the show stays "watching".
    expect(rate['status'], 'watching');
    // Never re-send a season: Shikimori models one entry per title.
    expect(rate.containsKey('season'), isFalse);
  });

  test('a scrobble at the last episode completes the entry', () async {
    await service.scrobble(malId: 52991, episode: 28);
    final body = (sent.lastWhere((o) => o.method != 'GET').data as Map);
    final rate = body['user_rate'] as Map;
    expect(rate['episodes'], 28);
    expect(rate['status'], 'completed');
  });

  test('scrobbling backwards is ignored, not written', () async {
    await service.scrobble(malId: 52991, episode: 5);
    final before = sent.where((o) => o.method != 'GET').length;
    await service.scrobble(malId: 52991, episode: 2);
    expect(sent.where((o) => o.method != 'GET').length, before);
  });

  test('an unknown title resolves to nothing instead of writing', () async {
    // No malId, and the mocked search returns the catalogue list — which has
    // no entry for this title, so the lookup finds nothing to write to.
    await service.scrobble(title: 'Nothing At All', episode: 1);
    expect(sent.where((o) => o.method != 'GET'), isEmpty);
  });
}
