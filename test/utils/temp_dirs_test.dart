import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'temp_dirs.dart';

void main() {
  final dir = Directory('unused-test-folder');
  FileSystemException inUse() => const FileSystemException(
    'Deletion failed',
    'unused-test-folder',
    OSError('in use', 32),
  );

  test('a folder still in use is tried again until it goes', () async {
    var calls = 0;
    await deleteTempDir(
      dir,
      wait: Duration.zero,
      delete: (_) async {
        calls++;
        if (calls < 3) throw inUse();
      },
    );
    expect(calls, 3);
  });

  test('a folder that stays in use is left, not failed', () async {
    var calls = 0;
    final notes = <String>[];
    await deleteTempDir(
      dir,
      wait: Duration.zero,
      attempts: 4,
      delete: (_) async {
        calls++;
        throw inUse();
      },
      note: notes.add,
    );
    expect(calls, 4);
    // said once, to the caller's note, not printed into the test log
    expect(notes, ['left unused-test-folder: still in use after 4 tries']);
  });

  test('another error still fails', () async {
    await expectLater(
      deleteTempDir(
        dir,
        wait: Duration.zero,
        delete: (_) async => throw const FileSystemException(
          'Deletion failed',
          'unused-test-folder',
          OSError('denied', 5),
        ),
      ),
      throwsA(isA<FileSystemException>()),
    );
  });
}
