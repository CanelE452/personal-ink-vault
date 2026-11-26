import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/kit/kit_tokens.dart';

// A CSS blur b is a Gaussian of sigma b / 2, so every blurred shadow's
// Flutter sigma must be b / 2.
void _expectShadow(
  BoxShadow s, {
  required Color color,
  required Offset offset,
  required double cssBlur,
  required double spread,
}) {
  expect(s.color, color);
  expect(s.offset, offset);
  expect(s.spreadRadius, spread);
  expect(s.blurSigma, closeTo(cssBlur / 2, 1e-9));
}

void main() {
  test('kit shadows blur like the design CSS', () {
    const menu = KitTokens.menuShadow;
    _expectShadow(
      menu[0],
      color: const Color(0x73142032),
      offset: const Offset(0, 18),
      cssBlur: 40,
      spread: -18,
    );
    expect(menu[1].blurRadius, 0);
    expect(menu[1].spreadRadius, 1);

    const sub = KitTokens.subMenuShadow;
    _expectShadow(
      sub[0],
      color: const Color(0x73142032),
      offset: const Offset(0, 14),
      cssBlur: 30,
      spread: -14,
    );
    expect(sub[1].blurRadius, 0);
    expect(sub[1].spreadRadius, 1);

    _expectShadow(
      KitTokens.switchThumbShadow.single,
      color: const Color.fromRGBO(12, 22, 44, 0.26),
      offset: const Offset(0, 1),
      cssBlur: 2,
      spread: 0,
    );
    _expectShadow(
      KitTokens.pillShadow.single,
      color: const Color.fromRGBO(12, 22, 44, 0.26),
      offset: const Offset(0, 6),
      cssBlur: 16,
      spread: -10,
    );

    const sel = KitTokens.selBarShadow;
    _expectShadow(
      sel[0],
      color: const Color.fromRGBO(0, 0, 0, 0.22),
      offset: const Offset(0, 6),
      cssBlur: 16,
      spread: -8,
    );
    expect(sel[1].blurRadius, 0);
    expect(sel[1].spreadRadius, 0.5);

    _expectShadow(
      KitTokens.panelShadow.single,
      color: const Color.fromRGBO(12, 22, 44, 0.26),
      offset: const Offset(0, 14),
      cssBlur: 34,
      spread: -16,
    );
    _expectShadow(
      KitTokens.sliderThumbShadow[0],
      color: const Color.fromRGBO(0, 0, 0, 0.18),
      offset: const Offset(0, 1),
      cssBlur: 3,
      spread: 0,
    );
  });
}
