// Tests for the shared Ctrl-modifier provider (#728).
//
// #694 gave the KEYBAR a sticky one-shot Ctrl modifier, but its armed state
// lived in the keybar widget (`CtrlModifier`), so the terminal soft-keyboard
// input path (flterm `controller.onOutput`) could never see it — armed Ctrl + a
// keyboard letter (e.g. R) did nothing and Ctrl stayed armed. #728 lifts the
// armed flag into this shared Riverpod provider so BOTH the keybar and the
// terminal input path can read + clear it.
//
// The notifier is a plain `bool` state with arm()/disarm()/toggle()/consume().
// `consume()` is the one-shot clear the terminal path calls after applying Ctrl
// to a keystroke; it returns whether it WAS armed so the caller knows whether to
// transform.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobissh/state/ctrl_modifier_provider.dart';

void main() {
  group('CtrlModifierNotifier — arm/disarm/toggle/consume (#728)', () {
    test('starts disarmed', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(ctrlModifierProvider), isFalse);
    });

    test('arm() sets armed true', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(ctrlModifierProvider.notifier).arm();
      expect(container.read(ctrlModifierProvider), isTrue);
    });

    test('disarm() clears armed', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final n = container.read(ctrlModifierProvider.notifier);
      n.arm();
      n.disarm();
      expect(container.read(ctrlModifierProvider), isFalse);
    });

    test('toggle() flips armed each call (matches keybar Ctrl tap)', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final n = container.read(ctrlModifierProvider.notifier);
      n.toggle();
      expect(container.read(ctrlModifierProvider), isTrue);
      n.toggle();
      expect(
        container.read(ctrlModifierProvider),
        isFalse,
        reason: 'a second Ctrl tap cancels the modifier',
      );
    });

    test('consume() returns true and clears when armed (one-shot)', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final n = container.read(ctrlModifierProvider.notifier);
      n.arm();
      final wasArmed = n.consume();
      expect(wasArmed, isTrue);
      expect(
        container.read(ctrlModifierProvider),
        isFalse,
        reason: 'consume clears the one-shot modifier',
      );
    });

    test('consume() returns false and stays clear when disarmed', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final n = container.read(ctrlModifierProvider.notifier);
      final wasArmed = n.consume();
      expect(wasArmed, isFalse);
      expect(container.read(ctrlModifierProvider), isFalse);
    });

    test('arm() while armed stays armed (idempotent, not a toggle)', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final n = container.read(ctrlModifierProvider.notifier);
      n.arm();
      n.arm();
      expect(container.read(ctrlModifierProvider), isTrue);
    });
  });
}
