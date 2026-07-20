// Session menu (#518) — mirrors the PWA's `renderSessionList` / `initSessionMenu`.
//
// #567: slimmed to the session-menu-slim direction — terminal real estate is
// at a premium, so the sheet keeps only what belongs:
//   1. List of active sessions (tap to switch, long-press for actions).
//   2. "New session".
//   3. A compact secondary row of session controls (keybar toggle, theme,
//      files) — no verbose subtitles, no oversized header.
//
// Tap-to-switch dismisses the menu. Long-press opens a contextual menu with
// Disconnect / Close — same actions the PWA exposes on the session row.
//
// #585: the menu is presented as a NON-MODAL OverlayEntry, NOT a
// `showModalBottomSheet` route. Pushing a modal route swaps the active focus
// scope, so the engine hid the soft keyboard the instant the menu opened and
// the terminal reflowed ("jumpiness"). Restoring focus on dismiss couldn't fix
// the drop-on-OPEN — only not-pushing-a-route does. The overlay never requests
// focus (wrapped in a `FocusScope(canRequestFocus: false)`), so the terminal's
// text input keeps the keyboard. The panel floats just ABOVE the keyboard
// (offset by `viewInsets.bottom`) instead of being covered by it.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../main.dart' show openConnectHome;
import '../services/session_messages.dart' show ForwardInfo, ForwardStatus;
import '../ssh/ssh_session.dart';
import '../state/detection_providers.dart';
import '../state/favorites_providers.dart';
import '../state/profiles_providers.dart';
import '../state/sessions.dart';
import '../state/ui_prefs_providers.dart';
import '../storage/profiles_store.dart' show ProfilesStore;
import '../util/large_landscape.dart';
import 'detection_lab_screen.dart';
import 'favorites_menu_sheet.dart';
import 'file_browser_screen.dart';
import 'port_forwards_sheet.dart';
import 'session_state_dot.dart';

/// Opens the session menu as a NON-MODAL overlay anchored to the bottom, above
/// the keyboard. Returns once dismissed (outside tap or an action closes it).
///
/// Unlike `showModalBottomSheet`, this inserts an `OverlayEntry` rather than
/// pushing a route, so the terminal keeps primary focus and the soft keyboard
/// stays up (#585).
///
/// [bottomReserve] is the height (logical px) of the session bar that summoned
/// the menu (phone layout). The panel floats ABOVE that reserved strip so its
/// last row (Files) never lands on top of the trigger — the owner hit "tap to
/// dismiss lands on Files" because the panel overlapped the bar (2026-06-01).
/// The full-screen tap barrier still covers the bar, so a tap on the (now-
/// uncovered) trigger dismisses the menu: same touch target opens AND closes it.
///
/// [topReserve] (#1086, owner 2026-07-20) is the mirror for the TABLET layout:
/// the session bar is a compact strip at the TOP, so the menu drops DOWN from it
/// as a left-anchored, width-capped dropdown ("menu should extend from the menu
/// bar") instead of rising from the bottom. Pass at most one of the two; when
/// [topReserve] > 0 it wins.
/// #1086: width of the tablet top-drop session menu. The menu's action-button
/// row needs ~400dp to lay out without overflow (it fills the phone bottom bar
/// full-width); 440 clears that with margin while staying a clear dropdown on a
/// wide tablet surface rather than a full-width sheet.
const double kTabletSessionMenuWidth = 440.0;

Future<void> showSessionMenu(
  BuildContext context, {
  double bottomReserve = 0,
  double topReserve = 0,
}) {
  final overlay = Overlay.of(context);
  final completer = Completer<void>();
  late OverlayEntry entry;
  final anchorTop = topReserve > 0;

  void close() {
    if (entry.mounted) entry.remove();
    if (!completer.isCompleted) completer.complete();
  }

  entry = OverlayEntry(
    builder: (ctx) {
      // Float the panel above the keyboard when it's up; sit just above the
      // session bar otherwise. This keeps the keyboard visible AND keeps the
      // bar's trigger uncovered so tapping it again dismisses (via the barrier).
      final keyboardInset = MediaQuery.of(ctx).viewInsets.bottom;
      final liftAboveBar = keyboardInset > 0 ? keyboardInset : bottomReserve;
      // TABLET: a left-anchored dropdown that hugs the top strip — bottom-
      // rounded (top flush against the bar), width-capped so it reads as a
      // desktop-style menu rather than a full-width sheet.
      final panel = FocusScope(
        // canRequestFocus:false guarantees the menu (and its tappable rows)
        // never steal focus from the terminal's editable — the keyboard stays
        // up. Taps still work; toggles/switches don't need focus.
        canRequestFocus: false,
        child: Material(
          color: Theme.of(ctx).colorScheme.surface,
          elevation: 8,
          borderRadius: anchorTop
              ? const BorderRadius.vertical(bottom: Radius.circular(16))
              : const BorderRadius.vertical(top: Radius.circular(16)),
          clipBehavior: Clip.antiAlias,
          child: SessionMenu(onClose: close),
        ),
      );
      return Stack(
        children: [
          // Outside-tap barrier. A plain GestureDetector does NOT request
          // focus, so dismissing the menu doesn't disturb the keyboard either.
          // It covers the whole screen INCLUDING the session bar, so a tap on
          // the trigger that opened the menu dismisses it.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: close,
              child: const ColoredBox(color: Color(0x66000000)),
            ),
          ),
          if (anchorTop)
            Positioned(
              left: 0,
              top: topReserve,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: kTabletSessionMenuWidth,
                ),
                child: panel,
              ),
            )
          else
            Positioned(left: 0, right: 0, bottom: liftAboveBar, child: panel),
        ],
      );
    },
  );

  overlay.insert(entry);
  return completer.future;
}

/// Step the ACTIVE session's font size by [delta] and PERSIST the result onto
/// its PROFILE (#640) so it survives restart/reconnect — mirroring how a
/// per-profile theme (#613) is stored on the profile, not just in-memory.
///
/// Two effects, in order:
///   1. In-memory per-session font (live render) via [SessionAppearanceNotifier]
///      — already clamped to [kFontSizeMin]..[kFontSizeMax].
///   2. Best-effort upsert of the clamped value onto the matching saved profile
///      (keyed by the active entry's `host:port:username`). NO-OP for an ad-hoc
///      connect with no saved profile — we never materialize one.
void _stepFont(
  WidgetRef ref,
  SessionsState sessions,
  String activeId,
  double delta,
) {
  final notifier = ref.read(sessionAppearanceProvider.notifier);
  notifier.adjustFontSize(activeId, delta);
  // The clamped in-memory value is now authoritative for this session.
  final size = ref.read(sessionFontSizeProvider(activeId));
  final active = sessions.active;
  if (active == null) return;
  // profileKey == the SavedProfile identityKey (host:port:username).
  unawaited(
    ref.read(profilesStoreProvider).setFontSize(active.profileKey, size),
  );
}

/// Set the ACTIVE session's font family to [familyId] (#679, #724) and PERSIST
/// it onto the session's PROFILE — mirroring [_stepFont]/#640 for font size and
/// [_pickTheme]/#613 for theme. The session menu used to ADVANCE to the next
/// face on each tap (#679); #724 swapped that blind cycle for a picker, so this
/// applies an explicitly chosen family. Two effects, in order:
///   1. In-memory per-session family (live render) via [SessionAppearanceNotifier].
///   2. Best-effort upsert of the chosen family onto the matching saved profile
///      (keyed by the active entry's `host:port:username`). NO-OP for an ad-hoc
///      connect with no saved profile — we never materialize one.
///
/// [appearance] and [store] are passed in (resolved before the menu overlay is
/// closed) rather than read off a `ref`: opening the picker CLOSES the menu
/// overlay (#664), which disposes the controls-row widget + its `ref`. Touching
/// `ref` afterwards throws "Cannot use ref after the widget was disposed", so
/// the picker callback must hold the notifier/store directly.
void _pickFontFamily(
  SessionAppearanceNotifier appearance,
  ProfilesStore store,
  SessionsState sessions,
  String activeId,
  String familyId,
) {
  appearance.setFontFamily(activeId, familyId);
  final active = sessions.active;
  if (active == null) return;
  unawaited(store.setFontFamily(active.profileKey, familyId));
}

/// Set the ACTIVE session's terminal palette to [index] (#601, #571, #724) and
/// PERSIST the matching theme KEY onto the session's PROFILE (#613) so it sticks
/// across restart/reconnect. The session menu used to CYCLE to the next palette
/// on each tap; #724 swapped that blind cycle for a picker, so this applies an
/// explicitly chosen palette. Two effects, in order:
///   1. In-memory per-session theme (live render) via [SessionAppearanceNotifier].
///   2. Best-effort upsert of the palette's PWA theme KEY onto the matching saved
///      profile. NO-OP for an ad-hoc connect with no saved profile.
///
/// [appearance] and [store] are passed in (resolved before the menu overlay is
/// closed) rather than read off a `ref` — see [_pickFontFamily] for why (#664).
void _pickTheme(
  SessionAppearanceNotifier appearance,
  ProfilesStore store,
  SessionsState sessions,
  String activeId,
  int index,
) {
  appearance.setTheme(activeId, index);
  final active = sessions.active;
  if (active == null) return;
  if (index < 0 || index >= terminalPalettes.length) return;
  unawaited(store.setTheme(active.profileKey, terminalPalettes[index].key));
}

/// The human label for a bundled font-family id (#679), for the picker control.
String _fontFamilyLabel(String id) {
  for (final f in terminalFontFamilies) {
    if (f.id == id) return f.label;
  }
  return id;
}

/// A compact, dismissible bottom-sheet picker (#724) listing [count] options as
/// a scrollable column with the [selectedIndex] marked by a check. Tapping an
/// option calls [onPick] and closes the sheet. Used for BOTH the theme picker
/// (all 38 palettes) and the font-family picker (all bundled faces) — same
/// idiom, so the two controls read consistently.
///
/// #664: the menu is a non-modal OverlayEntry, so we cannot use the overlay's
/// own context for a route-based sheet. [navigatorContext] is captured from a
/// `Navigator.of(context)` at the call site (the app's real Navigator), which
/// owns a valid route stack for `showModalBottomSheet`.
void _showPickerSheet({
  required BuildContext navigatorContext,
  required String title,
  required int count,
  required int selectedIndex,
  required String Function(int index) labelOf,
  required void Function(int index) onPick,
}) {
  showModalBottomSheet<void>(
    context: navigatorContext,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      return SafeArea(
        child: ConstrainedBox(
          // Keep the sheet compact (premium space): cap at ~half the screen and
          // let the list scroll past that.
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.6,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: Text(title, style: theme.textTheme.titleSmall),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: count,
                  itemBuilder: (lctx, i) {
                    final selected = i == selectedIndex;
                    return ListTile(
                      key: Key('picker-option-$i'),
                      dense: true,
                      selected: selected,
                      leading: Icon(
                        selected
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        size: 20,
                        color: selected
                            ? theme.colorScheme.primary
                            : theme.colorScheme.outlineVariant,
                      ),
                      title: Text(labelOf(i)),
                      onTap: () {
                        onPick(i);
                        Navigator.of(ctx).pop();
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class SessionMenu extends ConsumerWidget {
  const SessionMenu({super.key, required this.onClose});

  /// Dismisses the overlay. Replaces the old `Navigator.pop()` since the menu
  /// is no longer a route (#585).
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(sessionsProvider);
    // Theme + font + keybar are all PER-SESSION (#601, #571, #573): the menu
    // rows read and mutate the ACTIVE session only. With no active session
    // (empty list) these resolve to the default so the rows still render
    // sensibly.
    //
    // #1086: the keybar toggle reflects and flips the EFFECTIVE (rendered) state,
    // not the raw stored flag — in large-landscape an un-toggled session's keybar
    // is hidden by default, so the toggle must show "hidden" and flip to shown.
    // Resolution happens here (the notifier has no BuildContext to read the
    // layout from).
    final keybarVisible = resolveKeybarVisible(
      visible: ref.watch(activeSessionKeybarVisibleProvider),
      explicit: ref.watch(activeSessionKeybarVisibleExplicitProvider),
      largeLandscape: isLargeLandscape(MediaQuery.sizeOf(context)),
    );
    final activeId = sessions.activeId;
    final palette = ref.watch(activeSessionThemeProvider);
    final fontFamily = ref.watch(activeSessionFontFamilyProvider);

    return SingleChildScrollView(
      child: Column(
        key: const Key('session-menu'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Slim grab-handle affordance (replaces showDragHandle, which only
          // came with the modal sheet).
          Center(
            child: Container(
              width: 32,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          if (sessions.entries.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No sessions yet.'),
            )
          else ...[
            for (final e in sessions.entries)
              _SessionRow(
                entry: e,
                isActive: e.id == sessions.activeId,
                onClose: onClose,
              ),
            // #817: a "Reconnect all" affordance shown whenever ANY session is
            // non-connected (dropped/failed/disconnected/connecting). Mirrors the
            // PWA's `activeSessionList` reconnect-all. It watches every entry's
            // proxy state so it appears/disappears reactively.
            _ReconnectAllRow(entries: sessions.entries),
          ],
          // #721: open the FULL home (Profiles / Settings / Diagnostics) OVER
          // the live terminal — the SAME unified view as first-run, not a
          // reduced connect form. Reaches every setting + profiles without
          // disconnecting: pushing a route leaves the sessions (and their
          // keep-alive) intact underneath. Picking a profile here starts an
          // ADDITIONAL session and the embedded chooser pops back to the
          // terminal on connect (`_popWhenConnected`); the AppBar back arrow
          // returns to the active session. Closes the menu first so the pushed
          // route isn't covered by the overlay.
          ListTile(
            key: const Key('session-menu-new'),
            dense: true,
            leading: const Icon(Icons.add),
            title: const Text('Profiles & settings'),
            subtitle: const Text('Add a connection · all settings'),
            onTap: () {
              final navigator = Navigator.of(context);
              onClose();
              openConnectHome(navigator.context);
            },
          ),
          const Divider(height: 1),
          // Slim per-session controls (#567): the five stacked full-width
          // ListTiles (keybar / theme / font / files / disconnect) regrew the
          // menu into clutter — the owner's #2 priority was to slim it back to
          // the PWA's tight direction. They now collapse into ONE compact row
          // of monochrome icon-buttons. Every essential control is KEPT and
          // keeps its existing key (so appearance/keybar/disconnect tests and
          // device screenshots still address them). All are session-scoped and
          // act on the ACTIVE session only (#601, #571).
          _SessionControlsRow(
            activeId: activeId,
            sessions: sessions,
            keybarVisible: keybarVisible,
            themeLabel: palette.label,
            themeKey: palette.key,
            fontFamily: fontFamily,
            onClose: onClose,
          ),
        ],
      ),
    );
  }
}

/// One compact row replacing the old stack of secondary ListTiles (#567),
/// re-proportioned in #724.
///
/// Layout (left→right), evenly proportioned into comfortably-tappable segments:
///   1. theme PICKER (palette glyph + current label) — tap opens a bottom sheet
///      listing all [terminalPalettes] with the current one marked (#724).
///   2. font-size − / + (NO numeric value, #724) flanking a small "Aa" glyph.
///   3. font-family PICKER (text glyph + current label) — tap opens a bottom
///      sheet listing the bundled faces with the current one marked (#724).
///   4. keybar visibility toggle.
///   5. disconnect.
///
/// #724 swapped the theme + font-family controls from blind advance-to-next
/// CYCLES to explicit PICKERS, and dropped the font-size number (the − / +
/// alone are enough; the menu is premium space). The control KEYS are unchanged
/// (`session-menu-theme-cycle` / `session-menu-fontfamily-cycle`) so existing
/// presence tests + device screenshots still address them.
///
/// Monochrome Material icons only — no emoji
/// (feedback_monochrome_icons_no_emoji). Controls disable themselves when there
/// is no active session, mirroring the prior per-tile `enabled` gating. Every
/// control is session-scoped and acts on the ACTIVE session only (#601, #571).
class _SessionControlsRow extends ConsumerWidget {
  const _SessionControlsRow({
    required this.activeId,
    required this.sessions,
    required this.keybarVisible,
    required this.themeLabel,
    required this.themeKey,
    required this.fontFamily,
    required this.onClose,
  });

  final String? activeId;
  final SessionsState sessions;
  final bool keybarVisible;
  final String themeLabel;
  final String themeKey;
  final String fontFamily;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final hasActive = activeId != null;
    final themeIndex = terminalPalettes.indexWhere((p) => p.key == themeKey);
    final fontIndex = terminalFontFamilies.indexWhere(
      (f) => f.id == fontFamily,
    );
    // #955/#888: in-terminal link/path DETECTION (the right-edge gutter marks)
    // is a GLOBAL viewer pref. Surface it here as a one-tap toggle so the owner
    // can flip it without digging into Settings. Toggling off→on also fires the
    // terminal view's live re-register + re-scan of the current cells, so it
    // doubles as a "make the gutter re-evaluate now" control.
    // EFFECTIVE state: the #971 kill switch force-disables detection until the
    // repaint gap is fixed, so the toggle reflects OFF (and is disabled) while
    // it's set — the stored pref is preserved and returns when it flips back.
    final detectionKilled = kDetectionDisabled971;
    final detectionOn =
        !detectionKilled && ref.watch(detectionSettingsProvider).enabled;

    return Padding(
      key: const Key('session-menu-controls'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 1. Theme PICKER (#724). Tapping opens a scrollable bottom sheet of
          // ALL palettes with the current one marked; selecting one sets +
          // persists the ACTIVE session's theme. The current label sits next to
          // the glyph so the control still communicates state at a glance.
          Expanded(
            flex: 3,
            child: _PickerChip(
              itemKey: const Key('session-menu-theme-cycle'),
              icon: Icons.palette_outlined,
              label: themeLabel,
              enabled: hasActive,
              onTap: () {
                // #664: the menu is a full-screen OverlayEntry whose tap barrier
                // sits ABOVE any pushed route, so a bottom sheet shown while the
                // menu is open is un-tappable underneath the barrier. Capture the
                // app Navigator + the notifier/store (closing the menu disposes
                // this widget's `ref`), close the menu, THEN show the sheet —
                // same idiom as the "Profiles & settings" / Files affordances. We
                // mutate the session by id (`activeId!`), so closing first is safe.
                final navContext = Navigator.of(context).context;
                final appearance = ref.read(sessionAppearanceProvider.notifier);
                final store = ref.read(profilesStoreProvider);
                onClose();
                _showPickerSheet(
                  navigatorContext: navContext,
                  title: 'Theme',
                  count: terminalPalettes.length,
                  selectedIndex: themeIndex,
                  labelOf: (i) => terminalPalettes[i].label,
                  onPick: (i) =>
                      _pickTheme(appearance, store, sessions, activeId!, i),
                );
              },
            ),
          ),
          // 2. Font-size − / + (#724): NO numeric value between them. A muted
          // "Aa" glyph stands in for the value so the pair still reads as a
          // font-size control. Each button is a ~44px tap target.
          _StepButton(
            itemKey: const Key('session-menu-fontsize-dec'),
            tooltip: 'Decrease font size',
            icon: Icons.remove,
            enabled: hasActive,
            onTap: () => _stepFont(ref, sessions, activeId!, -kFontSizeStep),
          ),
          Text(
            'Aa',
            key: const Key('session-menu-fontsize-glyph'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          _StepButton(
            itemKey: const Key('session-menu-fontsize-inc'),
            tooltip: 'Increase font size',
            icon: Icons.add,
            enabled: hasActive,
            onTap: () => _stepFont(ref, sessions, activeId!, kFontSizeStep),
          ),
          // 3. Font-family PICKER (#724, was a cycle in #679). Same idiom as the
          // theme picker: tap opens a bottom sheet of the bundled faces with the
          // current one marked; selecting sets + persists the ACTIVE session's
          // family onto its profile (#640 idiom).
          Expanded(
            flex: 3,
            child: _PickerChip(
              itemKey: const Key('session-menu-fontfamily-cycle'),
              labelKey: const Key('session-menu-fontfamily-label'),
              icon: Icons.text_fields,
              label: _fontFamilyLabel(fontFamily),
              enabled: hasActive,
              onTap: () {
                // See the theme picker above (#664): capture the navigator +
                // notifier/store, close the overlay menu (which disposes `ref`),
                // then show the sheet so it isn't trapped under the barrier.
                final navContext = Navigator.of(context).context;
                final appearance = ref.read(sessionAppearanceProvider.notifier);
                final store = ref.read(profilesStoreProvider);
                onClose();
                _showPickerSheet(
                  navigatorContext: navContext,
                  title: 'Font',
                  count: terminalFontFamilies.length,
                  selectedIndex: fontIndex,
                  labelOf: (i) => terminalFontFamilies[i].label,
                  onPick: (i) => _pickFontFamily(
                    appearance,
                    store,
                    sessions,
                    activeId!,
                    terminalFontFamilies[i].id,
                  ),
                );
              },
            ),
          ),
          // 3a. Port forwards (#1047) — opens the ssh -L sheet for the ACTIVE
          // session. The glyph carries a count badge while any forward is
          // ACTIVE (cheap: the proxy caches the latest table). Same #664
          // overlay idiom as the pickers: capture the app navigator + the
          // entry/store, close the menu, THEN show the sheet.
          _ForwardsButton(
            entry: sessions.active,
            enabled: hasActive,
            onOpen: (entry) {
              final navContext = Navigator.of(context).context;
              final store = ref.read(profilesStoreProvider);
              onClose();
              unawaited(
                showPortForwardsSheet(navContext, entry: entry, store: store),
              );
            },
          ),
          // Files moved to a PER-ROW affordance (#649): each session row now
          // carries its own `session-menu-files-${id}` icon next to its X.
          // 3b. Link/path DETECTION toggle (#955/#888) — GLOBAL. Its glyph is a
          // link inside a BUBBLE (#971), echoing the right-edge gutter mark and
          // DISTINCT from the disconnect button's broken-chain (they used to
          // share Icons.link_off). Filled bubble = on, outline = off, muted +
          // disabled while the #971 kill switch has detection force-off.
          _StepButton(
            itemKey: const Key('session-menu-detection-toggle'),
            tooltip: detectionKilled
                ? 'Link detection is off while we fix a repaint issue'
                : (detectionOn ? 'Link detection: on' : 'Link detection: off'),
            iconWidget: _DetectionGlyph(
              active: detectionOn,
              color: detectionKilled
                  ? theme.colorScheme.onSurface.withValues(alpha: 0.38)
                  : (detectionOn
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant),
            ),
            selected: detectionOn,
            enabled: !detectionKilled,
            onTap: () => ref
                .read(detectionSettingsProvider.notifier)
                .setEnabled(!detectionOn),
            // #1031 review change 7: the lab's most frequent job ("this
            // highlight looks wrong") is noticed IN the terminal — long-press
            // jumps straight to the Detection lab, no Settings scroll. Same
            // #664 overlay idiom as the pickers: capture the app navigator,
            // close the menu (its barrier sits above pushed routes), THEN
            // push on that navigator.
            onLongPress: () {
              final navContext = Navigator.of(context).context;
              onClose();
              Navigator.of(navContext).push(
                MaterialPageRoute<void>(
                  builder: (_) => const DetectionLabScreen(),
                ),
              );
            },
          ),
          // 4. Keybar visibility toggle. Filled icon = visible, outlined =
          // hidden, so the glyph itself communicates the toggle state.
          // PER-SESSION (#573): flips THIS (active) session's flag only.
          _StepButton(
            itemKey: const Key('session-menu-keybar-toggle'),
            tooltip: keybarVisible ? 'Hide keybar' : 'Show keybar',
            icon: keybarVisible ? Icons.keyboard : Icons.keyboard_outlined,
            selected: keybarVisible,
            enabled: hasActive,
            // #1086: flip the EFFECTIVE (rendered) value. setKeybarVisible marks
            // the choice explicit, so the large-landscape hide-by-default no
            // longer applies to this session — the user's choice is honoured.
            onTap: () => ref
                .read(sessionAppearanceProvider.notifier)
                .setKeybarVisible(activeId!, !keybarVisible),
          ),
          // 5. Disconnect the ACTIVE session (#607). Fully closes (disconnect +
          // dispose + REMOVE the entry) so a re-connect restarts the service
          // (#564).
          _StepButton(
            itemKey: const Key('terminal-disconnect-button'),
            tooltip: 'Disconnect',
            icon: Icons.link_off,
            enabled: hasActive,
            onTap: () {
              onClose();
              ref.read(sessionsProvider.notifier).close(activeId!);
            },
          ),
        ],
      ),
    );
  }
}

/// A tappable picker affordance: a monochrome glyph + current-value label that
/// opens a picker sheet on tap (#724). Fills its [Expanded] slot so the theme
/// and font controls are evenly proportioned, with a ~44px-tall tap target.
class _PickerChip extends StatelessWidget {
  const _PickerChip({
    required this.itemKey,
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onTap,
    this.labelKey,
  });

  final Key itemKey;
  final Key? labelKey;
  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = enabled
        ? theme.colorScheme.onSurface
        : theme.colorScheme.onSurface.withValues(alpha: 0.38);
    return InkWell(
      key: itemKey,
      borderRadius: BorderRadius.circular(8),
      onTap: enabled ? onTap : null,
      child: Container(
        height: 44,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 20, color: fg),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                key: labelKey,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: fg),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A fixed-size ~44px icon button used for the font − / +, keybar toggle, and
/// disconnect controls — so every non-picker control in the row is the same
/// comfortable tap target (#724). [selected] tints the glyph for toggle state.
class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.itemKey,
    required this.tooltip,
    required this.enabled,
    required this.onTap,
    this.onLongPress,
    this.icon,
    this.iconWidget,
    this.selected = false,
  }) : assert(icon != null || iconWidget != null,
            'provide an icon or an iconWidget');

  final Key itemKey;
  final String tooltip;
  final IconData? icon;

  /// A custom glyph (e.g. the #971 detection bubble) rendered instead of
  /// [Icon]([icon]) when provided — for controls whose state a single Material
  /// glyph can't convey.
  final Widget? iconWidget;
  final bool enabled;
  final bool selected;
  final VoidCallback onTap;

  /// #1031 review change 7: optional long-press action (the detection glyph
  /// long-presses into the Detection lab). When set, the IconButton drops its
  /// tooltip — Tooltip installs its OWN long-press recognizer that would eat
  /// the gesture (the #943 IconButton-tooltip gotcha) — and an outer
  /// GestureDetector claims it instead.
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = selected ? theme.colorScheme.primary : null;
    final button = IconButton(
      key: itemKey,
      tooltip: onLongPress == null ? tooltip : null,
      iconSize: 20,
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      color: color,
      icon: iconWidget ?? Icon(icon),
      onPressed: enabled ? onTap : null,
    );
    if (onLongPress == null) return button;
    return GestureDetector(
      behavior: HitTestBehavior.deferToChild,
      onLongPress: enabled ? onLongPress : null,
      child: Semantics(label: tooltip, child: button),
    );
  }
}

/// Port-forwards control (#1047): a ~44px monochrome icon that opens the ssh
/// -L sheet for the ACTIVE session, wearing a small count badge while any
/// forward is ACTIVE. Reactive via the proxy's forward stream (initialData =
/// the proxy's cached table, so a re-opened menu shows the count immediately).
class _ForwardsButton extends StatelessWidget {
  const _ForwardsButton({
    required this.entry,
    required this.enabled,
    required this.onOpen,
  });

  final SessionEntry? entry;
  final bool enabled;
  final void Function(SessionEntry entry) onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final e = entry;
    if (e == null) {
      return IconButton(
        key: const Key('session-menu-port-forwards'),
        tooltip: 'Port forwards',
        iconSize: 20,
        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.settings_ethernet),
        onPressed: null,
      );
    }
    return StreamBuilder<List<ForwardInfo>>(
      stream: e.proxy.forwardEvents,
      initialData: e.proxy.forwards,
      builder: (context, snapshot) {
        final forwards = snapshot.data ?? const <ForwardInfo>[];
        final activeCount =
            forwards.where((f) => f.status == ForwardStatus.active).length;
        final glyph = Icon(
          Icons.settings_ethernet,
          color: activeCount > 0 ? theme.colorScheme.primary : null,
        );
        return IconButton(
          key: const Key('session-menu-port-forwards'),
          tooltip: activeCount > 0
              ? 'Port forwards ($activeCount active)'
              : 'Port forwards',
          iconSize: 20,
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          icon: activeCount > 0
              ? Badge.count(
                  key: const Key('session-menu-port-forwards-badge'),
                  count: activeCount,
                  child: glyph,
                )
              : glyph,
          onPressed: enabled ? () => onOpen(e) : null,
        );
      },
    );
  }
}

/// #971 detection glyph: a link inside a rounded BUBBLE — echoes the right-edge
/// URL gutter mark and is visually DISTINCT from the disconnect button's
/// broken-chain (`Icons.link_off`), which it used to share. [active] fills the
/// bubble; otherwise it's an outline. [color] carries the on/off/disabled tint.
class _DetectionGlyph extends StatelessWidget {
  const _DetectionGlyph({required this.active, required this.color});

  final bool active;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 26,
        height: 16,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? color.withValues(alpha: 0.20) : Colors.transparent,
          border: Border.all(color: color, width: 1.6),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(Icons.link, size: 12, color: color),
      ),
    );
  }
}

/// Session IDs the owner has EXCLUDED from "Reconnect all" (owner request:
/// reconnect-heavy workflow). A per-session opt-out — the row's ⊗ toggle — so the
/// mass reconnect SKIPS these while leaving each session in the list (it can
/// still be reconnected individually via its own Reconnect button). Ephemeral:
/// read by [_ReconnectAllRow], toggled by [_SessionRow]. A recovered session just
/// leaves the reconnect group; a stale id here is harmless (the filter no-ops).
final reconnectExcludedProvider =
    StateProvider<Set<String>>((ref) => <String>{});

class _SessionRow extends ConsumerWidget {
  const _SessionRow({
    required this.entry,
    required this.isActive,
    required this.onClose,
  });

  final SessionEntry entry;
  final bool isActive;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // #739: profile color swatch for THIS row's session. The per-session color
    // is seeded from the profile on connect (#653) and read via
    // `sessionColorProvider`. The SAME color identifies the SAME profile
    // everywhere (PWA `session-dot`).
    final profileColor = ref.watch(sessionColorProvider(entry.id));
    // #817: the row now reads the session's lifecycle STATE directly (not a
    // boolean) and surfaces a state-driven status dot + per-state action.
    // StreamBuilder on the proxy state stream keeps the row reactive as the
    // session moves connected → softDisconnected/reconnecting → failed without
    // re-opening the menu — exactly the PWA `activeSessionList` behaviour.
    return StreamBuilder<SshSessionData>(
      stream: entry.proxy.stream,
      initialData: entry.proxy.data,
      builder: (context, snapshot) {
        final data = snapshot.data ?? entry.proxy.data;
        return _buildRow(context, ref, data.state, data.error, profileColor);
      },
    );
  }

  Widget _buildRow(
    BuildContext context,
    WidgetRef ref,
    SshSessionState state,
    String? error,
    Color? profileColor,
  ) {
    final theme = Theme.of(context);
    final subtitle = _subtitleFor(theme, state, error);
    // Whether THIS session is opted out of "Reconnect all" (owner request).
    final excluded = ref.watch(reconnectExcludedProvider).contains(entry.id);
    final tile = ListTile(
      key: Key('session-menu-row-${entry.id}'),
      // ACTIVE session standout (owner ask): a primary-tinted fill via the
      // tile's own selectedTileColor (ListTile must paint its own bg/ink on its
      // Material ancestor — wrapping it in a colored box is disallowed), plus a
      // left accent stripe added by the border-only wrapper below. `selected`
      // also announces it to a11y and tints the label/glyph primary.
      selected: isActive,
      selectedTileColor: theme.colorScheme.primary.withValues(alpha: 0.10),
      // [status dot][terminal] — the dot's COLOR + animation reflect the
      // session state (#817): solid profile/accent when connected, pulsing
      // while connecting, amber while reconnecting, red on failure, grey when
      // user-disconnected. Monochrome theme glyphs only — no emoji
      // (feedback_monochrome_icons_no_emoji). The profile color is preserved as
      // the "connected" tint so the SAME color still identifies the profile.
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SessionStateDot(
            key: Key('session-menu-status-dot-${entry.id}'),
            // The swatch key is retained (#739 tests + device screenshots
            // address it) and now lives on the same dot.
            swatchKey: Key('session-menu-swatch-${entry.id}'),
            state: state,
            profileColor: profileColor,
          ),
          const SizedBox(width: 8),
          Icon(
            Icons.terminal,
            color: isActive ? theme.colorScheme.primary : null,
          ),
        ],
      ),
      dense: true,
      title: Text(
        entry.label,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      // A short status line under the label for non-connected states (#817) so
      // a dropped session is never an invisible/✕-only tile: "Connecting…",
      // "Reconnecting…", or the failure reason. Connected rows stay subtitle-
      // less (the slim #567 direction).
      subtitle: subtitle,
      // Trailing action set (#817): a Reconnect button is ADDED for drop states
      // (softDisconnected/reconnecting/failed/disconnected) — it's omitted while
      // connected/connecting (nothing to manually reconnect). Files stays a
      // per-row affordance in EVERY state (#649 contract — the browser handles a
      // non-live link itself). The ✕ is ALWAYS present and means "forget this
      // session" (explicit close).
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // #950: favorites star — shown ONLY when THIS session's profile has
          // marked favorites. Tap opens the profile-scoped favorites sheet;
          // tapping a favorite closes the menu and opens the file browser there.
          if (ref
                  .watch(profileFavoritesProvider(entry.profileKey))
                  .valueOrNull
                  ?.isNotEmpty ??
              false)
            IconButton(
              key: Key('session-menu-favorites-${entry.id}'),
              tooltip: 'Favorites',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.star),
              onPressed: () {
                final sessionId = entry.id;
                final profileKey = entry.profileKey;
                final navigator = Navigator.of(context);
                final store = ref.read(favoritesStoreProvider);
                // The container (not `ref`) survives the row unmounting when the
                // menu closes below — onChanged fires while the sheet is open.
                final container = ProviderScope.containerOf(
                  context,
                  listen: false,
                );
                // Close the session-menu overlay FIRST: it sits ABOVE routes, so
                // a modal sheet opened under it can't be tapped (its barrier
                // absorbs the pointers). Mirrors the Files button. Then show the
                // sheet on the root navigator's (stable) context.
                onClose();
                showFavoritesMenu(
                  navigator.context,
                  store: store,
                  profileKey: profileKey,
                  onNavigate: (path) {
                    unawaited(
                      openFileBrowser(
                        navigator.context,
                        sessionId,
                        initialPath: path,
                      ),
                    );
                  },
                  onChanged: () =>
                      container.invalidate(profileFavoritesProvider(profileKey)),
                );
              },
            ),
          IconButton(
            key: Key('session-menu-files-${entry.id}'),
            tooltip: 'Files',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.folder_outlined),
            // Open the file browser for THIS row's session id (its live SSH
            // connection drives SFTP). Close the menu first so the browser
            // route isn't covered by the overlay. #891: open at the profile's
            // default directory (else SFTP home) via openFileBrowserForSession.
            onPressed: () {
              final sessionId = entry.id;
              final navigator = Navigator.of(context);
              onClose();
              unawaited(
                openFileBrowserForSession(navigator.context, ref, sessionId),
              );
            },
          ),
          // Reconnect — for droppable states AND for a CONNECTED session (owner
          // request: force-reconnect an active session, e.g. to pick up a
          // control-mode toggle that only applies on reconnect). reconnect(id)
          // routes through the notifier → _reviveFromProfile, which re-issues
          // connect in ANY state (the same path the control-mode toggle uses);
          // it (re)starts the foreground isolate first so a last-session drop
          // that stopped the service still comes back.
          if (sessionCanReconnect(state) ||
              state == SshSessionState.connected)
            IconButton(
              key: Key('session-menu-reconnect-${entry.id}'),
              tooltip: state == SshSessionState.connected
                  ? 'Reconnect (force)'
                  : 'Reconnect',
              visualDensity: VisualDensity.compact,
              // Monochrome replay glyph (mirrors the recents reconnect icon).
              icon: const Icon(Icons.replay),
              onPressed: () =>
                  ref.read(sessionsProvider.notifier).reconnect(entry.id),
            ),
          // ⊗ Exclude this session from "Reconnect all" (owner request). Shown
          // only while it's IN the reconnect group (a droppable state). Distinct
          // from the ✕ below (which CLOSES/forgets the session) — this KEEPS the
          // session, it just makes the mass reconnect skip it; toggle again (⊕)
          // to re-include. It stays individually reconnectable via its own
          // Reconnect button.
          if (sessionCanReconnect(state))
            IconButton(
              key: Key('session-menu-exclude-reconnect-${entry.id}'),
              tooltip: excluded
                  ? 'Include in Reconnect all'
                  : 'Exclude from Reconnect all',
              visualDensity: VisualDensity.compact,
              icon: Icon(
                excluded ? Icons.add_circle_outline : Icons.highlight_off,
              ),
              onPressed: () => ref
                  .read(reconnectExcludedProvider.notifier)
                  .update((s) {
                    final next = <String>{...s};
                    if (!next.remove(entry.id)) next.add(entry.id);
                    return next;
                  }),
            ),
          IconButton(
            key: Key('session-menu-close-${entry.id}'),
            tooltip: 'Close session',
            icon: const Icon(Icons.close),
            onPressed: () {
              ref.read(sessionsProvider.notifier).close(entry.id);
            },
          ),
        ],
      ),
      onTap: () {
        ref.read(sessionsProvider.notifier).setActive(entry.id);
        onClose();
      },
    );
    // Non-active rows render plain. The ACTIVE session's fill comes from the
    // tile's selectedTileColor above; here we add a left accent stripe (border
    // ONLY — no background color, which would hide the ListTile's ink). Together
    // with the bold label + tinted terminal glyph, "which session am I looking
    // at" reads at a glance. Monochrome/theme-driven — no emoji
    // (feedback_monochrome_icons_no_emoji).
    if (!isActive) return tile;
    return DecoratedBox(
      key: Key('session-menu-active-${entry.id}'),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: theme.colorScheme.primary, width: 4),
        ),
      ),
      child: tile,
    );
  }

  /// The per-state status line under the row label, or null for `connected`
  /// (slim — no subtitle) and `idle` (pre-connect, nothing to say yet).
  Widget? _subtitleFor(
    ThemeData theme,
    SshSessionState state,
    String? error,
  ) {
    switch (state) {
      case SshSessionState.idle:
      case SshSessionState.connected:
        return null;
      case SshSessionState.connecting:
      case SshSessionState.authenticating:
      case SshSessionState.awaitingHostKey:
        return Text(
          key: Key('session-menu-status-text-${entry.id}'),
          'Connecting…',
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall,
        );
      case SshSessionState.softDisconnected:
      case SshSessionState.reconnecting:
        return Text(
          key: Key('session-menu-status-text-${entry.id}'),
          'Reconnecting…',
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: Colors.orange.shade700,
          ),
        );
      case SshSessionState.failed:
        final reason = (error != null && error.trim().isNotEmpty)
            ? error.trim()
            : 'Disconnected';
        return Text(
          key: Key('session-menu-status-text-${entry.id}'),
          reason,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.error,
          ),
        );
      case SshSessionState.disconnected:
        return Text(
          key: Key('session-menu-status-text-${entry.id}'),
          'Disconnected',
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        );
    }
  }
}

/// "Reconnect all" affordance (#817), shown only when at least one session is
/// in a manually-reconnectable drop state. Each tap force-reconnects every
/// dropped session (held params, no auth re-supply). It watches every entry's
/// proxy state so it appears/disappears reactively as sessions drop/recover —
/// mirroring the PWA `activeSessionList` reconnect-all.
class _ReconnectAllRow extends ConsumerStatefulWidget {
  const _ReconnectAllRow({required this.entries});

  final List<SessionEntry> entries;

  @override
  ConsumerState<_ReconnectAllRow> createState() => _ReconnectAllRowState();
}

class _ReconnectAllRowState extends ConsumerState<_ReconnectAllRow> {
  final List<StreamSubscription<SshSessionData>> _subs = [];

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(_ReconnectAllRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-subscribe when the entry set changes (a session added/removed).
    _resubscribe();
  }

  void _subscribe() {
    for (final e in widget.entries) {
      _subs.add(
        e.proxy.stream.listen((_) {
          if (mounted) setState(() {});
        }),
      );
    }
  }

  void _resubscribe() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _subscribe();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Owner request: sessions the user ⊗-excluded are SKIPPED by "Reconnect
    // all" (they stay in the list, reconnectable individually). Watching the set
    // rebuilds this row as exclusions toggle so the count + visibility track it.
    final excluded = ref.watch(reconnectExcludedProvider);
    final dropped = widget.entries
        .where(
          (e) =>
              sessionCanReconnect(e.proxy.data.state) &&
              !excluded.contains(e.id),
        )
        .toList();
    if (dropped.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: OutlinedButton.icon(
        key: const Key('session-menu-reconnect-all'),
        icon: const Icon(Icons.restart_alt, size: 18),
        label: Text(
          dropped.length == 1 ? 'Reconnect' : 'Reconnect all (${dropped.length})',
        ),
        onPressed: () {
          // Route through the notifier so the foreground task isolate is
          // (re)started before each reconnect command — see
          // SessionsNotifier.reconnect (#817). Each reconnect is fire-and-forget
          // (_reviveFromProfile), so one session that won't connect can't block
          // the others.
          final notifier = ref.read(sessionsProvider.notifier);
          for (final e in dropped) {
            notifier.reconnect(e.id);
          }
          // Owner request: don't leave the user parked on a session that won't
          // connect ("reconnect many hangs when one doesn't connect — should
          // focus first session"). FOCUS the first session immediately so they
          // land on a live view while the rest reconnect in the background.
          if (widget.entries.isNotEmpty) {
            notifier.setActive(widget.entries.first.id);
          }
        },
      ),
    );
  }
}
