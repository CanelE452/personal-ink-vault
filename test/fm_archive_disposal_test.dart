import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';

import 'utils/test_mock_channel_handlers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupMockPathProvider();
  FlavorConfig.setup();
  setUpAll(FileManager.init);
  for (final valid in [true, false]) {
    test('SBA import closes source with valid main=$valid', () async {
      final temp = await Directory.systemTemp.createTemp('sba-handle-');
      final source = File('${temp.path}/archive.sba');
      final archive = Archive()
        ..addFile(
          ArchiveFile.string(valid ? 'main.sbn2' : 'other.txt', 'note body'),
        )
        ..addFile(ArchiveFile.string('main.sbn2.0', 'asset bytes'));
      await source.writeAsBytes(ZipEncoder().encode(archive));
      final imported = await FileManager.importFile(source.path, '/');
      if (valid) {
        expect(
          await FileManager.getFile('$imported.sbn2').readAsString(),
          'note body',
        );
        expect(
          await FileManager.getFile('$imported.sbn2.0').readAsString(),
          'asset bytes',
        );
      } else {
        expect(imported, isNull);
      }
      // Windows rejects this immediately if the decoder retains its handle.
      await source.delete();
      expect(source.existsSync(), isFalse);
      await temp.delete();
    });
  }
}
