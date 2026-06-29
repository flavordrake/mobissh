// Persisted display order for saved profiles on the Connect panel (#481).
//
// Saved profiles render in an arbitrary/insertion order with no way to reorder.
// This adds a user-defined order: a SharedPreferences-backed list of profile
// `identityKey`s (`host:port:username`). The Connect panel applies the order
// before rendering and exposes drag-reorder + "Move to top / bottom" controls.
//
// Storage mirrors the favorites / files-sort stores: a single versioned JSON
// blob in shared_preferences with the migratable schema version INSIDE the
// value (never a key bump, per .claude/rules code-style). Corrupt /
// unknown-version data falls back to an empty order (validate → fallback, never
// crash) — an empty order means "insertion order", which is the prior behaviour.
//
// The order self-heals against the live profile set via [reconcileOrder]:
//   - a NEW profile (not in the order) appends to the END,
//   - a DELETED profile (in the order but gone) is dropped,
//   - IMPORTED profiles merge by identity — existing keep their slot, new append.
// The RECENT SESSIONS and Active Sessions lists are SEPARATE (chronological /
// live) and are unaffected by this order.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../storage/profiles_store.dart';
import 'profiles_providers.dart';

/// shared_preferences key (storage namespace `v1`; the migratable schema
/// version lives inside the value — see [_schemaVersion]).
const String profileOrderPrefKey = 'mobissh.profile.order.v1';

const int _schemaVersion = 1;

/// Decode the stored order list from a blob. Returns an empty list on
/// null/malformed/unknown-version input, and de-dupes / drops non-string
/// entries (corrupt-resilience — never crash, never surface a bad shape).
List<String> decodeProfileOrder(String? raw) {
  if (raw == null || raw.isEmpty) return const <String>[];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return const <String>[];
    final version = decoded['version'];
    if (version is! int || version != _schemaVersion) return const <String>[];
    final order = decoded['order'];
    if (order is! List) return const <String>[];
    final out = <String>[];
    final seen = <String>{};
    for (final entry in order) {
      if (entry is String && entry.isNotEmpty && seen.add(entry)) {
        out.add(entry);
      }
    }
    return out;
  } on FormatException {
    return const <String>[];
  }
}

String encodeProfileOrder(List<String> order) =>
    jsonEncode({'version': _schemaVersion, 'order': order});

/// Reconcile a stored [order] against the current [profileKeys] set:
/// keep known keys in their stored order, drop keys whose profile is gone,
/// and append profile keys that aren't in the order yet (in their given
/// order). Pure + total — the canonical "self-heal" used on every load and
/// after add/delete/import. De-dupes defensively.
List<String> reconcileOrder(List<String> profileKeys, List<String> order) {
  final known = profileKeys.toSet();
  final seen = <String>{};
  final out = <String>[];
  for (final id in order) {
    if (known.contains(id) && seen.add(id)) out.add(id);
  }
  for (final id in profileKeys) {
    if (seen.add(id)) out.add(id);
  }
  return out;
}

/// Return [profiles] sorted by [order]: entries listed in [order] come first
/// in that order, then any profile NOT in the order is appended in its original
/// position. Order entries with no matching profile are ignored. Pure +
/// unit-testable; the Connect panel calls this right before rendering.
List<SavedProfile> applyOrder(
  List<SavedProfile> profiles,
  List<String> order,
) {
  final byKey = <String, SavedProfile>{
    for (final p in profiles) p.identityKey: p,
  };
  final seen = <String>{};
  final out = <SavedProfile>[];
  for (final id in order) {
    final p = byKey[id];
    if (p != null && seen.add(id)) out.add(p);
  }
  for (final p in profiles) {
    if (seen.add(p.identityKey)) out.add(p);
  }
  return out;
}

/// Persisted, reactive profile display order (list of `identityKey`s). The
/// Connect panel watches this and applies it via [applyOrder]; mutations
/// ([moveToTop]/[moveToBottom]/[reorder]) persist immediately and update the
/// watcher synchronously. [sync] reconciles the order with the live profile set
/// so add/delete/import self-heal.
class ProfileOrderNotifier extends StateNotifier<List<String>> {
  ProfileOrderNotifier({Future<SharedPreferences>? prefs})
    : _prefs = prefs ?? SharedPreferences.getInstance(),
      super(const <String>[]) {
    _ready = _hydrate();
  }

  final Future<SharedPreferences> _prefs;

  /// Completes once the stored order has been loaded. [sync] awaits this so an
  /// auto-reconcile from the live profile set never clobbers the persisted order
  /// during the async hydrate window.
  late final Future<void> _ready;

  Future<void> _hydrate() async {
    try {
      final prefs = await _prefs;
      final order = decodeProfileOrder(prefs.getString(profileOrderPrefKey));
      if (!listEquals(order, state)) state = order;
    } catch (_) {
      // best-effort; keep the empty default if prefs is unavailable (tests).
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await _prefs;
      await prefs.setString(profileOrderPrefKey, encodeProfileOrder(state));
    } catch (_) {
      // best-effort persistence
    }
  }

  /// Reconcile the order against the current profile key set, dropping missing
  /// keys and appending new ones (#481 add/delete/import self-heal). Updates +
  /// persists only when something actually changed (idempotent — safe to call
  /// every build / on every profile-set change).
  Future<void> sync(List<String> profileKeys) async {
    await _ready;
    final next = reconcileOrder(profileKeys, state);
    if (!listEquals(next, state)) {
      state = next;
      await _persist();
    }
  }

  /// Move [id] to the front of the order. No-op when [id] isn't present.
  Future<void> moveToTop(String id) async {
    if (!state.contains(id)) return;
    final list = List<String>.from(state)..remove(id);
    list.insert(0, id);
    state = list;
    await _persist();
  }

  /// Move [id] to the end of the order. No-op when [id] isn't present.
  Future<void> moveToBottom(String id) async {
    if (!state.contains(id)) return;
    final list = List<String>.from(state)..remove(id);
    list.add(id);
    state = list;
    await _persist();
  }

  /// Reorder via drag. [oldIndex] is the dragged item's current position;
  /// [newIndex] is its destination index AFTER removal — the
  /// `ReorderableListView.onReorderItem` contract (the framework already
  /// adjusts for the removed slot). Indices are into the CURRENT order (the
  /// rendered list, which the Connect panel keeps in sync via [sync]).
  Future<void> reorder(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= state.length) return;
    final list = List<String>.from(state);
    final id = list.removeAt(oldIndex);
    var target = newIndex;
    if (target < 0) target = 0;
    if (target > list.length) target = list.length;
    list.insert(target, id);
    if (listEquals(list, state)) return;
    state = list;
    await _persist();
  }
}

/// Reactive, persisted profile display order (#481). Auto-reconciles against the
/// live saved-profile set ([savedProfilesProvider]): whenever profiles load or
/// change (add / delete / import), [ProfileOrderNotifier.sync] drops gone keys
/// and appends new ones — so the stored order self-heals without any UI plumbing.
final profileOrderProvider =
    StateNotifierProvider<ProfileOrderNotifier, List<String>>((ref) {
      final notifier = ProfileOrderNotifier();
      ref.listen<AsyncValue<List<SavedProfile>>>(savedProfilesProvider, (
        _,
        next,
      ) {
        final profiles = next.valueOrNull;
        if (profiles != null) {
          notifier.sync(profiles.map((p) => p.identityKey).toList());
        }
      }, fireImmediately: true);
      return notifier;
    });
