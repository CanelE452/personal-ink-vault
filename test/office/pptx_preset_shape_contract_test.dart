import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/office/office_templates.dart';
import 'package:saber/data/office/pptx_shape_delete.dart';
import 'package:saber/data/office/pptx_text_box.dart';
import 'package:xml/xml.dart';

void main() {
  final library = Platform.environment['INK_VAULT_NATIVE_LIBRARY'];
  test(
    'Dart inserts and deletes a real preset shape in an Office starter deck',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'piv-pptx-preset-',
      );
      addTearDown(() async {
        final owned = await temporary.resolveSymbolicLinks();
        expect(
          p.dirname(owned),
          await Directory.systemTemp.resolveSymbolicLinks(),
        );
        expect(p.basename(owned), startsWith('piv-pptx-preset-'));
        await Directory(owned).delete(recursive: true);
      });
      final source = File(p.join(temporary.path, 'source.pptx'));
      final output = File(p.join(temporary.path, 'candidate.pptx'));
      final starter = OfficeTemplates.create(
        OfficeTemplateKind.presentation,
        title: 'Shape contract',
      );
      await source.writeAsBytes(starter.bytes);
      final sourceSha = sha256.convert(starter.bytes).toString();
      final editor = PptxTextBoxEngine(libraryPath: library);
      final plan = await editor.inspectPresetShapes(
        sourcePath: source.path,
        sourceSha256: sourceSha,
      );
      expect(plan.slides.single.canAdd, isTrue);
      final result = await editor.addPresetShape(
        sourcePath: source.path,
        plan: plan,
        outputPath: output.path,
        slideIndex: 0,
        text: '  발표 & 자료\r\n다음 쪽  ',
        placement: PptxTextBoxPlacement.bottom,
        fontSize: 20,
        preset: PptxPresetShape.roundedRectangle,
        fillColor: null,
        lineColor: '274F69',
      );
      expect(result.slideCount, 1);
      expect(result.slideIndex, 0);
      expect(result.sourceSha256, sourceSha);
      expect(await source.readAsBytes(), starter.bytes);
      final outputBytes = await output.readAsBytes();
      expect(sha256.convert(outputBytes).toString(), result.outputSha256);
      final before = ZipDecoder().decodeBytes(starter.bytes);
      final after = ZipDecoder().decodeBytes(outputBytes);
      const slide = 'ppt/slides/slide1.xml';
      expect(
        after.files.map((file) => file.name),
        before.files.map((file) => file.name),
      );
      for (final file in before.files.where((file) => file.name != slide)) {
        expect(
          after.findFile(file.name)!.content,
          file.content,
          reason: file.name,
        );
      }
      final root = XmlDocument.parse(
        utf8.decode(after.findFile(slide)!.content),
      );
      const drawing = 'http://schemas.openxmlformats.org/drawingml/2006/main';
      const presentation =
          'http://schemas.openxmlformats.org/presentationml/2006/main';
      final shape = root
          .findAllElements('sp', namespace: presentation)
          .singleWhere(
            (shape) =>
                shape
                    .findAllElements('cNvPr', namespace: presentation)
                    .single
                    .getAttribute('id') ==
                '${result.shapeId}',
          );
      final visual = shape
          .findAllElements('cNvSpPr', namespace: presentation)
          .single;
      expect(visual.getAttribute('txBox'), isNull);
      expect(
        shape
            .findAllElements('prstGeom', namespace: drawing)
            .single
            .getAttribute('prst'),
        'roundRect',
      );
      expect(
        shape
            .findAllElements('t', namespace: drawing)
            .map((element) => element.innerText),
        ['  발표 & 자료', '다음 쪽  '],
      );
      final properties = shape
          .findAllElements('spPr', namespace: presentation)
          .single;
      expect(
        properties.findElements('noFill', namespace: drawing),
        hasLength(1),
      );
      expect(
        properties
            .findElements('ln', namespace: drawing)
            .single
            .findAllElements('srgbClr', namespace: drawing)
            .single
            .getAttribute('val'),
        '274F69',
      );

      final deleter = PptxShapeDeleteEngine(libraryPath: library);
      final deletePlan = await deleter.inspect(
        sourcePath: output.path,
        sourceSha256: result.outputSha256,
      );
      final shapes = await deleter.inspectSlide(
        sourcePath: output.path,
        plan: deletePlan,
        slideIndex: 0,
      );
      expect(shapes.map((target) => target.kind), ['textBox', 'shape']);
      final selected = shapes.singleWhere(
        (target) => target.shapeId == result.shapeId,
      );
      final deletedFile = File(p.join(temporary.path, 'deleted.pptx'));
      final deleted = await deleter.delete(
        sourcePath: output.path,
        plan: deletePlan,
        outputPath: deletedFile.path,
        slideIndex: 0,
        shapeId: selected.shapeId,
      );
      expect(deleted.slideCount, 1);
      expect(deleted.shapeId, result.shapeId);
      expect(await output.readAsBytes(), outputBytes);
      final deletedBytes = await deletedFile.readAsBytes();
      expect(sha256.convert(deletedBytes).toString(), deleted.outputSha256);
      final restored = ZipDecoder().decodeBytes(deletedBytes);
      expect(
        restored.files.map((entry) => entry.name),
        before.files.map((entry) => entry.name),
      );
      for (final entry in before.files) {
        expect(
          restored.findFile(entry.name)!.content,
          entry.content,
          reason: entry.name,
        );
      }
    },
    skip: library == null,
  );
}
