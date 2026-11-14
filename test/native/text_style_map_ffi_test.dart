import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/native/ink_vault_native.dart';

void main() {
  final libraryPath =
      Platform.environment['INK_VAULT_NATIVE_LIBRARY'] ??
      p.absolute('build', 'native', 'windows', 'ink_vault_native.dll');

  Map<String, dynamic> plan(InkVaultNative engine, String old, String text) =>
      engine.invoke({
        'op': 'text_style_map',
        'protocol': 'piv-text-style-map-1',
        'oldText': old,
        'newText': text,
      });

  test('actual Rust C ABI retains UTF16 ranges and exact Unicode hashes', () {
    final engine = InkVaultNative.open(libraryPath: libraryPath);
    const old = '한😀e\u0301\n끝';
    const text = '한😀Xe\u0301\n끝';
    final result = plan(engine, old, text);
    expect(result['oldUtf16Length'], old.length);
    expect(result['newUtf16Length'], text.length);
    expect(result['oldSha256'], sha256.convert(utf8.encode(old)).toString());
    expect(result['newSha256'], sha256.convert(utf8.encode(text)).toString());
    expect(result['paragraphs'], [
      {
        'sourceParagraph': 0,
        'segments': [
          {
            'kind': 'retain',
            'newStart': 0,
            'newEnd': 3,
            'oldStart': 0,
            'oldEnd': 3,
          },
          {
            'kind': 'inherit',
            'newStart': 3,
            'newEnd': 4,
            'oldStart': 1,
            'oldEnd': 3,
          },
          {
            'kind': 'retain',
            'newStart': 4,
            'newEnd': 6,
            'oldStart': 3,
            'oldEnd': 5,
          },
        ],
      },
      {
        'sourceParagraph': 1,
        'segments': [
          {
            'kind': 'retain',
            'newStart': 0,
            'newEnd': 1,
            'oldStart': 0,
            'oldEnd': 1,
          },
        ],
      },
    ]);
  });

  test(
    'actual Rust C ABI releases repeated plans and reports bounded failure',
    () {
      final engine = InkVaultNative.open(libraryPath: libraryPath);
      for (var index = 0; index < 128; index++) {
        final result = plan(engine, '👨‍👩‍👧‍👦', '👨‍👩‍👧‍👦$index');
        expect(result['protocol'], 'piv-text-style-map-1');
      }
      expect(
        () => plan(engine, 'a', List.filled(8193, 'a').join()),
        throwsA(
          isA<InkVaultNativeException>().having(
            (error) => error.code,
            'code',
            'text_style_limit',
          ),
        ),
      );
      expect(plan(engine, '', '')['paragraphs'], [
        {
          'sourceParagraph': 0,
          'segments': [
            {
              'kind': 'inherit',
              'newStart': 0,
              'newEnd': 0,
              'oldStart': 0,
              'oldEnd': 0,
            },
          ],
        },
      ]);
    },
  );
}
