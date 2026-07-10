// Detection Lab preview primitives (#1031 slice 2).
//
// [detectionLabPatternSpecs] is the lab's pattern registry: one entry per
// user-facing built-in type (url covers BOTH the regex `url` and `osc8` ids —
// one toggle gates both and they share id-level style, per the IA). Slice 3
// appends `custom.<slug>` entries here.
//
// [DetectionPreviewLine] renders one sample terminal line with the REAL
// affordance code — the wash via [GhosttyBubblePainter] fed by the SAME
// [DetectionStyleResolver] the runtime layers consult, and the chip via the
// shared [GutterMarkChip] — over a terminal-colored strip. No parallel
// preview styling exists (IA: preview trust — the preview IS the value).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/detection_providers.dart';
import '../state/sessions.dart';
import '../storage/custom_patterns_store.dart';
import '../state/ui_prefs_providers.dart';
import 'detection_style_resolver.dart';
import 'ghostty_gutter_layer.dart';
import 'ghostty_terminal_decorators.dart';

/// One lab pattern: identity, labels, sample line, and which stored style ids
/// it tunes.
@immutable
class DetectionLabPatternSpec {
  const DetectionLabPatternSpec({
    required this.key,
    required this.title,
    required this.icon,
    required this.styleIds,
    required this.samplePrefix,
    required this.sampleMatch,
    required this.bubble,
    this.isCustom = false,
  });

  /// Stable lab key (`url` / `path` / `command`; a custom pattern's ID) used
  /// in widget keys.
  final String key;

  /// Front-loaded display name ("URLs", "File paths", "Command lines").
  final String title;

  /// Monochrome Material glyph — the same one the gutter/Settings use.
  final IconData icon;

  /// The pattern ids this entry's tuning writes. The URL entry carries BOTH
  /// `url` and `osc8` (one user-facing type, id-level style kept in lockstep).
  final List<String> styleIds;

  /// Sample-line text before the match (plain terminal ink).
  final String samplePrefix;

  /// The matched sample text the wash/chip decorate.
  final String sampleMatch;

  /// Whether this pattern paints an inline bubble wash. The command pattern
  /// is GUTTER-ONLY (#998 C) — its preview honestly shows chip-only.
  final bool bubble;

  /// Whether this entry is a USER-DEFINED pattern (#1031 slice 3): its key is
  /// the immutable `custom.*` id, its enable bit lives in the custom store
  /// (not detectionSettingsProvider), and its detail page adds the
  /// definition/delete affordances.
  final bool isCustom;

  /// The id style reads resolve against (the first style id).
  String get primaryId => styleIds.first;

  /// Whether a REAL active (verified) state exists at runtime today — the
  /// review's change 1 gate: no controls for a state with no runtime effect.
  bool get hasActiveState => detectionPatternHasActiveState(primaryId);
}

/// The lab's built-in pattern registry (root cards render one card per entry).
const List<DetectionLabPatternSpec> detectionLabPatternSpecs = [
  DetectionLabPatternSpec(
    key: 'url',
    title: 'URLs',
    icon: Icons.link_outlined,
    styleIds: [kGhosttyUrlPatternId, kGhosttyOsc8PatternId],
    samplePrefix: 'visit ',
    sampleMatch: 'https://example.com/docs',
    bubble: true,
  ),
  DetectionLabPatternSpec(
    key: 'path',
    title: 'File paths',
    icon: Icons.folder_outlined,
    styleIds: [kGhosttyPathPatternId],
    samplePrefix: 'see ',
    sampleMatch: '/etc/ssh/sshd_config',
    bubble: true,
  ),
  DetectionLabPatternSpec(
    key: 'command',
    title: 'Command lines',
    icon: Icons.terminal,
    styleIds: [kGhosttyCommandPatternId],
    samplePrefix: r'$ ',
    sampleMatch: 'curl -sL setup.sh | bash',
    bubble: false,
  ),
];

/// Lookup by lab key. Throws on an unknown key (a programming error).
DetectionLabPatternSpec detectionLabPatternSpec(String key) =>
    detectionLabPatternSpecs.firstWhere((s) => s.key == key);

/// The generic monochrome glyph every USER-DEFINED pattern renders with
/// (#1031 slice 3 IA: one generic chip glyph — the gutter fallback uses the
/// same one).
const IconData kCustomPatternIcon = Icons.pattern;

/// Build the lab spec for a USER-DEFINED pattern (#1031 slice 3). The sample
/// line splits at the pattern's OWN first match ([compileCustomPatternRegex],
/// defensive): prefix = the text before it, match = the matched span the
/// wash/chip decorate. No match (or a broken regex) leaves [sampleMatch]
/// empty — the card renders its honest no-match / error state instead of a
/// fake highlight.
DetectionLabPatternSpec detectionLabSpecForCustomPattern(CustomPattern p) {
  final regex = compileCustomPatternRegex(p.source);
  var prefix = p.sampleLine;
  var match = '';
  if (regex != null && p.sampleLine.isNotEmpty) {
    final m = regex.firstMatch(p.sampleLine);
    if (m != null && m.end > m.start) {
      prefix = p.sampleLine.substring(0, m.start);
      match = p.sampleLine.substring(m.start, m.end);
    }
  }
  return DetectionLabPatternSpec(
    key: p.id,
    title: p.name,
    icon: kCustomPatternIcon,
    styleIds: [p.id],
    samplePrefix: prefix,
    sampleMatch: match,
    bubble: true,
    isCustom: true,
  );
}

/// Whether [key]'s pattern type is enabled in [d] — the SAME provider bits the
/// Settings toggles flip (one bit, three surfaces).
bool detectionLabTypeEnabled(DetectionSettings d, String key) => switch (key) {
  'url' => d.url,
  'path' => d.path,
  'command' => d.command,
  _ => false,
};

/// Flip [key]'s pattern type via the existing detection-settings notifier.
Future<void> detectionLabSetTypeEnabled(WidgetRef ref, String key, bool v) {
  final n = ref.read(detectionSettingsProvider.notifier);
  return switch (key) {
    'url' => n.setUrl(v),
    'path' => n.setPath(v),
    'command' => n.setCommand(v),
    _ => Future<void>.value(),
  };
}

/// The preview strip's theme inputs (#1031 IA review change 2: the preview
/// must SAY which theme it renders against, or it can lie).
@immutable
class DetectionLabPreviewTheme {
  const DetectionLabPreviewTheme({
    required this.sourceLabel,
    required this.accent,
    required this.background,
    required this.foreground,
    required this.brightness,
  });

  /// Front-loaded provenance line ("Previewing: Dark (active session)").
  final String sourceLabel;

  /// The accent the resolver falls back to (`palette.theme.selection`).
  final Color accent;

  final Color background;
  final Color foreground;

  /// The strip's effective luminance (drives the #1000 wash alphas).
  final Brightness brightness;
}

/// Neutral terminal strips for the luminance override — used only when the
/// user flips the preview AWAY from the live theme's own brightness (the
/// theme's real colors can't honestly render the other luminance).
const Color _kNeutralDarkBackground = Color(0xFF14181C);
const Color _kNeutralDarkForeground = Color(0xFFE0E0E0);
const Color _kNeutralLightBackground = Color(0xFFF6F6F2);
const Color _kNeutralLightForeground = Color(0xFF202020);

/// Resolve the preview theme: the FRONT (active) session's live palette when
/// one exists, else the app default theme — labeled either way (review change
/// 2). [luminanceOverride] flips the strip's brightness from that baseline
/// (the `[dark|light]` chip); when it flips AWAY from the theme's own
/// brightness the strip renders neutral colors of the requested luminance,
/// keeping the accent (which is what the overrides tune against).
DetectionLabPreviewTheme detectionLabPreviewTheme(
  WidgetRef ref, {
  Brightness? luminanceOverride,
}) {
  final named = ref.watch(activeSessionThemeProvider);
  final hasSession = ref.watch(activeSessionIdProvider) != null;
  var background = named.theme.background;
  var foreground = named.theme.foreground;
  final base = ThemeData.estimateBrightnessForColor(background);
  final effective = luminanceOverride ?? base;
  if (effective != base) {
    background = effective == Brightness.dark
        ? _kNeutralDarkBackground
        : _kNeutralLightBackground;
    foreground = effective == Brightness.dark
        ? _kNeutralDarkForeground
        : _kNeutralLightForeground;
  }
  return DetectionLabPreviewTheme(
    sourceLabel: hasSession
        ? 'Previewing: ${named.label} (active session)'
        : 'Previewing: ${named.label} (default theme)',
    accent: named.theme.selection,
    background: background,
    foreground: foreground,
    brightness: effective,
  );
}

/// One sample terminal line: prefix ink, the match under the REAL wash
/// ([GhosttyBubblePainter] + resolver output), and the REAL gutter chip
/// ([GutterMarkChip]) at the right edge — over a terminal-colored strip.
class DetectionPreviewLine extends StatelessWidget {
  const DetectionPreviewLine({
    super.key,
    required this.spec,
    required this.resolver,
    required this.background,
    required this.foreground,
    this.verified = false,
    this.stateLabel,
  });

  final DetectionLabPatternSpec spec;

  /// The SAME resolver type the runtime layers consult, built over the live
  /// stored overrides + the preview's accent/luminance.
  final DetectionStyleResolver resolver;

  /// The terminal strip's background (the preview's luminance baseline).
  final Color background;

  /// Plain terminal ink for the sample text.
  final Color foreground;

  /// Render the ACTIVE (verified, #990) state: stronger wash + bold ring chip.
  final bool verified;

  /// Optional state caption above the line ("Detected" / "Active (verified)").
  final String? stateLabel;

  @override
  Widget build(BuildContext context) {
    final resolved = resolver.resolveStyle(spec.primaryId, verified: verified);
    final chipStyle = verified ? GutterMarkStyle.bold : GutterMarkStyle.normal;
    final textStyle = TextStyle(
      fontFamily: 'monospace',
      fontSize: 14,
      color: foreground,
    );

    Widget match = Text(
      spec.sampleMatch,
      style: textStyle,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.clip,
    );
    if (spec.bubble) {
      // Measure the match so the REAL painter gets its exact glyph rect (the
      // runtime feeds it anchor rects; here the sample text IS the anchor).
      final tp = TextPainter(
        text: TextSpan(text: spec.sampleMatch, style: textStyle),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      final size = tp.size;
      tp.dispose();
      match = SizedBox(
        width: size.width,
        height: size.height,
        child: CustomPaint(
          painter: GhosttyBubblePainter(
            specs: [
              GhosttyBubbleSpec(
                segments: ghosttyBubbleSegments([
                  Rect.fromLTWH(0, 0, size.width, size.height),
                ]),
                verified: verified,
                washColor: resolved.washColor,
              ),
            ],
            color: resolver.accent,
            backgroundBrightness: resolver.backgroundBrightness,
          ),
          child: match,
        ),
      );
    }

    return Container(
      color: background,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (stateLabel != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                stateLabel!,
                style: TextStyle(
                  fontSize: 11,
                  color: foreground.withValues(alpha: 0.7),
                ),
              ),
            ),
          Row(
            children: [
              // Scale the whole sample line down rather than overflow on a
              // narrow phone — the wash stays glued to its glyphs.
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        spec.samplePrefix,
                        style: textStyle,
                        maxLines: 1,
                        softWrap: false,
                      ),
                      match,
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GutterMarkChip(
                style: chipStyle,
                accent: resolved.chipAccent,
                icon: spec.icon,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
