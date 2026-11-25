import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart' show AppLifecycleListener, Listenable;
import 'package:hive/hive.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestClient;

import '../provider/cloudstream_provider.dart';
import '../supabase/cloud_postgrest.dart';
import '../supabase/supabase_service.dart';
import 'sources_backup.dart';

/// Thin transport seam over the `sources_sync` cloud table, injectable so
/// [SourcesSync] is unit-testable without a live backend.
class SourcesSyncRemote {
  SourcesSyncRemote(
    SupabaseService service, {
    PostgrestClient? vpsClient,
    String? Function()? accessToken,
  }) : _cloud = CloudPostgrest(
         service,
         vpsClient: vpsClient,
         accessToken: accessToken,
       );

  final CloudPostgrest _cloud;

  /// The user's row as `{payload, revision}`, or null when they never synced
  /// sources from any device.
  Future<({String payload, int revision})?> getRow(String userKey) async {
    final row = await _cloud
        .from('sources_sync')
        .select('payload,revision')
        .eq('user_key', userKey)
        .maybeSingle();
    if (row == null) return null;
    return (
      payload: (row['payload'] ?? '').toString(),
      revision: (row['revision'] as num?)?.toInt() ?? 0,
    );
  }

  Future<void> upsertRow({
    required String userKey,
    required String payload,
    required int revision,
  }) async {
    await _cloud.from('sources_sync').upsert({
      'user_key': userKey,
      'payload': payload,
      'revision': revision,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  /// The cloud revision alone — one small read before a push, so two devices
  /// pushing close together can't hand out the same revision number.
  Future<int> currentRevision(String userKey) async {
    final row = await _cloud
        .from('sources_sync')
        .select('revision')
        .eq('user_key', userKey)
        .maybeSingle();
    return (row?['revision'] as num?)?.toInt() ?? 0;
  }
}

/// Carries the installed-source set between devices, reusing [SourcesBackup]
/// as its codec instead of a second serialiser.
///
/// The payload is exactly [SourcesBackup.build] — provider repos, installed
/// providers, CloudStream/Aniyomi/Mihon/LNReader/Mangayomi extensions and
/// per-source settings. Merge is [SourcesBackup.merge], which is union-only:
/// nothing on the receiving device is ever removed, so a pull can only add.
///
/// Sync model (mirrors the versioned library sync, at a much coarser grain —
/// the whole set is one row):
/// - `push` writes the current set with `revision + 1`.
/// - `pullFromCloud` skips the row when its revision is the one this device
///   last applied/uploaded, merges anything newer, and pushes the union back
///   only if the merge actually added something — otherwise two devices would
///   keep bumping the revision off each other at every launch.
/// - Nothing is ever pushed from a device whose set is completely empty: a
///   fresh install signing in must not blank the cloud row for everyone else.
class SourcesSync {
  SourcesSync(
    this._codec,
    this._currentUserId, {
    SourcesSyncRemote? remote,
    List<Listenable> signals = const [],
    Duration debounce = const Duration(seconds: 4),
  }) : _remote = remote,
       _signals = signals,
       _debounce = debounce;

  final SourcesBackup _codec;
  final String? Function() _currentUserId;
  final SourcesSyncRemote? _remote;
  final List<Listenable> _signals;
  final Duration _debounce;

  /// Same box the library sync uses for its per-account cursors — it is
  /// already open before any of this runs, and it never shows in the UI.
  static const String _metaBox = 'library_sync_meta';
  static const String _revisionPrefix = 'sources_sync_revision';
  static const String _seedPrefix = 'sources_sync_seeded';

  /// Hive boxes [SourcesBackup.build] reads. A change in any of them is what
  /// "the installed set changed" means — installs, uninstalls, repo adds,
  /// per-source settings.
  static const List<String> _watchedBoxes = [
    'provider_repos',
    'provider_registry',
    'provider_settings',
    // Repo URL lists per ecosystem.
    'aniyomi_repos',
    'mihon_repos',
    'lnreader_repos',
    CloudStreamManager.boxName, // 'cs_repos'
    // Installed extensions/plugins. Names are duplicated from the extension
    // services (AniyomiExtensionService.installedBoxName and friends) because
    // those classes are Android-facing and this file is core; the codec
    // already hardcodes the same strings for the same reason.
    'aniyomi_installed',
    'mihon_installed',
    'lnreader_plugins',
  ];

  final List<StreamSubscription<BoxEvent>> _subs = [];
  AppLifecycleListener? _lifecycle;
  Timer? _debounceTimer;
  Timer? _reconcileTimer;
  Future<void>? _inFlight;
  String? _lastPushed;

  /// Starts the delta push: any watched box change (or app going to the
  /// background) schedules one debounced upload. Safe to call twice.
  void attach() {
    if (_subs.isNotEmpty) return;
    for (final name in _watchedBoxes) {
      final events = _watchOf(name);
      if (events != null) {
        _subs.add(events.listen((_) => _schedulePush()));
      }
    }
    // Safety net: if a box was opened with a type [_watchOf] doesn't know, or
    // a manager writes through something Hive doesn't broadcast, a slow
    // reconciliation still converges the cloud row. It only uploads when the
    // payload actually changed, so an idle app stays quiet.
    _reconcileTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => unawaited(_pushIfChanged()),
    );
    for (final signal in _signals) {
      signal.addListener(_schedulePush);
    }
    try {
      _lifecycle = AppLifecycleListener(onPause: _schedulePush, onDetach: _pushNow);
    } catch (_) {
      // No widgets binding (unit tests) — the explicit calls still work.
    }
  }

  void dispose() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _subs.clear();
    for (final signal in _signals) {
      signal.removeListener(_schedulePush);
    }
    _lifecycle?.dispose();
    _debounceTimer?.cancel();
    _reconcileTimer?.cancel();
  }

  /// Change stream of an already-open box.
  ///
  /// `Hive.box(name)` without a type argument throws when that box was opened
  /// with one (`Box<Map>`, `Box<String>`, …) — the app opens each of
  /// [_watchedBoxes] with its own concrete type, so there is no single
  /// accessor. Try the shapes the app actually uses and fall back to the
  /// periodic reconciliation above rather than letting a watcher take the
  /// whole boot down.
  Stream<BoxEvent>? _watchOf(String name) {
    if (!Hive.isBoxOpen(name)) return null;
    for (final watch in <Stream<BoxEvent> Function()>[
      () => Hive.box(name).watch(),
      () => Hive.box<Map>(name).watch(),
      () => Hive.box<String>(name).watch(),
      () => Hive.box<List>(name).watch(),
      () => Hive.box<dynamic>(name).watch(),
    ]) {
      try {
        return watch();
      } catch (_) {
        // Wrong type argument for this box — try the next shape.
      }
    }
    return null;
  }

  /// Pushes only when the built payload differs from the last uploaded one.
  Future<void> _pushIfChanged() async {
    final uid = _currentUserId();
    if (uid == null || _remote == null) return;
    final current = jsonEncode(_codec.build());
    if (current == _lastPushed) return;
    await _push(uid);
  }

  void _schedulePush() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounce, _pushNow);
  }

  // ── pull / push ────────────────────────────────────────────────────────────

  /// One-time-per-account backfill, mirroring the library stores: push the
  /// local set first so a fresh device can't be left with an empty cloud row
  /// and so an account that never synced sources gets one on next launch.
  /// The flag is only set when the push succeeded, so an offline attempt
  /// retries next time.
  Future<void> seedCloudIfNeeded() async {
    final uid = _currentUserId();
    final remote = _remote;
    if (uid == null || remote == null || !Hive.isBoxOpen(_metaBox)) return;
    final box = Hive.box(_metaBox);
    final seedKey = '${_seedPrefix}_$uid';
    if (box.get(seedKey) == true) return;
    try {
      final row = await remote.getRow(uid);
      if (row == null) {
        final pushed = await _push(uid);
        if (!pushed) return;
      }
      await box.put(seedKey, true);
    } catch (_) {
      // Offline: stay unseeded so the next launch tries again.
    }
  }

  /// Pulls the account's source set and merges it into this device.
  ///
  /// Returns how many restore failures [SourcesBackup.merge] reported (each is
  /// a source that could not be re-fetched, e.g. a dead repository) so callers
  /// can log them; sync itself stays silent.
  Future<List<String>> pullFromCloud() async {
    final uid = _currentUserId();
    final remote = _remote;
    if (uid == null || remote == null) return const [];
    try {
      final row = await remote.getRow(uid);
      if (row == null) return const [];
      if (row.revision <= _appliedRevision(uid)) return const [];

      final decoded = jsonDecode(row.payload);
      if (decoded is! Map) return const [];
      final payload = Map<String, dynamic>.from(decoded);
      if (_isEmpty(payload)) {
        // A blank row is worse than no row: record its revision so we stop
        // re-reading it, but don't let it touch this device.
        _setAppliedRevision(uid, row.revision);
        return const [];
      }

      final before = jsonEncode(_codec.build());
      final failures = await _codec.merge(payload);
      final after = jsonEncode(_codec.build());
      _setAppliedRevision(uid, row.revision);

      // Only converge the cloud when the merge actually changed something —
      // otherwise every launch on every device would bump the revision and
      // wake the other devices for nothing.
      if (after != before) await _push(uid, knownRevision: row.revision);
      return failures;
    } catch (_) {
      return const [];
    }
  }

  /// Uploads the current set. Public so a caller that just changed sources
  /// (or the debounced watcher) can push immediately.
  Future<bool> push() {
    final uid = _currentUserId();
    if (uid == null) return Future.value(false);
    return _push(uid);
  }

  Future<bool> _pushNow() async => push();

  Future<bool> _push(String uid, {int? knownRevision}) async {
    final remote = _remote;
    if (remote == null) return false;
    // Serialise pushes: the watcher can fire while an upload is in flight, and
    // two concurrent revision reads would hand the same number to both.
    final previous = _inFlight;
    final completer = Completer<void>();
    _inFlight = completer.future;
    try {
      if (previous != null) await previous;
      final payload = _codec.build();
      if (_isEmpty(payload)) return false;
      final revision =
          (knownRevision ?? await remote.currentRevision(uid)) + 1;
      await remote.upsertRow(
        userKey: uid,
        payload: jsonEncode(payload),
        revision: revision,
      );
      _setAppliedRevision(uid, revision);
      _lastPushed = payload;
      return true;
    } catch (_) {
      return false; // offline / backend refused — next trigger retries
    } finally {
      completer.complete();
      if (identical(_inFlight, completer.future)) _inFlight = null;
    }
  }

  // ── per-account bookkeeping ─────────────────────────────────────────────────

  int _appliedRevision(String uid) {
    if (!Hive.isBoxOpen(_metaBox)) return 0;
    final raw = Hive.box(_metaBox).get('${_revisionPrefix}_$uid');
    return (raw as num?)?.toInt() ?? 0;
  }

  void _setAppliedRevision(String uid, int revision) {
    if (!Hive.isBoxOpen(_metaBox)) return;
    unawaited(Hive.box(_metaBox).put('${_revisionPrefix}_$uid', revision));
  }

  /// True when the payload holds nothing at all — no repos, no providers, no
  /// extensions, no per-source settings.
  static bool _isEmpty(Map<String, dynamic> payload) {
    for (final entry in payload.entries) {
      final v = entry.value;
      if (v is List && v.isNotEmpty) return false;
      if (v is Map && v.isNotEmpty) return false;
      if (v is String && v.isNotEmpty) return false;
    }
    return true;
  }
}
