import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/office/pptx_slide_layout.dart';

const _fixtureSha =
    '9240889c0b63d66516d4b04a0784faa71ec7c3a2d509893279d51736ee798af1';

void main() {
  final fixture = Platform.environment['PIV_PPTX_LAYOUT_TEST_FIXTURE'];
  final library = Platform.environment['PIV_PPTX_LAYOUT_TEST_DLL'];
  test(
    'Dart applies a compatible layout through the actual Rust library',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'piv-pptx-layout-',
      );
      final input = File(p.join(directory.path, 'source.pptx'));
      final output = File(p.join(directory.path, 'edited.pptx'));
      addTearDown(() async {
        if (output.existsSync()) await output.delete();
        if (input.existsSync()) await input.delete();
        await directory.delete();
      });
      await File(fixture!).copy(input.path);
      expect(sha256.convert(await input.readAsBytes()).toString(), _fixtureSha);
      final engine = PptxSlideLayoutEngine(libraryPath: library);
      final plan = await engine.inspect(
        sourcePath: input.path,
        sourceSha256: _fixtureSha,
      );
      expect(plan.slides.first.slideId, 256);
      const selectedLayout = 2147483651;
      expect(
        plan.slides.first.layouts.map((row) => row.id),
        contains(selectedLayout),
      );
      final result = await engine.apply(
        sourcePath: input.path,
        plan: plan,
        outputPath: output.path,
        slideIndex: 0,
        layoutId: selectedLayout,
      );
      expect(
        (result.slideCount, result.slideIndex, result.slideId, result.layoutId),
        (plan.slideCount, 0, 256, selectedLayout),
      );
      expect(result.sourceSha256, _fixtureSha);
      expect(result.outputSha256, isNot(_fixtureSha));
      expect(
        sha256.convert(await output.readAsBytes()).toString(),
        result.outputSha256,
      );
      final reopened = await engine.inspect(
        sourcePath: output.path,
        sourceSha256: result.outputSha256,
      );
      expect(reopened.slideCount, plan.slideCount);
      expect(
        reopened.slides.map((row) => (row.slideId, row.hidden, row.title)),
        plan.slides.map((row) => (row.slideId, row.hidden, row.title)),
      );
      expect(
        reopened.slides.first.layouts.map((row) => row.id),
        isNot(contains(selectedLayout)),
      );
      expect(sha256.convert(await input.readAsBytes()).toString(), _fixtureSha);
    },
    skip: fixture == null || library == null
        ? 'Set PIV_PPTX_LAYOUT_TEST_FIXTURE and PIV_PPTX_LAYOUT_TEST_DLL'
        : false,
  );
}
