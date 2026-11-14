import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/office/pptx_slide_clone.dart';
import 'package:saber/data/office/pptx_slide_delete.dart';
import 'package:saber/data/office/pptx_slide_reorder.dart';
import 'package:xml/xml.dart';

const _fixtureSha =
    'f4e0190053ab3411c39cdd481cb05014d212a94f03a17fc5196a32bf78312456';

void main() {
  final fixture = Platform.environment['PIV_PPTX_CLONE_TEST_FIXTURE'];
  final library = Platform.environment['PIV_PPTX_CLONE_TEST_LIBRARY'];
  final skip = fixture == null || library == null
      ? 'Set PIV_PPTX_CLONE_TEST_FIXTURE and PIV_PPTX_CLONE_TEST_LIBRARY'
      : false;

  test(
    'Rust PPTX deletion removes the selected part and protects the last slide',
    () async {
      final directory = await _draftDirectory();
      final input = await File(fixture!).copy(p.join(directory.path, 'source.pptx'));
      final output = p.join(directory.path, 'deleted.pptx');
      final engine = PptxSlideDeleteEngine(libraryPath: library);
      final plan = await engine.inspect(
        sourcePath: input.path,
        sourceSha256: _fixtureSha,
      );
      expect(plan.slides.map((slide) => slide.hidden), [false, false, true]);
      expect(plan.slides.last.canDelete, isTrue);
      final result = await engine.delete(
        sourcePath: input.path,
        plan: plan,
        outputPath: output,
        slideIndex: 2,
      );
      expect((result.slideCount, result.deletedIndex), (2, 2));
      final order = _slideOrder(_parts(input.readAsBytesSync()));
      final after = _parts(File(output).readAsBytesSync());
      expect(_slideOrder(after), order.take(2));
      expect(after.containsKey(order.last), isFalse);
      final reopened = await engine.inspect(
        sourcePath: output,
        sourceSha256: result.outputSha256,
      );
      final lastPath = p.join(directory.path, 'last.pptx');
      final last = await engine.delete(
        sourcePath: output,
        plan: reopened,
        outputPath: lastPath,
        slideIndex: 0,
      );
      final single = await engine.inspect(
        sourcePath: lastPath,
        sourceSha256: last.outputSha256,
      );
      expect(single.slideCount, 1);
      expect(single.slides.single.canDelete, isFalse);
      final rejected = p.join(directory.path, 'empty.pptx');
      await expectLater(
        engine.delete(
          sourcePath: lastPath,
          plan: single,
          outputPath: rejected,
          slideIndex: 0,
        ),
        throwsA(
          isA<InkVaultNativeException>().having(
            (error) => error.code,
            'code',
            'unsupported_slide',
          ),
        ),
      );
      expect(File(rejected).existsSync(), isFalse);
      expect(sha256.convert(input.readAsBytesSync()).toString(), _fixtureSha);
    },
    skip: skip,
  );

  test(
    'Rust PPTX move changes only the presentation order and can move back',
    () async {
      final directory = await _draftDirectory();
      final input = await File(fixture!)
          .copy(p.join(directory.path, 'source.pptx'));
      final output = p.join(directory.path, 'reordered.pptx');
      final engine = PptxSlideReorderEngine(libraryPath: library);
      final plan = await engine.inspect(
        sourcePath: input.path,
        sourceSha256: _fixtureSha,
      );
      expect(plan.slides.map((slide) => slide.index), [0, 1, 2]);
      expect(plan.slides.map((slide) => slide.hidden), [false, false, true]);
      final moved = await engine.move(
        sourcePath: input.path,
        plan: plan,
        outputPath: output,
        sourceIndex: 0,
        targetIndex: 2,
        after: true,
      );
      expect(
        (moved.slideCount, moved.sourceIndex, moved.destinationIndex),
        (3, 0, 2),
      );
      final before = _parts(input.readAsBytesSync());
      final after = _parts(File(output).readAsBytesSync());
      final order = _slideOrder(before);
      expect(_slideOrder(after), [...order.skip(1), order.first]);
      expect(after.keys, unorderedEquals(before.keys));
      expect(
        before.keys.where(
          (name) =>
              sha256.convert(before[name]!) != sha256.convert(after[name]!),
        ),
        ['ppt/presentation.xml'],
      );
      final reopened = await engine.inspect(
        sourcePath: output,
        sourceSha256: moved.outputSha256,
      );
      expect(reopened.slides.map((slide) => slide.hidden), [
        false,
        true,
        false,
      ]);
      final restoredPath = p.join(directory.path, 'order-restored.pptx');
      final restored = await engine.move(
        sourcePath: output,
        plan: reopened,
        outputPath: restoredPath,
        sourceIndex: 2,
        targetIndex: 0,
        after: false,
      );
      expect((restored.slideCount, restored.destinationIndex), (3, 0));
      expect(_slideOrder(_parts(File(restoredPath).readAsBytesSync())), order);
      expect(sha256.convert(input.readAsBytesSync()).toString(), _fixtureSha);
    },
    skip: skip,
  );

  test(
    'Rust PPTX clone preserves ordered parts and can duplicate again',
    () async {
      final directory = await _draftDirectory();
      final input = await File(fixture!)
          .copy(p.join(directory.path, 'source.pptx'));
      final output = p.join(directory.path, 'clone.pptx');
      final engine = PptxSlideCloneEngine(libraryPath: library);
      final plan = await engine.inspect(
        sourcePath: input.path,
        sourceSha256: _fixtureSha,
      );
      expect(plan.slides.map((slide) => slide.index), [0, 1, 2]);
      expect(
        plan.slides.map((slide) => slide.canDuplicate),
        everyElement(isTrue),
      );
      expect(plan.slides.map((slide) => slide.hidden), [false, false, true]);

      final clone = await engine.duplicate(
        sourcePath: input.path,
        plan: plan,
        outputPath: output,
        slideIndex: 0,
      );
      expect((clone.slideCount, clone.duplicateIndex), (4, 1));
      final before = _parts(input.readAsBytesSync());
      final after = _parts(File(output).readAsBytesSync());
      final oldSlides = _slideOrder(before);
      final newSlides = _slideOrder(after);
      expect([newSlides[0], ...newSlides.skip(2)], oldSlides);
      expect(after[newSlides[1]], before[oldSlides.first]);
      final addedNotes = after.keys.where(
        (name) =>
            name.startsWith('ppt/notesSlides/notesSlide') &&
            !before.containsKey(name),
      );
      expect(
        after[addedNotes.single],
        before['ppt/notesSlides/notesSlide1.xml'],
      );
      final changedOriginals = before.keys.where(
        (name) => sha256.convert(before[name]!) != sha256.convert(after[name]!),
      );
      expect(
        changedOriginals,
        unorderedEquals([
          '[Content_Types].xml',
          'ppt/presentation.xml',
          'ppt/_rels/presentation.xml.rels',
        ]),
      );

      final reopened = await engine.inspect(
        sourcePath: output,
        sourceSha256: clone.outputSha256,
      );
      expect(reopened.slides[1].canDuplicate, isTrue);
      final repeat = await engine.duplicate(
        sourcePath: output,
        plan: reopened,
        outputPath: p.join(directory.path, 'clone-again.pptx'),
        slideIndex: 1,
      );
      expect((repeat.slideCount, repeat.duplicateIndex), (5, 2));
      expect(sha256.convert(input.readAsBytesSync()).toString(), _fixtureSha);
    },
    skip: skip,
  );

  test(
    'Rust PPTX clone refuses a changed source and a preexisting output',
    () async {
      final directory = await _draftDirectory();
      final input = await File(fixture!)
          .copy(p.join(directory.path, 'source.pptx'));
      final output = File(p.join(directory.path, 'clone.pptx'));
      final engine = PptxSlideCloneEngine(libraryPath: library);
      final plan = await engine.inspect(
        sourcePath: input.path,
        sourceSha256: _fixtureSha,
      );
      Future<PptxSlideCloneOutput> duplicate() => engine.duplicate(
        sourcePath: input.path,
        plan: plan,
        outputPath: output.path,
        slideIndex: 0,
      );
      await output.writeAsString('unchanged');
      await expectLater(
        duplicate(),
        throwsA(
          isA<InkVaultNativeException>().having(
            (error) => error.code,
            'code',
            'output_exists',
          ),
        ),
      );
      expect(await output.readAsString(), 'unchanged');
      await output.delete();
      await input.writeAsString('modified', mode: FileMode.append);
      await expectLater(
        duplicate(),
        throwsA(
          isA<InkVaultNativeException>().having(
            (error) => error.code,
            'code',
            'source_changed',
          ),
        ),
      );
      expect(output.existsSync(), isFalse);
    },
    skip: skip,
  );
}

Future<Directory> _draftDirectory() async {
  final directory = await Directory.systemTemp.createTemp('piv-pptx-rust-');
  addTearDown(() async {
    for (final name in [
      'source.pptx',
      'clone.pptx',
      'clone-again.pptx',
      'reordered.pptx',
      'order-restored.pptx',
      'deleted.pptx',
      'last.pptx',
      'empty.pptx',
    ]) {
      final file = File(p.join(directory.path, name));
      if (file.existsSync()) await file.delete();
    }
    await directory.delete();
  });
  return directory;
}

Map<String, List<int>> _parts(List<int> bytes) => {
  for (final part in ZipDecoder().decodeBytes(bytes).files)
    if (part.isFile) part.name: part.content,
};

List<String> _slideOrder(Map<String, List<int>> parts) {
  final slides = XmlDocument.parse(
    String.fromCharCodes(parts['ppt/presentation.xml']!),
  );
  final relations = XmlDocument.parse(
    String.fromCharCodes(parts['ppt/_rels/presentation.xml.rels']!),
  );
  final paths = {
    for (final entry in relations.rootElement.childElements)
      entry.getAttribute('Id')!: p.posix.normalize(
        'ppt/${entry.getAttribute('Target')}',
      ),
  };
  return [
    for (final slide in slides.findAllElements('sldId', namespace: '*'))
      paths[slide.attributes
          .singleWhere(
            (attribute) =>
                attribute.name.local == 'id' && attribute.name.prefix != null,
          )
          .value]!,
  ];
}
