// #707 — the per-session terminal font picker (#679) lists the bundled
// monospace families. This asserts the contents of [terminalFontFamilies]:
// the three originals (JetBrainsMono / FiraCode / CascadiaCode) plus the
// three added in #707 (RobotoMono / UbuntuMono / Cousine). Iosevka is
// DEFERRED (needs a custom build) and must NOT appear yet.
//
// Each id must match a `fonts:` family registered in pubspec.yaml; a green
// `flutter test` build (which loads the manifest + font assets) plus this
// list assertion together confirm the picker offers exactly these faces and
// each resolves to a real bundled face via [resolveFontFamily].

import 'package:flutter_test/flutter_test.dart';

import 'package:mobissh/state/ui_prefs_providers.dart';

void main() {
  group('terminalFontFamilies (#679 + #707)', () {
    test('lists all six bundled families in order, no duplicates', () {
      final ids = terminalFontFamilies.map((f) => f.id).toList();
      expect(ids, <String>[
        'JetBrainsMono',
        'FiraCode',
        'CascadiaCode',
        'RobotoMono',
        'UbuntuMono',
        'Cousine',
      ]);
      expect(ids.toSet().length, ids.length, reason: 'no duplicate family ids');
    });

    test('the three #707 families are present with human labels', () {
      for (final entry in const <String, String>{
        'RobotoMono': 'Roboto Mono',
        'UbuntuMono': 'Ubuntu Mono',
        'Cousine': 'Cousine',
      }.entries) {
        final fam = terminalFontFamilies.firstWhere(
          (f) => f.id == entry.key,
          orElse: () => throw StateError('missing family ${entry.key}'),
        );
        expect(fam.label, entry.value);
      }
    });

    test('every #707 id is a known family and resolves to itself', () {
      for (final id in const ['RobotoMono', 'UbuntuMono', 'Cousine']) {
        expect(isKnownFontFamily(id), isTrue, reason: '$id must be bundled');
        expect(
          resolveFontFamily(id),
          id,
          reason: '$id must resolve to its own face, not the default',
        );
      }
    });

    test('Iosevka is deferred — must NOT be listed yet', () {
      expect(
        terminalFontFamilies.any((f) => f.id == 'Iosevka'),
        isFalse,
        reason: 'Iosevka needs a custom build (#707 defers it)',
      );
      expect(isKnownFontFamily('Iosevka'), isFalse);
    });
  });
}
