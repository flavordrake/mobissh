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
import '../state/profiles_providers.dart';
import '../state/sessions.dart';
import '../state/ui_prefs_providers.dart';
import '../storage/profiles_store.dart' show ProfilesStore;
import 'file_browser_screen.dart';

/// Opens the session menu as a NON-MODAL overlay anchored to the bottom, above
/// the keyboard. Returns once dismissed (outside tap or an action closes it).
///
/// Unlike `showModalBottomSheet`, this inserts an `OverlayEntry` rather than
/// pushing a route, so the terminal keeps primary focus and the soft keyboard
/// stays up (#585).
///
/// [bottomReserve] is the height (logical px) of the session bar that summoned
/// the menu. The panel floats ABOVE that reserved strip so its last row (Files)
/// never lands on top of the trigger — the owner hit "tap to dismiss lands on
/// Files" because the panel overlapped the bar (2026-06-01). The full-screen
/// tap barrier still covers the bar, so a tap on the (now-uncovered) trigger
/// dismisses the menu: same touch target opens AND closes it.
Future<void> showSessionMenu(BuildContext context, {double bottomReserve = 0}) {
  final overlay = Overlay.of(context);
  final completer = Completer<void>();
  late OverlayEntry entry;

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
          Positioned(
            left: 0,
            right: 0,
            bottom: liftAboveBar,
            // canRequestFocus:false guarantees the menu (and its tappable rows)
            // never steal focus from the terminal's editable — the keyboard
            // stays up. Taps still work; toggles/switches don't need focus.
            child: FocusScope(
              canRequestFocus: false,
              child: Material(
                color: Theme.of(ctx).colorScheme.surface,
                elevation: 8,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(16),
                ),
                clipBehavior: Clip.antiAlias,
                child: SessionMenu(onClose: close),
              ),
            ),
          ),
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
    final keybarVisible = ref.watch(activeSessionKeybarVisibleProvider);
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
          else
            for (final e in sessions.entries)
              _SessionRow(
                entry: e,
                isActive: e.id == sessions.activeId,
                onClose: onClose,
              ),
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
          // Files moved to a PER-ROW affordance (#649): each session row now
          // carries its own `session-menu-files-${id}` icon next to its X.
          // 4. Keybar visibility toggle. Filled icon = visible, outlined =
          // hidden, so the glyph itself communicates the toggle state.
          // PER-SESSION (#573): flips THIS (active) session's flag only.
          _StepButton(
            itemKey: const Key('session-menu-keybar-toggle'),
            tooltip: keybarVisible ? 'Hide keybar' : 'Show keybar',
            icon: keybarVisible ? Icons.keyboard : Icons.keyboard_outlined,
            selected: keybarVisible,
            enabled: hasActive,
            onTap: () => ref
                .read(sessionAppearanceProvider.notifier)
                .toggleKeybarVisible(activeId!),
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
    required this.icon,
    required this.enabled,
    required this.onTap,
    this.selected = false,
  });

  final Key itemKey;
  final String tooltip;
  final IconData icon;
  final bool enabled;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = selected ? theme.colorScheme.primary : null;
    return IconButton(
      key: itemKey,
      tooltip: tooltip,
      iconSize: 20,
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      color: color,
      icon: Icon(icon),
      onPressed: enabled ? onTap : null,
    );
  }
}

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
    final theme = Theme.of(context);
    // #739: profile color swatch for THIS row's session. The per-session color
    // is seeded from the profile on connect (#653) and read via
    // `sessionColorProvider`. Unlike the session bar — which falls back to the
    // theme accent (`session-bar-swatch`) — a colorless session here shows a
    // NEUTRAL muted dot (`outlineVariant`), never a fake real-looking color
    // (issue #739). The SAME color identifies the SAME profile everywhere
    // (PWA `session-dot`).
    final profileColor = ref.watch(sessionColorProvider(entry.id));
    final swatchColor = profileColor ?? theme.colorScheme.outlineVariant;
    return ListTile(
      key: Key('session-menu-row-${entry.id}'),
      // [swatch][terminal] — the small filled circle (profile color, else a
      // neutral dot) sits immediately left of the existing terminal glyph so the
      // row reads as `● ⌨ label`, mirroring the profile list / session bar.
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            key: Key('session-menu-swatch-${entry.id}'),
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: swatchColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Icon(
            Icons.terminal,
            color: isActive ? theme.colorScheme.primary : null,
          ),
        ],
      ),
      // #567: the label alone identifies the session (mirrors the PWA's slim
      // session list, which shows the label + a connection dot, no verbose
      // user@host:port subtitle). Dropping the subtitle halves each row's
      // height and tightens the menu.
      dense: true,
      title: Text(
        entry.label,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      // [file icon][X] — the file icon opens the browser for THIS row's
      // session (#649); the X disconnects/closes THIS row's session. Both are
      // per-row so a multi-session menu addresses each session independently.
      // The file glyph is monochrome (Material `folder_outlined`, currentColor)
      // — no emoji (feedback_monochrome_icons_no_emoji).
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: Key('session-menu-files-${entry.id}'),
            tooltip: 'Files',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.folder_outlined),
            // Open the file browser for THIS row's session id (its live SSH
            // connection drives SFTP), not just the active session. Close the
            // menu first so the browser route isn't covered by the overlay.
            onPressed: () {
              final sessionId = entry.id;
              final navigator = Navigator.of(context);
              onClose();
              openFileBrowser(navigator.context, sessionId);
            },
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
      onLongPress: () => _showRowActions(context, ref),
    );
  }

  void _showRowActions(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const Key('session-menu-action-disconnect'),
              leading: const Icon(Icons.link_off),
              title: const Text('Disconnect'),
              onTap: () {
                entry.proxy.disconnect();
                Navigator.of(ctx).pop();
              },
            ),
            ListTile(
              key: const Key('session-menu-action-close'),
              leading: const Icon(Icons.close),
              title: const Text('Close session'),
              onTap: () {
                ref.read(sessionsProvider.notifier).close(entry.id);
                Navigator.of(ctx).pop();
              },
            ),
          ],
        ),
      ),
    );
  }
}
