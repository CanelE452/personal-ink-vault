import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/native/ink_vault_native.dart';

void main() {
  final libraryPath =
      Platform.environment['INK_VAULT_NATIVE_LIBRARY'] ??
      p.absolute('build', 'native', 'windows', 'ink_vault_native.dll');

  test('missing native library reports an actionable error', () {
    expect(
      () => InkVaultNative.open(
        libraryPath: p.absolute('build', 'missing-native-library.dll'),
      ),
      throwsA(
        isA<InkVaultNativeException>().having(
          (e) => e.code,
          'code',
          'library_unavailable',
        ),
      ),
    );
  });

  test('actual compiled library searches, resolves links, validates folders and revisions', () {
    final engine = InkVaultNative.open(libraryPath: libraryPath);
    expect(engine.version, '0.1.0');
    const documents = [
      {'id': 'a', 'title': '문서', 'markdown': '[[b#page-1|별칭]] #수학/선형'},
      {'id': 'b', 'title': 'Rust', 'markdown': '공통 엔진'},
    ];
    expect(
      engine.invoke({
        'op': 'search',
        'documents': documents,
        'query': '엔진',
      })['matches'],
      [
        {'id': 'b', 'title': 'Rust', 'snippet': '공통 엔진', 'score': 1},
      ],
    );
    final graph = engine.invoke({
      'op': 'analyze_documents',
      'documents': documents,
    });
    expect(graph['edges'], [
      {'from': 'a', 'to': 'b'},
    ]);
    expect((graph['documents'] as List).first['tags'], ['수학', '수학/선형']);
    expect(
      engine.invoke({
        'op': 'folder_move',
        'folders': [
          {'id': 'a', 'parentId': null},
        ],
        'id': 'a',
        'parentId': null,
      })['valid'],
      true,
    );
    expect(
      () => engine.invoke({'op': 'validate_revision', 'revision': {}}),
      throwsA(
        isA<InkVaultNativeException>().having(
          (e) => e.code,
          'code',
          'invalid_revision',
        ),
      ),
    );
  });

  test('actual native response memory survives repeated Unicode calls and structured errors', () {
    final engine = InkVaultNative.open(libraryPath: libraryPath);
    for (var i = 0; i < 1000; i++) {
      expect(
        engine.invoke({
          'op': 'sha256',
          'bytes': [97, 98, 99],
        })['sha256'],
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    }
    expect(
      () => engine.invoke({'op': 'unsupported'}),
      throwsA(
        isA<InkVaultNativeException>().having(
          (e) => e.code,
          'code',
          'unknown_operation',
        ),
      ),
    );
  });
}
