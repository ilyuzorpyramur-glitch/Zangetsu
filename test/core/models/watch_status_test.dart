import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/l10n/app_localizations_en.dart';
import 'package:watch_app/l10n/app_localizations_ru.dart';
import 'package:watch_app/l10n/ui_strings.dart';

// The enum itself carries DATA only — the persisted key and each tracker's
// protocol value. Display labels moved to `ui_strings.dart` because this file
// used to hold Russian literals that showed up verbatim in every other UI
// language (an English build said "Смотрю" on the status sheet).
void main() {
  final en = AppLocalizationsEn();
  final ru = AppLocalizationsRu();

  group('display labels are localized', () {
    test('English reads as English', () {
      expect(watchStatusLabel(en, WatchStatus.watching, reading: false),
          'Watching');
      expect(watchStatusLabel(en, WatchStatus.planning, reading: false),
          'Plan to Watch');
      expect(watchStatusLabel(en, WatchStatus.completed, reading: false),
          'Completed');
      expect(watchStatusShortLabel(en, WatchStatus.planning, reading: false),
          'Planning');
    });

    test('reading kinds use the reading words, not the watching ones', () {
      expect(watchStatusLabel(en, WatchStatus.watching, reading: true),
          'Reading');
      expect(watchStatusLabel(en, WatchStatus.planning, reading: true),
          'Plan to Read');
      // Completed/Paused/Dropped need no reading-specific word.
      expect(watchStatusLabel(en, WatchStatus.completed, reading: true),
          'Completed');
      expect(watchStatusLabel(en, WatchStatus.paused, reading: true),
          'Paused');
    });

    test('Russian reads as Russian, and never as the English word', () {
      final watching = watchStatusLabel(ru, WatchStatus.watching, reading: false);
      expect(watching, isNot('Watching'));
      expect(watching, contains(RegExp('[А-Яа-яЁё]')));
      final reading = watchStatusLabel(ru, WatchStatus.watching, reading: true);
      expect(reading, isNot(contains('Reading')));
    });

    test('every status has a label in both languages', () {
      for (final s in WatchStatus.values) {
        for (final reading in [false, true]) {
          expect(watchStatusLabel(en, s, reading: reading), isNotEmpty);
          expect(watchStatusLabel(ru, s, reading: reading), isNotEmpty);
          expect(watchStatusShortLabel(en, s, reading: reading), isNotEmpty);
          expect(watchStatusShortLabel(ru, s, reading: reading), isNotEmpty);
        }
      }
    });
  });

  group('protocol values are untouched by display changes', () {
    test('the persisted key is the enum name', () {
      expect(WatchStatus.values.map((s) => s.name).toList(), [
        'planning',
        'watching',
        'completed',
        'paused',
        'dropped',
      ]);
      for (final s in WatchStatus.values) {
        expect(s.key, s.name);
      }
    });

    test('MAL keeps its reading spellings, anime is unaffected', () {
      expect(malStatusFor(WatchStatus.watching, reading: false), 'watching');
      expect(malStatusFor(WatchStatus.watching, reading: true), 'reading');
      expect(malStatusFor(WatchStatus.planning, reading: false),
          'plan_to_watch');
      expect(malStatusFor(WatchStatus.planning, reading: true),
          'plan_to_read');
      // Shared spellings pass through in both modes.
      for (final s in [
        WatchStatus.completed,
        WatchStatus.paused,
        WatchStatus.dropped,
      ]) {
        expect(malStatusFor(s, reading: true), malStatusFor(s, reading: false));
      }
    });

    test('AniList and Simkl mappings are unchanged', () {
      expect(WatchStatus.watching.anilist, 'CURRENT');
      expect(WatchStatus.watching.simkl, 'watching');
      expect(WatchStatus.paused.simkl, 'hold');
      expect(watchStatusFromAniList('REPEATING'), WatchStatus.watching);
      expect(watchStatusFromName('dropped'), WatchStatus.dropped);
      expect(watchStatusFromName('nonsense'), isNull);
    });
  });
}
