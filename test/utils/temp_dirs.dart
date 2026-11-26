import 'dart:io';

/// Deletes a test's temporary folder. On Windows a file in it can stay held
/// for a moment after the vault closed (errno 32, "used by another
/// process"), which failed tests that had passed (Task 19). It tries again
/// every [wait], [attempts] times in all, and then leaves the folder in the
/// system's temporary folder instead of failing the test. Other errors fail
/// as before. [delete] stands in for the real deletion and [note] for the
/// printed line in its own test.
Future<void> deleteTempDir(
  Directory dir, {
  Duration wait = const Duration(milliseconds: 100),
  int attempts = 20,
  Future<void> Function(Directory dir)? delete,
  void Function(String line)? note,
}) async {
  final remove = delete ?? (dir) => dir.delete(recursive: true);
  // ignore: avoid_print
  final say = note ?? print;
  for (var attempt = 1; ; attempt++) {
    try {
      await remove(dir);
      return;
    } on FileSystemException catch (error) {
      if (!_inUse(error)) rethrow;
      if (attempt >= attempts) {
        say('left ${dir.path}: still in use after $attempts tries');
        return;
      }
      await Future<void>.delayed(wait);
    }
  }
}

/// Windows' "used by another process" (ERROR_SHARING_VIOLATION).
bool _inUse(FileSystemException error) => error.osError?.errorCode == 32;
