import 'dart:async';
import 'dart:collection';
import 'dart:ui' show PlatformDispatcher;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';

import '../locale/locale_controller.dart';
import '../metadata/tmdb.dart';
import '../translation/plain_text_translation_service.dart';

/// Russian for the *metadata* of a title: synopsis, genres, tags, format,
/// status and the like.
///
/// Three sources, in order of preference:
///  1. **Shikimori** (`/api/animes/<MAL id>`) — the official Russian synopsis
///     for anime, when the title carries a MAL id.
///  2. **TMDB** (`/3/{movie,tv}/<id>?language=ru-RU`) — the Russian overview
///     for films and series.
///  3. **Machine translation** of the English text the catalogue gave us —
///     for everything without an id, and as the fallback when 1/2 come back
///     empty.
///
/// Short, closed-vocabulary strings (genres, formats, statuses, countries,
/// cast roles) never leave the device: they are answered from [_vocab], so a
/// home row full of genres costs no requests at all.
///
/// Everything that does go to the network is queued one at a time and cached
/// on disk, so a title is translated once per install. [text] / [synopsis] are
/// synchronous and answer from the cache (falling back to the original);
/// callers queue a miss. Listeners are notified when new translations land.
class MetaRu extends ChangeNotifier {
  MetaRu._();

  static final MetaRu instance = MetaRu._();

  static const String boxName = 'meta_ru';
  static const String _shikimoriBase = 'https://shikimori.io';
  static const String _tmdbBase = 'https://${Tmdb.host}/3';

  static const Duration _slotGap = Duration(milliseconds: 300);
  static const Duration _rateLimitPause = Duration(seconds: 30);
  static const Duration _requestTimeout = Duration(seconds: 12);

  /// Google's keyless endpoint rejects very long queries; longer texts are
  /// split on sentence boundaries.
  static const int _chunk = 1400;

  static final RegExp _cyrillic = RegExp('[А-Яа-яЁё]');
  static final RegExp _latin = RegExp('[A-Za-z]');

  final Dio _dio = Dio();
  final PlainTextTranslationService _mt = PlainTextTranslationService();

  Box<dynamic>? _box;
  final Map<String, String> _cache = {};
  final Set<String> _queued = {};
  final Set<String> _failed = {};
  final Queue<_MetaJob> _jobs = Queue<_MetaJob>();

  int _running = 0;
  DateTime _lastStart = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _blockedUntil = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _notifyTimer;
  bool _notifyPending = false;
  bool _disposed = false;
  bool _ready = false;

  bool get isReady => _ready;
  int get knownCount => _cache.length;

  /// Whether Russian metadata should be shown at all.
  ///
  /// This service is the RUSSIAN layer over catalogue metadata — genres,
  /// statuses, cast roles, synopses. It has no idea which UI language the app
  /// is in, and it used to answer every caller unconditionally, so an English
  /// (or German, or Arabic) interface showed Russian genre chips and Russian
  /// roles. Gate the whole layer on the current app language instead of at
  /// each of the ~40 call sites: [text] and [synopsis] then return the
  /// original English string, which is exactly right for a non-Russian build.
  ///
  /// "System (auto)" needs the device locale, which is only reachable through
  /// the platform dispatcher — that is why this is a getter, not a constant.
  static bool get isRussian {
    final tag = LocaleController.tag;
    if (tag != LocaleController.systemTag) return tag == 'ru';
    return PlatformDispatcher.instance.locale.languageCode == 'ru';
  }

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
      debugPrint('[meta-ru] cache unavailable: $e');
    }
    _ready = true;
  }

  // ── Public lookups ───────────────────────────────────────────────────────

  /// Russian form of a short metadata string (genre, format, role, country…),
  /// or the original when nothing is known yet.
  String text(String? raw) {
    final t = (raw ?? '').trim();
    if (t.isEmpty) return '';
    if (!isRussian) return t;
    final vocab = _vocab[_norm(t)];
    if (vocab != null) return vocab;
    if (!_needsTranslation(t)) return t;
    return _cache[_key(t)] ?? t;
  }

  /// Russian synopsis for [raw] (the catalogue's English description), using
  /// the title's [malId] / [tmdbId] for an official translation when possible.
  String synopsis(String? raw, {int? malId, int? tmdbId, bool tmdbIsTv = false}) {
    final t = (raw ?? '').trim();
    if (!isRussian) return t;
    final idKey = _synopsisKey(malId: malId, tmdbId: tmdbId, tmdbIsTv: tmdbIsTv);
    if (idKey != null) {
      final hit = _cache[idKey];
      if (hit != null && hit.isNotEmpty) return hit;
    }
    if (t.isEmpty) return '';
    if (!_needsTranslation(t)) return t;
    return _cache[_key(t)] ?? t;
  }

  /// Queue a translation for a short metadata string. Safe from `build`.
  void request(String? raw, {bool label = true}) {
    if (!_ready || !isRussian) return;
    final t = (raw ?? '').trim();
    if (t.isEmpty || t.length > 2400) return;
    if (!_needsTranslation(t)) return;
    if (_vocab.containsKey(_norm(t))) return;
    final k = _key(t);
    if (_cache.containsKey(k) || _queued.contains(k) || _failed.contains(k)) {
      return;
    }
    _queued.add(k);
    _jobs.add(_MetaJob.mt(k, t));
    _scheduleDrain();
  }

  /// Queue a synopsis translation. Safe from `build`.
  void requestSynopsis({
    String? text,
    int? malId,
    int? tmdbId,
    bool tmdbIsTv = false,
  }) {
    if (!_ready || !isRussian) return;
    final t = (text ?? '').trim();
    final idKey = _synopsisKey(malId: malId, tmdbId: tmdbId, tmdbIsTv: tmdbIsTv);
    if (idKey != null) {
      if (_cache.containsKey(idKey) || _queued.contains(idKey) || _failed.contains(idKey)) {
        return;
      }
      _queued.add(idKey);
      _jobs.add(
        _MetaJob.synopsis(
          idKey,
          t,
          malId: malId,
          tmdbId: tmdbId,
          tmdbIsTv: tmdbIsTv,
        ),
      );
      _scheduleDrain();
      return;
    }
    if (t.isEmpty || t.length < 12 || !_needsTranslation(t)) return;
    final k = _key(t);
    if (_cache.containsKey(k) || _queued.contains(k) || _failed.contains(k)) {
      return;
    }
    _queued.add(k);
    _jobs.add(_MetaJob.mt(k, t));
    _scheduleDrain();
  }

  /// Genres for a whole row/film card: vocabulary only, no requests. The
  /// caller may [request] a miss.
  List<String> genres(List<String> raw) => [for (final g in raw) text(g)];

  // ── Queue ────────────────────────────────────────────────────────────────

  void _scheduleDrain() {
    if (_running >= 1 || _jobs.isEmpty) return;
    final now = DateTime.now();
    if (now.isBefore(_blockedUntil)) {
      Timer(_blockedUntil.difference(now), _scheduleDrain);
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
    if (!_ready || _jobs.isEmpty) return;
    if (DateTime.now().isBefore(_blockedUntil)) {
      Timer(_blockedUntil.difference(DateTime.now()), _drain);
      return;
    }
    final job = _jobs.removeFirst();
    _running = 1;
    _lastStart = DateTime.now();
    unawaited(_run(job));
  }

  Future<void> _run(_MetaJob job) async {
    try {
      String? result;
      if (job.kind == _MetaKind.synopsis) {
        if (job.malId != null) {
          result = await _fetchShikimori(job.malId!);
        } else if (job.tmdbId != null) {
          result = await _fetchTmdb(job.tmdbId!, tv: job.tmdbIsTv);
        }
      }
      // No id, or the official source came back empty — machine-translate the
      // English text the catalogue gave us.
      if ((result == null || result.trim().isEmpty) && job.text.isNotEmpty) {
        result = await _translate(job.text);
      }
      if (result != null && result.trim().isNotEmpty) {
        _store(job.key, result.trim());
      } else {
        _failed.add(job.key);
      }
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 429) {
        _blockedUntil = DateTime.now().add(_rateLimitPause);
        debugPrint('[meta-ru] 429 — pausing for ${_rateLimitPause.inSeconds}s');
      } else {
        _failed.add(job.key);
        debugPrint('[meta-ru] ${job.key} failed: ${e.message}');
      }
    } catch (e) {
      _failed.add(job.key);
      debugPrint('[meta-ru] ${job.key} failed: $e');
    } finally {
      _queued.remove(job.key);
      _running = 0;
      _scheduleDrain();
    }
  }

  void _store(String key, String value) {
    if (_cache[key] == value) return;
    _cache[key] = value;
    unawaited(_box?.put(key, value) ?? Future<void>.value());
    _notifySoon();
  }

  void _notifySoon() {
    if (_notifyPending) return;
    _notifyPending = true;
    _notifyTimer?.cancel();
    _notifyTimer = Timer(const Duration(milliseconds: 500), () {
      _notifyPending = false;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _notifyTimer?.cancel();
    super.dispose();
  }

  // ── Sources ──────────────────────────────────────────────────────────────

  Options get _opts => Options(
    headers: {
      'User-Agent': 'HataruZangetsu/2.3.6',
      'Accept': 'application/json',
    },
    responseType: ResponseType.json,
    followRedirects: true,
    receiveTimeout: _requestTimeout,
    sendTimeout: _requestTimeout,
  );

  Future<String?> _fetchShikimori(int malId) async {
    try {
      final res = await _dio.get<dynamic>(
        '$_shikimoriBase/api/animes/$malId',
        options: _opts,
      );
      final data = res.data;
      if (data is! Map) return null;
      final desc = _stripHtml((data['description'] as String?) ?? '');
      if (desc.isEmpty) return null;
      if (!_cyrillic.hasMatch(desc)) return null;
      return desc;
    } on DioException catch (e) {
      if (e.response?.statusCode == 429) rethrow;
      debugPrint('[meta-ru] shikimori $malId: ${e.message}');
      return null;
    } catch (e) {
      debugPrint('[meta-ru] shikimori $malId: $e');
      return null;
    }
  }

  Future<String?> _fetchTmdb(int id, {required bool tv}) async {
    try {
      final res = await _dio.get<dynamic>(
        '$_tmdbBase/${tv ? 'tv' : 'movie'}/$id',
        queryParameters: {'api_key': Tmdb.apiKey, 'language': 'ru-RU'},
        options: _opts,
      );
      final data = res.data;
      if (data is! Map) return null;
      final desc = ((data['overview'] as String?) ?? '').trim();
      if (desc.isEmpty) return null;
      if (!_cyrillic.hasMatch(desc)) return null;
      return desc;
    } catch (e) {
      debugPrint('[meta-ru] tmdb $id: $e');
      return null;
    }
  }

  Future<String?> _translate(String text) async {
    final parts = _split(text);
    final out = <String>[];
    for (final part in parts) {
      final translated = await _mt.translate(
        part,
        sourceLanguage: 'auto',
        targetLanguage: 'ru',
      );
      if (translated.trim().isEmpty) return null;
      out.add(translated.trim());
    }
    return out.join('\n\n');
  }

  /// Split long text into endpoint-sized pieces on sentence boundaries.
  List<String> _split(String text) {
    final t = text.trim();
    if (t.length <= _chunk) return [t];
    final out = <String>[];
    final buffer = StringBuffer();
    for (final sentence in t.split(RegExp(r'(?<=[.!?…])\s+'))) {
      if (buffer.length + sentence.length + 1 > _chunk && buffer.isNotEmpty) {
        out.add(buffer.toString().trim());
        buffer.clear();
      }
      if (sentence.length > _chunk) {
        // A single monster sentence: cut it on spaces.
        var rest = sentence;
        while (rest.length > _chunk) {
          final cut = rest.lastIndexOf(' ', _chunk);
          final at = cut > 200 ? cut : _chunk;
          out.add(rest.substring(0, at).trim());
          rest = rest.substring(at).trim();
        }
        if (rest.isNotEmpty) buffer.write(rest);
        continue;
      }
      if (buffer.isNotEmpty) buffer.write(' ');
      buffer.write(sentence);
    }
    if (buffer.toString().trim().isNotEmpty) out.add(buffer.toString().trim());
    return out.isEmpty ? [t] : out;
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  String _key(String text) => 't:${text.hashCode.toRadixString(16)}:${text.length}';

  String? _synopsisKey({int? malId, int? tmdbId, bool tmdbIsTv = false}) {
    if (malId != null) return 'd:mal:$malId';
    if (tmdbId != null) return 'd:tmdb:${tmdbIsTv ? 'tv' : 'movie'}:$tmdbId';
    return null;
  }

  bool _needsTranslation(String text) {
    if (!_latin.hasMatch(text)) return false;
    // Mostly Cyrillic already (e.g. "Наруто: Ураганные хроники") — leave it.
    final cyr = _cyrillic.allMatches(text).length;
    final lat = _latin.allMatches(text).length;
    return lat > 0 && lat >= cyr;
  }

  String _norm(String value) => value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

  static String _stripHtml(String html) {
    var s = html;
    // Shikimori writes BBCode into `description`: [character=123]Имя[/character],
    // [url=…]…[/url], [spoiler]…[/spoiler]. Keep the visible words, drop the tags.
    if (s.contains('[')) {
      s = s.replaceAll(RegExp(r'\[/?[a-zA-Z][^\]]*\]'), '');
    }
    if (!s.contains('<')) return s.trim();
    s = s
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</p>', caseSensitive: false), '\n\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return s.trim();
  }
}

enum _MetaKind { mt, synopsis }

class _MetaJob {
  _MetaJob.mt(this.key, this.text)
    : kind = _MetaKind.mt,
      malId = null,
      tmdbId = null,
      tmdbIsTv = false;

  _MetaJob.synopsis(
    this.key,
    this.text, {
    this.malId,
    this.tmdbId,
    this.tmdbIsTv = false,
  }) : kind = _MetaKind.synopsis;

  final String key;
  final String text;
  final _MetaKind kind;
  final int? malId;
  final int? tmdbId;
  final bool tmdbIsTv;
}

/// A [Text] that shows the Russian metadata once [MetaRu] knows it.
///
/// Drop-in replacement for the synopsis / genre [Text] widgets: it queues the
/// lookup itself and rebuilds in place when the translation lands.
class RuMetaText extends StatefulWidget {
  const RuMetaText(
    this.text, {
    super.key,
    this.synopsis = false,
    this.malId,
    this.tmdbId,
    this.tmdbIsTv = false,
    this.style,
    this.maxLines,
    this.overflow = TextOverflow.clip,
    this.textAlign,
  });

  final String text;
  final bool synopsis;
  final int? malId;
  final int? tmdbId;
  final bool tmdbIsTv;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow overflow;
  final TextAlign? textAlign;

  @override
  State<RuMetaText> createState() => _RuMetaTextState();
}

class _RuMetaTextState extends State<RuMetaText> {
  @override
  void initState() {
    super.initState();
    _request();
    MetaRu.instance.addListener(_onTranslations);
  }

  @override
  void didUpdateWidget(RuMetaText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.malId != widget.malId ||
        oldWidget.tmdbId != widget.tmdbId) {
      _request();
    }
  }

  void _request() {
    if (widget.synopsis) {
      MetaRu.instance.requestSynopsis(
        text: widget.text,
        malId: widget.malId,
        tmdbId: widget.tmdbId,
        tmdbIsTv: widget.tmdbIsTv,
      );
    } else {
      MetaRu.instance.request(widget.text);
    }
  }

  void _onTranslations() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void dispose() {
    MetaRu.instance.removeListener(_onTranslations);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final value = widget.synopsis
        ? MetaRu.instance.synopsis(
            widget.text,
            malId: widget.malId,
            tmdbId: widget.tmdbId,
            tmdbIsTv: widget.tmdbIsTv,
          )
        : MetaRu.instance.text(widget.text);
    return Text(
      value,
      style: widget.style,
      maxLines: widget.maxLines,
      overflow: widget.overflow,
      textAlign: widget.textAlign,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Closed vocabulary: answered on-device, no request, no key.
// ─────────────────────────────────────────────────────────────────────────────

const Map<String, String> _vocab = {
  // ── Genres (AniList / MAL / TMDB / Simkl) ──
  'action': 'Экшн',
  'action & adventure': 'Экшн и приключения',
  'adult cast': 'Взрослые персонажи',
  'adventure': 'Приключения',
  'female protagonist': 'Женский протагонист',
  'male protagonist': 'Мужской протагонист',
  'school': 'Школа',
  'idol': 'Идолы',
  'survival': 'Выживание',
  'time travel': 'Путешествия во времени',
  'love triangle': 'Любовный треугольник',
  'ensemble cast': 'Ансамбль персонажей',
  'coming of age': 'Взросление',
  'animation': 'Анимация',
  'anime': 'Аниме',
  'comedy': 'Комедия',
  'crime': 'Криминал',
  'documentary': 'Документальное',
  'drama': 'Драма',
  'ecchi': 'Этти',
  'family': 'Семейное',
  'fantasy': 'Фэнтези',
  'food': 'Кулинария',
  'game': 'Игры',
  'gender bender': 'Смена пола',
  'harem': 'Гарем',
  'historical': 'Историческое',
  'history': 'История',
  'horror': 'Ужасы',
  'isekai': 'Исэкай',
  'josei': 'Дзёсэй',
  'kids': 'Детское',
  'magic': 'Магия',
  'martial arts': 'Боевые искусства',
  'mecha': 'Меха',
  'military': 'Военное',
  'music': 'Музыка',
  'mystery': 'Детектив',
  'news': 'Новости',
  'parody': 'Пародия',
  'psychological': 'Психологическое',
  'reality': 'Реалити',
  'romance': 'Романтика',
  'sci-fi': 'Фантастика',
  'science fiction': 'Фантастика',
  'sci-fi & fantasy': 'Фантастика и фэнтези',
  'seinen': 'Сэйнэн',
  'shoujo': 'Сёдзё',
  'shoujo ai': 'Сёдзё-ай',
  'shounen': 'Сёнэн',
  'shounen ai': 'Сёнэн-ай',
  'slice of life': 'Повседневность',
  'soap': 'Мыльная опера',
  'space': 'Космос',
  'sports': 'Спорт',
  'super power': 'Суперспособности',
  'supernatural': 'Сверхъестественное',
  'talk': 'Ток-шоу',
  'thriller': 'Триллер',
  'tv movie': 'Телефильм',
  'vampire': 'Вампиры',
  'war': 'Война',
  'western': 'Вестерн',
  // ── Formats / source material ──
  'tv': 'ТВ-сериал',
  'tv short': 'Короткометражный ТВ',
  'movie': 'Фильм',
  'special': 'Спешл',
  'ova': 'OVA',
  'ona': 'ONA',
  'music video': 'Клип',
  'manga': 'Манга',
  'light novel': 'Ранобэ',
  'novel': 'Роман',
  'original': 'Оригинальный сюжет',
  'visual novel': 'Визуальная новелла',
  'web manga': 'Веб-манга',
  'manhwa': 'Манхва',
  'manhua': 'Маньхуа',
  'one shot': 'Ваншот',
  'doujinshi': 'Додзинси',
  'picture book': 'Книжка с картинками',
  // ── Statuses ──
  'ongoing': 'Онгоинг',
  'airing': 'Выходит',
  'completed': 'Завершён',
  'finished': 'Завершён',
  'hiatus': 'Пауза',
  'on hold': 'Отложено',
  'cancelled': 'Отменён',
  'canceled': 'Отменён',
  'upcoming': 'Скоро',
  'not yet aired': 'Ещё не вышло',
  'releasing': 'Выходит',
  // ── Watch statuses ──
  'watching': 'Смотрю',
  'reading': 'Читаю',
  'plan to watch': 'В планах',
  'planning': 'В планах',
  'plan to read': 'В планах',
  'paused': 'Отложено',
  'dropped': 'Брошено',
  // ── Cast roles ──
  'main': 'Главная роль',
  'supporting': 'Второстепенная роль',
  'background': 'Эпизодическая роль',
  // ── Countries / regions ──
  'japan': 'Япония',
  'jp': 'Япония',
  'china': 'Китай',
  'cn': 'Китай',
  'south korea': 'Южная Корея',
  'kr': 'Южная Корея',
  'taiwan': 'Тайвань',
  'tw': 'Тайвань',
  'usa': 'США',
  'us': 'США',
  'united states of america': 'США',
  'united states': 'США',
  'united kingdom': 'Великобритания',
  'gb': 'Великобритания',
  'france': 'Франция',
  'fr': 'Франция',
  'germany': 'Германия',
  'de': 'Германия',
  'italy': 'Италия',
  'spain': 'Испания',
  'russia': 'Россия',
  'ru': 'Россия',
  'canada': 'Канада',
  'australia': 'Австралия',
  'india': 'Индия',
  'thailand': 'Таиланд',
  'philippines': 'Филиппины',
  // ── Units / misc labels ──
  'min': 'мин',
  'minutes': 'мин',
  'episode': 'Серия',
  'episodes': 'Серии',
  'season': 'Сезон',
  'seasons': 'Сезоны',
  'movie (film)': 'Фильм',
  'no description available.': 'Описание пока недоступно.',
  'studio': 'Студия',
  'cast': 'Персонажи',
};
