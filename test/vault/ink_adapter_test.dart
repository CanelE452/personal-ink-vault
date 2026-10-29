import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/canvas/_asset_cache.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/vault/saber_ink_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  test(
    'capture preserves PDF bytes and fails if an attachment is missing',
    () async {
      final temp = await Directory.systemTemp.createTemp('ink-capture-');
      final pdf = File('${temp.path}/original.pdf');
      final bytes = Uint8List.fromList([37, 80, 68, 70, 0, 255, 13, 10]);
      await pdf.writeAsBytes(bytes);
      final core = EditorCoreInfo(filePath: '/test');
      core.pages.add(
        EditorPage(
          backgroundImage: PdfEditorImage(
            id: 0,
            pdfBytes: null,
            pdfFile: pdf,
            pdfPage: 0,
            pageIndex: 0,
            pageSize: const Size(100, 200),
            naturalSize: const Size(100, 200),
            assetCache: core.assetCache,
            onMoveImage: null,
            onDeleteImage: null,
            onMiscChange: null,
          ),
        ),
      );
      final snapshot = await SaberInkAdapter.capture(core, 0);
      expect(snapshot['main.sbn2.0'], bytes);
      await pdf.delete();
      await expectLater(
        SaberInkAdapter.capture(core, 0),
        throwsA(isA<FileSystemException>()),
      );
      expect(core.assetCache.allowRemovingAssets, isTrue);
      core.dispose();
      await temp.delete(recursive: true);
    },
  );
  test(
    'page UUID survives reorder and serialization; duplicates get a new UUID',
    () {
      final page = EditorPage();
      final other = EditorPage();
      final id = page.pageId;
      final pages = [page, other]
        ..removeAt(0)
        ..add(page);
      final json = pages.last.toJson(OrderedAssetCache());
      final restored = EditorPage.fromJson(
        json,
        inlineAssets: null,
        readOnly: false,
        fileVersion: 19,
        sbnPath: '/test',
        assetCache: AssetCache(),
      );
      expect(restored.pageId, id);
      expect(page.copyWith().pageId, id);
      expect(page.copyWith(pageId: null, newIdentity: true).pageId, isNot(id));
      for (final p in [page, other, restored]) {
        p.dispose();
      }
    },
  );
}
