// Shared first-class color picker (#1030).
//
// Used by the profile editor for the per-profile device swatch; the detection
// lab (#1031) reuses it for per-pattern highlight colors. Two entry points:
//   - [ColorPickerPanel]: the picker surface itself (testable directly).
//   - [showColorPickerSheet]: modal bottom-sheet wrapper. Returns
//     `null` = cancelled, [ColorPickerResult] with `color == null` = cleared
//     ("no color" / "use theme color" — the #1031 override-clearing contract),
//     otherwise the picked color.
//
// Hand-rolled HSV panel (SV square + hue slider via CustomPaint) instead of a
// pub dependency: flex_color_picker is pure Dart but drags flex_seed_scheme +
// a large unused API and risks lockfile drift against the pinned
// compileSdk-36 toolchain (file_picker precedent); the minimal panel is ~150
// lines and gives exact control over thumb-friendly target sizes (the owner
// is visually impaired, phone-first).
//
// Monochrome-glyph rule applies to ICONS only — the swatch/preview colors ARE
// the user content here.

import 'package:flutter/material.dart';

import '../state/ui_prefs_providers.dart' show colorFromHex;

/// Shared preset quick-swatches. The profile editor renders these as one-tap
/// chips and the picker repeats them as presets; #1031 reuses the same set for
/// pattern colors. Chosen for mutual distinguishability and legibility on both
/// dark and light surfaces.
const List<Color> colorPickerPresets = <Color>[
  Color(0xFFE53935), // red
  Color(0xFFFB8C00), // orange
  Color(0xFFFDD835), // yellow
  Color(0xFF43A047), // green
  Color(0xFF00ACC1), // cyan
  Color(0xFF1E88E5), // blue
  Color(0xFF8E24AA), // purple
  Color(0xFFD81B60), // pink
];

/// Format an (opaque) color as the lowercase `#rrggbb` hex the profile store
/// carries ([SavedProfile.color]); inverse of [colorFromHex] for 6-digit input.
String hexFromColor(Color color) {
  final rgb = color.toARGB32() & 0xFFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0')}';
}

/// Sheet outcome wrapper so callers can tell "picked nothing" (sheet returns
/// null) from "picked NO color" (`color == null` — clear the override).
class ColorPickerResult {
  const ColorPickerResult(this.color);

  /// The picked color, or null when the user chose the clear action.
  final Color? color;
}

/// Open the shared picker as a modal bottom sheet.
///
/// [clearLabel], when given, adds a clear action returning
/// `ColorPickerResult(null)` — e.g. 'No color (theme accent)' in the profile
/// editor or 'Use theme color' in the detection lab.
Future<ColorPickerResult?> showColorPickerSheet(
  BuildContext context, {
  Color? initial,
  String title = 'Pick a color',
  String? clearLabel,
  List<Color> presets = colorPickerPresets,
  String? previewLabel,
}) {
  return showModalBottomSheet<ColorPickerResult>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => Padding(
      // Keep the hex field + actions above the soft keyboard.
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
      ),
      child: SingleChildScrollView(
        child: ColorPickerPanel(
          initial: initial,
          title: title,
          clearLabel: clearLabel,
          presets: presets,
          previewLabel: previewLabel,
          onApply: (color) =>
              Navigator.of(sheetContext).pop(ColorPickerResult(color)),
          onClear: clearLabel == null
              ? null
              : () =>
                    Navigator.of(sheetContext).pop(const ColorPickerResult(null)),
          onCancel: () => Navigator.of(sheetContext).pop(),
        ),
      ),
    ),
  );
}

/// The picker surface: SV square + hue slider + hex entry + preset chips +
/// live preview + actions. Pure widget (no storage) so both the profile
/// editor and the detection lab can host it.
class ColorPickerPanel extends StatefulWidget {
  const ColorPickerPanel({
    super.key,
    this.initial,
    this.title = 'Pick a color',
    this.clearLabel,
    this.presets = colorPickerPresets,
    this.previewLabel,
    required this.onApply,
    this.onClear,
    this.onCancel,
  });

  /// Seed color; null starts on the first preset.
  final Color? initial;

  final String title;

  /// Label for the clear ("no color") action; null hides the action.
  final String? clearLabel;

  final List<Color> presets;

  /// Text shown next to the preview dot (defaults to a session-row mock).
  final String? previewLabel;

  final ValueChanged<Color> onApply;
  final VoidCallback? onClear;
  final VoidCallback? onCancel;

  @override
  State<ColorPickerPanel> createState() => _ColorPickerPanelState();
}

class _ColorPickerPanelState extends State<ColorPickerPanel> {
  late HSVColor _hsv;
  late final TextEditingController _hexCtrl;

  /// Set when the hex field holds unparseable text; the preview and Apply then
  /// stick to the last valid color / disable respectively.
  bool _hexInvalid = false;

  Color get _color => _hsv.toColor();

  @override
  void initState() {
    super.initState();
    final seed = widget.initial ?? widget.presets.first;
    _hsv = HSVColor.fromColor(seed);
    _hexCtrl = TextEditingController(text: hexFromColor(seed));
  }

  @override
  void dispose() {
    _hexCtrl.dispose();
    super.dispose();
  }

  /// Adopt a color picked interactively (SV square / hue / preset) — syncs the
  /// hex field to the selection.
  void _select(HSVColor hsv) {
    setState(() {
      _hsv = hsv;
      _hexInvalid = false;
      _hexCtrl.text = hexFromColor(hsv.toColor());
    });
  }

  void _onHexChanged(String text) {
    final parsed = colorFromHex(text);
    setState(() {
      if (parsed == null) {
        _hexInvalid = text.trim().isNotEmpty;
      } else {
        _hexInvalid = false;
        _hsv = HSVColor.fromColor(parsed);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hex = hexFromColor(_color);
    return Padding(
      key: const Key('color-picker-panel'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          _SvSquare(hsv: _hsv, onChanged: _select),
          const SizedBox(height: 12),
          _HueSlider(hsv: _hsv, onChanged: _select),
          const SizedBox(height: 12),
          // Live preview: where the color lands — the session-row dot next to
          // a big swatch carrying the hex value.
          Row(
            children: [
              Container(
                key: const Key('color-picker-preview'),
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: _color,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.previewLabel ?? 'session row',
                  style: theme.textTheme.bodyMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Container(
                width: 72,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _color,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Text(
                  hex,
                  style: theme.textTheme.labelSmall?.copyWith(
                    // Contrast the swatch itself, not the app theme.
                    color: _color.computeLuminance() > 0.5
                        ? Colors.black
                        : Colors.white,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('color-picker-hex'),
            controller: _hexCtrl,
            decoration: InputDecoration(
              labelText: 'Hex',
              hintText: '#ff8800',
              errorText: _hexInvalid ? 'Invalid hex color' : null,
              border: const OutlineInputBorder(),
            ),
            autocorrect: false,
            enableSuggestions: false,
            onChanged: _onHexChanged,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final preset in widget.presets)
                _PresetChip(
                  key: Key('color-picker-preset-${hexFromColor(preset)}'),
                  color: preset,
                  selected: hexFromColor(preset) == hex,
                  onTap: () => _select(HSVColor.fromColor(preset)),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              if (widget.onClear != null)
                Expanded(
                  child: OutlinedButton(
                    key: const Key('color-picker-clear'),
                    onPressed: widget.onClear,
                    child: Text(
                      widget.clearLabel ?? 'No color',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              if (widget.onClear != null) const SizedBox(width: 8),
              TextButton(
                key: const Key('color-picker-cancel'),
                onPressed: widget.onCancel,
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  key: const Key('color-picker-apply'),
                  onPressed: _hexInvalid
                      ? null
                      : () => widget.onApply(_color),
                  child: const Text('Apply'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Round preset swatch, thumb-sized (48dp), with a selection ring.
class _PresetChip extends StatelessWidget {
  const _PresetChip({
    super.key,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkResponse(
      onTap: onTap,
      radius: 28,
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected
                ? theme.colorScheme.onSurface
                : theme.colorScheme.outlineVariant,
            width: selected ? 3 : 1,
          ),
        ),
        child: selected
            ? Icon(
                Icons.check,
                size: 24,
                color: color.computeLuminance() > 0.5
                    ? Colors.black
                    : Colors.white,
              )
            : null,
      ),
    );
  }
}

/// Saturation/value plane for the current hue. Tap or drag anywhere on the
/// square; the thumb rides the selection.
class _SvSquare extends StatelessWidget {
  const _SvSquare({required this.hsv, required this.onChanged});

  final HSVColor hsv;
  final ValueChanged<HSVColor> onChanged;

  void _handle(Offset local, Size size) {
    final s = (local.dx / size.width).clamp(0.0, 1.0);
    final v = 1.0 - (local.dy / size.height).clamp(0.0, 1.0);
    onChanged(hsv.withSaturation(s).withValue(v));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, 200);
        return GestureDetector(
          key: const Key('color-picker-sv'),
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => _handle(d.localPosition, size),
          onPanStart: (d) => _handle(d.localPosition, size),
          onPanUpdate: (d) => _handle(d.localPosition, size),
          child: CustomPaint(
            size: size,
            painter: _SvPainter(hsv),
          ),
        );
      },
    );
  }
}

class _SvPainter extends CustomPainter {
  _SvPainter(this.hsv);

  final HSVColor hsv;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(8));
    canvas.clipRRect(rrect);
    // White → pure hue along X, then transparent → black along Y.
    final hueColor = HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor();
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: [Colors.white, hueColor],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black],
        ).createShader(rect),
    );
    // Thumb ring at the current S/V.
    final thumb = Offset(
      hsv.saturation * size.width,
      (1 - hsv.value) * size.height,
    );
    canvas.drawCircle(
      thumb,
      12,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = Colors.white,
    );
    canvas.drawCircle(
      thumb,
      12,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.black54,
    );
  }

  @override
  bool shouldRepaint(_SvPainter oldDelegate) => oldDelegate.hsv != hsv;
}

/// Full-spectrum hue bar, 48dp tall for a comfortable drag target.
class _HueSlider extends StatelessWidget {
  const _HueSlider({required this.hsv, required this.onChanged});

  final HSVColor hsv;
  final ValueChanged<HSVColor> onChanged;

  void _handle(Offset local, double width) {
    final hue = (local.dx / width).clamp(0.0, 1.0) * 360.0;
    onChanged(hsv.withHue(hue.clamp(0.0, 359.999)));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, 48);
        return GestureDetector(
          key: const Key('color-picker-hue'),
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => _handle(d.localPosition, size.width),
          onPanStart: (d) => _handle(d.localPosition, size.width),
          onPanUpdate: (d) => _handle(d.localPosition, size.width),
          child: CustomPaint(
            size: size,
            painter: _HuePainter(hsv.hue),
          ),
        );
      },
    );
  }
}

class _HuePainter extends CustomPainter {
  _HuePainter(this.hue);

  final double hue;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(8));
    canvas.clipRRect(rrect);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: [
            for (var h = 0; h <= 360; h += 60)
              HSVColor.fromAHSV(1, h.toDouble().clamp(0, 359.999), 1, 1)
                  .toColor(),
          ],
        ).createShader(rect),
    );
    // Thumb: vertical pill at the current hue.
    final x = (hue / 360.0) * size.width;
    final thumbRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(x.clamp(6, size.width - 6), size.height / 2),
        width: 10,
        height: size.height - 6,
      ),
      const Radius.circular(5),
    );
    canvas.drawRRect(
      thumbRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = Colors.white,
    );
    canvas.drawRRect(
      thumbRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.black54,
    );
  }

  @override
  bool shouldRepaint(_HuePainter oldDelegate) => oldDelegate.hue != hue;
}
