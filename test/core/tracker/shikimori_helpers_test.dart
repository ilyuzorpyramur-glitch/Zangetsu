import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/tracker/shikimori_service.dart';
import 'package:watch_app/core/tracker/tracker.dart';

// Shikimori is the one tracker whose anime ids are MAL ids, whose statuses are
// a single enum for both kinds, and whose images come back as site-relative
// paths. Each of those is a silent-wrong-data bug if it drifts, so the pure
// helpers behind them are pinned here rather than only exercised on a device.
void main() {
  group('request paths', () {
    test('catalogue paths are plural lowercase, target types capitalised', () {
      // Two spellings that must not be swapped: the resource in a URL path is
      // `/animes/…` + `/mangas/…`, a rate's target_type is `Anime`/`Manga`.
      expect(shikimoriCatalogueRoot(MediaKind.anime), 'animes');
      expect(shikimoriCatalogueRoot(MediaKind.manga), 'mangas');
      expect(shikimoriTargetType(MediaKind.anime), 'Anime');
      expect(shikimoriTargetType(MediaKind.manga), 'Manga');
      // Movies/series have no list here; they fall through to the anime root
      // rather than inventing a third resource.
      expect(shikimoriCatalogueRoot(MediaKind.movie), 'animes');
      expect(shikimoriCatalogueRoot(MediaKind.tv), 'animes');
    });

    test('progress field is episodes for anime, chapters for manga', () {
      expect(shikimoriProgressField(MediaKind.anime), 'episodes');
      expect(shikimoriProgressField(MediaKind.manga), 'chapters');
    });
  });

  group('statuses', () {
    test('every WatchStatus maps to a status the API accepts', () {
      // The five values Shikimori's rate resource documents. A sixth value
      // (`rewatching`) exists but is an input we never send.
      const allowed = {
        'watching',
        'planned',
        'completed',
        'on_hold',
        'dropped',
      };
      for (final s in WatchStatus.values) {
        expect(allowed, contains(shikimoriStatusFor(s)));
      }
      expect(shikimoriStatusFor(WatchStatus.paused), 'on_hold');
      expect(shikimoriStatusFor(WatchStatus.planning), 'planned');
    });

    test('reading them back is the inverse, with rewatching as watching', () {
      for (final s in WatchStatus.values) {
        expect(shikimoriWatchStatus(shikimoriStatusFor(s)), s);
      }
      expect(shikimoriWatchStatus('rewatching'), WatchStatus.watching);
      expect(shikimoriWatchStatus('nonsense'), isNull);
      expect(shikimoriWatchStatus(null), isNull);
    });

    test('manga uses the same status enum — no separate reading spelling', () {
      // Unlike MAL, Shikimori has no `reading`/`plan_to_read`: a manga entry
      // is `watching`. Sending MAL's spelling here would be rejected.
      expect(shikimoriStatusFor(WatchStatus.watching), isNot('reading'));
      expect(shikimoriStatusFor(WatchStatus.planning), isNot('plan_to_read'));
    });
  });

  group('catalogue entries', () {
    test('images: relative paths get the site root, absolute ones pass', () {
      expect(
        shikimoriImageUrl({
          'original': '/system/animes/original/52991.jpg?1710731127',
        }),
        'https://shikimori.io/system/animes/original/52991.jpg?1710731127',
      );
      expect(
        shikimoriImageUrl({'original': 'https://cdn.example/x.jpg'}),
        'https://cdn.example/x.jpg',
      );
      expect(shikimoriImageUrl(null), isNull);
      expect(shikimoriImageUrl({'original': ''}), isNull);
      // A missing size falls back to the next one that exists.
      expect(
        shikimoriImageUrl({'preview': '/p.jpg'}, size: 'x96'),
        'https://shikimori.io/p.jpg',
      );
    });

    test('total: zero episodes/chapters reads as null, not as zero', () {
      // Their API answers 0 for "still airing / unknown", and a 0 would make
      // the progress badge say "EP 4/0".
      expect(shikimoriTotal({'episodes': 28}, MediaKind.anime), 28);
      expect(shikimoriTotal({'episodes': 0}, MediaKind.anime), isNull);
      expect(shikimoriTotal({'episodes': null}, MediaKind.anime), isNull);
      expect(shikimoriTotal({'chapters': 120}, MediaKind.manga), 120);
      expect(shikimoriTotal({'chapters': 0}, MediaKind.manga), isNull);
      // An anime entry's chapters field must never answer a manga read.
      expect(shikimoriTotal({'episodes': 12}, MediaKind.manga), isNull);
    });

    test('light novels split out of the manga list', () {
      expect(shikimoriIsNovel('light_novel'), isTrue);
      expect(shikimoriIsNovel('novel'), isTrue);
      expect(shikimoriIsNovel('manga'), isFalse);
      expect(shikimoriIsNovel(null), isFalse);
      expect(
        shikimoriProviderType(MediaKind.manga, 'light_novel'),
        ProviderType.novel,
      );
      expect(
        shikimoriProviderType(MediaKind.manga, 'manhwa'),
        ProviderType.manga,
      );
      // Anime never becomes a novel, whatever kind the entry claims.
      expect(
        shikimoriProviderType(MediaKind.anime, 'light_novel'),
        ProviderType.anime,
      );
    });
  });

  group('site root', () {
    test('is the API base with its /api suffix removed', () {
      expect(shikimoriSite, 'https://shikimori.io');
    });
  });
}
