Tracking: #1153 (slices #1154, #1155)

# Link highlight options (native)

Status: SPEC v1 (2026-09-16). Owner directive: replace the one-tap detection toggle with an options menu — intensity (low / medium / high: saturation + visual noise of the overlay), gutter side, and gutter mode (overlay the last column vs a dedicated column). Plan, spec, red→green tests on UI and impl.

## 1. Purpose

Detection ("link highlight") paints wash bubbles under detected URLs/paths and puts chips in a right-edge gutter strip. Today the session-menu button is a bare on/off toggle and every visual parameter is a compile-time constant. Users on bright themes or dense TUIs want the overlay quieter; left-handed / left-rail (tablet) users want the gutter on the left; users who lose the last terminal column under the strip want a real reserved column instead. This spec turns the toggle into a small options menu and makes those three parameters persisted user settings with a zero-visual-change default.

## 2. Scope

In: session-menu options sheet; `DetectionSettings` extension (intensity, gutterSide, gutterMode); intensity composition in the style resolver + gutter layer; gutter side for BOTH right-edge layers; dedicated-column gutter mode incl. PTY grid math and touch mapping; Detection Lab preview parity; settings reset; tests (unit, widget, emulator).

Out: per-pattern intensity (already the Lab's per-pattern sliders — unchanged); chip colour/opacity changes (chip accent identity is a contract, §6); a Settings-panel mirror of the three controls (open decision D1); keybar entry; PWA.

## 3. Options menu (UI)

R1. Tapping `Key('session-menu-detection-toggle')` no longer flips `enabled`. It closes the session menu (the #664 idiom: `onClose()` first, the menu barrier sits above pushed routes) and opens a modal bottom sheet `Key('link-highlight-menu')`.

R2. Sheet contents, top to bottom, all LIVE-apply (no Save button; every change persists immediately through `DetectionSettingsNotifier`):
- Master switch `Key('link-highlight-enabled')` bound to `enabled` (glyph on the session-menu button keeps reflecting `enabled`).
- Intensity segmented control: `Key('link-highlight-intensity-low')`, `-medium`, `-high`. Labels "Low", "Medium", "High".
- Gutter side segmented control: `Key('link-highlight-side-left')`, `-right`. Labels "Left", "Right".
- Gutter mode segmented control: `Key('link-highlight-mode-overlay')`, `-column`. Labels "Overlay last column", "Dedicated column".
- Tile `Key('link-highlight-lab')` "Detection Lab…" → pushes `DetectionLabScreen` (same route the long-press uses).

R3. Long-press on the session-menu button keeps opening the Detection Lab (existing behaviour and test `session_menu_slim_test.dart:216-235` unchanged).

R4. When `kDetectionDisabled971` is true the button stays disabled with the kill-switch tooltip; the sheet is unreachable (unchanged).

R5. Intensity/side/mode controls are enabled regardless of `enabled` (a user may configure while off); they take effect the moment detection is on.

R6. Large-landscape layout (#1086): the session menu drops from the top bar; the same button opens the same sheet. No separate tablet UI.

## 4. Data model

R7. `DetectionSettings` gains three fields, all additive with defaults equal to today's behaviour:
- `DetectionIntensity intensity = DetectionIntensity.medium` (`enum DetectionIntensity { low, medium, high }`)
- `GutterSide gutterSide = GutterSide.right` (`enum GutterSide { left, right }`)
- `GutterMode gutterMode = GutterMode.overlay` (`enum GutterMode { overlay, column }`)
Enums live in `native/lib/state/detection_providers.dart`. JSON fields `intensity`, `gutterSide`, `gutterMode` store the enum `name`. Notifier setters `setIntensity`, `setGutterSide`, `setGutterMode`.

R8. Persistence stays in the existing key `mobissh.detection.settings` (never a key bump). Additive fields follow the `command`/`relpath` precedent: `detectionSettingsSchemaVersion` stays 1; a pre-existing stored value hydrates the new fields to their defaults; an unknown or non-string enum name falls back to the default field-by-field (corrupt-resilient, never throws). No backup allowlist change (`backup_restore.dart:_allowedSettingKeys`) because no new key.

R9. Settings → Reset (`settings_panel.dart:501-511`) restores the three fields to defaults alongside the existing detection fields.

R10. The terminal view's `ref.listen<DetectionSettings>(detectionSettingsProvider, …)` (`ghostty_terminal_view.dart:4508`) clears + re-registers patterns. It MUST NOT fire for a change of intensity/side/mode only: select on the pattern-relevant projection (`enabled, url, path, command, relpath`) so a pure-visual change rides the `ref.watch` rebuild path (like a Lab style edit) and never rescans.

## 5. Intensity semantics

Intensity is a GLOBAL level composed over the shipped derivation. Medium is the identity: with `intensity == medium` every colour and every alpha is bit-identical to today (the golden test in `detection_style_resolver_test.dart:37-58` is parameterised on the level and stays green at medium).

R11. Wash colour. In `DetectionStyleResolver.resolveStyle` the base wash colour (`ghosttyBubbleWashColor` or the Lab hue) is transformed by the level BEFORE the per-pattern Lab intensity multiplier and its clamp band (`kDetectionIntensityMin/Max/Gap`):
- low: HSL saturation × 0.6, alpha × 0.6
- medium: identity (no HSL round-trip — the code path must not touch the colour at all)
- high: HSL saturation × 1.25 (clamped to 1.0), alpha × 1.35 (clamped to 1.0)
The resulting alpha at low must stay ≥ 0.12 and the colour must never resolve to null/transparent (the #1074 shot test's tracking assertion keys on non-null).

R12. Ordering invariant: for every pattern × verified × background, `alpha(low) < alpha(medium) < alpha(high)` and `detected < verified` still holds within each level (composition happens before the pair clamp, so it cannot invert the pair).

R13. Chips are untouched by intensity: `chipAccent`, `chipColor(accent)` and chip opacity 1.0 are unchanged at every level (`detection_style_resolver.dart:118-121` contract; seam test stays green). What the level does change in the gutter layer ("visual noise"):
- strip hint fill (`ghosttyGutterLayer` `color.withValues(alpha: 0.06)`): low 0.0, medium 0.06, high 0.10
- chip drop shadow (`GutterMarkChip` `boxShadow` alpha 0.35): low none, medium 0.35, high 0.35
These values are exposed via a `GutterMarkStyle`-adjacent `GutterNoise` record resolved from the level so the Lab preview (§7) renders the same thing.

R14. The #1060 alpha band test (`ghostty_wash_alpha_1053_test.dart`) asserts the four `kGhostty*WashAlpha*` constants; those constants are NOT edited. New tests assert the composed values at each level.

## 6. Gutter side

R15. `GutterSide` moves BOTH right-edge layers together: `GhosttyGutterLayer` (chips) and `GutterLineSelectLayer` (line-select strip). They never sit on opposite edges. Positioned `left: 0` / `right: 0`, chip `Align` and inset mirror by side.

R16. `_isGutterCol(col)` mirrors: right → `col > cols - gutterCols` (today), left → `col <= gutterCols`.

R17. Gutter chip tap / long-press / gutter line-select gestures work identically on the left (same keys `gutter-mark-<row>`, same menus). The wash layer is side-agnostic.

## 7. Gutter mode

R18. `GutterMode.overlay` is today's behaviour: the 28dp strip is a translucent overlay over the last ~N columns; PTY cols unchanged; text selection suppressed under the strip.

R19. `GutterMode.column` reserves the strip: `ghosttyGridForBox` subtracts `kGutterStripWidth` from `innerW` on the gutter side, the `TerminalView` gets an asymmetric padding (`kGhosttyTerminalPadding` + `kGutterStripWidth` on that side), and PTY cols shrink accordingly (`_submitKeyboardAwareGrid` → `proxy.sendResize`). `_isGutterCol` returns false (nothing to suppress). Switching mode on a live session resubmits the grid immediately (observable as `tput cols` changing by `ceil(28 / cellWidth)`... exactly: `floor((innerW - 28) / cellW)` vs `floor(innerW / cellW)`).

R20. ONE geometry value drives every consumer. Introduce `GhosttyGutterGeometry({side, mode, stripWidth})` with `EdgeInsets terminalPadding` (padding incl. the reserved strip) and `double reservedWidth` (0 in overlay). Consumers that MUST read it: `ghosttyGridForBox`, `ghosttyCellForPosition` (touch → cell), the `TerminalView` padding, `GhosttyWashLayer` rect derivation, `GhosttyGutterLayer`, `GutterLineSelectLayer`, `_isGutterCol`, the #988 bubble anchor. Drift between any two = bug; a unit test pins that the wash rect for cell (0,0) and the touch→cell map agree for all four side×mode combinations.

R21. Overlay chips in column mode still align vertically to rows exactly as in overlay mode (row placement uses the same `padding.top` + `row * cellHeight`).

## 8. Detection Lab interplay

R22. Lab previews (`detection_lab_preview.dart`) render through the real resolver, so wash previews follow the global level automatically. The chip preview (`GutterMarkChip`) takes the same `GutterNoise` as the live gutter so shadow/strip parity holds.

R23. The Lab's per-pattern inactive/active sliders compose ON TOP of the level (§5 R11 order). The `lab-accent-note` gains no new text; the Lab master toggle stays bound to `enabled`.

## 9. Acceptance

A1. Unit (`detection_providers_test.dart`): defaults medium/right/overlay; JSON round-trip of all three; hydrate of a v1 value lacking the fields → defaults; `"intensity":"ultra"` / `"gutterSide":42` → defaults for that field only, other fields kept.
A2. Unit (`detection_style_resolver_test.dart`): golden equality at medium for every built-in pattern × state × luminance (existing test, parameterised); R12 ordering; R11 low floor ≥ 0.12; chip identity at all levels (R13).
A3. Unit (`ghostty_terminal_view` grid math): `ghosttyGridForBox` cols for overlay vs column (both sides); `ghosttyCellForPosition` agrees with wash rects (R20) for all four combinations.
A4. Widget (`session_menu_slim_test.dart`): tap opens `link-highlight-menu` and does NOT flip `enabled`; each control writes its field; long-press still opens the Lab; `link-highlight-lab` opens the Lab.
A5. Widget (`ghostty_gutter_layer_test.dart` / `gutter_line_select_test.dart`): chips and select strip at `left: 0` when side=left, both layers same edge; strip hint alpha per level; chip shadow present/absent per level.
A6. Widget: R10 — changing intensity does not trigger the re-register listener (spy on the pattern registration seam), changing `url` does.
A7. Emulator (shot test, fleet emulator): connect, `printf` a URL line, switch side=left → `gutter-mark-<row>` centre x < screen width/2 and wash rows unchanged; switch mode=column → `tput cols` output shrinks by the expected delta and grows back on overlay; chips still on the row. Layout change ⇒ emulator red→green REQUIRED before merge (device-class rule).
A8. Settings reset restores all three (`settings_page_combined_test.dart`).

## 10. Phasing (child issues)

Slice 1 — state + resolver + options menu (unit + widget). `DetectionSettings` fields/enums/setters (R7–R10), intensity composition (R11–R14) incl. `GutterNoise`, the bottom sheet (R1–R6), Lab parity (R22–R23), reset (R9). Side/mode are persisted and shown in the menu but have no geometric effect yet (documented in the sheet as taking effect in Slice 2? NO — the controls are hidden until Slice 2 lands: Slice 1 renders only Enabled + Intensity + Lab; Slice 2 adds the two segmented controls). Tests A1, A2, A4 (intensity part), A5 (noise part), A6, A8.

Slice 2 — gutter geometry (widget + emulator). `GhosttyGutterGeometry` (R20), side (R15–R17), column mode (R18–R19, R21), menu controls for side/mode (R2 remainder), tests A3, A4 (side/mode part), A5 (side part), A7.

Slice 1 merges before Slice 2 starts (Slice 2 depends on the enums and the sheet).

## 11. Open decisions

D1. Settings-panel mirror of the three controls (alongside the per-type toggles). Recommendation: defer; the sheet is one tap from any session and Settings already links to the Lab.
D2. Whether the strip width differs per mode (a dedicated column could be narrower, e.g. one cell width). Recommendation: keep 28dp in both modes (chip tap target 24dp + ring).
D3. Whether `GutterMode.column` should also apply to the line-select strip's hit area (it does by construction with R20; no extra decision unless the owner wants overlay-only line select).
