import 'dart:async';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:watch_app/core/hive/safe_box.dart';

import '../app_config.dart';
import '../environment.dart';
import '../i18n/meta_ru.dart';
import '../models/media_item.dart';
import '../models/provider_info.dart';
import '../models/watch_status.dart';
import '../platform/apple_tv.dart';
import 'tracker.dart';

// ── Pure helpers (top-level so a test can pin them without a live API) ───────

/// The catalogue resource for [kind] in a URL path. Two different spellings
/// live next to each other on this API and swapping them is a silent 404:
/// the RESOURCE is plural lowercase (`/animes/52991`, `/mangas/2`), while a
/// rate's `target_type` field is capitalised singular (`Anime` / `Manga`).
String shikimoriCatalogueRoot(MediaKind kind) =>
    kind == MediaKind.manga ? 'mangas' : 'animes';

/// A rate's `target_type` for [kind] — capitalised, as the API expects it on
/// both read and write.
String shikimoriTargetType(MediaKind kind) =>
    kind == MediaKind.manga ? 'Manga' : 'Anime';

/// The rate field that carries progress for [kind]: `episodes` for anime,
/// `chapters` for manga/novels.
String shikimoriProgressField(MediaKind kind) =>
    kind == MediaKind.manga ? 'chapters' : 'episodes';

/// Shikimori's `kind` values that mean "a novel" rather than a comic. Their
/// manga catalogue files light novels as `light_novel` / `novel`, and there is
/// no separate list for them — the same split MAL needs.
bool shikimoriIsNovel(String? kind) =>
    kind == 'light_novel' || kind == 'novel';

/// Our [ProviderType] for a Shikimori catalogue entry.
ProviderType shikimoriProviderType(MediaKind kind, String? entryKind) {
  if (kind != MediaKind.manga) return ProviderType.anime;
  return shikimoriIsNovel(entryKind)
      ? ProviderType.novel
      : ProviderType.manga;
}

/// [WatchStatus] → Shikimori's rate status. Manga uses the SAME enum on their
/// side (`watching` covers reading), so there is no reading twin here.
String shikimoriStatusFor(WatchStatus s) => switch (s) {
  WatchStatus.watching => 'watching',
  WatchStatus.planning => 'planned',
  WatchStatus.completed => 'completed',
  WatchStatus.paused => 'on_hold',
  WatchStatus.dropped => 'dropped',
};

/// Shikimori's rate status → [WatchStatus] (null for values we don't know).
/// `rewatching` maps to watching: it is a watching state with a rewatch count,
/// which this app does not model.
WatchStatus? shikimoriWatchStatus(String? status) => switch (status) {
  'watching' || 'rewatching' => WatchStatus.watching,
  'planned' => WatchStatus.planning,
  'completed' => WatchStatus.completed,
  'on_hold' => WatchStatus.paused,
  'dropped' => WatchStatus.dropped,
  _ => null,
};

/// Site root (`https://shikimori.io`) — [Environment.shikimoriApi] plus its own
/// `/api` suffix removed, so the two can never drift apart.
String get shikimoriSite => Environment.shikimoriApi.endsWith('/api')
    ? Environment.shikimoriApi.substring(0, Environment.shikimoriApi.length - 4)
    : Environment.shikimoriApi;

/// Absolute URL for an image path Shikimori hands back relative
/// (`/system/animes/original/52991.jpg?1710731127`).
String? shikimoriImageUrl(Object? image, {String size = 'original'}) {
  if (image is! Map) return null;
  final path =
      (image[size] ?? image['original'] ?? image['preview']) as String?;
  if (path == null || path.isEmpty) return null;
  if (path.startsWith('http')) return path;
  return '$shikimoriSite$path';
}

/// A title as the app shows it: the Russian name in a Russian build (that is
/// the whole reason this tracker earns its first slot), the romaji otherwise.
String shikimoriTitle(Map entry) {
  final ru = (entry['russian'] as String?)?.trim() ?? '';
  final name = (entry['name'] as String?)?.trim() ?? '';
  final preferRu = MetaRu.isRussian;
  if (preferRu && ru.isNotEmpty) return ru;
  return name.isNotEmpty ? name : ru;
}

/// Total episodes (anime) or chapters (manga) from a catalogue entry. Zero
/// means "unknown / still airing" on this API and must read as null rather
/// than as "a zero-episode title".
int? shikimoriTotal(Map entry, MediaKind kind) {
  final raw = kind == MediaKind.manga
      ? (entry['chapters'] as num?)
      : (entry['episodes'] as num?);
  final n = raw?.toInt();
  return (n != null && n > 0) ? n : null;
}

/// Shikimori tracker. Anime ids ARE MAL ids (its whole catalogue is keyed by
/// them), so a title with a `malId` needs no lookup at all — the cheapest
/// resolution of any tracker here.
///
/// OAuth2 authorization code against their Doorkeeper app: the token exchange
/// needs the client secret, which arrives at build time through
/// [Environment.shikimoriClientSecret] (repo secrets — never in the tree).
/// Access tokens live 24 hours, so every request goes through [_validToken],
/// which refreshes on expiry and retries once on a 401 `invalid_token`.
///
/// Every request must carry a real `User-Agent` naming the app — Shikimori
/// bans the IP of a client that looks like a bot, including on `/oauth/token`.
class ShikimoriService extends ChangeNotifier implements Tracker {
  ShikimoriService(this._dio) {
    // app_links has no tvOS impl; TV connects trackers via phone QR pairing.
    if (isAppleTv) return;
    _linkSub = _appLinks.uriLinkStream.listen(_onLink, onError: (_) {});
    _appLinks
        .getInitialLink()
        .then((uri) {
          if (uri != null) _onLink(uri);
        })
        .catchError((_) {});
  }

  final Dio _dio;
  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSub;
  Completer<bool>? _pending;

  static const String boxName = 'shikimori';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) await openBoxSafely(boxName);
  }

  Box get _box => Hive.box(boxName);

  @override
  String get displayName => 'Shikimori';

  @override
  bool get supportsReading => true; // anime + manga (light novels included)

  /// False in a local `flutter run`, where the build-time secrets are absent:
  /// without a client id there is no OAuth app to authorize against, and a
  /// Connect button that can only fail is worse than one that isn't offered.
  bool get isConfigured =>
      Environment.shikimoriClientId.isNotEmpty &&
      Environment.shikimoriClientSecret.isNotEmpty;

  /// Deliberately NOT gated on [isConfigured]: a session relayed from the
  /// phone (the TV path) carries a working token even in a build without the
  /// OAuth secrets, and it stays usable until the 24-hour token lapses. Only
  /// the browser connect has to be refused there — see [connect].
  @override
  bool get isConnected =>
      (_box.get('accessToken') as String?)?.isNotEmpty == true &&
      _box.get('viewerName') != null;

  @override
  String? get viewerName => _box.get('viewerName') as String?;
  @override
  String? get viewerAvatar => _box.get('viewerAvatar') as String?;

  @override
  bool get autoSync => (_box.get('autoSync') as bool?) ?? true;
  @override
  set autoSync(bool value) {
    _box.put('autoSync', value);
    notifyListeners();
  }

  /// Shikimori bans IPs that talk to it without a product name, so this goes on
  /// every single call — the OAuth token endpoint included.
  static String get _userAgent => '$kAppName/$kAppVersion (Android; Flutter)';

  Options _opts({String? token, bool form = false}) => Options(
    headers: {
      'User-Agent': _userAgent,
      if (token != null) 'Authorization': 'Bearer $token',
    },
    contentType: form ? Headers.formUrlEncodedContentType : null,
    validateStatus: (s) => s != null && s < 500,
  );

  /// Last request time, so the batched hydration below stays under their
  /// 5 rps / 90 rpm budget instead of tripping a ban.
  DateTime _lastCall = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _minGap = Duration(milliseconds: 260);

  Future<void> _throttle() async {
    final since = DateTime.now().difference(_lastCall);
    if (since < _minGap) await Future<void>.delayed(_minGap - since);
    _lastCall = DateTime.now();
  }

  /// Their `Retry-After` in seconds, or a 2 s floor — Shikimori doesn't
  /// document one, so the floor is what actually runs.
  static Duration _retryAfter(Headers headers) {
    final raw = headers.value('retry-after');
    final secs = int.tryParse(raw ?? '');
    return Duration(seconds: (secs == null || secs <= 0) ? 2 : secs);
  }

  // ── OAuth (authorization code, client secret required) ─────────────────────

  String _randomString(int len) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    final r = Random.secure();
    return List.generate(len, (_) => chars[r.nextInt(chars.length)]).join();
  }

  @override
  Future<bool> connect() async {
    if (!isConfigured) return false;
    final state = _randomString(16);
    await _box.put('state', state);
    final url = Uri.parse(
      '${Environment.shikimoriAuthorizeUrl}'
      '?response_type=code'
      '&client_id=${Environment.shikimoriClientId}'
      '&redirect_uri=${Uri.encodeComponent(Environment.shikimoriRedirectUri)}'
      '&state=$state',
    );
    _pending = Completer<bool>();
    final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!ok) {
      _pending = null;
      return false;
    }
    try {
      return await _pending!.future.timeout(const Duration(minutes: 3));
    } catch (_) {
      _pending = null;
      return false;
    }
  }

  void _onLink(Uri uri) {
    if (uri.scheme != Environment.trackerRedirectScheme ||
        uri.host != Environment.shikimoriRedirectHost) {
      return;
    }
    unawaited(_handleRedirect(uri));
  }

  Future<void> _handleRedirect(Uri uri) async {
    final code = uri.queryParameters['code'];
    final state = uri.queryParameters['state'];
    final expected = _box.get('state') as String?;
    // A missing/foreign state means this redirect isn't ours (or the app was
    // killed mid-flow and the box lost it) — refuse rather than trade a code
    // that belongs to another session.
    if (code == null || code.isEmpty || (expected != null && state != expected)) {
      _resolvePending(false);
      return;
    }
    try {
      final res = await _dio.post<dynamic>(
        Environment.shikimoriTokenUrl,
        data: {
          'grant_type': 'authorization_code',
          'client_id': Environment.shikimoriClientId,
          'client_secret': Environment.shikimoriClientSecret,
          'code': code,
          'redirect_uri': Environment.shikimoriRedirectUri,
        },
        options: _opts(form: true),
      );
      if (!await _storeToken(res.data)) {
        _resolvePending(false);
        return;
      }
      await _fetchViewer();
      notifyListeners();
      _resolvePending(viewerName != null);
    } catch (_) {
      _resolvePending(false);
    }
  }

  void _resolvePending(bool ok) {
    final p = _pending;
    _pending = null;
    if (p != null && !p.isCompleted) p.complete(ok);
  }

  Future<bool> _storeToken(dynamic data) async {
    if (data is! Map) return false;
    final access = data['access_token'] as String?;
    if (access == null || access.isEmpty) return false;
    // 24 hours per the API; the fallback only matters if they ever omit it.
    final expiresIn = (data['expires_in'] as num?)?.toInt() ?? 86400;
    await _box.put('accessToken', access);
    await _box.put('refreshToken', data['refresh_token'] as String?);
    await _box.put(
      'expiresAt',
      DateTime.now().millisecondsSinceEpoch + expiresIn * 1000,
    );
    return true;
  }

  /// A valid access token, refreshing when expired. Null when disconnected or
  /// the refresh was refused.
  Future<String?> _validToken({bool forceRefresh = false}) async {
    final token = _box.get('accessToken') as String?;
    if (token == null || token.isEmpty) return null;
    final expiresAt = (_box.get('expiresAt') as int?) ?? 0;
    final fresh =
        DateTime.now().millisecondsSinceEpoch < expiresAt - 120000;
    if (fresh && !forceRefresh) return token;
    final refresh = _box.get('refreshToken') as String?;
    if (refresh == null || refresh.isEmpty) return fresh ? token : null;
    try {
      final res = await _dio.post<dynamic>(
        Environment.shikimoriTokenUrl,
        data: {
          'grant_type': 'refresh_token',
          'client_id': Environment.shikimoriClientId,
          'client_secret': Environment.shikimoriClientSecret,
          'refresh_token': refresh,
        },
        options: _opts(form: true),
      );
      if (await _storeToken(res.data)) {
        notifyListeners();
        return _box.get('accessToken') as String?;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _fetchViewer() async {
    final token = _box.get('accessToken') as String?;
    if (token == null) return;
    try {
      final res = await _dio.get<dynamic>(
        '${Environment.shikimoriApi}/users/whoami',
        options: _opts(token: token),
      );
      final d = res.data;
      // whoami answers `null` for an unauthenticated/token-less call instead
      // of a 401, so a map check IS the auth check here.
      if (d is Map && d['id'] != null) {
        await _box.put('viewerId', (d['id'] as num).toInt());
        await _box.put('viewerName', '${d['nickname'] ?? ''}');
        final avatar = shikimoriImageUrl(d['image'], size: 'x96');
        if (avatar != null) await _box.put('viewerAvatar', avatar);
      }
    } catch (_) {}
  }

  int? get _viewerId => (_box.get('viewerId') as num?)?.toInt();

  @override
  Future<void> disconnect() async {
    for (final k in const [
      'accessToken',
      'refreshToken',
      'expiresAt',
      'viewerId',
      'viewerName',
      'viewerAvatar',
      'state',
      'rateIds',
    ]) {
      await _box.delete(k);
    }
    notifyListeners();
  }

  // ── Low-level GET/POST with one 401 retry ──────────────────────────────────

  /// A GET that renews the token once when the server says it lapsed
  /// (`401 invalid_token`) — a 24-hour token means this path runs daily.
  Future<dynamic> _get(String path, {Map<String, dynamic>? query}) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final token = await _validToken(forceRefresh: attempt > 0);
      if (token == null) return null;
      await _throttle();
      try {
        final res = await _dio.get<dynamic>(
          path,
          queryParameters: query,
          options: _opts(token: token),
        );
        if (res.statusCode == 401 && attempt == 0) continue;
        // 429 is the library-sync throttle (90 requests a minute). Wait out
        // their Retry-After when they send one, else a short backoff, and try
        // the same call once more — one skipped page would silently truncate
        // the user's library.
        if (res.statusCode == 429 && attempt == 0) {
          await Future<void>.delayed(_retryAfter(res.headers));
          continue;
        }
        if (res.statusCode != null && res.statusCode! >= 400) return null;
        return res.data;
      } catch (_) {
        if (attempt == 0) continue;
        return null;
      }
    }
    return null;
  }

  Future<dynamic> _send(
    String method,
    String path, {
    Object? body,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final token = await _validToken(forceRefresh: attempt > 0);
      if (token == null) return null;
      await _throttle();
      try {
        final res = await _dio.request<dynamic>(
          path,
          data: body,
          options: _opts(token: token).copyWith(method: method),
        );
        if (res.statusCode == 401 && attempt == 0) continue;
        if (res.statusCode == 429 && attempt == 0) {
          await Future<void>.delayed(_retryAfter(res.headers));
          continue;
        }
        return res;
      } catch (_) {
        if (attempt == 0) continue;
        return null;
      }
    }
    return null;
  }

  // ── Catalogue metadata (id → title/cover/total), cached ────────────────────

  String _metaKey(MediaKind kind) =>
      kind == MediaKind.manga ? 'metaManga' : 'metaAnime';

  Map<String, dynamic> _metaMap(MediaKind kind) =>
      Map<String, dynamic>.from((_box.get(_metaKey(kind)) as Map?) ?? {});

  /// Cached catalogue entry for [id], if one was fetched already.
  Map? _cachedMeta(MediaKind kind, int id) {
    final raw = _metaMap(kind)['$id'];
    return raw is Map ? raw : null;
  }

  /// One Hive write per BATCH, not per title: the map holds every cached
  /// entry, so putting it after each of a 600-title library's entries would
  /// rewrite the same growing blob 600 times (tens of MB of churn on a TV's
  /// flash for one refresh).
  Future<void> _putMetaMany(MediaKind kind, List<Map> entries) async {
    if (entries.isEmpty) return;
    final m = _metaMap(kind);
    for (final entry in entries) {
      final id = (entry['id'] as num?)?.toInt();
      if (id == null) continue;
      m['$id'] = {
        'title': shikimoriTitle(entry),
        'cover': shikimoriImageUrl(entry['image']),
        'total': shikimoriTotal(entry, kind),
        'kind': entry['kind'],
        // Their site path (`/animes/52991-sousou-no-frieren`), for "Open in
        // browser" in the sync sheet.
        'slug': '${entry['url'] ?? ''}',
      };
    }
    await _box.put(_metaKey(kind), m);
  }

  Future<void> _putMeta(MediaKind kind, int id, Map entry) =>
      _putMetaMany(kind, [entry]);

  /// One catalogue entry, from cache or the network (`/animes/{id}`).
  Future<Map?> _meta(MediaKind kind, int id) async {
    final cached = _cachedMeta(kind, id);
    if (cached != null) return cached;
    final data = await _get(
      '${Environment.shikimoriApi}/${shikimoriCatalogueRoot(kind)}/$id',
    );
    if (data is Map) {
      await _putMeta(kind, id, data);
      return _cachedMeta(kind, id);
    }
    return null;
  }

  /// Batched hydration for [ids] — Shikimori's `user_rates` carries no titles,
  /// so a full library needs the catalogue read back. 50 ids per request is
  /// their documented cap; the cache makes this a one-time cost per title.
  Future<void> _hydrate(MediaKind kind, Iterable<int> ids) async {
    final wanted = [
      for (final id in ids)
        if (_cachedMeta(kind, id) == null) id,
    ];
    if (wanted.isEmpty) return;
    final root = shikimoriCatalogueRoot(kind);
    for (var i = 0; i < wanted.length; i += 50) {
      final chunk = wanted.sublist(i, min(i + 50, wanted.length));
      final data = await _get(
        '${Environment.shikimoriApi}/$root',
        query: {'ids': chunk.join(','), 'limit': 50},
      );
      if (data is List) {
        await _putMetaMany(kind, data.whereType<Map>().toList());
      }
    }
  }

  // ── Rate (the user's entry) lookups ────────────────────────────────────────

  /// `target_type:target_id` → rate id, for the entries this device has seen.
  /// Saves a round trip per write; a miss falls back to one filtered GET.
  String _rateKey(MediaKind kind, int id) =>
      '${shikimoriTargetType(kind)}:$id';

  Map<String, dynamic> get _rateIds => Map<String, dynamic>.from(
    (_box.get('rateIds') as Map?) ?? {},
  );

  Future<void> _rememberRate(MediaKind kind, int id, int? rateId) async {
    final m = _rateIds;
    if (rateId == null) {
      m.remove(_rateKey(kind, id));
    } else {
      m[_rateKey(kind, id)] = rateId;
    }
    await _box.put('rateIds', m);
  }

  /// Same batching reason as [_putMetaMany]: a library read learns one rate id
  /// per row, and putting the box per row is what turns a 600-title refresh
  /// into 600 full rewrites.
  Future<void> _rememberRates(Map<String, int> rates) async {
    if (rates.isEmpty) return;
    final m = _rateIds;
    m.addAll(rates);
    await _box.put('rateIds', m);
  }

  /// The user's rate row for one title, or null when it isn't on their list.
  Future<Map?> _rate(MediaKind kind, int id) async {
    final me = _viewerId;
    if (me == null) return null;
    final data = await _get(
      '${Environment.shikimoriApi}/v2/user_rates',
      query: {
        'user_id': me,
        'target_id': id,
        'target_type': shikimoriTargetType(kind),
        'limit': 1,
      },
    );
    if (data is! List || data.isEmpty) return null;
    final row = data.first;
    if (row is! Map) return null;
    final rateId = (row['id'] as num?)?.toInt();
    if (rateId != null) await _rememberRate(kind, id, rateId);
    return row;
  }

  /// Rate id for [id] — cache first, one GET on a miss.
  Future<int?> _rateId(MediaKind kind, int id) async {
    final cached = _rateIds[_rateKey(kind, id)];
    if (cached is int) return cached;
    final row = await _rate(kind, id);
    return (row?['id'] as num?)?.toInt();
  }

  /// Writes [fields] to the user's entry for [id], creating the entry when it
  /// doesn't exist yet (Shikimori has no upsert: POST creates, PATCH updates).
  Future<bool> _write(
    MediaKind kind,
    int id,
    Map<String, dynamic> fields,
  ) async {
    final existing = await _rateId(kind, id);
    if (existing != null) {
      final res = await _send(
        'PATCH',
        '${Environment.shikimoriApi}/v2/user_rates/$existing',
        body: {'user_rate': fields},
      );
      return res != null && (res.statusCode ?? 500) < 300;
    }
    final res = await _send(
      'POST',
      '${Environment.shikimoriApi}/v2/user_rates',
      body: {
        'user_rate': {
          'target_id': id,
          'target_type': shikimoriTargetType(kind),
          // A create without a status is refused, and a score-only edit would
          // otherwise arrive as one. `planned` is the API's own default.
          'status': shikimoriStatusFor(WatchStatus.planning),
          ...fields,
        },
      },
    );
    if (res == null || (res.statusCode ?? 500) >= 300) return false;
    final body = res.data;
    if (body is Map) {
      final rateId = (body['id'] as num?)?.toInt();
      if (rateId != null) await _rememberRate(kind, id, rateId);
    }
    return true;
  }

  // ── Title resolution ───────────────────────────────────────────────────────

  /// Title search → its Shikimori/MAL id, cached per kind. Shikimori's id IS
  /// the MAL id, so this is only a fallback for titles that arrive without one.
  Future<int?> _resolveByTitle(String? title, MediaKind kind) async {
    if (title == null || title.trim().isEmpty) return null;
    final key = 'title${kind == MediaKind.manga ? 'Manga' : 'Anime'}';
    final cache = Map<String, dynamic>.from((_box.get(key) as Map?) ?? {});
    final needle = title.trim().toLowerCase();
    final cached = cache[needle];
    if (cached is int) return cached;
    final data = await _get(
      '${Environment.shikimoriApi}/${shikimoriCatalogueRoot(kind)}',
      query: {'search': title.trim(), 'limit': 1},
    );
    if (data is! List || data.isEmpty) return null;
    final first = data.first;
    if (first is! Map) return null;
    final id = (first['id'] as num?)?.toInt();
    if (id == null) return null;
    await _putMeta(kind, id, first);
    cache[needle] = id;
    await _box.put(key, cache);
    return id;
  }

  /// `{id, total}` for a title — the pinned id wins, then the MAL id (free:
  /// same numbering), then a title search.
  Future<({int id, int? total})?> _resolve(
    MediaKind kind,
    int? malId,
    String? title, {
    String? pinnedId,
  }) async {
    final pinned = int.tryParse(pinnedId ?? '');
    final id = pinned ?? malId ?? await _resolveByTitle(title, kind);
    if (id == null) return null;
    final meta = await _meta(kind, id);
    return (id: id, total: (meta?['total'] as num?)?.toInt());
  }

  /// Remembers our own progress write, so [scrobble] can use the cheap
  /// `increment` call when it is provably the next episode and an absolute
  /// PATCH otherwise.
  Future<void> _setLocalProgress(MediaKind kind, int id, int value) async {
    final key = 'progress${kind == MediaKind.manga ? 'Manga' : 'Anime'}';
    final m = Map<String, dynamic>.from((_box.get(key) as Map?) ?? {});
    m['$id'] = value;
    await _box.put(key, m);
  }

  int _localProgress(MediaKind kind, int id) {
    final key = 'progress${kind == MediaKind.manga ? 'Manga' : 'Anime'}';
    final v = ((_box.get(key) as Map?) ?? const {})['$id'];
    return v is num ? v.toInt() : 0;
  }

  // ── Tracker writes ─────────────────────────────────────────────────────────

  @override
  Future<void> markWatching({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    MediaKind kind = MediaKind.anime,
  }) async {
    if (!isConnected || !autoSync) return;
    final a = await _resolve(kind, malId, title);
    if (a == null) return;
    final total = a.total;
    if (total != null && _localProgress(kind, a.id) >= total) return;
    // The entry is already on the list and was put in `watching` by us (that
    // is what put its rate id in this cache) — nothing to say, and playback
    // start is the worst moment to spend two requests on it. This also leaves
    // a title the user later marked completed alone, which is the point.
    if (_rateIds[_rateKey(kind, a.id)] is int) return;
    // First sight of this title: a finished/dropped entry must not be dragged
    // back to watching by the next thing the user opens.
    final current = (await _rate(kind, a.id))?['status'] as String?;
    if (current != null && current != 'planned') return;
    await _write(kind, a.id, {
      'status': shikimoriStatusFor(WatchStatus.watching),
    });
  }

  @override
  Future<void> scrobble({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    required int episode,
    int? season, // seasons are separate entries on Shikimori — unused
    int? seasonEpisode,
    MediaKind kind = MediaKind.anime,
    bool novel = false,
  }) async {
    if (!isConnected || !autoSync || episode <= 0) return;
    final a = await _resolve(kind, malId, title);
    if (a == null) return;
    if (episode <= _localProgress(kind, a.id)) return; // never go backwards
    var ep = episode;
    final total = a.total;
    if (total != null && ep > total) ep = total;
    final completed = total != null && ep >= total;

    // Cheap path: their `increment` endpoint advances by exactly one, which is
    // what a "next episode" scrobble means. Only take it when our own last
    // write proves it lands on the right number — otherwise an absolute PATCH
    // (idempotent, no read-modify-write) is the safe answer.
    final rateId = await _rateId(kind, a.id);
    final canIncrement =
        rateId != null && !completed && _localProgress(kind, a.id) == ep - 1;
    if (canIncrement) {
      final res = await _send(
        'POST',
        '${Environment.shikimoriApi}/v2/user_rates/$rateId/increment',
      );
      if (res != null && (res.statusCode ?? 500) < 300) {
        await _setLocalProgress(kind, a.id, ep);
        return;
      }
    }
    final ok = await _write(kind, a.id, {
      shikimoriProgressField(kind): ep,
      'status': shikimoriStatusFor(
        completed ? WatchStatus.completed : WatchStatus.watching,
      ),
    });
    if (ok) await _setLocalProgress(kind, a.id, ep);
  }

  @override
  Future<void> setStatus({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    required WatchStatus status,
    MediaKind kind = MediaKind.anime,
  }) async {
    if (!isConnected) return;
    final a = await _resolve(kind, malId, title);
    if (a == null) return;
    final fields = <String, dynamic>{'status': shikimoriStatusFor(status)};
    // "Completed" on Shikimori is a status, but their own UI also expects the
    // count to match the total; writing it here is what makes the two agree.
    if (status == WatchStatus.completed && a.total != null && a.total! > 0) {
      fields[shikimoriProgressField(kind)] = a.total;
      await _setLocalProgress(kind, a.id, a.total!);
    }
    await _write(kind, a.id, fields);
  }

  @override
  Future<void> removeFromList({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    String? pinnedId,
    MediaKind kind = MediaKind.anime,
  }) async {
    if (!isConnected) return;
    // Pinned id first: a corrected match must delete the corrected entry, not
    // the one the app originally guessed (same precedence as MAL/AniList).
    final a = await _resolve(kind, malId, title, pinnedId: pinnedId);
    if (a == null) return;
    final rateId = await _rateId(kind, a.id);
    if (rateId == null) return;
    final res = await _send(
      'DELETE',
      '${Environment.shikimoriApi}/v2/user_rates/$rateId',
    );
    if (res != null && (res.statusCode ?? 500) < 300) {
      await _rememberRate(kind, a.id, null);
      await _setLocalProgress(kind, a.id, 0);
    }
  }

  /// The title's page on shikimori.io: their own `url` when the catalogue
  /// entry carried one, else the by-id path (which redirects).
  static String _entryUrl(MediaKind kind, int id, Map? meta) {
    final slug = '${meta?['slug'] ?? ''}';
    if (slug.startsWith('/')) return '$shikimoriSite$slug';
    return '$shikimoriSite/${shikimoriCatalogueRoot(kind)}/$id';
  }

  // ── Tracker reads ──────────────────────────────────────────────────────────

  /// The user's whole library: one `user_rates` read per kind, then titles and
  /// covers hydrated in batches (cached on disk, so it is one-time per title).
  /// Best-effort — `[]` on any error, never throws.
  @override
  Future<List<TrackerListItem>> fetchList() async {
    if (!isConnected) return const [];
    final me = _viewerId;
    if (me == null) return const [];
    final both = await Future.wait([
      _fetchListOf(MediaKind.anime, me),
      _fetchListOf(MediaKind.manga, me),
    ]);
    return [...both[0], ...both[1]];
  }

  Future<List<TrackerListItem>> _fetchListOf(MediaKind kind, int me) async {
    final rows = <Map>[];
    for (var page = 1; page <= 10; page++) {
      final data = await _get(
        '${Environment.shikimoriApi}/v2/user_rates',
        query: {
          'user_id': me,
          'target_type': shikimoriTargetType(kind),
          'limit': 1000,
          'page': page,
        },
      );
      if (data is! List) break;
      rows.addAll(data.whereType<Map>());
      if (data.length < 1000) break;
    }
    if (rows.isEmpty) return const [];

    final ids = [
      for (final r in rows)
        if ((r['target_id'] as num?)?.toInt() != null)
          (r['target_id'] as num).toInt(),
    ];
    await _hydrate(kind, ids);

    final out = <TrackerListItem>[];
    final rateIds = <String, int>{};
    for (final r in rows) {
      final id = (r['target_id'] as num?)?.toInt();
      final status = shikimoriWatchStatus(r['status'] as String?);
      if (id == null || status == null) continue;
      final rateId = (r['id'] as num?)?.toInt();
      if (rateId != null) rateIds[_rateKey(kind, id)] = rateId;
      final meta = _cachedMeta(kind, id);
      final score = (r['score'] as num?)?.toDouble();
      out.add(
        TrackerListItem(
          updatedAt: DateTime.tryParse('${r['updated_at'] ?? ''}'),
          item: MediaItem(
            // Reading kinds get their own namespace: Shikimori's anime and
            // manga id spaces overlap, so `tracker:shikimori:21` would
            // otherwise name two different titles.
            id: kind == MediaKind.manga
                ? 'tracker:shikimori:manga:$id'
                : 'tracker:shikimori:$id',
            title: '${meta?['title'] ?? ''}',
            cover: meta?['cover'] as String?,
            type: shikimoriProviderType(kind, meta?['kind'] as String?),
            malId: id,
            url: '',
            sourceId: '',
          ),
          status: status,
          progress: (r[shikimoriProgressField(kind)] as num?)?.toInt(),
          score: (score != null && score > 0) ? score : null,
          totalEpisodes: (meta?['total'] as num?)?.toInt(),
        ),
      );
    }
    await _rememberRates(rateIds);
    return out;
  }

  // ── Single-entry read/write + search (sync sheet + match-fixer) ─────────────

  @override
  Future<TrackerEntry?> fetchEntry({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    String? pinnedId,
    MediaKind kind = MediaKind.anime,
    bool novel = false, // Shikimori's manga search has no format filter
  }) async {
    if (!isConnected) return null;
    final a = await _resolve(kind, malId, title, pinnedId: pinnedId);
    if (a == null) return null;
    final rate = await _rate(kind, a.id);
    final meta = await _meta(kind, a.id);
    final reading = kind == MediaKind.manga;
    final total = a.total;
    final score = (rate?['score'] as num?)?.toDouble();
    return TrackerEntry(
      trackerName: displayName,
      onList: rate != null,
      url: _entryUrl(kind, a.id, meta),
      title: (meta?['title'] as String?)?.trim(),
      status: shikimoriWatchStatus(rate?['status'] as String?),
      score: (score == null || score == 0) ? null : score,
      progress: (rate?[shikimoriProgressField(kind)] as num?)?.toInt(),
      maxEpisodes: reading ? null : total,
      chapters: reading ? total : null,
    );
  }

  @override
  Future<void> updateEntry({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    String? pinnedId,
    WatchStatus? status,
    double? score,
    int? progress,
    bool? isPrivate,
    MediaKind kind = MediaKind.anime,
  }) async {
    if (!isConnected) return;
    final a = await _resolve(kind, malId, title, pinnedId: pinnedId);
    if (a == null) return;
    final fields = <String, dynamic>{};
    if (status != null) fields['status'] = shikimoriStatusFor(status);
    // Shikimori's score is an integer 0–10 and 0 means "no score" — the sheet
    // offers halves, so round, and let 0 clear the rating the way their UI does.
    if (score != null) fields['score'] = score.round().clamp(0, 10);
    if (progress != null) fields[shikimoriProgressField(kind)] = progress;
    if (fields.isEmpty) return;
    final ok = await _write(kind, a.id, fields);
    if (ok && progress != null) await _setLocalProgress(kind, a.id, progress);
  }

  @override
  Future<List<TrackerSearchResult>> searchEntries(
    String query, {
    MediaKind kind = MediaKind.anime,
  }) async {
    // Shikimori indexes anime and manga only — a movie/TV query answered from
    // its anime catalogue would be confident nonsense.
    if (kind == MediaKind.movie || kind == MediaKind.tv) return const [];
    if (query.trim().isEmpty) return const [];
    final data = await _get(
      '${Environment.shikimoriApi}/${shikimoriCatalogueRoot(kind)}',
      query: {'search': query.trim(), 'limit': 12},
    );
    if (data is! List) return const [];
    final out = <TrackerSearchResult>[];
    for (final e in data) {
      if (e is! Map) continue;
      final id = (e['id'] as num?)?.toInt();
      if (id == null) continue;
      await _putMeta(kind, id, e);
      final kindName = (e['kind'] as String?);
      final year = '${e['aired_on'] ?? ''}'.split('-').first;
      final parts = [
        if (kindName != null && kindName.isNotEmpty)
          kindName.replaceAll('_', ' ').toUpperCase(),
        if (year.length == 4) year,
      ];
      out.add(
        TrackerSearchResult(
          trackerName: displayName,
          id: '$id',
          title: shikimoriTitle(e),
          cover: shikimoriImageUrl(e['image']),
          subtitle: parts.isEmpty ? null : parts.join(' · '),
          maxEpisodes: shikimoriTotal(e, kind),
        ),
      );
    }
    return out;
  }

  // ── Session export/import (TV relay) ───────────────────────────────────────

  @override
  Map<String, dynamic>? exportSession() {
    if (!isConnected) return null;
    return {
      'accessToken': _box.get('accessToken'),
      'refreshToken': _box.get('refreshToken'),
      'expiresAt': _box.get('expiresAt'),
      'viewerId': _box.get('viewerId'),
      'viewerName': _box.get('viewerName'),
      'viewerAvatar': _box.get('viewerAvatar'),
    };
  }

  @override
  Future<void> importSession(Map<String, dynamic> s) async {
    await _box.put('accessToken', s['accessToken']);
    await _box.put('refreshToken', s['refreshToken']);
    await _box.put('expiresAt', s['expiresAt']);
    await _box.put('viewerId', s['viewerId']);
    await _box.put('viewerName', s['viewerName']);
    await _box.put('viewerAvatar', s['viewerAvatar']);
    notifyListeners();
  }

  @override
  void dispose() {
    _linkSub?.cancel();
    super.dispose();
  }
}
