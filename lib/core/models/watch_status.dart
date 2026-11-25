/// A title's place in the user's library — the same set AniList / MAL / Simkl
/// use. Stored locally (and pushed to AniList for anime). Used to organise My
/// List and drive the "Add to List" status sheet.
enum WatchStatus { planning, watching, completed, paused, dropped }

extension WatchStatusX on WatchStatus {
  /// Persisted key (the enum name).
  String get key => name;

  // NOTE: display labels are NOT here any more. They live in
  // `lib/l10n/ui_strings.dart` (`watchStatusLabel` / `watchStatusShortLabel`),
  // because this file used to hold Russian literals that leaked into every
  // other UI language. Only the persisted key and the per-tracker protocol
  // values below stay on the enum — those are data, never display text.
  /// AniList `MediaListStatus` value.
  String get anilist => switch (this) {
    WatchStatus.planning => 'PLANNING',
    WatchStatus.watching => 'CURRENT',
    WatchStatus.completed => 'COMPLETED',
    WatchStatus.paused => 'PAUSED',
    WatchStatus.dropped => 'DROPPED',
  };

  /// MyAnimeList `my_list_status.status` value.
  String get mal => switch (this) {
    WatchStatus.planning => 'plan_to_watch',
    WatchStatus.watching => 'watching',
    WatchStatus.completed => 'completed',
    WatchStatus.paused => 'on_hold',
    WatchStatus.dropped => 'dropped',
  };

  /// Simkl list name (`to` field on /sync/add-to-list).
  String get simkl => switch (this) {
    WatchStatus.planning => 'plantowatch',
    WatchStatus.watching => 'watching',
    WatchStatus.completed => 'completed',
    WatchStatus.paused => 'hold',
    WatchStatus.dropped => 'dropped',
  };
}

/// [WatchStatusX.mal], but reading-aware: MyAnimeList's manga list uses
/// `reading`/`plan_to_read` instead of `watching`/`plan_to_watch` —
/// `completed`/`on_hold`/`dropped` are shared. Protocol data, like [WatchStatusX.mal],
/// so `reading: false` is byte-identical to it.
String malStatusFor(WatchStatus s, {required bool reading}) {
  if (!reading) return s.mal;
  return switch (s) {
    WatchStatus.watching => 'reading',
    WatchStatus.planning => 'plan_to_read',
    WatchStatus.completed || WatchStatus.paused || WatchStatus.dropped => s.mal,
  };
}

/// Parse a stored status name (null/unknown → null).
WatchStatus? watchStatusFromName(String? name) {
  if (name == null) return null;
  for (final s in WatchStatus.values) {
    if (s.name == name) return s;
  }
  return null;
}

/// Map an AniList `MediaListStatus` to our [WatchStatus]. REPEATING counts as
/// watching.
WatchStatus? watchStatusFromAniList(String? status) => switch (status) {
  'CURRENT' || 'REPEATING' => WatchStatus.watching,
  'PLANNING' => WatchStatus.planning,
  'COMPLETED' => WatchStatus.completed,
  'PAUSED' => WatchStatus.paused,
  'DROPPED' => WatchStatus.dropped,
  _ => null,
};
