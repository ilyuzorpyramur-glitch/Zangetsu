import 'dart:async';
import 'dart:collection';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';

import '../metadata/tmdb.dart';

/// Russian titles for catalogue titles that come from English-language
/// metadata (AniList / MAL / TMDB / Simkl all answer in English).
///
/// The source of truth is Shikimori — its public API carries the official
/// Russian name of every anime — with TMDB's `ru-RU` search as the fallback
/// for films and series. Everything is cached on disk, so a title is looked
/// up once per install and shows up in Russian from then on.
///
/// Lookups happen in the background: [display] is synchronous and answers from
/// the cache (falling back to the original title), [request] queues a miss.
/// Listeners are notified when new translations land.
class TitleRu extends ChangeNotifier {
  TitleRu._();

  static final TitleRu instance = TitleRu._();

  static const String boxName = 'title_ru';
  static const String _shikimoriBase = 'https://shikimori.io';
  static const String _tmdbBase = 'https://${Tmdb.host}/3';

  /// Shikimori asks for <= 5 rps and <= 90 rpm; three slots with a gap keeps a
  /// cold home row (~120 titles) inside that even when it fires at once.
  static const int _maxConcurrent = 1;
  static const Duration _slotGap = Duration(milliseconds: 800);
  static const Duration _rateLimitPause = Duration(seconds: 20);
  static const Duration _requestTimeout = Duration(seconds: 9);

  static final RegExp _cyrillic = RegExp('[А-Яа-яЁё]');
  static final RegExp _latin = RegExp('[A-Za-z]');

  final Dio _dio = Dio();
  Box<dynamic>? _box;
  final Map<String, String> _cache = {};
  final Set<String> _queued = {};
  final Set<String> _failed = {};
  final Queue<_TitleJob> _jobs = Queue<_TitleJob>();
  /// Films/series don't touch Shikimori, so their lookups (TMDB only) run on a
  /// faster lane instead of waiting behind a throttled anime queue.
  final Queue<_TitleJob> _fastJobs = Queue<_TitleJob>();
  int _fastRunning = 0;
  static const int _fastConcurrent = 3;
  int _shikiStrikes = 0;
  DateTime _shikiOffUntil = DateTime.fromMillisecondsSinceEpoch(0);

  int _running = 0;
  DateTime _lastStart = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _blockedUntil = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _notifyTimer;
  bool _notifyPending = false;
  bool _ready = false;

  bool get isReady => _ready;
  int get knownCount => _cache.length;

  Future<void> init() async {
    try {
      _box = Hive.isBoxOpen(boxName)
          ? Hive.box(boxName)
          : await Hive.openBox(boxName);
      for (final key in _box!.keys) {
        final value = _box!.get(key);
        if (value is String) _cache['$key'] = value;
      }
    } catch (e) {
      debugPrint('[title-ru] cache unavailable: $e');
    }
    _ready = true;
  }

  String _key(String title) => title.trim().toLowerCase();

  /// Cached Russian title, or [title] itself when none is known yet.
  String display(String title) => _cache[_key(title)] ?? title;

  /// Whether a lookup for [title] has already been answered (a known Russian
  /// name, or a known "none").
  bool has(String title) => _cache.containsKey(_key(title));

  bool get isOn => true;

  /// Queue a lookup for [title]. Safe to call from `build` — it only enqueues
  /// and returns immediately.
  void request(String title, {int? year, bool anime = true}) {
    if (!_ready) return;
    final t = title.trim();
    if (t.length < 2 || t.length > 120) return;
    if (!_latin.hasMatch(t) && !_cyrillic.hasMatch(t)) return;
    if (_cyrillic.hasMatch(t)) {
      // Already Russian — nothing to do, but remember it so the row above
      // stops asking.
      final k = _key(t);
      if (!_cache.containsKey(k)) {
        _cache[k] = t;
        _box?.put(k, t);
      }
      return;
    }
    final k = _key(t);
    if (_cache.containsKey(k) || _queued.contains(k) || _failed.contains(k)) {
      return;
    }
    _queued.add(k);
    if (anime) {
      _jobs.add(_TitleJob(t, year, true));
      _scheduleDrain();
    } else {
      _fastJobs.add(_TitleJob(t, year, false));
      _drainFast();
    }
  }

  /// Look [title] up right now and return the Russian name (null when nothing
  /// convincing was found). Used by callers that can await, e.g. the detail
  /// screen's first paint.
  Future<String?> resolveNow(String title, {int? year, bool anime = true}) async {
    if (!_ready) return null;
    final t = title.trim();
    if (t.isEmpty) return null;
    final cached = _cache[_key(t)];
    if (cached != null) return cached.isEmpty ? null : cached;
    final found = await _lookup(t, year: year, anime: anime);
    _store(t, found);
    return found;
  }

  void _drainFast() {
    if (!_ready) return;
    while (_fastRunning < _fastConcurrent && _fastJobs.isNotEmpty) {
      final job = _fastJobs.removeFirst();
      _fastRunning++;
      unawaited(() async {
        try {
          final found = await _lookupTmdb(job.title, year: job.year);
          _store(job.title, found);
        } catch (e) {
          _failed.add(_key(job.title));
          debugPrint('[title-ru] "${job.title}" failed: $e');
        } finally {
          _queued.remove(_key(job.title));
          _fastRunning--;
          _drainFast();
        }
      }());
    }
  }

  void _scheduleDrain() {
    if (_running >= _maxConcurrent) return;
    if (_jobs.isEmpty) return;
    final now = DateTime.now();
    if (now.isBefore(_blockedUntil)) {
      Timer(_blockedUntil.difference(now), _drain);
      return;
    }
    final since = now.difference(_lastStart);
    final wait = since < _slotGap ? _slotGap - since : Duration.zero;
    if (wait == Duration.zero) {
      _drain();
    } else {
      Timer(wait, _drain);
    }
  }

  void _drain() {
    if (!_ready) return;
    if (DateTime.now().isBefore(_blockedUntil)) {
      Timer(_blockedUntil.difference(DateTime.now()), _drain);
      return;
    }
    while (_running < _maxConcurrent && _jobs.isNotEmpty) {
      final job = _jobs.removeFirst();
      _running++;
      _lastStart = DateTime.now();
      unawaited(_runJob(job));
      return _scheduleDrain();
    }
  }

  Future<void> _runJob(_TitleJob job) async {
    try {
      final found = await _lookup(job.title, year: job.year, anime: job.anime);
      _store(job.title, found);
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 429 && job.attempts < 3) {
        // Shikimori throttles hard (and the whole flat may share one exit IP):
        // back off for everyone and put this job back at the front.
        _blockedUntil = DateTime.now().add(_rateLimitPause);
        _queued.remove(_key(job.title));
        _jobs.addFirst(_TitleJob(job.title, job.year, job.anime, job.attempts + 1));
        debugPrint('[title-ru] 429 on "${job.title}" — pausing lookups');
      } else {
        _failed.add(_key(job.title));
        debugPrint('[title-ru] "${job.title}" failed: ${e.message}');
      }
    } catch (e) {
      _failed.add(_key(job.title));
      debugPrint('[title-ru] "${job.title}" failed: $e');
    } finally {
      _queued.remove(_key(job.title));
      _running--;
      _scheduleDrain();
    }
  }

  void _store(String original, String? russian) {
    final k = _key(original);
    final value = russian ?? '';
    if (_cache[k] == value) return;
    _cache[k] = value;
    unawaited(_box?.put(k, value) ?? Future<void>.value());
    _notifySoon();
  }

  void _notifySoon() {
    if (_notifyPending) return;
    _notifyPending = true;
    _notifyTimer?.cancel();
    _notifyTimer = Timer(const Duration(milliseconds: 600), () {
      _notifyPending = false;
      if (!_disposed) notifyListeners();
    });
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _notifyTimer?.cancel();
    super.dispose();
  }

  Future<String?> _lookup(String title, {int? year, bool anime = true}) async {
    if (anime) {
      try {
        final shiki = DateTime.now().isBefore(_shikiOffUntil)
            ? null
            : await _lookupShikimori(title, year: year);
        if (shiki != null) return shiki;
      } on DioException catch (e) {
        if (e.response?.statusCode == 429) {
          // Throttled: pause the queue and let TMDB answer this one. After a
          // few strikes Shikimori is dropped for a while — a shared exit IP
          // can be throttled for hours, and TMDB's Russian names are a fine
          // fallback meanwhile.
          _blockedUntil = DateTime.now().add(_rateLimitPause);
          _shikiStrikes++;
          if (_shikiStrikes >= 5) {
            _shikiOffUntil = DateTime.now().add(const Duration(minutes: 30));
            debugPrint('[title-ru] shikimori off for 30 min');
          }
          debugPrint('[title-ru] shikimori 429 — pausing lookups');
        } else {
          rethrow;
        }
      }
    }
    final tmdb = await _lookupTmdb(title, year: year);
    if (tmdb != null) return tmdb;
    if (!anime) {
      // A film/series miss in TMDB may still be an anime season entry.
      return _lookupShikimori(title, year: year);
    }
    return null;
  }

  Future<String?> _lookupShikimori(String title, {int? year}) async {
    try {
      final res = await _dio.get<dynamic>(
        '$_shikimoriBase/api/animes',
        queryParameters: {
          'search': title,
          'limit': 6,
          'order': 'ranked',
        },
        options: Options(
          headers: {
            'User-Agent': 'HataruZangetsu/2.3.6',
            'Accept': 'application/json',
          },
          responseType: ResponseType.json,
          followRedirects: true,
          receiveTimeout: _requestTimeout,
          sendTimeout: _requestTimeout,
        ),
      );
      final data = res.data;
      if (data is! List) return null;
      _ShikiCandidate? best;
      for (final raw in data) {
        if (raw is! Map) continue;
        final russian = (raw['russian'] as String?)?.trim();
        if (russian == null || russian.isEmpty) continue;
        if (!_cyrillic.hasMatch(russian)) continue;
        final kind = (raw['kind'] as String?) ?? '';
        if (kind == 'pv' || kind == 'cm' || kind == 'music') continue;
        final names = <String>[
          (raw['name'] as String?) ?? '',
          (raw['english'] as List?)?.cast<String>().join(' ') ?? '',
          (raw['japanese'] as List?)?.cast<String>().join(' ') ?? '',
        ];
        var score = 0.0;
        for (final n in names) {
          if (n.isEmpty) continue;
          final s = _similarity(title, n);
          if (s > score) score = s;
        }
        final airedYear = int.tryParse('${raw['aired_on']}'.split('-').first);
        if (year != null && airedYear != null) {
          final delta = (airedYear - year).abs();
          if (delta == 0) {
            score += 0.12;
          } else if (delta == 1) {
            score += 0.04;
          } else if (delta > 2) {
            score -= 0.10;
          }
        }
        final candidate = _ShikiCandidate(russian, score);
        if (best == null || candidate.score > best.score) best = candidate;
      }
      if (best == null || best.score < 0.62) return null;
      return best.russian;
    } on DioException catch (e) {
      if (e.response?.statusCode == 429) rethrow;
      debugPrint('[title-ru] shikimori "${title}": $e');
      return null;
    } catch (e) {
      debugPrint('[title-ru] shikimori "${title}": $e');
      return null;
    }
  }

  Future<String?> _lookupTmdb(String title, {int? year}) async {
    try {
      final res = await _dio.get<dynamic>(
        '$_tmdbBase/search/multi',
        queryParameters: {
          'api_key': Tmdb.apiKey,
          'query': title,
          'language': 'ru-RU',
          'include_adult': false,
          if (year != null) 'year': year,
        },
        options: Options(
          responseType: ResponseType.json,
          receiveTimeout: _requestTimeout,
          sendTimeout: _requestTimeout,
        ),
      );
      final data = res.data;
      final results = data is Map ? data['results'] : null;
      if (results is! List) return null;
      _ShikiCandidate? best;
      for (final raw in results) {
        if (raw is! Map) continue;
        final mediaType = raw['media_type'];
        if (mediaType != 'movie' && mediaType != 'tv') continue;
        final localized = ((raw['title'] ?? raw['name']) as String?)?.trim();
        if (localized == null || localized.isEmpty) continue;
        if (!_cyrillic.hasMatch(localized)) continue;
        final original = ((raw['original_title'] ?? raw['original_name']) as String?) ?? '';
        var score = _similarity(title, original);
        final date = '${raw['release_date'] ?? raw['first_air_date'] ?? ''}';
        final tmdbYear = int.tryParse(date.split('-').first);
        if (year != null && tmdbYear != null) {
          final delta = (tmdbYear - year).abs();
          if (delta == 0) {
            score += 0.12;
          } else if (delta == 1) {
            score += 0.04;
          } else if (delta > 2) {
            score -= 0.10;
          }
        }
        final popularity = (raw['popularity'] as num?)?.toDouble() ?? 0;
        if (popularity > 30) score += 0.03;
        final candidate = _ShikiCandidate(localized, score);
        if (best == null || candidate.score > best.score) best = candidate;
      }
      if (best == null || best.score < 0.60) return null;
      return best.russian;
    } catch (e) {
      debugPrint('[title-ru] tmdb "${title}": $e');
      return null;
    }
  }
}

class _TitleJob {
  const _TitleJob(this.title, this.year, this.anime, [this.attempts = 0]);

  final String title;
  final int? year;
  final bool anime;
  final int attempts;
}

class _ShikiCandidate {
  const _ShikiCandidate(this.russian, this.score);

  final String russian;
  final double score;
}

String _normalize(String value) {
  final lower = value.toLowerCase();
  final buffer = StringBuffer();
  for (final rune in lower.runes) {
    final char = String.fromCharCode(rune);
    if (RegExp(r'[a-z0-9а-яё]').hasMatch(char)) buffer.write(char);
  }
  return buffer.toString();
}

/// 0..1 similarity between two titles — cheap Levenshtein over normalised
/// strings, plus a bonus when one contains the other.
double _similarity(String a, String b) {
  final x = _normalize(a);
  final y = _normalize(b);
  if (x.isEmpty || y.isEmpty) return 0;
  if (x == y) return 1;
  if (x.length > 3 && y.contains(x)) return 0.92;
  if (y.length > 3 && x.contains(y)) return 0.92;

  final rows = List<int>.generate(y.length + 1, (i) => i);
  for (var i = 1; i <= x.length; i++) {
    var prev = rows[0];
    rows[0] = i;
    for (var j = 1; j <= y.length; j++) {
      final temp = rows[j];
      final cost = x.codeUnitAt(i - 1) == y.codeUnitAt(j - 1) ? 0 : 1;
      var next = rows[j - 1] + 1;
      final del = rows[j] + 1;
      final sub = prev + cost;
      if (del < next) next = del;
      if (sub < next) next = sub;
      rows[j] = next;
      prev = temp;
    }
  }
  final distance = rows[y.length];
  final longest = x.length > y.length ? x.length : y.length;
  return 1 - distance / longest;
}

/// A [Text] that shows the Russian title once [TitleRu] knows one.
///
/// Drop-in replacement for the title [Text] widgets in cards, hero banners and
/// the detail header: it enqueues the lookup itself and rebuilds in place when
/// the translation lands, without rebuilding the screen around it.
class RuTitleText extends StatefulWidget {
  const RuTitleText(
    this.title, {
    super.key,
    this.year,
    this.anime = true,
    this.style,
    this.maxLines,
    this.overflow = TextOverflow.ellipsis,
    this.textAlign,
  });

  final String title;
  final int? year;
  final bool anime;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow overflow;
  final TextAlign? textAlign;

  @override
  State<RuTitleText> createState() => _RuTitleTextState();
}

class _RuTitleTextState extends State<RuTitleText> {
  @override
  void initState() {
    super.initState();
    _request();
    TitleRu.instance.addListener(_onTranslations);
  }

  @override
  void didUpdateWidget(RuTitleText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.title != widget.title || oldWidget.year != widget.year) {
      _request();
    }
  }

  void _request() {
    TitleRu.instance.request(widget.title, year: widget.year, anime: widget.anime);
  }

  void _onTranslations() {
    if (!mounted) return;
    if (!TitleRu.instance.has(widget.title)) return;
    setState(() {});
  }

  @override
  void dispose() {
    TitleRu.instance.removeListener(_onTranslations);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(
    TitleRu.instance.display(widget.title),
    style: widget.style,
    maxLines: widget.maxLines,
    overflow: widget.overflow,
    textAlign: widget.textAlign,
  );
}
