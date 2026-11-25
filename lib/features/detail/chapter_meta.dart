import '../../core/models/episode.dart';
import '../../l10n/app_localizations.dart';

/// Line 2 of a chapter row in reading (manga/novel) mode.
///
/// Reads `scanlator · relative date`, dropping whichever half is missing —
/// most sources have no scanlator, plenty have no usable date, and a row with
/// neither loses the line entirely.
///
/// Returns null when there's nothing to show, so the caller can drop the whole
/// line and let the row shrink.
String? chapterMetaLine(AppLocalizations l10n, Episode ep, {DateTime? now}) {
  final parts = <String>[
    // Already normalised at ingest by [scanlatorLabel] — null means no group.
    ?ep.scanlator,
    ?relativeDate(l10n, ep.date, now: now),
  ];
  return parts.isEmpty ? null : parts.join('  ·  ');
}

const List<String> _ruMonthsShort = [
  'янв',
  'фев',
  'мар',
  'апр',
  'мая',
  'июн',
  'июл',
  'авг',
  'сен',
  'окт',
  'ноя',
  'дек',
];

const List<String> _enMonthsShort = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// Air date of an episode as a human line: "6 окт 2026".
///
/// The episode row used to print `ep.date` verbatim, and the catalogues hand
/// us ISO-8601 ("2026-10-06T15:00:00.000Z") — an unreadable stamp in the
/// middle of a nicely localised screen. Anything unparseable is still shown
/// as-is, which is better than nothing for a source's own quirky format.
String? airDateLabel(AppLocalizations l10n, String? raw) {
  final s = raw?.trim();
  if (s == null || s.isEmpty) return null;
  final d = DateTime.tryParse(s);
  if (d == null) return s;
  final local = d.toLocal();
  final russian = l10n.localeName.toLowerCase().startsWith('ru');
  final month = (russian ? _ruMonthsShort : _enMonthsShort)[local.month - 1];
  return '${local.day} $month ${local.year}';
}

/// "2 days ago" for anything we can parse as a date; the raw string verbatim
/// when we can't (sources hand us all sorts of formats and showing theirs
/// beats showing nothing); null for empty/absent.
String? relativeDate(AppLocalizations l10n, String? raw, {DateTime? now}) {
  final s = raw?.trim();
  if (s == null || s.isEmpty) return null;
  final d = DateTime.tryParse(s);
  if (d == null) return s;

  final days = (now ?? DateTime.now()).difference(d).inDays;
  if (days <= 0) return l10n.relativeToday;
  if (days == 1) return l10n.relativeYesterday;
  if (days < 7) return l10n.relativeDaysAgo(days);
  if (days < 30) return l10n.relativeWeeksAgo(days ~/ 7);
  if (days < 365) return l10n.relativeMonthsAgo(days ~/ 30);
  return l10n.relativeYearsAgo(days ~/ 365);
}
