import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

final _fontsDir =
    '${Directory.current.path}${Platform.pathSeparator}test'
    '${Platform.pathSeparator}fixtures${Platform.pathSeparator}fonts';

/// Raw bytes of JetBrains Mono Regular, available after [loadBundledFonts].
///
/// Used to pass to [measureCellMetrics]'s `fontData` parameter so that
/// exact font table metrics (underline/strikethrough position and thickness)
/// are read from the binary tables rather than estimated.
Uint8List? jetBrainsMonoBytes;

/// Font family fallback list for golden tests. References only the fonts
/// loaded by [loadBundledFonts] so glyph rendering does not depend on any
/// platform-installed font (e.g. Apple Color Emoji), keeping output
/// deterministic across macOS minor versions and CPU architectures.
const bundledFontFamilyFallback = <String>[
  'Noto Color Emoji',
  'Noto Emoji',
  'Noto Sans JP',
];

Future<void> loadBundledFonts() async {
  jetBrainsMonoBytes = await _load(
    'JetBrainsMono-Regular.ttf',
    'JetBrains Mono',
  );
  await _load('JetBrainsMono-Bold.ttf', 'JetBrains Mono');
  await _load('NotoColorEmoji-Regular.ttf', 'Noto Color Emoji');
  await _load('NotoEmoji-Regular.ttf', 'Noto Emoji');
  await _load('NotoSansJP-Regular.ttf', 'Noto Sans JP');
}

Future<Uint8List> _load(String filename, String family) async {
  final path = '$_fontsDir${Platform.pathSeparator}$filename';
  final bytes = File(path).readAsBytesSync();
  await ui.loadFontFromList(Uint8List.fromList(bytes), fontFamily: family);
  return Uint8List.fromList(bytes);
}
