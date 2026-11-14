import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flex_color_picker/flex_color_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/widgets.dart' as pw;
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/components/canvas/save_indicator.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/office/android_office_engine.dart';
import 'package:saber/data/office/docx_body_text.dart';
import 'package:saber/data/office/docx_find_replace.dart';
import 'package:saber/data/office/docx_paragraph_insert.dart';
import 'package:saber/data/office/docx_photo_replacement.dart';
import 'package:saber/data/office/docx_table_insert.dart';
import 'package:saber/data/office/docx_table_structure.dart';
import 'package:saber/data/office/hwp_office_engine.dart';
import 'package:saber/data/office/office_annotation_store.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/office/office_image_asset.dart';
import 'package:saber/data/office/office_preview_engine.dart';
import 'package:saber/data/office/office_templates.dart';
import 'package:saber/data/office/office_view_state.dart';
import 'package:saber/data/office/pptx_find_replace.dart';
import 'package:saber/data/office/pptx_photo_addition.dart';
import 'package:saber/data/office/pptx_photo_replacement.dart';
import 'package:saber/data/office/pptx_shape_delete.dart';
import 'package:saber/data/office/pptx_shape_geometry.dart';
import 'package:saber/data/office/pptx_shape_order.dart';
import 'package:saber/data/office/pptx_shape_text.dart';
import 'package:saber/data/office/pptx_slide_clone.dart';
import 'package:saber/data/office/pptx_slide_delete.dart';
import 'package:saber/data/office/pptx_slide_insert.dart';
import 'package:saber/data/office/pptx_slide_layout.dart';
import 'package:saber/data/office/pptx_slide_reorder.dart';
import 'package:saber/data/office/pptx_text_box.dart';
import 'package:saber/data/office/windows_office_engine.dart';
import 'package:saber/data/vault/saber_ink_adapter.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saber/pages/office/office_workspace.dart';
import 'package:saber/pages/office/windows_office_editor.dart';
import 'package:xml/xml.dart';

import '../utils/test_editor.dart';
import '../utils/test_mock_channel_handlers.dart';
import 'annotation_store_test.dart' show annotationOfficeFile, annotationPdf;
import 'docx_photo_replacement_test.dart' show docxPhotoFixture;
import 'pptx_photo_replacement_test.dart'
    show pptxPhotoFixture, pptxReplacementPhoto;

final class _PptxPhotoFile extends PlatformFile {
  new(this.bytes);
  final Uint8List bytes;
  @override
  String get name => 'replacement.png';
  @override
  Future<int?> length() async => bytes.length;
  @override
  Stream<Uint8List> readAsByteStream() => Stream.value(bytes);
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected photo picker access: ${invocation.memberName}',
  );
}

final class _PptxPhotoPicker extends FilePickerPlatform {
  new(this.file);
  final PlatformFile file;
  var calls = 0;

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    calls++;
    return file;
  }
}

class FixtureOfficeEngine extends AndroidOfficeEngine {
  new({this.available = true, this.onEdit, this.cleanup});
  final bool available;
  final Future<AndroidOfficeEditResult> Function(String, String)? onEdit;
  final VoidCallback? cleanup;
  @override
  Future<AndroidOfficeCapabilities> capabilities() async =>
      AndroidOfficeCapabilities(
        available: available,
        engineVersion: 'fixture-engine',
        editableFormats: available ? ['docx', 'pptx'] : [],
      );
  @override
  Future<AndroidOfficeEditResult> edit({
    required String sourcePath,
    required String sessionId,
  }) async {
    if (onEdit == null)
      return const AndroidOfficeEditResult(
        status: AndroidOfficeEditStatus.cancelled,
        engineVersion: 'fixture-engine',
      );
    final inputHash = sha256
        .convert(await File(sourcePath).readAsBytes())
        .toString();
    final result = await onEdit!(sourcePath, sessionId);
    if (result.status != AndroidOfficeEditStatus.saved ||
        result.inputSourceSha256 != null)
      return result;
    return AndroidOfficeEditResult(
      status: result.status,
      engineVersion: result.engineVersion,
      sessionId: result.sessionId,
      sourcePath: result.sourcePath,
      pdfPath: result.pdfPath,
      sourceSha256: result.sourceSha256,
      pdfSha256: result.pdfSha256,
      pdfPageCount: result.pdfPageCount,
      inputSourceSha256: inputHash,
    );
  }
}

class _FixtureAndroidLegacyEngine extends FixtureOfficeEngine {
  new(this.supported, this.convert);

  final bool supported;
  final Future<OfficeConversionResult?> Function(File, String) convert;

  @override
  Future<AndroidOfficeCapabilities> capabilities() async =>
      AndroidOfficeCapabilities(
        available: true,
        engineVersion: 'conversion-test',
        editableFormats: ['doc', 'ppt'],
        supportsLegacyConversion: supported,
      );

  @override
  Future<OfficeConversionResult?> convertLegacy({
    required File source,
    required String sessionId,
    required String expectedSourceSha256,
  }) => convert(source, expectedSourceSha256);
}

class _FixtureAndroidCloneEngine extends FixtureOfficeEngine {
  new(this.inspect);

  final Future<AndroidOfficeNativeObservationResult?> Function(
    String path,
    String id,
    String sourceHash,
  )
  inspect;

  @override
  Future<AndroidOfficeNativeObservationResult?> inspectPresentation({
    required String sourcePath,
    required String sessionId,
    required String inputSourceSha256,
  }) => inspect(sourcePath, sessionId, inputSourceSha256);
}

class _FixtureAndroidCloneObservation
    implements AndroidOfficeNativeObservationResult {
  new({
    required this.sessionId,
    required this.sourceSha256,
    required this.pdf,
    required this.pdfSha256,
    required this.partCount,
    required this.pageCount,
    required this.onDispose,
  });

  final File pdf;
  final VoidCallback onDispose;
  @override
  final String sessionId;
  @override
  final String sourceSha256;
  @override
  final String pdfSha256;
  @override
  final int partCount;
  @override
  final int pageCount;
  @override
  String get format => 'pptx';
  @override
  String get engineVersion => 'fixture-clone-observation';
  @override
  String get pdfPath => pdf.path;

  @override
  Future<void> dispose() async {
    onDispose();
    await pdf.delete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected clone observation field ${invocation.memberName}',
  );
}

class _FixturePptxPhotoAddition extends PptxPhotoAdditionEngine {
  new(this.original, this.candidate, this.image, {required this.wrongSlide});

  final Uint8List original, candidate;
  final WindowsOfficeImageAsset image;
  final bool wrongSlide;
  String? source, output;
  var adds = 0;

  @override
  Future<PptxPhotoAdditionPlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) async {
    source = sourcePath;
    expect(await File(sourcePath).readAsBytes(), original);
    expect(sourceSha256, sha256.convert(original).toString());
    return PptxPhotoAdditionPlan(
      sourceSha256: sourceSha256,
      slides: const [
        PptxPhotoAdditionSlide(index: 0, hidden: false, canAdd: false),
        PptxPhotoAdditionSlide(
          index: 1,
          hidden: true,
          canAdd: true,
          title: '사진 실습',
          sectionName: '실습',
        ),
      ],
    );
  }

  @override
  Future<PptxPhotoAdditionOutput> add({
    required String sourcePath,
    required PptxPhotoAdditionPlan plan,
    required String outputPath,
    required int slideIndex,
    required String assetPath,
    required String assetSha256,
  }) async {
    adds++;
    output = outputPath;
    expect(sourcePath, source);
    expect(plan.sourceSha256, sha256.convert(original).toString());
    expect(await File(sourcePath).readAsBytes(), original);
    expect(slideIndex, 1);
    expect(p.dirname(assetPath), p.dirname(sourcePath));
    expect(await File(assetPath).readAsBytes(), image.bytes);
    expect(assetSha256, image.sha256);
    await File(outputPath).writeAsBytes(candidate);
    return (
      sourceSha256: plan.sourceSha256,
      outputSha256: sha256.convert(candidate).toString(),
      slideCount: 2,
      slideIndex: wrongSlide ? 0 : 1,
      shapeId: 41,
    );
  }
}

class _FixturePptxSlideClone extends PptxSlideCloneEngine {
  new(this.input, this.output);

  final Uint8List input;
  final Uint8List output;
  String? sourcePath;
  String? outputPath;
  var applyCount = 0;

  @override
  Future<PptxSlideClonePlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) async {
    this.sourcePath = sourcePath;
    expect(await File(sourcePath).readAsBytes(), input);
    expect(sourceSha256, sha256.convert(input).toString());
    return PptxSlideClonePlan(
      sourceSha256: sourceSha256,
      slides: const [
        PptxSlideChoice(
          index: 0,
          canDuplicate: true,
          hidden: false,
          title: '강의 시작',
        ),
        PptxSlideChoice(
          index: 1,
          canDuplicate: false,
          hidden: true,
          title: '별도 개체',
        ),
      ],
    );
  }

  @override
  Future<PptxSlideCloneOutput> duplicate({
    required String sourcePath,
    required PptxSlideClonePlan plan,
    required String outputPath,
    required int slideIndex,
  }) async {
    applyCount++;
    expect(slideIndex, 0);
    expect(plan.sourceSha256, sha256.convert(input).toString());
    expect(sourcePath, this.sourcePath);
    expect(
      FileSystemEntity.typeSync(outputPath, followLinks: false),
      FileSystemEntityType.notFound,
    );
    this.outputPath = outputPath;
    await File(outputPath).writeAsBytes(output);
    return PptxSlideCloneOutput(
      sourceSha256: plan.sourceSha256,
      outputSha256: sha256.convert(output).toString(),
      slideCount: 3,
      duplicateIndex: 1,
    );
  }
}

class _FixturePptxSlideReorder extends PptxSlideReorderEngine {
  new(
    this.input,
    this.output, {
    required this.reportedDestination,
    this.sectionGroups,
  });

  final Uint8List input;
  final Uint8List output;
  final int reportedDestination;
  final (int, int)? sectionGroups;
  String? sourcePath;
  String? outputPath;
  var applyCount = 0;

  @override
  Future<PptxSlideReorderPlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) async {
    this.sourcePath = sourcePath;
    expect(await File(sourcePath).readAsBytes(), input);
    expect(sourceSha256, sha256.convert(input).toString());
    return PptxSlideReorderPlan(
      sourceSha256: sourceSha256,
      slides: [
        PptxSlideReorderChoice(
          index: 0,
          hidden: false,
          title: '강의 시작',
          sectionTitle: sectionGroups == null ? '도입' : '실습',
          sectionGroup: sectionGroups?.$1,
        ),
        PptxSlideReorderChoice(
          index: 1,
          hidden: true,
          title: '예시',
          sectionTitle: '실습',
          sectionGroup: sectionGroups?.$2,
        ),
      ],
    );
  }

  @override
  Future<PptxSlideReorderOutput> move({
    required String sourcePath,
    required PptxSlideReorderPlan plan,
    required String outputPath,
    required int sourceIndex,
    required int targetIndex,
    required bool after,
  }) async {
    applyCount++;
    expect(
      (sourceIndex, targetIndex, after),
      (0, 1, sectionGroups?.$1 == sectionGroups?.$2),
    );
    expect(plan.sourceSha256, sha256.convert(input).toString());
    expect(sourcePath, this.sourcePath);
    expect(
      FileSystemEntity.typeSync(outputPath, followLinks: false),
      FileSystemEntityType.notFound,
    );
    this.outputPath = outputPath;
    await File(outputPath).writeAsBytes(output);
    return PptxSlideReorderOutput(
      sourceSha256: plan.sourceSha256,
      outputSha256: sha256.convert(output).toString(),
      slideCount: 2,
      sourceIndex: sourceIndex,
      destinationIndex: reportedDestination,
    );
  }
}

class _FixturePptxSlideDisplay extends PptxSlideReorderEngine {
  new(this.input, this.output, {required this.originalHidden});

  final Uint8List input;
  final Uint8List output;
  final bool originalHidden;
  String? sourcePath;
  String? outputPath;
  var applyCount = 0;

  @override
  Future<PptxSlideReorderPlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) async {
    this.sourcePath = sourcePath;
    expect(await File(sourcePath).readAsBytes(), input);
    expect(sourceSha256, sha256.convert(input).toString());
    return PptxSlideReorderPlan(
      sourceSha256: sourceSha256,
      slides: [
        PptxSlideReorderChoice(index: 0, hidden: originalHidden, title: '실습'),
      ],
    );
  }

  @override
  Future<PptxSlideDisplayOutput> setHidden({
    required String sourcePath,
    required PptxSlideReorderPlan plan,
    required String outputPath,
    required int slideIndex,
    required bool expectedHidden,
    required bool hidden,
  }) async {
    applyCount++;
    expect(sourcePath, this.sourcePath);
    expect(plan.sourceSha256, sha256.convert(input).toString());
    expect(
      (slideIndex, expectedHidden, hidden),
      (0, originalHidden, !originalHidden),
    );
    expect(
      FileSystemEntity.typeSync(outputPath, followLinks: false),
      FileSystemEntityType.notFound,
    );
    this.outputPath = outputPath;
    await File(outputPath).writeAsBytes(output);
    return PptxSlideDisplayOutput(
      sourceSha256: plan.sourceSha256,
      outputSha256: sha256.convert(output).toString(),
      slideCount: 1,
      slideIndex: slideIndex,
      hidden: hidden,
    );
  }
}

Uint8List _pptxDisplayFixture(Uint8List source, {required bool hidden}) {
  const part = 'ppt/slides/slide1.xml';
  final archive = ZipDecoder().decodeBytes(source);
  final slide = XmlDocument.parse(utf8.decode(archive.findFile(part)!.content));
  slide.rootElement.setAttribute('show', hidden ? '0' : '1');
  archive.addFile(ArchiveFile.string(part, slide.toXmlString()));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

class _FixturePptxSlideBackground extends PptxSlideReorderEngine {
  new(this.input, this.output, this.initial, this.requested);

  final Uint8List input, output;
  final String initial, requested;
  String? sourcePath;
  var applyCount = 0;

  @override
  Future<PptxSlideReorderPlan> inspectBackground({
    required String sourcePath,
    required String sourceSha256,
  }) async {
    this.sourcePath = sourcePath;
    expect(await File(sourcePath).readAsBytes(), input);
    expect(sourceSha256, sha256.convert(input).toString());
    return PptxSlideReorderPlan(
      sourceSha256: sourceSha256,
      slides: [
        PptxSlideReorderChoice(index: 0, hidden: true, background: initial),
        const PptxSlideReorderChoice(
          index: 1,
          hidden: false,
          background: 'unsupported',
        ),
      ],
    );
  }

  @override
  Future<PptxSlideBackgroundOutput> setBackground({
    required String sourcePath,
    required PptxSlideReorderPlan plan,
    required String outputPath,
    required int slideIndex,
    required String background,
  }) async {
    applyCount++;
    expect(sourcePath, this.sourcePath);
    expect(plan.sourceSha256, sha256.convert(input).toString());
    expect((slideIndex, background), (0, requested));
    expect(File(outputPath).existsSync(), isFalse);
    await File(outputPath).writeAsBytes(output);
    return (
      sourceSha256: plan.sourceSha256,
      outputSha256: sha256.convert(output).toString(),
      slideCount: 2,
      slideIndex: slideIndex,
      background: background,
    );
  }
}

Uint8List _pptxBackgroundFixture(Uint8List source, String background) {
  if (background == 'inherited') return source;
  const part = 'ppt/slides/slide1.xml';
  final archive = ZipDecoder().decodeBytes(source);
  final slide = XmlDocument.parse(utf8.decode(archive.findFile(part)!.content));
  final data = slide.rootElement.childElements.singleWhere(
    (element) => element.localName == 'cSld',
  );
  data.children.insert(
    0,
    XmlDocumentFragment.parse(
      '<p:bg><p:bgPr><a:solidFill><a:srgbClr val="${background.substring(1)}"/>'
      '</a:solidFill><a:effectLst/></p:bgPr></p:bg>',
    ).children.single.copy(),
  );
  archive.addFile(ArchiveFile.string(part, slide.toXmlString()));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

class _FixturePptxSlideDelete extends PptxSlideDeleteEngine {
  new(
    this.input,
    this.output, {
    required this.singleSlide,
    required this.reportedIndex,
  });

  final Uint8List input;
  final Uint8List output;
  final bool singleSlide;
  final int reportedIndex;
  String? sourcePath;
  String? outputPath;
  var applyCount = 0;

  @override
  Future<PptxSlideDeletePlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) async {
    this.sourcePath = sourcePath;
    expect(await File(sourcePath).readAsBytes(), input);
    expect(sourceSha256, sha256.convert(input).toString());
    return PptxSlideDeletePlan(
      sourceSha256: sourceSha256,
      slides: [
        const PptxSlideDeleteChoice(
          index: 0,
          hidden: false,
          canDelete: false,
          title: '강의 시작',
        ),
        if (!singleSlide)
          const PptxSlideDeleteChoice(
            index: 1,
            hidden: true,
            canDelete: true,
            title: '예시',
            sectionName: '실습',
          ),
      ],
    );
  }

  @override
  Future<PptxSlideDeleteOutput> delete({
    required String sourcePath,
    required PptxSlideDeletePlan plan,
    required String outputPath,
    required int slideIndex,
  }) async {
    applyCount++;
    expect(slideIndex, 1);
    expect(plan.sourceSha256, sha256.convert(input).toString());
    expect(sourcePath, this.sourcePath);
    expect(File(outputPath).existsSync(), isFalse);
    this.outputPath = outputPath;
    await File(outputPath).writeAsBytes(output);
    return PptxSlideDeleteOutput(
      sourceSha256: plan.sourceSha256,
      outputSha256: sha256.convert(output).toString(),
      slideCount: 1,
      deletedIndex: reportedIndex,
    );
  }
}

class _FixturePptxSlideLayout extends PptxSlideLayoutEngine {
  new(
    this.input,
    this.output, {
    required this.unavailable,
    required this.wrongSlide,
  });

  final Uint8List input;
  final Uint8List output;
  final bool unavailable;
  final bool wrongSlide;
  String? sourcePath;
  String? outputPath;
  var applyCount = 0;

  @override
  Future<PptxSlideLayoutPlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) async {
    this.sourcePath = sourcePath;
    expect(await File(sourcePath).readAsBytes(), input);
    expect(sourceSha256, sha256.convert(input).toString());
    return PptxSlideLayoutPlan(
      sourceSha256: sourceSha256,
      slides: [
        const PptxSlideLayoutChoice(
          index: 0,
          slideId: 256,
          hidden: false,
          layouts: [],
        ),
        PptxSlideLayoutChoice(
          index: 1,
          slideId: 263,
          hidden: true,
          title: '실습 예시',
          sectionName: '실습',
          layouts: unavailable
              ? const []
              : const [
                  PptxSlideInsertLayout(
                    id: 2147483650,
                    name: '실습 레이아웃',
                    kind: 'obj',
                  ),
                  PptxSlideInsertLayout(
                    id: 2147483651,
                    name: '실습 레이아웃',
                    kind: 'obj',
                  ),
                  PptxSlideInsertLayout(
                    id: 2147483652,
                    name: '요약 레이아웃',
                    kind: 'titleOnly',
                  ),
                  PptxSlideInsertLayout(id: 2147483653, name: 'tx', kind: 'tx'),
                  PptxSlideInsertLayout(
                    id: 2147483654,
                    name: 'obj',
                    kind: 'obj',
                  ),
                ],
        ),
      ],
    );
  }

  @override
  Future<PptxSlideLayoutOutput> apply({
    required String sourcePath,
    required PptxSlideLayoutPlan plan,
    required String outputPath,
    required int slideIndex,
    required int layoutId,
  }) async {
    applyCount++;
    expect(sourcePath, this.sourcePath);
    expect(slideIndex, 1);
    expect(plan.slides[slideIndex].slideId, 263);
    expect(layoutId, 2147483651);
    expect(File(outputPath).existsSync(), isFalse);
    this.outputPath = outputPath;
    await File(outputPath).writeAsBytes(output);
    return PptxSlideLayoutOutput(
      sourceSha256: plan.sourceSha256,
      outputSha256: sha256.convert(output).toString(),
      slideCount: plan.slideCount,
      slideIndex: slideIndex,
      slideId: wrongSlide ? 256 : 263,
      layoutId: layoutId,
    );
  }
}

class _FixturePptxSlideInsert extends PptxSlideInsertEngine {
  new(
    this.input,
    this.output, {
    required this.noEligiblePosition,
    required this.reportedIndex,
    this.layouts = const [],
    this.wrongLayout = false,
  });

  final Uint8List input;
  final Uint8List output;
  final bool noEligiblePosition;
  final int reportedIndex;
  final List<PptxSlideInsertLayout> layouts;
  final bool wrongLayout;
  String? sourcePath;
  String? outputPath;
  int? requestedLayoutId;
  var applyCount = 0;

  @override
  Future<PptxSlideInsertPlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) async {
    this.sourcePath = sourcePath;
    expect(await File(sourcePath).readAsBytes(), input);
    expect(sourceSha256, sha256.convert(input).toString());
    return PptxSlideInsertPlan(
      sourceSha256: sourceSha256,
      slides: [
        const PptxSlideInsertChoice(
          index: 0,
          hidden: false,
          canInsert: false,
          title: '강의 시작',
        ),

        PptxSlideInsertChoice(
          index: 1,
          hidden: true,
          canInsert: !noEligiblePosition,
          title: '예시',
          sectionName: '실습',
          layouts: layouts,
        ),
      ],
    );
  }

  @override
  Future<PptxSlideInsertOutput> insert({
    required String sourcePath,
    required PptxSlideInsertPlan plan,
    required String outputPath,
    required int slideIndex,
    int? layoutId,
  }) async {
    applyCount++;
    requestedLayoutId = layoutId;
    expect(slideIndex, 1);
    expect(plan.sourceSha256, sha256.convert(input).toString());
    expect(sourcePath, this.sourcePath);
    expect(File(outputPath).existsSync(), isFalse);
    this.outputPath = outputPath;
    await File(outputPath).writeAsBytes(output);
    return PptxSlideInsertOutput(
      sourceSha256: plan.sourceSha256,
      outputSha256: sha256.convert(output).toString(),
      slideCount: 3,
      insertedIndex: reportedIndex,
      layoutId: wrongLayout ? 2147483649 : layoutId,
    );
  }
}

class _FixturePptxTextBox extends PptxTextBoxEngine {
  new(this.input, this.output, {required this.wrongSlide});

  final Uint8List input, output;
  final bool wrongSlide;
  String? sourcePath, outputPath;
  ({int index, String text, PptxTextBoxPlacement placement, int size})? added;

  @override
  Future<PptxTextBoxPlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) async {
    this.sourcePath = sourcePath;
    expect(await File(sourcePath).readAsBytes(), input);
    expect(sourceSha256, sha256.convert(input).toString());
    return PptxTextBoxPlan(
      sourceSha256: sourceSha256,
      slides: const [
        PptxTextBoxSlide(index: 0, hidden: false, canAdd: false, title: '표지'),
        PptxTextBoxSlide(
          index: 1,
          hidden: true,
          canAdd: true,
          title: '예시',
          sectionName: '실습',
        ),
      ],
    );
  }

  @override
  Future<PptxTextBoxOutput> add({
    required String sourcePath,
    required PptxTextBoxPlan plan,
    required String outputPath,
    required int slideIndex,
    required String text,
    required PptxTextBoxPlacement placement,
    required int fontSize,
  }) async {
    expect(sourcePath, this.sourcePath);
    expect(plan.sourceSha256, sha256.convert(input).toString());
    expect(File(outputPath).existsSync(), isFalse);
    this.outputPath = outputPath;
    added = (
      index: slideIndex,
      text: text,
      placement: placement,
      size: fontSize,
    );
    await File(outputPath).writeAsBytes(output);
    return PptxTextBoxOutput(
      sourceSha256: plan.sourceSha256,
      outputSha256: sha256.convert(output).toString(),
      slideCount: plan.slideCount,
      slideIndex: wrongSlide ? 0 : slideIndex,
      shapeId: 12,
    );
  }
}

class _FixturePptxPresetShape extends _FixturePptxTextBox {
  new(super.input, super.output, {required super.wrongSlide});

  ({PptxPresetShape kind, String? fill, String line})? shape;

  @override
  Future<PptxTextBoxPlan> inspectPresetShapes({
    required String sourcePath,
    required String sourceSha256,
  }) => inspect(sourcePath: sourcePath, sourceSha256: sourceSha256);

  @override
  Future<PptxTextBoxOutput> addPresetShape({
    required String sourcePath,
    required PptxTextBoxPlan plan,
    required String outputPath,
    required int slideIndex,
    required String text,
    required PptxTextBoxPlacement placement,
    required int fontSize,
    required PptxPresetShape preset,
    required String? fillColor,
    required String lineColor,
  }) {
    shape = (kind: preset, fill: fillColor, line: lineColor);
    return add(
      sourcePath: sourcePath,
      plan: plan,
      outputPath: outputPath,
      slideIndex: slideIndex,
      text: text,
      placement: placement,
      fontSize: fontSize,
    );
  }
}

class _FixturePptxTableAdd extends PptxTableAddEngine {
  new(this.original, this.candidate, {required this.wrongDimensions});

  final Uint8List original, candidate;
  final bool wrongDimensions;
  String? sourcePath, outputPath;
  ({int slideIndex, int rows, int columns})? added;

  @override
  Future<PptxTextBoxPlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) async {
    this.sourcePath = sourcePath;
    expect(await File(sourcePath).readAsBytes(), original);
    expect(sourceSha256, sha256.convert(original).toString());
    return PptxTextBoxPlan(
      sourceSha256: sourceSha256,
      slides: const [
        PptxTextBoxSlide(index: 0, hidden: false, canAdd: false, title: '표지'),
        PptxTextBoxSlide(index: 1, hidden: true, canAdd: true, title: '예시'),
      ],
    );
  }

  @override
  Future<PptxTableAddOutput> add({
    required String sourcePath,
    required PptxTextBoxPlan plan,
    required String outputPath,
    required int slideIndex,
    required int rows,
    required int columns,
  }) async {
    expect(sourcePath, this.sourcePath);
    expect(plan.sourceSha256, sha256.convert(original).toString());
    expect(File(outputPath).existsSync(), isFalse);
    this.outputPath = outputPath;
    added = (slideIndex: slideIndex, rows: rows, columns: columns);
    await File(outputPath).writeAsBytes(candidate);
    return (
      sourceSha256: plan.sourceSha256,
      outputSha256: sha256.convert(candidate).toString(),
      slideCount: plan.slideCount,
      slideIndex: slideIndex,
      shapeId: 12,
      rows: wrongDimensions ? rows - 1 : rows,
      columns: columns,
    );
  }
}

class _FixturePptxTableCellText extends PptxTableCellTextEngine {
  new(this.original, this.candidate, {required this.wrongTarget});

  final Uint8List original, candidate;
  final bool wrongTarget;
  final loadedSlides = <int>[];
  String? sourcePath, outputPath;
  ({int slideIndex, int shapeId, int row, int column})? replaced;
  List<PptxShapeTextChange>? changes;

  @override
  Future<PptxShapeTextPlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) async {
    this.sourcePath = sourcePath;
    expect(await File(sourcePath).readAsBytes(), original);
    expect(sourceSha256, sha256.convert(original).toString());
    return PptxShapeTextPlan(
      sourceSha256: sourceSha256,
      slides: const [
        PptxShapeTextSlide(index: 0, hidden: false, title: '표지'),
        PptxShapeTextSlide(index: 1, hidden: true, title: '표 실습'),
      ],
    );
  }

  @override
  Future<List<PptxTableCellTextTable>> inspectSlide({
    required String sourcePath,
    required PptxShapeTextPlan plan,
    required int slideIndex,
  }) async {
    expect(sourcePath, this.sourcePath);
    expect(plan.sourceSha256, sha256.convert(original).toString());
    loadedSlides.add(slideIndex);
    if (slideIndex != 1) return [];
    final otherCell = PptxTableCellTextCell(
      row: 0,
      column: 0,
      runs: const [
        PptxShapeTextRun(paragraphIndex: 0, runIndex: 0, text: '다른 셀'),
      ],
    );
    return [
      PptxTableCellTextTable(
        shapeId: 4,
        name: '다른 표',
        rows: 1,
        columns: 1,
        cells: [otherCell],
      ),
      PptxTableCellTextTable(
        shapeId: 12,
        name: '실습 표',
        rows: 3,
        columns: 4,
        cells: [
          otherCell,
          PptxTableCellTextCell(
            row: 1,
            column: 2,
            runs: [
              const PptxShapeTextRun(paragraphIndex: 0, runIndex: 0, text: ''),
              for (var runIndex = 1; runIndex < 8; runIndex++)
                PptxShapeTextRun(
                  paragraphIndex: 0,
                  runIndex: runIndex,
                  text: '유지할 글자 구간 $runIndex',
                ),
              const PptxShapeTextRun(
                paragraphIndex: 0,
                runIndex: 8,
                text: '지울 문구',
              ),
            ],
          ),
        ],
      ),
    ];
  }

  @override
  Future<PptxTableCellTextOutput> replace({
    required String sourcePath,
    required PptxShapeTextPlan plan,
    required String outputPath,
    required int slideIndex,
    required int shapeId,
    required int row,
    required int column,
    required List<PptxShapeTextChange> changes,
  }) async {
    expect(sourcePath, this.sourcePath);
    expect(plan.sourceSha256, sha256.convert(original).toString());
    expect(File(outputPath).existsSync(), isFalse);
    this.outputPath = outputPath;
    replaced = (
      slideIndex: slideIndex,
      shapeId: shapeId,
      row: row,
      column: column,
    );
    this.changes = List.of(changes);
    await File(outputPath).writeAsBytes(candidate);
    return (
      sourceSha256: plan.sourceSha256,
      outputSha256: sha256.convert(candidate).toString(),
      slideCount: plan.slideCount,
      slideIndex: slideIndex,
      shapeId: shapeId,
      row: row,
      column: wrongTarget ? 0 : column,
    );
  }
}

class _FixturePptxTableStructure extends PptxTableStructureEngine {
  new(this.original, this.candidate, {required this.wrongCandidateHash});

  final Uint8List original, candidate;
  final bool wrongCandidateHash;
  String? sourcePath, outputPath;
  ({int slideIndex, int shapeId, PptxTableStructureAction action, int index})?
  edited;

  @override
  Future<PptxShapeTextPlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) async {
    this.sourcePath = sourcePath;
    expect(await File(sourcePath).readAsBytes(), original);
    expect(sourceSha256, sha256.convert(original).toString());
    return PptxShapeTextPlan(
      sourceSha256: sourceSha256,
      slides: const [
        PptxShapeTextSlide(index: 0, hidden: false, title: '표 실습'),
      ],
    );
  }

  @override
  Future<List<PptxTableStructureTable>> inspectSlide({
    required String sourcePath,
    required PptxShapeTextPlan plan,
    required int slideIndex,
  }) async {
    expect(sourcePath, this.sourcePath);
    expect(plan.sourceSha256, sha256.convert(original).toString());
    expect(slideIndex, 0);
    return [
      PptxTableStructureTable(
        shapeId: 12,
        name: '실습 표',
        rows: 3,
        columns: 1,
        rowInsertGaps: const [0, 2, 3],
        columnInsertGaps: const [0, 1],
        rowDelete: const [2],
        columnDelete: const [],
      ),
    ];
  }

  @override
  Future<PptxTableStructureOutput> edit({
    required String sourcePath,
    required PptxShapeTextPlan plan,
    required String outputPath,
    required int slideIndex,
    required PptxTableStructureTable table,
    required PptxTableStructureAction action,
    required int index,
  }) async {
    expect(sourcePath, this.sourcePath);
    expect(plan.sourceSha256, sha256.convert(original).toString());
    expect(File(outputPath).existsSync(), isFalse);
    this.outputPath = outputPath;
    edited = (
      slideIndex: slideIndex,
      shapeId: table.shapeId,
      action: action,
      index: index,
    );
    await File(outputPath).writeAsBytes(candidate);
    return (
      sourceSha256: plan.sourceSha256,
      outputSha256: sha256
          .convert(wrongCandidateHash ? const [0] : candidate)
          .toString(),
      slideCount: plan.slideCount,
      slideIndex: slideIndex,
      shapeId: table.shapeId,
      action: action,
      index: index,
      rows: table.rows + action.rowDelta,
      columns: table.columns + action.columnDelta,
    );
  }
}

class _FixturePptxTableMerge extends PptxTableMergeEngine {
  new(this.original, this.candidate, {required this.alreadyMerged});

  final Uint8List original, candidate;
  final bool alreadyMerged;
  (PptxTableMergeAction, PptxTableCellRange)? applied;
  static const range = (row: 0, column: 0, rowSpan: 2, columnSpan: 2);

  @override
  Future<PptxShapeTextPlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) async {
    expect(await File(sourcePath).readAsBytes(), original);
    expect(sourceSha256, sha256.convert(original).toString());
    return PptxShapeTextPlan(
      sourceSha256: sourceSha256,
      slides: const [PptxShapeTextSlide(index: 0, hidden: false)],
    );
  }

  @override
  Future<List<PptxTableMergeTable>> inspectSlide({
    required String sourcePath,
    required PptxShapeTextPlan plan,
    required int slideIndex,
  }) async {
    expect(slideIndex, 0);
    return [
      PptxTableMergeTable(
        shapeId: 12,
        name: '실습 표',
        rows: alreadyMerged ? 2 : 3,
        columns: alreadyMerged ? 2 : 3,
        mergedRanges: alreadyMerged ? [range] : const [],
      ),
    ];
  }

  @override
  Future<PptxTableMergeOutput> edit({
    required String sourcePath,
    required PptxShapeTextPlan plan,
    required String outputPath,
    required int slideIndex,
    required PptxTableMergeTable table,
    required PptxTableMergeAction action,
    required PptxTableCellRange range,
  }) async {
    expect(await File(sourcePath).readAsBytes(), original);
    expect(slideIndex, 0);
    expect(table.shapeId, 12);
    expect(range, _FixturePptxTableMerge.range);
    expect(table.allows(action, range), isTrue);
    applied = (action, range);
    await File(outputPath).writeAsBytes(candidate);
    return (
      sourceSha256: plan.sourceSha256,
      outputSha256: sha256.convert(candidate).toString(),
      slideCount: 1,
      slideIndex: slideIndex,
      shapeId: table.shapeId,
      action: action,
      range: range,
      rows: table.rows,
      columns: table.columns,
    );
  }
}

class _FixturePptxSpeakerNotes extends PptxSpeakerNotesEngine {
  new(this.original, this.candidate, this.notes);

  final Uint8List original, candidate;
  final PptxSpeakerNotes notes;
  String? sourcePath, outputPath;
  ({int slideIndex, String text})? edited;

  @override
  Future<PptxShapeTextPlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) async {
    this.sourcePath = sourcePath;
    expect(await File(sourcePath).readAsBytes(), original);
    expect(sourceSha256, sha256.convert(original).toString());
    return PptxShapeTextPlan(
      sourceSha256: sourceSha256,
      slides: const [
        PptxShapeTextSlide(index: 0, hidden: false, title: '발표 실습'),
      ],
    );
  }

  @override
  Future<PptxSpeakerNotes> inspectSlide({
    required String sourcePath,
    required PptxShapeTextPlan plan,
    required int slideIndex,
  }) async {
    expect(sourcePath, this.sourcePath);
    expect(plan.sourceSha256, sha256.convert(original).toString());
    expect(slideIndex, 0);
    return notes;
  }

  @override
  Future<PptxSpeakerNotesOutput> edit({
    required String sourcePath,
    required PptxShapeTextPlan plan,
    required String outputPath,
    required int slideIndex,
    required String text,
  }) async {
    expect(sourcePath, this.sourcePath);
    expect(plan.sourceSha256, sha256.convert(original).toString());
    expect(File(outputPath).existsSync(), isFalse);
    this.outputPath = outputPath;
    edited = (slideIndex: slideIndex, text: text);
    await File(outputPath).writeAsBytes(candidate);
    return (
      sourceSha256: plan.sourceSha256,
      outputSha256: sha256.convert(candidate).toString(),
      slideCount: plan.slideCount,
      slideIndex: slideIndex,
    );
  }
}

class _FixturePptxShapeText extends PptxShapeTextEngine {
  new(this.input, this.output, {required this.wrongShape});

  final Uint8List input, output;
  final bool wrongShape;
  String? sourcePath, outputPath;
  final loadedSlides = <int>[];
  List<PptxShapeTextChange>? appliedChanges;
  PptxShapeTextFormat? appliedFormat;

  @override
  Future<PptxShapeTextPlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) async {
    this.sourcePath = sourcePath;
    expect(await File(sourcePath).readAsBytes(), input);
    expect(sourceSha256, sha256.convert(input).toString());
    return PptxShapeTextPlan(
      sourceSha256: sourceSha256,
      slides: const [
        PptxShapeTextSlide(index: 0, hidden: false, title: '표지'),
        PptxShapeTextSlide(index: 1, hidden: true, title: '실습'),
      ],
    );
  }

  @override
  Future<List<PptxShapeTextShape>> inspectSlide({
    required String sourcePath,
    required PptxShapeTextPlan plan,
    required int slideIndex,
  }) async {
    expect(sourcePath, this.sourcePath);
    expect(plan.sourceSha256, sha256.convert(input).toString());
    loadedSlides.add(slideIndex);
    if (slideIndex != 1) return [];
    return [
      PptxShapeTextShape(
        shapeId: 21,
        name: '요점 도형',
        runs: const [
          PptxShapeTextRun(paragraphIndex: 0, runIndex: 0, text: '기존 🧑‍🔬 문구'),
          PptxShapeTextRun(paragraphIndex: 1, runIndex: 0, text: '기존 둘째 문구'),
        ],
      ),
    ];
  }

  @override
  Future<PptxShapeTextOutput> replace({
    required String sourcePath,
    required PptxShapeTextPlan plan,
    required String outputPath,
    required int slideIndex,
    required PptxShapeTextShape shape,
    required List<PptxShapeTextChange> changes,
  }) async {
    appliedChanges = List.of(changes);
    return _writeOutput(sourcePath, plan, outputPath, slideIndex, shape);
  }

  @override
  Future<PptxShapeTextOutput> format({
    required String sourcePath,
    required PptxShapeTextPlan plan,
    required String outputPath,
    required int slideIndex,
    required PptxShapeTextShape shape,
    required PptxShapeTextFormat format,
  }) async {
    appliedFormat = format;
    return _writeOutput(sourcePath, plan, outputPath, slideIndex, shape);
  }

  Future<PptxShapeTextOutput> _writeOutput(
    String sourcePath,
    PptxShapeTextPlan plan,
    String outputPath,
    int slideIndex,
    PptxShapeTextShape shape,
  ) async {
    expect(sourcePath, this.sourcePath);
    expect(File(outputPath).existsSync(), isFalse);
    expect(slideIndex, 1);
    expect(shape.shapeId, 21);
    this.outputPath = outputPath;
    await File(outputPath).writeAsBytes(output);
    return PptxShapeTextOutput(
      sourceSha256: plan.sourceSha256,
      outputSha256: sha256.convert(output).toString(),
      slideCount: plan.slideCount,
      slideIndex: slideIndex,
      shapeId: wrongShape ? 22 : shape.shapeId,
    );
  }
}

class _FixturePptxShapeOrder extends PptxShapeOrderEngine {
  new(this.input, this.output);

  final Uint8List input;
  final Uint8List output;
  (int, PptxShapeOrderDirection, int, int)? applied;

  @override
  Future<PptxShapeOrderPlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) async {
    expect(await File(sourcePath).readAsBytes(), input);
    expect(sourceSha256, sha256.convert(input).toString());
    return (
      sourceSha256: sourceSha256,
      slides: const [(index: 0, hidden: false, title: null)],
    );
  }

  @override
  Future<List<PptxShapeOrderTarget>> inspectSlide({
    required String sourcePath,
    required PptxShapeOrderPlan plan,
    required int slideIndex,
  }) async {
    expect(slideIndex, 0);
    expect(await File(sourcePath).readAsBytes(), input);
    return const [
      (shapeId: 2, name: '배경', kind: 'shape'),
      (shapeId: 3, name: '범례', kind: 'textBox'),
      (shapeId: 4, name: '자료', kind: 'picture'),
    ];
  }

  @override
  Future<PptxShapeOrderResult> apply({
    required String sourcePath,
    required PptxShapeOrderPlan plan,
    required String outputPath,
    required int slideIndex,
    required int shapeId,
    required PptxShapeOrderDirection direction,
    required int fromIndex,
    required int shapeCount,
  }) async {
    expect(slideIndex, 0);
    expect(shapeCount, 3);
    expect(await File(sourcePath).readAsBytes(), input);
    expect(File(outputPath).existsSync(), isFalse);
    final destination = direction.destination(fromIndex, shapeCount)!;
    applied = (shapeId, direction, fromIndex, destination);
    await File(outputPath).writeAsBytes(output);
    return (
      sourceSha256: plan.sourceSha256,
      outputSha256: sha256.convert(output).toString(),
      slideCount: 1,
      slideIndex: slideIndex,
      shapeId: shapeId,
      fromIndex: fromIndex,
      toIndex: destination,
    );
  }
}

class _FixturePptxShapeGeometry extends PptxShapeGeometryEngine {
  new(this.input, this.output, {required this.wrongReply});

  static const originalGeometry = PptxShapeGeometry(
    xEmu: 800000,
    yEmu: 2900000,
    widthEmu: 2650000,
    heightEmu: 1600000,
  );
  static const target = PptxShapeGeometryShape(
    shapeId: 100,
    name: 'Target photo',
    kind: 'picture',
    geometry: originalGeometry,
    canMove: true,
    canResize: true,
    aspectRatioLocked: false,
  );

  final Uint8List input, output;
  final bool wrongReply;
  String? sourcePath, outputPath;
  PptxShapeGeometry? applied;

  @override
  Future<PptxShapeGeometryPlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) async {
    this.sourcePath = sourcePath;
    expect(await File(sourcePath).readAsBytes(), input);
    expect(sourceSha256, sha256.convert(input).toString());
    return PptxShapeGeometryPlan(
      sourceSha256: sourceSha256,
      slides: const [PptxShapeGeometrySlide(index: 0, hidden: false)],
    );
  }

  @override
  Future<List<PptxShapeGeometryShape>> inspectSlide({
    required String sourcePath,
    required PptxShapeGeometryPlan plan,
    required int slideIndex,
  }) async {
    expect(sourcePath, this.sourcePath);
    expect(slideIndex, 0);
    return const [target];
  }

  @override
  Future<PptxShapeGeometryOutput> replace({
    required String sourcePath,
    required PptxShapeGeometryPlan plan,
    required String outputPath,
    required int slideIndex,
    required PptxShapeGeometryShape shape,
    required PptxShapeGeometry geometry,
  }) async {
    expect(sourcePath, this.sourcePath);
    expect(p.dirname(outputPath), p.dirname(sourcePath));
    expect(File(outputPath).existsSync(), isFalse);
    expect(slideIndex, 0);
    expect(shape.shapeId, target.shapeId);
    this.outputPath = outputPath;
    applied = geometry;
    await File(outputPath).writeAsBytes(output);
    return PptxShapeGeometryOutput(
      sourceSha256: plan.sourceSha256,
      outputSha256: sha256.convert(output).toString(),
      slideCount: plan.slideCount,
      slideIndex: slideIndex,
      shapeId: shape.shapeId,
      geometry: wrongReply ? originalGeometry : geometry,
    );
  }
}

class _FixturePptxShapeDelete extends PptxShapeDeleteEngine {
  new(this.input, this.output, {required this.wrongTarget});

  final Uint8List input, output;
  final bool wrongTarget;
  String? sourcePath, outputPath;
  var deleteCalls = 0;

  @override
  Future<PptxShapeDeletePlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) async {
    this.sourcePath = sourcePath;
    expect(await File(sourcePath).readAsBytes(), input);
    expect(sourceSha256, sha256.convert(input).toString());
    return PptxShapeDeletePlan(
      sourceSha256: sourceSha256,
      slides: const [(index: 0, hidden: false, title: 'Presentation title')],
    );
  }

  @override
  Future<List<PptxShapeDeleteTarget>> inspectSlide({
    required String sourcePath,
    required PptxShapeDeletePlan plan,
    required int slideIndex,
  }) async {
    expect(sourcePath, this.sourcePath);
    expect(slideIndex, 0);
    return const [(shapeId: 2, name: 'Title', kind: 'textBox')];
  }

  @override
  Future<PptxShapeDeleteOutput> delete({
    required String sourcePath,
    required PptxShapeDeletePlan plan,
    required String outputPath,
    required int slideIndex,
    required int shapeId,
  }) async {
    expect(sourcePath, this.sourcePath);
    expect(p.dirname(outputPath), p.dirname(sourcePath));
    expect(File(outputPath).existsSync(), isFalse);
    expect(slideIndex, 0);
    expect(shapeId, 2);
    deleteCalls++;
    this.outputPath = outputPath;
    await File(outputPath).writeAsBytes(output);
    return (
      sourceSha256: plan.sourceSha256,
      outputSha256: sha256.convert(output).toString(),
      slideCount: plan.slideCount,
      slideIndex: slideIndex,
      shapeId: wrongTarget ? 4 : shapeId,
    );
  }
}

class FixtureOfficePreview extends OfficePreviewEngine {
  new(this.run);
  final Future<OfficePreviewResult?> Function(String path, String id) run;
  @override
  Future<OfficePreviewResult?> preview({
    required String sourcePath,
    required String sessionId,
  }) => run(sourcePath, sessionId);
}

class _FixturePptxFindReplace extends PptxFindReplaceEngine {
  new(this.input, this.output, {this.wrongCount = false, this.releasePreview});

  final Uint8List input, output;
  final bool wrongCount;
  final Completer<void>? releasePreview;
  String? sourcePath, outputPath, replacement;

  @override
  Future<PptxFindReplacePreview> preview({
    required String sourcePath,
    required String sourceSha256,
    required String find,
  }) async {
    this.sourcePath = sourcePath;
    expect(await File(sourcePath).readAsBytes(), input);
    expect(sourceSha256, sha256.convert(input).toString());
    if (releasePreview case final release?) {
      await release.future;
      expect(await File(sourcePath).readAsBytes(), input);
    }
    final matches = find == 'First'
        ? const [(slideIndex: 0, snippet: 'First draft · First', count: 2)]
        : const <PptxFindMatch>[];
    return PptxFindReplacePreview(
      sourceSha256: sourceSha256,
      find: find,
      slideCount: 1,
      matchCount: matches.isEmpty ? 0 : 2,
      matches: matches,
    );
  }

  @override
  Future<PptxFindReplaceOutput> replaceAll({
    required String sourcePath,
    required PptxFindReplacePreview plan,
    required String outputPath,
    required String replacement,
  }) async {
    expect(sourcePath, this.sourcePath);
    expect(p.dirname(outputPath), p.dirname(sourcePath));
    expect(File(outputPath).existsSync(), isFalse);
    expect(plan.find, 'First');
    expect(plan.matchCount, 2);
    this.outputPath = outputPath;
    this.replacement = replacement;
    await File(outputPath).writeAsBytes(output, flush: true);
    return (
      sourceSha256: plan.sourceSha256,
      outputSha256: sha256.convert(output).toString(),
      slideCount: 1,
      matchCount: wrongCount ? 1 : 2,
    );
  }
}

class _FixtureDocxFindReplace extends DocxFindReplaceEngine {
  new(this.input, this.output, {this.wrongCount = false, this.releasePreview});

  final Uint8List input, output;
  final bool wrongCount;
  final Completer<void>? releasePreview;
  String? sourcePath, outputPath, replacement;

  @override
  Future<DocxFindReplacePreview> preview({
    required String sourcePath,
    required String sourceSha256,
    required String find,
  }) async {
    this.sourcePath = sourcePath;
    expect(await File(sourcePath).readAsBytes(), input);
    expect(sourceSha256, sha256.convert(input).toString());
    if (releasePreview != null) {
      await releasePreview!.future;
      expect(await File(sourcePath).readAsBytes(), input);
    }
    final matches = find == 'First'
        ? const [(paragraphIndex: 0, snippet: 'First draft · First', count: 2)]
        : const <DocxFindMatch>[];
    return DocxFindReplacePreview(
      sourceSha256: sourceSha256,
      find: find,
      matchCount: matches.isEmpty ? 0 : 2,
      matches: matches,
    );
  }

  @override
  Future<DocxFindReplaceOutput> replaceAll({
    required String sourcePath,
    required DocxFindReplacePreview plan,
    required String outputPath,
    required String replacement,
  }) async {
    expect(sourcePath, this.sourcePath);
    expect(p.dirname(outputPath), p.dirname(sourcePath));
    expect(File(outputPath).existsSync(), isFalse);
    expect(plan.find, 'First');
    expect(plan.matchCount, 2);
    this.outputPath = outputPath;
    this.replacement = replacement;
    await File(outputPath).writeAsBytes(output, flush: true);
    return (
      sourceSha256: plan.sourceSha256,
      outputSha256: sha256.convert(output).toString(),
      matchCount: wrongCount ? 1 : 2,
      paragraphCount: 1,
    );
  }
}

class _FixtureDocxBodyText extends DocxBodyTextEngine {
  new(this.input, this.output, {required this.wrongTarget});

  final Uint8List input, output;
  final bool wrongTarget;
  String? sourcePath, outputPath;
  String? replacement;

  @override
  Future<DocxBodyTextPlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) async {
    this.sourcePath = sourcePath;
    expect(await File(sourcePath).readAsBytes(), input);
    expect(sourceSha256, sha256.convert(input).toString());
    return DocxBodyTextPlan(
      sourceSha256: sourceSha256,
      paragraphs: [
        DocxBodyTextParagraph(
          paragraphIndex: 0,
          runs: const [DocxBodyTextRun(runIndex: 0, text: 'First draft')],
        ),
      ],
    );
  }

  @override
  Future<DocxBodyTextOutput> replace({
    required String sourcePath,
    required DocxBodyTextPlan plan,
    required String outputPath,
    required int paragraphIndex,
    required int runIndex,
    required String text,
  }) async {
    expect(sourcePath, this.sourcePath);
    expect(p.dirname(outputPath), p.dirname(sourcePath));
    expect(File(outputPath).existsSync(), isFalse);
    expect((paragraphIndex, runIndex), (0, 0));
    this.outputPath = outputPath;
    replacement = text;
    await File(outputPath).writeAsBytes(output, flush: true);
    return DocxBodyTextOutput(
      sourceSha256: plan.sourceSha256,
      outputSha256: sha256.convert(output).toString(),
      paragraphIndex: paragraphIndex,
      runIndex: wrongTarget ? runIndex + 1 : runIndex,
    );
  }
}

class _FixtureDocxCellText extends DocxBodyTextEngine {
  new(this.input, this.output, {required this.wrongAddress});

  static const address = (tableIndex: 0, rowIndex: 0, cellIndex: 1);
  final Uint8List input, output;
  final bool wrongAddress;
  String? sourcePath, outputPath, replacement;

  @override
  Future<DocxTableCellTextPlan> inspectCells({
    required String sourcePath,
    required String sourceSha256,
  }) async {
    this.sourcePath = sourcePath;
    expect(await File(sourcePath).readAsBytes(), input);
    expect(sourceSha256, sha256.convert(input).toString());
    return DocxTableCellTextPlan(
      sourceSha256: sourceSha256,
      cells: [
        DocxTableCellText(
          address: address,
          paragraphs: [
            DocxBodyTextParagraph(
              paragraphIndex: 0,
              runs: const [DocxBodyTextRun(runIndex: 0, text: '')],
            ),
          ],
        ),
      ],
    );
  }

  @override
  Future<DocxTableCellTextOutput> replaceCell({
    required String sourcePath,
    required DocxTableCellTextPlan plan,
    required String outputPath,
    required DocxTableCellAddress address,
    required int paragraphIndex,
    required int runIndex,
    required String text,
  }) async {
    expect(sourcePath, this.sourcePath);
    expect(p.dirname(outputPath), p.dirname(sourcePath));
    expect(File(outputPath).existsSync(), isFalse);
    expect(address, _FixtureDocxCellText.address);
    expect((paragraphIndex, runIndex), (0, 0));
    this.outputPath = outputPath;
    replacement = text;
    await File(outputPath).writeAsBytes(output, flush: true);
    return DocxTableCellTextOutput(
      sourceSha256: plan.sourceSha256,
      outputSha256: sha256.convert(output).toString(),
      address: wrongAddress
          ? (tableIndex: 0, rowIndex: 0, cellIndex: 0)
          : address,
      paragraphIndex: paragraphIndex,
      runIndex: runIndex,
    );
  }
}

class _FixtureDocxParagraphInsert extends DocxParagraphInsertEngine {
  new(this.input, this.output);

  final Uint8List input, output;
  String? sourcePath, outputPath, insertedText;
  int? anchor;
  DocxParagraphPosition? position;

  @override
  Future<DocxParagraphInsertPlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) async {
    this.sourcePath = sourcePath;
    expect(await File(sourcePath).readAsBytes(), input);
    expect(sourceSha256, sha256.convert(input).toString());
    return DocxParagraphInsertPlan(
      sourceSha256: sourceSha256,
      paragraphs: const [
        DocxParagraphAnchor(
          index: 0,
          text: 'Summary',
          canBefore: true,
          canAfter: false,
        ),
        DocxParagraphAnchor(
          index: 1,
          text: 'Results',
          canBefore: true,
          canAfter: true,
        ),
      ],
    );
  }

  @override
  Future<DocxParagraphInsertOutput> insert({
    required String sourcePath,
    required DocxParagraphInsertPlan plan,
    required String outputPath,
    required int anchorParagraphIndex,
    required DocxParagraphPosition position,
    required String text,
  }) async {
    this.outputPath = outputPath;
    anchor = anchorParagraphIndex;
    this.position = position;
    insertedText = text;
    expect(sourcePath, this.sourcePath);
    expect(p.dirname(outputPath), p.dirname(sourcePath));
    expect(File(outputPath).existsSync(), isFalse);
    await File(outputPath).writeAsBytes(output);
    return DocxParagraphInsertOutput(
      sourceSha256: plan.sourceSha256,
      outputSha256: sha256.convert(output).toString(),
      paragraphIndex:
          anchorParagraphIndex +
          (position == DocxParagraphPosition.after ? 1 : 0),
    );
  }
}

class _FixtureDocxPhotoInsert extends _FixtureDocxParagraphInsert {
  new(super.input, super.output, this.image);

  final WindowsOfficeImageAsset image;

  @override
  Future<DocxParagraphInsertOutput> insertPhoto({
    required String sourcePath,
    required DocxParagraphInsertPlan plan,
    required String outputPath,
    required int anchorParagraphIndex,
    required DocxParagraphPosition position,
    required String assetPath,
    required String assetSha256,
  }) async {
    this.outputPath = outputPath;
    anchor = anchorParagraphIndex;
    this.position = position;
    expect(sourcePath, this.sourcePath);
    expect(plan.sourceSha256, sha256.convert(input).toString());
    expect(p.dirname(outputPath), p.dirname(sourcePath));
    expect(p.dirname(assetPath), p.dirname(sourcePath));
    expect(File(outputPath).existsSync(), isFalse);
    expect(await File(assetPath).readAsBytes(), image.bytes);
    expect(assetSha256, image.sha256);
    await File(outputPath).writeAsBytes(output);
    return DocxParagraphInsertOutput(
      sourceSha256: plan.sourceSha256,
      outputSha256: sha256.convert(output).toString(),
      paragraphIndex: position.insertionIndex(anchorParagraphIndex),
    );
  }
}

class _FixtureDocxTableInsert extends DocxTableInsertEngine {
  new(this.input, this.output, {required this.wrongTablePosition});

  final Uint8List input, output;
  final bool wrongTablePosition;
  String? sourcePath, outputPath;
  int? anchor;
  List<List<String>>? insertedCells;

  @override
  Future<DocxTableInsertPlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) async {
    this.sourcePath = sourcePath;
    expect(await File(sourcePath).readAsBytes(), input);
    expect(sourceSha256, sha256.convert(input).toString());
    return DocxTableInsertPlan(
      sourceSha256: sourceSha256,
      paragraphs: const [
        DocxTableParagraph(index: 0, text: 'Summary'),
        DocxTableParagraph(index: 1, text: 'Results'),
      ],
    );
  }

  @override
  Future<DocxTableInsertOutput> insert({
    required String sourcePath,
    required DocxTableInsertPlan plan,
    required String outputPath,
    required int? afterParagraphIndex,
    required List<List<String>> cells,
  }) async {
    this.outputPath = outputPath;
    anchor = afterParagraphIndex;
    insertedCells = cells;
    expect(sourcePath, this.sourcePath);
    expect(p.dirname(sourcePath), p.dirname(outputPath));
    expect(plan.sourceSha256, sha256.convert(input).toString());
    expect(File(outputPath).existsSync(), isFalse);
    await File(outputPath).writeAsBytes(output);
    return DocxTableInsertOutput(
      sourceSha256: plan.sourceSha256,
      outputSha256: sha256.convert(output).toString(),
      afterParagraphIndex: wrongTablePosition ? null : afterParagraphIndex,
      rows: cells.length,
      columns: cells.first.length,
      tableIndex: 0,
    );
  }
}

class _FixtureDocxPhotoReplacement extends DocxPhotoReplacementEngine {
  new(this.input, this.output, this.originalPhoto);

  final Uint8List input, output, originalPhoto;
  String? sourcePath, outputPath;
  var replacements = 0, removals = 0, rotations = 0;

  @override
  Future<DocxPhotoPlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) async {
    this.sourcePath = sourcePath;
    expect(await File(sourcePath).readAsBytes(), input);
    expect(sourceSha256, sha256.convert(input).toString());
    return DocxPhotoPlan(
      sourceSha256: sourceSha256,
      photos: [
        for (var index = 0; index < 2; index++)
          DocxPhotoTarget(
            index: index,
            title: '공유 원본 ${index + 1}',
            mediaPart: 'word/media/shared.png',
            mediaSha256: sha256.convert(originalPhoto).toString(),
            format: 'png',
          ),
      ],
    );
  }

  @override
  Future<String> replace({
    required String sourcePath,
    required DocxPhotoPlan plan,
    required int photoIndex,
    required String outputPath,
    required String assetPath,
    required String assetSha256,
  }) async {
    replacements++;
    this.outputPath = outputPath;
    expect(sourcePath, this.sourcePath);
    expect(photoIndex, 1);
    expect(p.dirname(sourcePath), p.dirname(outputPath));
    expect(p.dirname(sourcePath), p.dirname(assetPath));
    expect(plan.sourceSha256, sha256.convert(input).toString());
    expect(
      sha256.convert(await File(assetPath).readAsBytes()).toString(),
      assetSha256,
    );
    expect(assetSha256, isNot(plan.photos[1].mediaSha256));
    expect(File(outputPath).existsSync(), isFalse);
    await File(outputPath).writeAsBytes(output);
    return sha256.convert(output).toString();
  }

  @override
  Future<String> remove({
    required String sourcePath,
    required DocxPhotoPlan plan,
    required int photoIndex,
    required String outputPath,
  }) async {
    removals++;
    this.outputPath = outputPath;
    expect(sourcePath, this.sourcePath);
    expect(photoIndex, 1);
    expect(p.dirname(sourcePath), p.dirname(outputPath));
    expect(plan.sourceSha256, sha256.convert(input).toString());
    expect(File(outputPath).existsSync(), isFalse);
    await File(outputPath).writeAsBytes(output);
    return sha256.convert(output).toString();
  }

  @override
  Future<String> rotate({
    required String sourcePath,
    required DocxPhotoPlan plan,
    required int photoIndex,
    required String outputPath,
  }) async {
    rotations++;
    this.outputPath = outputPath;
    expect(sourcePath, this.sourcePath);
    expect(photoIndex, 1);
    expect(p.dirname(sourcePath), p.dirname(outputPath));
    expect(plan.sourceSha256, sha256.convert(input).toString());
    expect(File(outputPath).existsSync(), isFalse);
    await File(outputPath).writeAsBytes(output);
    return sha256.convert(output).toString();
  }
}

class _FixtureDocxTableStructure extends DocxTableStructureEngine {
  new(this.original, this.candidate, {this.wrongSize = false});

  final Uint8List original, candidate;
  final bool wrongSize;
  String? sourcePath, outputPath;
  var edits = 0;

  @override
  Future<DocxTableStructurePlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) async {
    this.sourcePath = sourcePath;
    expect(await File(sourcePath).readAsBytes(), original);
    expect(sourceSha256, sha256.convert(original).toString());
    return DocxTableStructurePlan(
      sourceSha256: sourceSha256,
      tables: const [
        DocxTableStructureTable(
          tableIndex: 0,
          rowCount: 2,
          columnCount: 2,
          preview: 'Table preview',
        ),
      ],
    );
  }

  @override
  Future<DocxTableStructureOutput> edit({
    required String sourcePath,
    required DocxTableStructurePlan plan,
    required String outputPath,
    required int tableIndex,
    required DocxTableStructureAction action,
    required int index,
    int? anchorIndex,
  }) async {
    edits++;
    this.outputPath = outputPath;
    expect(sourcePath, this.sourcePath);
    expect(plan.sourceSha256, sha256.convert(original).toString());
    expect(
      (tableIndex, action, index, anchorIndex),
      (0, DocxTableStructureAction.insertRow, 0, 0),
    );
    await File(outputPath).writeAsBytes(candidate, flush: true);
    return DocxTableStructureOutput(
      sourceSha256: plan.sourceSha256,
      outputSha256: sha256.convert(candidate).toString(),
      tableIndex: tableIndex,
      rowCount: wrongSize ? 2 : 3,
      columnCount: 2,
    );
  }
}

class TrackingWindowsPreviewEngine extends WindowsOfficeEngine {
  new({required WindowsOfficeRunner runner}) : super(runner: runner);
  WindowsOfficePreview? lastPreview;

  @override
  Future<WindowsOfficePreview> preview(
    String sourcePath, {
    required List<WindowsOfficeOperation> operations,
    required String sessionId,
    String? expectedSourceSha256,
    Map<String, WindowsOfficeImageAsset> imageAssets = const {},
  }) async {
    final lease = await super.preview(
      sourcePath,
      operations: operations,
      sessionId: sessionId,
      expectedSourceSha256: expectedSourceSha256,
      imageAssets: imageAssets,
    );
    lastPreview = lease;
    return lease;
  }
}

Map<String, Object?> wordPreviewSnapshot(
  String hash, {
  bool edited = false,
  bool second = false,
}) => {
  'kind': 'word',
  'sourceSha256': hash,
  'bodyOwnerId': 'body',
  'blocks': [
    {'kind': 'paragraph', 'id': 'p0'},
  ],
  'paragraphs': [
    {'id': 'p0', 'ownerId': 'body', 'text': 'WORD BODY'},
  ],
  'tables': [],
  'wordOwners': [
    {
      'id': 'header',
      'kind': 'header',
      'references': [
        {'pageStyleId': 'page0', 'variant': 'default'},
      ],
      'blocks': [
        {'kind': 'paragraph', 'id': 'hp0'},
      ],
      'paragraphs': [
        {'id': 'hp0', 'ownerId': 'header', 'text': 'WORD HEADER'},
      ],
      'tableIds': [],
    },
  ],
  'pageStyles': [
    {
      'id': 'page0',
      'name': 'ImportedPage',
      'displayName': '사용 중 페이지',
      'inUse': true,
      'canEditGeometry': true,
      'width': 210,
      'height': 297,
      'landscape': false,
      'leftMargin': edited ? 25.4 : 20,
      'rightMargin': 20,
      'topMargin': second ? 21 : 20,
      'bottomMargin': 20,
      'layoutSha256':
          (second
              ? 'd'
              : edited
              ? 'c'
              : 'b') *
          64,
      'regions': {
        'header': {'default': 'header'},
        'footer': {'default': null},
      },
    },
  ],
  'slides': [],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();
  late Directory temp;
  late NoteRepository repository;
  late OfficeDocumentStore store;
  late VaultNote note;
  late Uint8List importedOriginal;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('office-workspace-');
    await FileManager.init(
      documentsDirectory: '${temp.path}/documents',
      shouldWatchRootDirectory: false,
    );
    repository = await NoteRepository.open(
      Directory('${temp.path}/vault'),
      createFormatVersion: 2,
    );
    store = OfficeDocumentStore(repository);
    importedOriginal = annotationOfficeFile('original');
    note = await store.importDocument(
      title: 'Lecture',
      fileName: 'lecture.docx',
      bytes: importedOriginal,
    );
  });
  tearDown(() async {
    await repository.close();
    await temp.delete(recursive: true);
  });

  Future<void> receiveIncompleteSource({VaultNote? related}) async {
    await repository.importRevision(
      RevisionRecord(
        vaultId: repository.vaultId,
        revisionId: newId(),
        entityId: related?.sourceEntityId ?? newId(),
        kind: EntityKind.attachment,
        ownerNoteId: related?.id ?? newId(),
        deviceId: newId(),
        parentRevisionIds: [newId()],
        blobs: {},
        formatVersion: 2,
      ),
      blobsByHash: {},
    );
    expect(repository.pendingRevisionCount, 1);
  }

  Future<void> drain(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 12));
      });
      await tester.pump(const Duration(milliseconds: 12));
    }
  }

  Future<T> withPumping<T>(
    WidgetTester tester,
    Future<T> Function() operation,
  ) async {
    var done = false;
    T? result;
    Object? failure;
    StackTrace? trace;
    await tester.runAsync(() async {
      operation()
          .timeout(const Duration(seconds: 15))
          .then(
            (value) {
              result = value;
              done = true;
            },
            onError: (Object error, StackTrace stack) {
              failure = error;
              trace = stack;
              done = true;
            },
          );
    });
    for (var i = 0; i < 100 && !done; i++) {
      await drain(tester);
    }
    expect(
      done,
      isTrue,
      reason: 'Office I/O must finish while the UI is pumped',
    );
    if (failure != null) Error.throwWithStackTrace(failure!, trace!);
    return result as T;
  }

  Future<GlobalKey<OfficeWorkspaceState>> mount(
    WidgetTester tester,
    FixtureOfficeEngine? engine, {
    WindowsOfficeEngine? windowsEngine,
    HwpStructuredOfficeEngine? hwpEngine,
    OfficePreviewEngine? previewEngine,
    DocxBodyTextEngine? docxBodyText,
    DocxFindReplaceEngine? docxFindReplace,
    DocxParagraphInsertEngine? docxParagraphInsert,
    DocxPhotoReplacementEngine? docxPhotoReplacement,
    DocxTableInsertEngine? docxTableInsert,
    DocxTableStructureEngine? docxTableStructure,
    PptxFindReplaceEngine? pptxFindReplace,
    PptxSlideCloneEngine? pptxSlideClone,
    PptxSlideDeleteEngine? pptxSlideDelete,
    PptxSlideInsertEngine? pptxSlideInsert,
    PptxSlideLayoutEngine? pptxSlideLayout,
    PptxSlideReorderEngine? pptxSlideReorder,
    PptxPhotoAdditionEngine? pptxPhotoAddition,
    PptxTextBoxEngine? pptxTextBox,
    PptxTableAddEngine? pptxTableAdd,
    PptxTableCellTextEngine? pptxTableCellText,
    PptxTableStructureEngine? pptxTableStructure,
    PptxTableMergeEngine? pptxTableMerge,
    PptxSpeakerNotesEngine? pptxSpeakerNotes,
    PptxShapeTextEngine? pptxShapeText,
    PptxShapeGeometryEngine? pptxShapeGeometry,
    PptxShapeOrderEngine? pptxShapeOrder,
    PptxShapeDeleteEngine? pptxShapeDelete,
    ValueChanged<bool>? dirty,
    ValueChanged<bool>? busy,
    Future<void> Function(VaultNote)? onConvertedCopy,
  }) async {
    final key = GlobalKey<OfficeWorkspaceState>();
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: OfficeWorkspace(
              key: key,
              repository: repository,
              note: note,
              engine: engine,
              windowsEngine: windowsEngine,
              hwpEngine: hwpEngine,
              previewEngine: previewEngine,
              docxBodyText: docxBodyText,
              docxFindReplace: docxFindReplace,
              docxParagraphInsert: docxParagraphInsert,
              docxPhotoReplacement: docxPhotoReplacement,
              docxTableInsert: docxTableInsert,
              docxTableStructure: docxTableStructure,
              pptxFindReplace: pptxFindReplace,
              pptxSlideClone: pptxSlideClone,
              pptxSlideDelete: pptxSlideDelete,
              pptxSlideInsert: pptxSlideInsert,
              pptxSlideLayout: pptxSlideLayout,
              pptxSlideReorder: pptxSlideReorder,
              pptxPhotoAddition: pptxPhotoAddition,
              pptxTextBox: pptxTextBox,
              pptxTableAdd: pptxTableAdd,
              pptxTableCellText: pptxTableCellText,
              pptxTableStructure: pptxTableStructure,
              pptxTableMerge: pptxTableMerge,
              pptxSpeakerNotes: pptxSpeakerNotes,
              pptxShapeText: pptxShapeText,
              pptxShapeGeometry: pptxShapeGeometry,
              pptxShapeOrder: pptxShapeOrder,
              pptxShapeDelete: pptxShapeDelete,
              onDirtyChanged: dirty,
              onBusyChanged: busy,
              onConvertedCopy: onConvertedCopy,
              onBack: () {},
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 80; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 15));
      });
      await tester.pump(const Duration(milliseconds: 15));
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty &&
          find
              .byKey(const ValueKey('office-edition-selector'))
              .evaluate()
              .isNotEmpty)
        break;
    }
    final advanced = find.byKey(const ValueKey('office-advanced-tools'));
    if (advanced.evaluate().isNotEmpty) {
      await tester.ensureVisible(advanced);
      await tester.tap(advanced);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.ensureVisible(
        find.byKey(const ValueKey('office-edit-original')),
      );
    }
    addTearDown(() async {
      engine?.cleanup?.call();
      final state = key.currentState;
      await tester.pumpWidget(const SizedBox());
      var settled = state == null;
      await tester.runAsync(() async {
        state?.save().then(
          (_) {
            settled = true;
          },
          onError: (Object _, StackTrace _) {
            settled = true;
          },
        );
      });
      for (var i = 0; i < 100 && !settled; i++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 15));
        });
        await tester.pump(const Duration(milliseconds: 15));
      }
      expect(
        settled,
        isTrue,
        reason: 'Disposed Office workspace must drain pending source I/O',
      );
      var closed = false;
      await tester.runAsync(() async {
        repository.close().then(
          (_) {
            closed = true;
          },
          onError: (Object _, StackTrace _) {
            closed = true;
          },
        );
      });
      for (var i = 0; i < 100 && !closed; i++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        });
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(
        closed,
        isTrue,
        reason: 'Repository close must also drain its captured zone',
      );
    });
    return key;
  }

  Future<AndroidOfficeEditResult> savedResult(
    String input,
    String id, {
    bool badHash = false,
  }) async {
    expect(await File(input).readAsBytes(), importedOriginal);
    final output = Directory('${temp.path}/native/$id');
    await output.create(recursive: true);
    final source = File('${output.path}/edited.docx');
    final pdf = File('${output.path}/preview.pdf');
    final edited = annotationOfficeFile('edited');
    final preview = annotationPdf('edited');
    await source.writeAsBytes(edited);
    await pdf.writeAsBytes(preview);
    return AndroidOfficeEditResult(
      status: AndroidOfficeEditStatus.saved,
      engineVersion: 'fixture-engine',
      sessionId: id,
      sourcePath: source.path,
      pdfPath: pdf.path,
      sourceSha256: badHash ? '0' * 64 : sha256.convert(edited).toString(),
      pdfSha256: sha256.convert(preview).toString(),
      pdfPageCount: 1,
    );
  }

  testWidgets(
    'opening the same Office PDF on two devices saves ink only after an edit',
    (tester) async {
      final (edition, peer) = await withPumping(tester, () async {
        final pdf = pw.Document()
          ..addPage(pw.Page(build: (_) => pw.Container()))
          ..addPage(pw.Page(build: (_) => pw.Container()));
        final edition = await store.commitEdited(
          await store.beginEdit(note),
          originalBytes: importedOriginal,
          pdfBytes: await pdf.save(),
          engineVersion: 'first-ink-fixture',
          pageCount: 2,
        );
        final peer = await NoteRepository.open(
          Directory('${temp.path}/first-ink-peer'),
          vaultId: repository.vaultId,
          createFormatVersion: 2,
        );
        try {
          for (final record in await repository.revisions()) {
            await peer.importRevision(
              record,
              blobsByHash: {
                for (final ref in record.blobs.values)
                  ref.hash: await repository.readBlob(ref.hash),
              },
            );
          }
        } catch (_) {
          await peer.close();
          rethrow;
        }
        return (edition, peer);
      });
      final localKey = GlobalKey<OfficeWorkspaceState>();
      final peerKey = GlobalKey<OfficeWorkspaceState>();
      final engine = FixtureOfficeEngine();
      final bindingId = edition.bindingId!;

      Finder under(GlobalKey<OfficeWorkspaceState> key, Finder matching) =>
          find.descendant(of: find.byKey(key), matching: matching);

      Future<EditorState> openPdf(GlobalKey<OfficeWorkspaceState> key) async {
        final open = under(
          key,
          find.byKey(const ValueKey('office-preview-pdf')),
        );
        final editor = under(key, find.byType(Editor));
        final busy = under(key, find.byType(LinearProgressIndicator));
        for (var i = 0; i < 80 && open.evaluate().isEmpty; i++) {
          await drain(tester);
        }
        await tester.runAsync(() async {
          tester.widget<FilledButton>(open).onPressed!();
        });
        for (
          var i = 0;
          i < 80 && (editor.evaluate().isEmpty || busy.evaluate().isNotEmpty);
          i++
        ) {
          await drain(tester);
        }
        expect(busy, findsNothing);
        return tester.state<EditorState>(editor);
      }

      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1800, 1000);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      try {
        await tester.pumpWidget(
          TranslationProvider(
            child: MaterialApp(
              home: Scaffold(
                body: Row(
                  children: [
                    for (final (key, repo) in [
                      (localKey, repository),
                      (peerKey, peer),
                    ])
                      Expanded(
                        child: OfficeWorkspace(
                          key: key,
                          repository: repo,
                          note: note,
                          engine: engine,
                          showBackButton: key == peerKey,
                          onBack: () {},
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
        final localEditor = await openPdf(localKey);
        final cleanPeer = await openPdf(peerKey);
        expect(under(localKey, find.byType(SaveIndicator)), findsNothing);
        expect(under(peerKey, find.byType(SaveIndicator)), findsOneWidget);
        expect(under(localKey, find.byTooltip(t.editor.pages)), findsOneWidget);
        expect(under(peerKey, find.byTooltip(t.editor.pages)), findsOneWidget);
        await withPumping(tester, localKey.currentState!.save);
        await withPumping(tester, peerKey.currentState!.save);

        for (final repo in [repository, peer]) {
          expect(
            await withPumping(tester, () => repo.heads(bindingId)),
            isEmpty,
            reason: 'Opening and saving an unedited PDF is only viewing',
          );
        }
        expect(localEditor.history.canUndo, isFalse);
        expect(cleanPeer.history.canUndo, isFalse);
        final peerPage = cleanPeer.coreInfo.pages[1];
        expect(peerPage.pageId, localEditor.coreInfo.pages[1].pageId);
        expect(
          cleanPeer.revealPage(
            peerPage.pageId,
            background: peerPage.backgroundImage!,
          ),
          isTrue,
        );
        await tester.pump();
        expect(cleanPeer.currentPageIndex, 1);

        const firstEdit = 'First annotation on page two';
        localEditor.insertPageAfter(0);
        final editedPage = localEditor.coreInfo.pages[2];
        expect(editedPage.pageId, peerPage.pageId);
        final text = editedPage.quill.controller.document;
        text.insert(0, firstEdit);
        await drain(tester);
        localEditor.undo();
        expect(text.toPlainText(), isNot(contains(firstEdit)));
        localEditor.redo();
        expect(text.toPlainText(), contains(firstEdit));
        await drain(tester);
        await withPumping(tester, localKey.currentState!.save);
        final ink = await withPumping(tester, () async {
          final ink = (await repository.heads(bindingId)).single;
          expect(ink.parentRevisionIds, isEmpty);
          expect(ink.deviceId, repository.deviceId);
          await peer.importRevision(
            ink,
            blobsByHash: {
              for (final ref in ink.blobs.values)
                ref.hash: await repository.readBlob(ref.hash),
            },
          );
          return ink;
        });

        final editor = under(peerKey, find.byType(Editor));
        final busy = under(peerKey, find.byType(LinearProgressIndicator));
        for (var i = 0; i < 80; i++) {
          final state = tester.state<EditorState>(editor);
          if (!identical(state, cleanPeer) && busy.evaluate().isEmpty) {
            break;
          }
          await drain(tester);
        }
        final receiving = tester.state<EditorState>(editor);
        expect(receiving, isNot(same(cleanPeer)));
        expect(receiving.currentPageIndex, 2);
        final visiblePage =
            receiving.coreInfo.pages[receiving.currentPageIndex];
        expect(visiblePage.pageId, peerPage.pageId);
        expect((visiblePage.backgroundImage as PdfEditorImage).pdfPage, 1);
        expect(
          visiblePage.quill.controller.document.toPlainText(),
          contains(firstEdit),
        );
        expect(
          (await withPumping(
            tester,
            () => peer.heads(bindingId),
          )).map((head) => head.revisionId),
          [ink.revisionId],
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        // CanvasImage releases cached PDF images after the editor unmounts.
        await tester.pump(const Duration(seconds: 6));
        await drain(tester);
        await withPumping(tester, peer.close);
        await withPumping(tester, repository.close);
      }
    },
  );

  testWidgets(
    'two devices first open the same Office original without branching it',
    (tester) async {
      final source = await withPumping(tester, () => store.readLatest(note));
      expect(source.pdfBytes, isNull);
      final pdf = pw.Document()..addPage(pw.Page(build: (_) => pw.Container()));
      final pdfBytes = await pdf.save();
      final pdfHash = sha256.convert(pdfBytes).toString();

      Future<void> exchange(NoteRepository from, NoteRepository to) async {
        for (final record in await from.revisions()) {
          await to.importRevision(
            record,
            blobsByHash: {
              for (final ref in record.blobs.values)
                ref.hash: await from.readBlob(ref.hash),
            },
          );
        }
      }

      final peer = await withPumping(tester, () async {
        final peer = await NoteRepository.open(
          Directory('${temp.path}/first-preview-peer'),
          vaultId: repository.vaultId,
          createFormatVersion: 2,
        );
        try {
          await exchange(repository, peer);
        } catch (_) {
          await peer.close();
          rethrow;
        }
        return peer;
      });
      final localKey = GlobalKey<OfficeWorkspaceState>();
      final peerKey = GlobalKey<OfficeWorkspaceState>();
      final engine = FixtureOfficeEngine();
      var conversions = 0;
      final preview = FixtureOfficePreview((path, id) async {
        final producer = ++conversions;
        expect(await File(path).readAsBytes(), importedOriginal);
        final output = await File('${temp.path}/$id.pdf')
            .writeAsBytes(pdfBytes);
        return OfficePreviewResult(
          pdfPath: output.path,
          pdfSha256: pdfHash,
          pageCount: 1,
          sourceSha256: source.originalSha256,
          engineVersion: 'fixture-renderer-$producer',
        );
      });

      Finder under(GlobalKey<OfficeWorkspaceState> key, Finder matching) =>
          find.descendant(of: find.byKey(key), matching: matching);

      Future<EditorState> openPdf(GlobalKey<OfficeWorkspaceState> key) async {
        final open = under(
          key,
          find.byKey(const ValueKey('office-preview-pdf')),
        );
        final editor = under(key, find.byType(Editor));
        final busy = under(key, find.byType(LinearProgressIndicator));
        for (var i = 0; i < 80 && open.evaluate().isEmpty; i++) {
          await drain(tester);
        }
        await tester.runAsync(() async {
          tester.widget<FilledButton>(open).onPressed!();
        });
        for (
          var i = 0;
          i < 80 && (editor.evaluate().isEmpty || busy.evaluate().isNotEmpty);
          i++
        ) {
          await drain(tester);
        }
        expect(busy, findsNothing);
        return tester.state<EditorState>(editor);
      }

      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1800, 1000);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      try {
        expect(peer.deviceId, isNot(repository.deviceId));
        await tester.pumpWidget(
          TranslationProvider(
            child: MaterialApp(
              home: Scaffold(
                body: Row(
                  children: [
                    for (final (key, repo) in [
                      (localKey, repository),
                      (peerKey, peer),
                    ])
                      Expanded(
                        child: OfficeWorkspace(
                          key: key,
                          repository: repo,
                          note: note,
                          engine: engine,
                          previewEngine: preview,
                          onBack: () {},
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
        final localEditor = await openPdf(localKey);
        final peerEditor = await openPdf(peerKey);
        expect(conversions, 2, reason: 'Each device must convert before sync');

        await withPumping(tester, () async {
          await exchange(repository, peer);
          await exchange(peer, repository);
          final variants = <RevisionRecord>[];
          for (final repo in [repository, peer]) {
            final heads = await repo.heads(note.sourceEntityId!);
            expect(
              heads.map((head) => head.revisionId),
              [source.revision.revisionId],
              reason:
                  'PDF conversion must leave the original source head intact',
            );
            final derived = (await repo.revisions())
                .where(
                  (record) =>
                      record.kind == EntityKind.attachment &&
                      record.ownerNoteId == note.id &&
                      record.entityId != note.sourceEntityId,
                )
                .single;
            expect(derived.parentRevisionIds, isEmpty);
            expect(
              derived.blobs.values.map((blob) => blob.hash),
              contains(pdfHash),
            );
            variants.add(derived);
          }
          expect(variants.first.revisionId, variants.last.revisionId);
          expect(variants.first.entityId, variants.last.entityId);
        });

        expect(
          localEditor.coreInfo.pages.first.pageId,
          peerEditor.coreInfo.pages.first.pageId,
        );
        await withPumping(tester, localKey.currentState!.save);
        await withPumping(tester, peerKey.currentState!.save);
        final localView = await withPumping(
          tester,
          () => OfficeViewStore(repository, note.id).load(),
        );
        final peerView = await withPumping(
          tester,
          () => OfficeViewStore(peer, note.id).load(),
        );
        final binding = localView!.bindingId!;
        expect(localView.sourceRevisionId, source.revision.revisionId);
        expect(peerView!.bindingId, binding);
        expect(
          await withPumping(tester, () => repository.heads(binding)),
          isEmpty,
        );
        expect(await withPumping(tester, () => peer.heads(binding)), isEmpty);

        localEditor.drawTestStroke();
        await withPumping(tester, localKey.currentState!.save);
        await withPumping(tester, () async {
          final ink = (await repository.heads(binding)).single;
          expect(ink.kind, EntityKind.ink);
          expect(ink.parentRevisionIds, isEmpty);
          expect(ink.deviceId, repository.deviceId);
          await exchange(repository, peer);
          final received = (await peer.heads(binding)).single;
          expect(received.revisionId, ink.revisionId);
          expect(received.deviceId, repository.deviceId);
        });
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 6));
        await drain(tester);
        await withPumping(tester, peer.close);
        await withPumping(tester, repository.close);
      }
    },
  );

  testWidgets(
    'an untouched imported Office document can enter PDF annotation and preserve its exact original',
    (tester) async {
      final first = (await tester.runAsync(() => store.readLatest(note)))!;
      var previews = 0;
      late Uint8List previewBytes;
      final busy = <bool>[];
      final preview = FixtureOfficePreview((path, id) async {
        previews++;
        expect(await File(path).readAsBytes(), importedOriginal);
        final document = pw.Document()
          ..addPage(pw.Page(build: (_) => pw.Container()));
        previewBytes = await document.save();
        final output = await File('${temp.path}/unchanged-preview.pdf')
            .writeAsBytes(previewBytes);
        return OfficePreviewResult(
          pdfPath: output.path,
          pdfSha256: sha256.convert(previewBytes).toString(),
          pageCount: 1,
          sourceSha256: sha256.convert(importedOriginal).toString(),
          engineVersion: 'preview-fixture',
        );
      });
      final key = await mount(
        tester,
        FixtureOfficeEngine(),
        previewEngine: preview,
        busy: busy.add,
      );
      await tester.runAsync(() async {
        final button = tester.widget<FilledButton>(
          find.byKey(const ValueKey('office-preview-pdf')),
        );
        expect(button.onPressed, isNotNull);
        button.onPressed!();
      });
      for (
        var i = 0;
        i < 80 &&
            (busy.isEmpty ||
                busy.last ||
                find.byType(Editor).evaluate().isEmpty);
        i++
      ) {
        await drain(tester);
      }
      expect(find.byType(Editor), findsOneWidget);
      expect(busy.last, isFalse);
      final editor = tester.state<EditorState>(find.byType(Editor));
      editor.drawTestStroke();
      var saved = false;
      Object? saveError;
      await tester.runAsync(() async {
        key.currentState!.save().then(
          (_) => saved = true,
          onError: (Object error) {
            saveError = error;
            saved = true;
          },
        );
      });
      for (var i = 0; i < 80 && !saved; i++) {
        await drain(tester);
      }
      expect(
        saved,
        isTrue,
        reason: 'PDF ink save must finish while UI/asset tasks are pumped',
      );
      expect(saveError, isNull);
      var reloaded = false;
      Object? reloadError;
      await tester.runAsync(() async {
        () async {
          final current = await store.readLatest(note);
          expect(current.revision.revisionId, first.revision.revisionId);
          expect(current.originalBytes, importedOriginal);
          expect(current.pdfBytes, isNull);
          final variant = (await store.readPdfVariants(note, current)).single;
          expect(variant.sourceRevisionId, first.revision.revisionId);
          expect(
            await store.readPdfVariantBytes(note, current, variant),
            previewBytes,
          );
          final ink = (await repository.heads(variant.bindingId)).single;
          final restored = await SaberInkAdapter.load(repository, ink);
          try {
            expect(restored.pages.first.strokes, isNotEmpty);
          } finally {
            restored.dispose();
          }
        }().then(
          (_) => reloaded = true,
          onError: (Object error) {
            reloadError = error;
            reloaded = true;
          },
        );
      });
      for (var i = 0; i < 80 && !reloaded; i++) {
        await drain(tester);
      }
      expect(reloaded, isTrue, reason: 'PDF ink snapshot reload must finish');
      expect(reloadError, isNull);
      expect(previews, 1);
      await tester.pumpWidget(const SizedBox());
      // CanvasImage intentionally releases cached PDF images five seconds
      // after unmount. Drain that lifecycle before Flutter checks timers.
      await tester.pump(const Duration(seconds: 6));
      await drain(tester);
    },
  );

  testWidgets(
    'public save awaits an unfinished read-only preview and cancellation creates no PDF variant',
    (tester) async {
      final entered = (await tester.runAsync(() async => Completer<void>()))!;
      final release = (await tester.runAsync(
        () async => Completer<OfficePreviewResult?>(),
      ))!;
      final preview = FixtureOfficePreview((_, _) async {
        entered.complete();
        return release.future;
      });
      final key = await mount(
        tester,
        FixtureOfficeEngine(),
        previewEngine: preview,
      );
      Future<void>? saving;
      var settled = false;
      try {
        await tester.runAsync(() async {
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('office-preview-pdf')),
              )
              .onPressed!();
        });
        for (var i = 0; i < 80 && !entered.isCompleted; i++) {
          await drain(tester);
        }
        expect(
          entered.isCompleted,
          isTrue,
          reason: 'Read-only preview must be reached before parent save',
        );
        final preparing = find.byKey(const ValueKey('office-pdf-preparing'));
        expect(preparing, findsOneWidget);
        await tester.runAsync(() async {
          saving = key.currentState!.save().then((_) => settled = true);
        });
        await drain(tester);
        expect(settled, isFalse);
        await tester.runAsync(() async {
          release.complete(null);
        });
        for (var i = 0; i < 80 && !settled; i++) {
          await drain(tester);
        }
        expect(settled, isTrue);
        await tester.runAsync(() => saving!);
        expect(find.byType(Editor), findsNothing);
        expect(preparing, findsNothing);
        final editions = await withPumping(
          tester,
          () => store.readEditions(note),
        );
        expect(editions, hasLength(1));
        expect(
          await withPumping(
            tester,
            () => store.readPdfVariants(note, editions.single),
          ),
          isEmpty,
        );
      } finally {
        if (!release.isCompleted)
          await tester.runAsync(() async => release.complete(null));
      }
    },
  );

  testWidgets('failed Office conversion clears progress and allows retry', (
    tester,
  ) async {
    var attempts = 0;
    final preview = FixtureOfficePreview((_, _) async {
      attempts++;
      if (attempts == 1) throw StateError('PDF conversion failed');
      return null;
    });
    await mount(tester, FixtureOfficeEngine(), previewEngine: preview);
    final action = find.byKey(const ValueKey('office-preview-pdf'));
    final preparing = find.byKey(const ValueKey('office-pdf-preparing'));
    final error = find.textContaining('PDF conversion failed');
    await tester.runAsync(() => tester.tap(action));
    for (var i = 0; i < 80 && error.evaluate().isEmpty; i++) {
      await drain(tester);
    }
    expect(error, findsOneWidget);
    expect(preparing, findsNothing);
    expect(find.textContaining('PDF 필기용 문서를 준비'), findsNothing);
    expect(tester.widget<FilledButton>(action).onPressed, isNotNull);
    await tester.runAsync(() => tester.tap(action));
    for (
      var i = 0;
      i < 80 && (attempts < 2 || preparing.evaluate().isNotEmpty);
      i++
    ) {
      await drain(tester);
    }
    expect(attempts, 2);
    expect(error, findsNothing);
    expect(preparing, findsNothing);
    expect(find.byType(Editor), findsNothing);
  });

  for (final kind in [
    OfficeTemplateKind.presentation,
    OfficeTemplateKind.document,
  ]) {
    final word = kind == OfficeTemplateKind.document;
    final extension = word ? 'docx' : 'pptx';
    final label = word ? 'Word' : 'PPT';
    for (final scenario in [0, 1, 2, 3]) {
      final concurrent = scenario == 1;
      final recoverAfterFailure = scenario == 2;
      final changedPreview = scenario == 3;
      testWidgets(
        'Windows $label preview stays private and cached save preserves ${changedPreview
            ? 'a changed operation signature'
            : recoverAfterFailure
            ? 'failed-save preview refresh'
            : concurrent
            ? 'concurrent branches'
            : 'the original revision'}',
        (tester) async {
          importedOriginal = OfficeTemplates.create(
            kind,
            title: 'Preview source',
          ).bytes;
          note = (await tester.runAsync(
            () => store.importDocument(
              title: 'Preview',
              fileName: 'preview.$extension',
              bytes: importedOriginal,
            ),
          ))!;
          final first = (await tester.runAsync(() => store.readLatest(note)))!;
          final sourceHash = sha256.convert(importedOriginal).toString();
          final editedBytes = OfficeTemplates.create(
            kind,
            title: 'Preview edited',
          ).bytes;
          final editedHash = sha256.convert(editedBytes).toString();
          final previewBytes = annotationPdf('private draft');
          var operations = [
            if (word)
              WindowsOfficeOperation.pageGeometry(
                id: 'page0',
                expectedLayoutSha256: 'b' * 64,
                leftMargin: 25.4,
              )
            else
              WindowsOfficeOperation.slideDisplay(id: 's0', visible: false),
          ];
          var applied = 0;
          Map<String, Object?> snapshot(String hash, {bool visible = true}) =>
              word
              ? wordPreviewSnapshot(
                  hash,
                  edited: !visible,
                  second: !visible && operations.length > 1,
                )
              : {
                  'kind': 'presentation',
                  'sourceSha256': hash,
                  'paragraphs': [],
                  'tables': [],
                  'masters': [
                    {
                      'id': 'm0',
                      'name': 'Common',
                      'width': 280,
                      'height': 157.5,
                      'shapes': [],
                    },
                  ],
                  'layoutOptions': [
                    {'code': 20, 'label': 'Blank'},
                  ],
                  'slides': [
                    {
                      'id': 's0',
                      'width': 280,
                      'height': 157.5,
                      'masterId': 'm0',
                      'layoutCode': 20,
                      'designSha256': 'b' * 64,
                      'visible': visible,
                      'showMasterObjects': true,
                      'shapes': [],
                    },
                  ],
                };
          final engine = WindowsOfficeEngine(
            runner: (request) async {
              if (request['mode'] == 'inspect') {
                expect(
                  await File(request['sourcePath'] as String).readAsBytes(),
                  importedOriginal,
                );
                final pdf = await File('${temp.path}/$label-initial.pdf')
                    .writeAsBytes(annotationPdf('initial'));
                return {
                  'snapshot': {
                    ...snapshot(sourceHash),
                    'previewPdfPath': pdf.path,
                    'previewPageCount': 1,
                  },
                };
              }
              applied++;
              final live = request['includeDraftSnapshot'] == true;
              expect(live, !recoverAfterFailure || applied != 2);
              expect(request['expectedSourceSha256'], sourceHash);
              expect(request['operations'], [
                for (final operation in operations) operation.toJson(),
              ]);
              expect(
                await File(request['sourcePath'] as String).readAsBytes(),
                importedOriginal,
              );
              final source = await File('${temp.path}/$label-edited.$extension')
                  .writeAsBytes(editedBytes);
              final bytes = recoverAfterFailure && applied == 2
                  ? Uint8List.fromList([1, 2, 3])
                  : previewBytes;
              final pdf = await File('${temp.path}/$label-private.pdf')
                  .writeAsBytes(bytes);
              return {
                'status': 'saved',
                'sessionId': request['sessionId'],
                'sourcePath': source.path,
                'pdfPath': pdf.path,
                'sourceSha256': editedHash,
                'pdfSha256': sha256.convert(bytes).toString(),
                'pdfPageCount': 1,
                'engineVersion': 'synthetic-$label-preview',
                'snapshot': snapshot(editedHash, visible: false),
                if (live) 'draftSnapshot': snapshot(sourceHash, visible: false),
              };
            },
          );
          await mount(tester, null, windowsEngine: engine);
          await tester.runAsync(
            () async =>
                tester.tap(find.byKey(const ValueKey('office-edit-original'))),
          );
          for (
            var i = 0;
            i < 120 && find.byType(WindowsOfficeEditor).evaluate().isEmpty;
            i++
          ) {
            await drain(tester);
          }
          final editor = tester.widget<WindowsOfficeEditor>(
            find.byType(WindowsOfficeEditor),
          );
          expect(
            editor.onPreview,
            isNotNull,
            reason: 'The host must provide the private native preview route',
          );
          final beforePreviewEditions = (await tester.runAsync(
            () => store.readEditions(note),
          ))!.length;
          var view = await withPumping(
            tester,
            () => editor.onPreview!(operations, {}),
          );
          expect(view.baseSourceSha256, sourceHash);
          expect(view.snapshot.kind, word ? 'word' : 'presentation');
          if (word) {
            expect(view.snapshot.bodyOwnerId, 'body');
            expect(view.snapshot.wordOwners!.single.id, 'header');
            expect(view.snapshot.pageStyles!.single.leftMargin, 25.4);
            expect(view.snapshot.sourceSha256, sourceHash);
          } else
            expect(view.snapshot.slides.single.visible, false);
          expect(File(view.pdfPath).existsSync(), true);
          expect(
            (await tester.runAsync(() => store.readEditions(note)))!.length,
            beforePreviewEditions,
          );
          expect(
            (await tester.runAsync(() => store.readLatest(note)))!
                .revision
                .revisionId,
            first.revision.revisionId,
          );
          expect(
            (await tester.runAsync(
              () => repository.heads(note.sourceEntityId!),
            ))!,
            hasLength(1),
          );
          if (concurrent) {
            await tester.runAsync(() async {
              final other = await store.beginEdit(note);
              await store.commitEdited(
                other,
                originalBytes: OfficeTemplates.create(
                  kind,
                  title: 'Concurrent',
                ).bytes,
                pdfBytes: annotationPdf('other'),
                engineVersion: 'other',
                pageCount: 1,
              );
            });
          }
          if (recoverAfterFailure || changedPreview) {
            final previousPreview = File(view.pdfPath).parent;
            addTearDown(() async {
              if (previousPreview.existsSync())
                await previousPreview.delete(recursive: true);
            });
            operations = [
              ...operations,
              if (word)
                WindowsOfficeOperation.pageGeometry(
                  id: 'page0',
                  expectedLayoutSha256: 'c' * 64,
                  topMargin: 21,
                )
              else
                WindowsOfficeOperation.slideDisplay(
                  id: 's0',
                  showMasterObjects: false,
                ),
            ];
            if (recoverAfterFailure) {
              await expectLater(
                withPumping(
                  tester,
                  () => editor.onCommitWithAssets!(operations, {}),
                ),
                throwsA(isA<FormatException>()),
              );
              expect(applied, 2);
              expect(
                (await tester.runAsync(() => store.readLatest(note)))!
                    .revision
                    .revisionId,
                first.revision.revisionId,
              );
            }
            final previousSignature = view.signature;
            view = await withPumping(
              tester,
              () => editor.onPreview!(operations, {}),
            );
            expect(
              applied,
              recoverAfterFailure ? 3 : 2,
              reason: 'A normal apply without a live snapshot cannot be a preview cache hit',
            );
            expect(view.signature, isNot(previousSignature));
            expect(
              (await tester.runAsync(() => store.readLatest(note)))!
                  .revision
                  .revisionId,
              first.revision.revisionId,
            );
            if (word) expect(view.snapshot.pageStyles!.single.topMargin, 21);
          }
          await withPumping(
            tester,
            () => editor.onCommitWithAssets!(operations, {}),
          );
          expect(
            applied,
            recoverAfterFailure
                ? 3
                : changedPreview
                ? 2
                : 1,
            reason: 'Save reuses the exact validated preview signature',
          );
          final heads = (await tester.runAsync(
            () => repository.heads(note.sourceEntityId!),
          ))!;
          expect(heads, hasLength(concurrent ? 2 : 1));
          final editions = (await tester.runAsync(
            () => store.readEditions(note),
          ))!;
          expect(
            editions.any(
              (edition) =>
                  edition.originalBytes.length == editedBytes.length &&
                  sha256.convert(edition.originalBytes).toString() ==
                      editedHash,
            ),
            true,
          );
          expect(
            (await tester.runAsync(
              () =>
                  store.readLatest(note, revisionId: first.revision.revisionId),
            ))!.originalBytes,
            importedOriginal,
          );
          await withPumping(tester, () async => editor.onBack());
          await drain(tester);
          expect(File(view.pdfPath).existsSync(), false);
          expect(
            File('${temp.path}/$label-edited.$extension').readAsBytesSync(),
            editedBytes,
          );
          expect(
            File('${temp.path}/$label-private.pdf').readAsBytesSync(),
            previewBytes,
          );
        },
      );
    }
  }

  for (final failureMode in ['wrong-kind', 'route-close', 'unmount']) {
    testWidgets(
      'Windows Word preview rejects $failureMode and cleans only owned copies',
      (tester) async {
        importedOriginal = OfficeTemplates.create(
          OfficeTemplateKind.document,
          title: 'Word private source',
        ).bytes;
        note = (await tester.runAsync(
          () => store.importDocument(
            title: 'Word private',
            fileName: 'private.docx',
            bytes: importedOriginal,
          ),
        ))!;
        final first = (await tester.runAsync(() => store.readLatest(note)))!;
        final sourceHash = sha256.convert(importedOriginal).toString();
        final editedBytes = OfficeTemplates.create(
          OfficeTemplateKind.document,
          title: 'Word private output',
        ).bytes;
        final editedHash = sha256.convert(editedBytes).toString();
        final pdfBytes = annotationPdf('word private output');
        final release = Completer<void>();
        var started = false;
        final outputSource = File('${temp.path}/rejected-word.docx');
        final outputPdf = File('${temp.path}/rejected-word.pdf');
        final engine = TrackingWindowsPreviewEngine(
          runner: (request) async {
            expect(
              await File(request['sourcePath'] as String).readAsBytes(),
              importedOriginal,
            );
            if (request['mode'] == 'inspect') {
              final initial = await File('${temp.path}/rejected-initial.pdf')
                  .writeAsBytes(annotationPdf('initial'));
              return {
                'snapshot': {
                  ...wordPreviewSnapshot(sourceHash),
                  'previewPdfPath': initial.path,
                  'previewPageCount': 1,
                },
              };
            }
            expect(request['includeDraftSnapshot'], isTrue);
            expect(request['expectedSourceSha256'], sourceHash);
            expect(request['operations'], [
              {
                'op': 'pageGeometry',
                'id': 'page0',
                'expectedLayoutSha256': 'b' * 64,
                'leftMargin': 25.4,
              },
            ]);
            started = true;
            await release.future;
            await outputSource.writeAsBytes(editedBytes);
            await outputPdf.writeAsBytes(pdfBytes);
            return {
              'status': 'saved',
              'sessionId': request['sessionId'],
              'sourcePath': outputSource.path,
              'pdfPath': outputPdf.path,
              'sourceSha256': editedHash,
              'pdfSha256': sha256.convert(pdfBytes).toString(),
              'pdfPageCount': 1,
              'engineVersion': 'synthetic-word-private',
              'snapshot': wordPreviewSnapshot(editedHash, edited: true),
              'draftSnapshot': failureMode == 'wrong-kind'
                  ? {
                      'kind': 'presentation',
                      'sourceSha256': sourceHash,
                      'paragraphs': [],
                      'tables': [],
                      'slides': [],
                      'masters': [],
                    }
                  : wordPreviewSnapshot(sourceHash, edited: true),
            };
          },
        );
        addTearDown(() async {
          if (!release.isCompleted) release.complete();
          await engine.lastPreview?.dispose();
        });
        await mount(tester, null, windowsEngine: engine);
        await tester.runAsync(
          () => tester.tap(find.byKey(const ValueKey('office-edit-original'))),
        );
        for (
          var i = 0;
          i < 120 && find.byType(WindowsOfficeEditor).evaluate().isEmpty;
          i++
        ) {
          await drain(tester);
        }
        final editor = tester.widget<WindowsOfficeEditor>(
          find.byType(WindowsOfficeEditor),
        );
        expect(
          editor.onPreview,
          isNotNull,
          reason: 'Word requires the private preview host callback',
        );
        final editionsBefore = (await tester.runAsync(
          () => store.readEditions(note),
        ))!.length;
        var settled = false;
        Object? failure;
        await tester.runAsync(() async {
          editor
              .onPreview!([
                WindowsOfficeOperation.pageGeometry(
                  id: 'page0',
                  expectedLayoutSha256: 'b' * 64,
                  leftMargin: 25.4,
                ),
              ], {})
              .then(
                (_) {
                  settled = true;
                },
                onError: (Object error, StackTrace stack) {
                  failure = error;
                  settled = true;
                },
              );
        });
        for (var i = 0; i < 80 && !started; i++) await drain(tester);
        expect(started, isTrue);
        expect(settled, isFalse);
        if (failureMode == 'route-close') {
          await withPumping(tester, () async => editor.onBack());
          await drain(tester);
          expect(find.byType(WindowsOfficeEditor), findsNothing);
        } else if (failureMode == 'unmount') {
          await tester.pumpWidget(const SizedBox());
          await drain(tester);
        }
        await tester.runAsync(() async => release.complete());
        for (var i = 0; i < 100 && !settled; i++) await drain(tester);
        expect(settled, isTrue);
        expect(failure, isA<StateError>());
        expect(engine.lastPreview, isNotNull);
        expect(
          File(engine.lastPreview!.result.sourcePath).existsSync(),
          isFalse,
        );
        expect(File(engine.lastPreview!.result.pdfPath).existsSync(), isFalse);
        expect(
          Directory(p.dirname(engine.lastPreview!.result.pdfPath)).existsSync(),
          isFalse,
        );
        expect(outputSource.readAsBytesSync(), editedBytes);
        expect(outputPdf.readAsBytesSync(), pdfBytes);
        expect(
          (await tester.runAsync(() => store.readEditions(note)))!.length,
          editionsBefore,
        );
        final latest = (await tester.runAsync(() => store.readLatest(note)))!;
        expect(latest.revision.revisionId, first.revision.revisionId);
        expect(latest.originalBytes, importedOriginal);
        expect(
          (await tester.runAsync(
            () => repository.heads(note.sourceEntityId!),
          ))!,
          hasLength(1),
        );
        if (failureMode == 'wrong-kind') {
          await withPumping(tester, () async => editor.onBack());
          await drain(tester);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'Windows original editor commits captured source then public save closes its route',
    (tester) async {
      final first = (await tester.runAsync(() => store.readLatest(note)))!;
      var applied = 0;
      final engine = WindowsOfficeEngine(
        runner: (request) async {
          Map<String, dynamic> snapshot(String hash, String text) => {
            'kind': 'word',
            'sourceSha256': hash,
            'paragraphs': [
              {'id': 'p0', 'text': text},
            ],
            'tables': [],
            'slides': [],
          };
          if (request['mode'] == 'inspect') {
            expect(request['preview'], true);
            final path = request['sourcePath'] as String;
            expect(await File(path).readAsBytes(), importedOriginal);
            final preview = File('${temp.path}/initial.pdf');
            await preview.writeAsBytes(annotationPdf('initial'));
            return {
              'snapshot': {
                ...snapshot(
                  sha256.convert(importedOriginal).toString(),
                  '원래 제목',
                ),
                'previewPdfPath': preview.path,
                'previewPageCount': 1,
              },
            };
          }
          applied++;
          expect(
            request['expectedSourceSha256'],
            sha256.convert(importedOriginal).toString(),
          );
          expect(request['operations'], [
            {'op': 'paragraphText', 'id': 'p0', 'text': 'Windows 수정'},
          ]);
          final result = await savedResult(
            request['sourcePath'] as String,
            request['sessionId'] as String,
          );
          return {
            'status': 'saved',
            'sessionId': result.sessionId,
            'sourcePath': result.sourcePath,
            'pdfPath': result.pdfPath,
            'sourceSha256': result.sourceSha256,
            'pdfSha256': result.pdfSha256,
            'pdfPageCount': 1,
            'engineVersion': 'windows-fixture',
            'snapshot': snapshot(result.sourceSha256!, 'Windows 수정'),
          };
        },
      );
      final key = await mount(tester, null, windowsEngine: engine);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('office-edit-original')));
      });
      for (
        var i = 0;
        i < 120 && find.byType(WindowsOfficeEditor).evaluate().isEmpty;
        i++
      ) {
        await drain(tester);
      }
      expect(find.byType(WindowsOfficeEditor), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('office-paragraph-p0')),
        'Windows 수정',
      );
      var finished = false;
      Object? failed;
      await tester.runAsync(() async {
        key.currentState!.save().then(
          (_) {
            finished = true;
          },
          onError: (Object error) {
            failed = error;
            finished = true;
          },
        );
      });
      for (var i = 0; i < 120 && !finished; i++) {
        await drain(tester);
      }
      expect(failed, isNull);
      expect(finished, true);
      expect(applied, 1);
      expect(find.byType(WindowsOfficeEditor), findsNothing);
      final latest = (await tester.runAsync(() => store.readLatest(note)))!;
      expect(latest.revision.parentRevisionIds, [first.revision.revisionId]);
      expect(latest.bindingId, isNotNull);
      expect(latest.pdfBytes, annotationPdf('edited'));
      expect(
        (await tester.runAsync(
          () => store.readLatest(note, revisionId: first.revision.revisionId),
        ))!.originalBytes,
        importedOriginal,
      );
      expect(
        await tester.runAsync(() => repository.heads(note.inkEntityId)),
        isEmpty,
      );
    },
  );

  for (final concurrent in [false, true]) {
    testWidgets(
      concurrent
          ? 'Windows PPTX duplicate rejects a newer source received during editing'
          : 'Windows PPTX duplicate publishes a new PDF without replacing older ink',
      (tester) async {
        Future<Uint8List> pdf(String text, {int pages = 1}) {
          final document = pw.Document();
          for (var index = 0; index < pages; index++) {
            document.addPage(pw.Page(build: (_) => pw.Text(text)));
          }
          return document.save();
        }

        final original = OfficeTemplates.create(
          OfficeTemplateKind.presentation,
          title: 'Original presentation',
        ).bytes;
        final clone = OfficeTemplates.create(
          OfficeTemplateKind.presentation,
          title: 'Generated copy',
        ).bytes;
        final (before, ink, oldPdf, newPdf) = await withPumping(
          tester,
          () async {
            note = await store.importDocument(
              title: 'Duplicate target',
              fileName: 'slides.pptx',
              bytes: original,
            );
            final oldPdf = await pdf('Original PDF');
            final before = await store.commitEdited(
              await store.beginEdit(note),
              originalBytes: original,
              pdfBytes: oldPdf,
              engineVersion: 'duplicate-original',
              pageCount: 1,
            );
            final annotation = await OfficeAnnotationStore(repository)
                .open(note, before);
            final core = EditorCoreInfo(filePath: annotation.workingPath)
              ..pages = [EditorPage()];
            try {
              core.pages.single.quill.controller.document.insert(
                0,
                'Previous handwriting',
              );
              await annotation.saveSnapshot(core, 0);
              final ink = (await repository.heads(before.bindingId!)).single;
              return (before, ink, oldPdf, await pdf('Cloned PDF', pages: 2));
            } finally {
              core.dispose();
            }
          },
        );
        final inkFiles = await withPumping(
          tester,
          () => repository.readFiles(ink),
        );
        OfficeEdition? arrived;
        var applies = 0;
        Map<String, Object?> snapshot(String hash, int count) => {
          'kind': 'presentation',
          'sourceSha256': hash,
          'paragraphs': [],
          'tables': [],
          'slides': [
            for (var index = 0; index < count; index++)
              {
                'id': 'slide-$index',
                'width': 280,
                'height': 157.5,
                'shapes': [],
                'canDuplicate': true,
              },
          ],
        };
        final engine = WindowsOfficeEngine(
          runner: (request) async {
            expect(
              await File(request['sourcePath'] as String).readAsBytes(),
              original,
            );
            if (request['mode'] == 'inspect') {
              final preview = await File('${temp.path}/duplicate-initial.pdf')
                  .writeAsBytes(annotationPdf('initial duplicate preview'));
              return {
                'snapshot': {
                  ...snapshot(before.originalSha256, 1),
                  'previewPdfPath': preview.path,
                  'previewPageCount': 1,
                },
              };
            }
            applies++;
            expect(request['expectedSourceSha256'], before.originalSha256);
            expect(request['includeDraftSnapshot'], isNull);
            expect(request['operations'], [
              {'op': 'slideDuplicate', 'id': 'slide-0'},
            ]);
            if (concurrent) {
              final peer = await NoteRepository.open(
                Directory('${temp.path}/duplicate-peer'),
                vaultId: repository.vaultId,
                createFormatVersion: 2,
              );
              try {
                for (final revision in await repository.revisions()) {
                  await peer.importRevision(
                    revision,
                    blobsByHash: {
                      for (final ref in revision.blobs.values)
                        ref.hash: await repository.readBlob(ref.hash),
                    },
                  );
                }
                final peerStore = OfficeDocumentStore(peer);
                final newer = await peerStore.commitEdited(
                  await peerStore.beginEdit(note),
                  originalBytes: OfficeTemplates.create(
                    OfficeTemplateKind.presentation,
                    title: 'Incoming presentation',
                  ).bytes,
                  pdfBytes: await pdf('Incoming PDF'),
                  engineVersion: 'duplicate-peer',
                  pageCount: 1,
                );
                expect(newer.revision.deviceId, isNot(repository.deviceId));
                await repository.importRevision(
                  newer.revision,
                  blobsByHash: {
                    for (final ref in newer.revision.blobs.values)
                      ref.hash: await peer.readBlob(ref.hash),
                  },
                );
                arrived = newer;
              } finally {
                await peer.close();
              }
            }
            final source = await File('${temp.path}/duplicate-edited.pptx')
                .writeAsBytes(clone);
            final preview = await File('${temp.path}/duplicate-edited.pdf')
                .writeAsBytes(newPdf);
            final hash = sha256.convert(clone).toString();
            return {
              'status': 'saved',
              'sessionId': request['sessionId'],
              'sourcePath': source.path,
              'pdfPath': preview.path,
              'sourceSha256': hash,
              'pdfSha256': sha256.convert(newPdf).toString(),
              'pdfPageCount': 2,
              'engineVersion': 'duplicate-fixture',
              'snapshot': snapshot(hash, 2),
            };
          },
        );
        final key = await mount(tester, null, windowsEngine: engine);
        await tester.runAsync(
          () => tester.tap(find.byKey(const ValueKey('office-edit-original'))),
        );
        final editor = find.byType(WindowsOfficeEditor);
        for (var index = 0; index < 80 && editor.evaluate().isEmpty; index++) {
          await drain(tester);
        }
        expect(editor, findsOneWidget);
        await tester.tap(find.byTooltip('슬라이드 복제'));
        await tester.pump();
        if (concurrent) {
          await expectLater(
            withPumping(tester, key.currentState!.save),
            throwsA(
              isA<StateError>().having(
                (error) => error.message,
                'message',
                contains('Revision heads changed'),
              ),
            ),
          );
          expect(editor, findsOneWidget);
          expect(find.textContaining('Revision heads changed'), findsOneWidget);
        } else {
          await withPumping(tester, key.currentState!.save);
          expect(editor, findsNothing);
        }
        expect(applies, 1);
        final heads = await withPumping(
          tester,
          () => repository.heads(note.sourceEntityId!),
        );
        final latest = await withPumping(tester, () => store.readLatest(note));
        expect(heads.single.revisionId, latest.revision.revisionId);
        expect(latest.revision.parentRevisionIds, [before.revision.revisionId]);
        expect(latest.bindingId, isNot(before.bindingId));
        if (concurrent) {
          expect(latest.revision.revisionId, arrived!.revision.revisionId);
          expect(latest.pdfBytes, arrived!.pdfBytes);
        } else {
          expect(latest.originalBytes, clone);
          expect(latest.pdfBytes, newPdf);
          expect(latest.pageCount, 2);
        }
        final historical = await withPumping(
          tester,
          () => store.readLatest(note, revisionId: before.revision.revisionId),
        );
        expect(historical.originalBytes, original);
        expect(historical.pdfBytes, oldPdf);
        expect(historical.bindingId, before.bindingId);
        final historicalInk = await withPumping(
          tester,
          () => repository.heads(before.bindingId!),
        );
        expect(historicalInk.single.revisionId, ink.revisionId);
        expect(
          await withPumping(tester, () => repository.readFiles(ink)),
          inkFiles,
        );
        expect(
          await withPumping(tester, () => repository.heads(latest.bindingId!)),
          isEmpty,
        );
      },
    );
  }

  testWidgets(
    'Windows save refresh does not read the historical original payload',
    (tester) async {
      final original = (await tester.runAsync(() => store.readLatest(note)))!;
      final engine = WindowsOfficeEngine(
        runner: (request) async {
          Map<String, dynamic> snapshot(String hash) => {
            'kind': 'word',
            'sourceSha256': hash,
            'paragraphs': [
              {'id': 'p0', 'text': '원래 제목'},
            ],
            'tables': [],
            'slides': [],
          };
          if (request['mode'] == 'inspect') {
            final preview = File('${temp.path}/refresh-initial.pdf');
            await preview.writeAsBytes(annotationPdf('initial'));
            return {
              'snapshot': {
                ...snapshot(sha256.convert(importedOriginal).toString()),
                'previewPdfPath': preview.path,
                'previewPageCount': 1,
              },
            };
          }
          final result = await savedResult(
            request['sourcePath'] as String,
            request['sessionId'] as String,
          );
          return {
            'status': 'saved',
            'sessionId': result.sessionId,
            'sourcePath': result.sourcePath,
            'pdfPath': result.pdfPath,
            'sourceSha256': result.sourceSha256,
            'pdfSha256': result.pdfSha256,
            'pdfPageCount': 1,
            'engineVersion': 'windows-fixture',
            'snapshot': snapshot(result.sourceSha256!),
          };
        },
      );
      final key = await mount(tester, null, windowsEngine: engine);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('office-edit-original')));
      });
      for (
        var i = 0;
        i < 120 && find.byType(WindowsOfficeEditor).evaluate().isEmpty;
        i++
      ) {
        await drain(tester);
      }
      expect(find.byType(WindowsOfficeEditor), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('office-paragraph-p0')),
        '저장된 수정',
      );
      var injected = false;
      var finished = false;
      Object? failure;
      await tester.runAsync(() async {
        final outerZone = Zone.current;
        final oldBlob = File(
          '${repository.root.path}/blobs/${original.originalSha256}',
        );
        final target = p.normalize(oldBlob.absolute.path);
        IOOverrides.runZoned(
          () {
            key.currentState!.save().then(
              (_) {
                finished = true;
              },
              onError: (Object error) {
                failure = error;
                finished = true;
              },
            );
          },
          createFile: (path) {
            final actual = outerZone.run(() => File(path));
            if (p.equals(p.normalize(p.absolute(path)), target)) {
              return TransientOfficeSourceFile(actual, () {
                if (injected) return false;
                injected = true;
                return true;
              });
            }
            return actual;
          },
        );
      });
      for (var i = 0; i < 120 && !finished; i++) {
        await drain(tester);
      }
      expect(finished, true);
      expect(
        injected,
        false,
        reason: 'Post-commit refresh must not reopen the historical original',
      );
      final editions = (await tester.runAsync(() => store.readEditions(note)))!;
      expect(editions, hasLength(2));
      expect(editions.first.originalBytes, annotationOfficeFile('edited'));
      expect(editions.first.bindingId, isNotNull);
      expect(
        failure,
        isNull,
        reason: 'A history refresh must leave the committed save successful',
      );
      expect(find.byType(WindowsOfficeEditor), findsNothing);
      expect(find.text('원본과 PDF를 저장했습니다.'), findsOneWidget);
    },
  );

  for (final (extension, outcome, platform) in const [
    ('hwpx', 'save', TargetPlatform.windows),
    ('hwpx', 'peer before apply', TargetPlatform.windows),
    ('hwpx', 'peer during apply', TargetPlatform.android),
    ('hwp', 'save', TargetPlatform.windows),
    ('hwp', 'peer before apply', TargetPlatform.windows),
    ('hwp', 'peer during apply', TargetPlatform.android),
    ('hwp', 'unrelated pending revision', TargetPlatform.android),
    ('hwpx', 'unrelated pending revision', TargetPlatform.android),
    ('hwpx', 'related pending revision', TargetPlatform.android),
  ]) {
    final format = extension.toUpperCase();
    testWidgets('$format table structure shared workspace handles $outcome', (
      tester,
    ) async {
      final saves =
          outcome == 'save' || outcome == 'unrelated pending revision';
      if (platform == TargetPlatform.android) {
        tester.view.physicalSize = extension == 'hwpx'
            ? const Size(412, 892)
            : const Size(1200, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
      }
      const tableId = 's0:p1:t0';
      final isHwpx = extension == 'hwpx';
      Uint8List source(String title) => isHwpx
          ? OfficeTemplates.create(OfficeTemplateKind.hwpx, title: title).bytes
          : Uint8List.fromList([
              0xd0,
              0xcf,
              0x11,
              0xe0,
              0xa1,
              0xb1,
              0x1a,
              0xe1,
              ...utf8.encode(title),
            ]);
      final original = source('원래 표');
      final edited = source('행을 추가한 표');
      final peerBytes = source('다른 기기에서 저장한 표');
      final oldPdf = annotationPdf('before HWPX table structure');
      final newPdf = annotationPdf('after HWPX table structure');
      final peerPdf = annotationPdf('peer HWPX table');
      final oldInk = Uint8List.fromList([4, 9, 16]);
      final (prior, inkRevision) = await withPumping(tester, () async {
        note = await store.importDocument(
          title: '한글 표 실습',
          fileName: 'table.$extension',
          bytes: original,
        );
        final prior = await store.commitEdited(
          await store.beginEdit(note),
          originalBytes: original,
          pdfBytes: oldPdf,
          engineVersion: 'before-hwpx-structure',
          pageCount: 1,
        );
        final ink = await OfficeAnnotationStore(repository).open(note, prior);
        return (prior, await ink.saveFiles({'main.sbn2': oldInk}));
      });
      OfficeEdition? peer;
      Future<void> publishPeer() async {
        peer = await store.commitEdited(
          await store.beginEdit(note),
          originalBytes: peerBytes,
          pdfBytes: peerPdf,
          engineVersion: 'peer-hwpx-structure',
          pageCount: 1,
        );
      }

      var applied = 0;
      final originalHash = sha256.convert(original).toString();
      final hwp = HwpStructuredOfficeEngine(
        runner: (request) async {
          final input = request['sourcePath'] as String;
          expect(p.extension(input), '.$extension');
          expect(await File(input).readAsBytes(), original);
          if (request['mode'] == 'inspect') {
            final pdf = await File(p.join(temp.path, 'hwpx-initial.pdf'))
                .writeAsBytes(oldPdf);
            return {
              'snapshot': {
                'kind': 'word',
                'sourceSha256': originalHash,
                'previewPdfPath': pdf.path,
                'previewPdfSha256': sha256.convert(oldPdf).toString(),
                'previewPageCount': 1,
                'paragraphs': [],
                'slides': [],
                'tables': [
                  {
                    'id': tableId,
                    'cells': {'0,0': '첫 셀', '1,0': '둘째 셀'},
                    'structure': {
                      'rows': 2,
                      'columns': 1,
                      'canInsertRow': true,
                      'canDeleteRow': true,
                      'canInsertColumn': isHwpx,
                      'canDeleteColumn': false,
                    },
                  },
                ],
              },
            };
          }
          applied++;
          expect(request['expectedSourceSha256'], originalHash);
          expect(request['operations'], const [
            {
              'op': 'tableStructure',
              'id': tableId,
              'action': 'insertRow',
              'index': 0,
            },
          ]);
          if (outcome == 'peer during apply') await publishPeer();
          final output = await Directory(p.join(temp.path, 'hwpx-output'))
              .create();
          final source = await File(p.join(output.path, 'edited.$extension'))
              .writeAsBytes(edited);
          final pdf = await File(p.join(output.path, 'preview.pdf'))
              .writeAsBytes(newPdf);
          final outputHash = sha256.convert(edited).toString();
          return {
            'status': 'saved',
            'sessionId': request['sessionId'],
            'sourcePath': source.path,
            'pdfPath': pdf.path,
            'sourceSha256': outputHash,
            'pdfSha256': sha256.convert(newPdf).toString(),
            'pdfPageCount': 1,
            'engineVersion': 'hwpx-structure-test',
            'snapshot': {
              'kind': 'word',
              'sourceSha256': outputHash,
              'paragraphs': [],
              'tables': [
                {
                  'id': tableId,
                  'cells': {'0,0': '', '1,0': '첫 셀', '2,0': '둘째 셀'},
                },
              ],
              'slides': [],
            },
          };
        },
      );
      await mount(tester, null, hwpEngine: hwp);
      await tester.runAsync(
        () => tester.tap(find.byKey(const ValueKey('office-edit-original'))),
      );
      final control = find.byKey(
        const ValueKey('office-hwpx-edit-structure-$tableId'),
      );
      for (var i = 0; i < 12 && control.evaluate().isEmpty; i++) {
        await drain(tester);
      }
      expect(control, findsOneWidget);
      expect(find.text(isHwpx ? '표 행·열 편집' : '표 행 편집'), findsOneWidget);
      await tester.tap(control);
      await tester.pump(const Duration(milliseconds: 350));
      Future<void> choose(String key, String label) async {
        await tester.tap(find.byKey(ValueKey('office-hwpx-structure-$key')));
        await tester.pump(const Duration(milliseconds: 350));
        await tester.tap(find.text(label).last);
        await tester.pump(const Duration(milliseconds: 350));
      }

      await choose('action', '행 추가');
      await choose('position', '1행 앞');
      await tester.tap(
        find.byKey(const ValueKey('office-hwpx-structure-confirm')),
      );
      await tester.pump(const Duration(milliseconds: 350));
      if (outcome == 'peer before apply')
        await withPumping(tester, publishPeer);
      if (outcome.endsWith('pending revision')) {
        await withPumping(
          tester,
          () => receiveIncompleteSource(
            related: outcome == 'related pending revision' ? note : null,
          ),
        );
      }
      await tester.runAsync(() => tester.tap(find.text('저장하고 닫기')));
      for (var i = 0; i < 12; i++) {
        await drain(tester);
        if (saves
            ? find.byType(WindowsOfficeEditor).evaluate().isEmpty
            : find.text('저장 재시도').evaluate().isNotEmpty) {
          break;
        }
      }
      expect(applied, outcome == 'peer before apply' ? 0 : 1);
      final latest = await withPumping(tester, () => store.readLatest(note));
      if (saves) {
        expect(latest.originalBytes, edited);
        expect(latest.pdfBytes, newPdf);
        expect(latest.revision.parentRevisionIds, [prior.revision.revisionId]);
        expect(latest.bindingId, isNot(prior.bindingId));
        expect(find.byType(WindowsOfficeEditor), findsNothing);
      } else {
        expect(latest.revision.revisionId, (peer ?? prior).revision.revisionId);
        expect(latest.originalBytes, peer == null ? original : peerBytes);
        expect(latest.pdfBytes, peer == null ? oldPdf : peerPdf);
        expect(find.text('행 추가 · 1행 앞'), findsOneWidget);
        expect(find.text('저장 재시도'), findsOneWidget);
      }
      final savedPrior = await withPumping(
        tester,
        () => store.readLatest(note, revisionId: prior.revision.revisionId),
      );
      final savedInk = await withPumping(
        tester,
        () => repository.readFiles(inkRevision),
      );
      expect(savedPrior.originalBytes, original);
      expect(savedPrior.pdfBytes, oldPdf);
      expect(savedInk['main.sbn2'], oldInk);
      if (outcome.endsWith('pending revision')) {
        expect(repository.pendingRevisionCount, 1);
      }
    }, variant: TargetPlatformVariant({platform}));
  }

  testWidgets(
    'HWP originals select the structured text-only editor and preserve their source edition',
    (tester) async {
      final originalBytes = Uint8List.fromList([
        0xd0,
        0xcf,
        0x11,
        0xe0,
        0xa1,
        0xb1,
        0x1a,
        0xe1,
        ...'original'.codeUnits,
      ]);
      final editedBytes = Uint8List.fromList([
        0xd0,
        0xcf,
        0x11,
        0xe0,
        0xa1,
        0xb1,
        0x1a,
        0xe1,
        ...'edited'.codeUnits,
      ]);
      await tester.runAsync(() async {
        note = await store.importDocument(
          title: '한글 원본',
          fileName: '연구.hwp',
          bytes: originalBytes,
        );
      });
      final first = (await tester.runAsync(() => store.readLatest(note)))!;
      var applied = 0;
      final hwp = HwpStructuredOfficeEngine(
        runner: (request) async {
          Map<String, dynamic> snapshot(String hash) => {
            'kind': 'word',
            'sourceSha256': hash,
            'paragraphs': [
              {'id': 's0:p0', 'text': '원문 문단'},
            ],
            'tables': [],
            'slides': [],
          };
          final input = request['sourcePath'] as String;
          expect(p.extension(input), '.hwp');
          expect(await File(input).readAsBytes(), originalBytes);
          if (request['mode'] == 'inspect') {
            final preview = File('${temp.path}/hwp-initial.pdf');
            final bytes = annotationPdf('hwp-initial');
            await preview.writeAsBytes(bytes);
            return {
              'snapshot': {
                ...snapshot(sha256.convert(originalBytes).toString()),
                'previewPdfPath': preview.path,
                'previewPageCount': 1,
                'previewPdfSha256': sha256.convert(bytes).toString(),
              },
            };
          }
          applied++;
          expect(request['operations'], [
            {'op': 'paragraphText', 'id': 's0:p0', 'text': '한글 수정'},
          ]);
          final output = await Directory('${temp.path}/hwp-native').create();
          final source = await File('${output.path}/edited.hwp')
              .writeAsBytes(editedBytes);
          final pdfBytes = annotationPdf('hwp-edited');
          final pdf = await File('${output.path}/preview.pdf')
              .writeAsBytes(pdfBytes);
          final hash = sha256.convert(editedBytes).toString();
          return {
            'status': 'saved',
            'sessionId': request['sessionId'],
            'sourcePath': source.path,
            'pdfPath': pdf.path,
            'sourceSha256': hash,
            'pdfSha256': sha256.convert(pdfBytes).toString(),
            'pdfPageCount': 1,
            'engineVersion': 'hwp-fixture',
            'snapshot': snapshot(hash),
          };
        },
      );
      final key = await mount(tester, null, hwpEngine: hwp);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('office-edit-original')),
            )
            .onPressed,
        isNotNull,
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('office-edit-original')));
      });
      for (
        var i = 0;
        i < 120 && find.byType(WindowsOfficeEditor).evaluate().isEmpty;
        i++
      ) {
        await drain(tester);
      }
      expect(find.byType(WindowsOfficeEditor), findsOneWidget);
      expect(find.byTooltip('굵게'), findsNothing);
      final hwpEditor = tester.widget<WindowsOfficeEditor>(
        find.byType(WindowsOfficeEditor),
      );
      expect(hwpEditor.allowParagraphAlignment, isTrue);
      expect(hwpEditor.allowFormatting, isFalse);
      expect(hwpEditor.allowedTextStyleProperties, contains('underline'));
      expect(find.textContaining('미리보기에는 포함된 한글 글꼴'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('office-paragraph-s0:p0')),
        '한글 수정',
      );
      var finished = false;
      Object? failure;
      await tester.runAsync(() async {
        key.currentState!.save().then(
          (_) {
            finished = true;
          },
          onError: (Object error) {
            failure = error;
            finished = true;
          },
        );
      });
      for (var i = 0; i < 120 && !finished; i++) {
        await drain(tester);
      }
      expect(failure, isNull);
      expect(finished, true);
      expect(applied, 1);
      final latest = (await tester.runAsync(() => store.readLatest(note)))!;
      expect(latest.originalBytes, editedBytes);
      expect(latest.revision.parentRevisionIds, [first.revision.revisionId]);
      expect(latest.bindingId, isNotNull);
      expect(
        (await tester.runAsync(
          () => store.readLatest(note, revisionId: first.revision.revisionId),
        ))!.originalBytes,
        originalBytes,
      );
    },
  );

  final blankHwpLibrary = Platform.environment['PIV_HWP_BLANK_TEST_DLL'];
  final blankHwpFixtures = Platform.environment['PIV_HWP_BLANK_TEST_FIXTURES'];
  final hwpFonts = p.absolute('build/native/fonts');
  for (final extension in ['hwp', 'hwpx']) {
    final fixture = blankHwpFixtures == null
        ? null
        : File(p.join(blankHwpFixtures, 'shipped-blank.$extension'));
    testWidgets(
      'actual $extension blank original can be typed, saved, and cleared',
      (tester) async {
        final input = (await tester.runAsync(fixture!.readAsBytes))!;
        await tester.runAsync(() async {
          note = await store.importDocument(
            title: '빈 한글 원본',
            fileName: '빈 문서.$extension',
            bytes: input,
          );
        });
        final before = (await tester.runAsync(() => store.readLatest(note)))!;
        final engine = HwpStructuredOfficeEngine(
          libraryPath: blankHwpLibrary,
          fontDirectory: hwpFonts,
        );
        final workspace = await mount(tester, null, hwpEngine: engine);
        const id = 's0:p0';
        final field = find.byKey(const ValueKey('office-paragraph-$id'));
        const text = '가😀 첫 입력';

        Future<void> expectEditableBody(String expected) async {
          final open = find.byKey(const ValueKey('office-edit-original'));
          expect(tester.widget<FilledButton>(open).onPressed, isNotNull);
          await tester.runAsync(() => tester.tap(open));
          final editor = find.byType(WindowsOfficeEditor);
          for (var i = 0; i < 80 && editor.evaluate().isEmpty; i++) {
            await drain(tester);
          }
          expect(editor, findsOneWidget);
          expect(
            field,
            findsOneWidget,
            reason: 'The first body paragraph must exist even when empty',
          );
          final textField = tester.widget<TextField>(field);
          expect(textField.readOnly, isFalse);
          expect(textField.controller!.text, expected);
          final paragraph = tester
              .widget<WindowsOfficeEditor>(editor)
              .snapshot
              .paragraphs
              .singleWhere((row) => row.id == id);
          expect(paragraph.textDetails!.canReplace, isTrue);
          expect(paragraph.textDetails!.utf16Length, expected.length);
          expect(
            paragraph.textDetails!.textSha256,
            sha256.convert(utf8.encode(expected)).toString(),
          );
        }

        await expectEditableBody('');
        await tester.enterText(field, text);
        await withPumping(tester, workspace.currentState!.save);
        final edited = (await tester.runAsync(() => store.readLatest(note)))!;
        expect(edited.originalFileName, '빈 문서.$extension');
        expect(edited.originalSha256, isNot(before.originalSha256));
        expect(edited.revision.parentRevisionIds, [before.revision.revisionId]);
        expect(edited.pageCount, 1);
        expect(edited.pdfBytes, isNotEmpty);

        await expectEditableBody(text);
        await tester.enterText(field, '');
        await withPumping(tester, workspace.currentState!.save);
        final cleared = (await tester.runAsync(() => store.readLatest(note)))!;
        expect(cleared.revision.parentRevisionIds, [
          edited.revision.revisionId,
        ]);
        expect(cleared.pageCount, 1);
        expect(cleared.pdfBytes, isNotEmpty);
        await expectEditableBody('');

        final historic = (await tester.runAsync(
          () => store.readLatest(note, revisionId: before.revision.revisionId),
        ))!;
        expect(historic.originalBytes, input);
        expect(await tester.runAsync(fixture.readAsBytes), input);
      },
      skip:
          !Platform.isWindows ||
          blankHwpLibrary == null ||
          !File(blankHwpLibrary).existsSync() ||
          fixture == null ||
          !fixture.existsSync() ||
          !File(p.join(hwpFonts, 'NotoSansCJKkr-Regular.otf')).existsSync(),
    );
  }

  final deleteHwpLibrary = Platform.environment['PIV_HWP_DELETE_TEST_DLL'];
  final deleteHwpFixtures =
      Platform.environment['PIV_HWP_DELETE_TEST_FIXTURES'];
  for (final extension in ['hwp', 'hwpx']) {
    final fixture = deleteHwpFixtures == null
        ? null
        : File(
            p.join(
              deleteHwpFixtures,
              extension == 'hwp' ? 'original.hwp' : 'clean-original.hwpx',
            ),
          );
    testWidgets(
      'actual $extension paragraph deletion saves the original and matching PDF during another note sync',
      (tester) async {
        tester.view.physicalSize = extension == 'hwpx'
            ? const Size(412, 892)
            : const Size(1200, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final input = (await tester.runAsync(fixture!.readAsBytes))!;
        final engine = HwpStructuredOfficeEngine(
          libraryPath: deleteHwpLibrary,
          fontDirectory: hwpFonts,
        );
        final oldInk = Uint8List.fromList([4, 9, 16]);
        final (before, oldInkRevision) = await withPumping(tester, () async {
          note = await store.importDocument(
            title: '문단 삭제',
            fileName: '문단 삭제.$extension',
            bytes: input,
          );
          final preview = await engine.inspect(fixture.path, preview: true);
          try {
            final prior = await store.commitEdited(
              await store.beginEdit(note),
              originalBytes: input,
              pdfBytes: await File(preview.previewPdfPath!).readAsBytes(),
              engineVersion: 'native-delete-baseline',
              pageCount: preview.previewPageCount!,
            );
            final ink = await OfficeAnnotationStore(repository)
                .open(note, prior);
            return (prior, await ink.saveFiles({'main.sbn2': oldInk}));
          } finally {
            await preview.disposePreview();
          }
        });
        final workspace = await mount(tester, null, hwpEngine: engine);
        final editor = find.byType(WindowsOfficeEditor);
        Future<WindowsOfficeSnapshot> openEditor() async {
          final open = find.byKey(const ValueKey('office-edit-original'));
          expect(tester.widget<FilledButton>(open).onPressed, isNotNull);
          await tester.runAsync(() => tester.tap(open));
          for (var i = 0; i < 80 && editor.evaluate().isEmpty; i++) {
            await drain(tester);
          }
          return tester.widget<WindowsOfficeEditor>(editor).snapshot;
        }

        final snapshot = await openEditor();
        final target = snapshot.paragraphs.indexWhere(
          (paragraph) => paragraph.id == 's0:p1',
        );
        expect(target, greaterThanOrEqualTo(0));
        expect(snapshot.paragraphs[target].structure?.canDelete, isTrue);
        expect(
          snapshot.paragraphs.any(
            (row) => row.id == 's0:p0' && row.structure?.canDelete == true,
          ),
          isFalse,
        );
        final expected = snapshot.paragraphs.map((row) => row.text).toList()
          ..removeAt(target);
        final delete = find.byKey(
          const ValueKey('office-hwp-delete-paragraph-s0:p1'),
        );
        await tester.scrollUntilVisible(
          delete,
          120,
          scrollable: find
              .descendant(of: editor, matching: find.byType(Scrollable))
              .first,
        );
        await tester.tap(delete);
        await tester.pump();
        expect(find.text('삭제 예정'), findsOneWidget);
        await withPumping(tester, receiveIncompleteSource);
        await withPumping(tester, workspace.currentState!.save);

        final latest = (await tester.runAsync(() => store.readLatest(note)))!;
        expect(latest.revision.parentRevisionIds, [before.revision.revisionId]);
        expect(latest.originalFileName, '문단 삭제.$extension');
        expect(latest.originalSha256, isNot(before.originalSha256));
        expect(latest.bindingId, isNotNull);
        expect(latest.bindingId, isNot(before.bindingId));
        expect(latest.pageCount, greaterThanOrEqualTo(1));
        expect(latest.pdfSha256, sha256.convert(latest.pdfBytes!).toString());
        expect(latest.pdfSha256, isNot(before.pdfSha256));
        final reopened = await openEditor();
        expect(reopened.sourceSha256, latest.originalSha256);
        expect(reopened.paragraphs.map((row) => row.text), expected);
        final previous = (await tester.runAsync(
          () => store.readLatest(note, revisionId: before.revision.revisionId),
        ))!;
        expect(previous.originalBytes, input);
        expect(previous.pdfBytes, before.pdfBytes);
        final preservedInk = await withPumping(
          tester,
          () => repository.readFiles(oldInkRevision),
        );
        expect(preservedInk['main.sbn2'], oldInk);
        expect(repository.pendingRevisionCount, 1);
        expect(await tester.runAsync(fixture.readAsBytes), input);
      },
      skip:
          !Platform.isWindows ||
          deleteHwpLibrary == null ||
          !File(deleteHwpLibrary).existsSync() ||
          fixture == null ||
          !fixture.existsSync(),
      variant: const TargetPlatformVariant({TargetPlatform.android}),
    );
  }

  testWidgets(
    'explicit Android engine remains authoritative for HWP fixture workspaces',
    (tester) async {
      await tester.runAsync(() async {
        note = await store.importDocument(
          title: '한글',
          fileName: '연구.hwp',
          bytes: Uint8List.fromList([1, 2, 3]),
        );
      });
      final hwp = HwpStructuredOfficeEngine(
        runner: (_) async => throw StateError(
          'HWP adapter must not replace an explicit Android engine',
        ),
      );
      await mount(
        tester,
        FixtureOfficeEngine(available: false),
        hwpEngine: hwp,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('office-edit-original')),
            )
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets(
    'unavailable original editor shows preserved original and no fabricated PDF',
    (tester) async {
      await mount(tester, FixtureOfficeEngine(available: false));
      expect(find.text('lecture.docx'), findsOneWidget);
      expect(find.textContaining('원본은 기기에 보관'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('office-edit-original')),
            )
            .onPressed,
        isNull,
      );
      expect(find.text('PDF가 아직 없습니다.'), findsOneWidget);
      expect(
        await tester.runAsync(() => repository.heads(note.inkEntityId)),
        isEmpty,
      );
    },
  );

  testWidgets(
    'native saved response commits matching source and PDF as a new edition',
    (tester) async {
      final first = (await tester.runAsync(() => store.readLatest(note)))!;
      final key = await mount(
        tester,
        FixtureOfficeEngine(onEdit: (path, id) => savedResult(path, id)),
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('office-edit-original')));
      });
      await drain(tester);
      await withPumping(tester, key.currentState!.save);
      await tester.pump();
      final latest = (await tester.runAsync(() => store.readLatest(note)))!;
      expect(latest.revision.parentRevisionIds, [first.revision.revisionId]);
      expect(latest.pdfBytes, annotationPdf('edited'));
      expect(find.text('원본과 PDF를 저장했습니다.'), findsOneWidget);
      expect(
        await tester.runAsync(() => repository.heads(note.inkEntityId)),
        isEmpty,
      );
      expect(
        (await tester.runAsync(() => store.readEditions(note)))!.length,
        2,
      );
    },
  );

  for (final concurrentEdit in [false, true]) {
    testWidgets(
      concurrentEdit
          ? 'Android PPTX photo replacement preserves a newer edition received during preview'
          : 'Android PPTX photo replacement previews the changed file and publishes a new edition',
      (tester) async {
        final input = pptxPhotoFixture();
        final replacement = pptxReplacementPhoto();
        final first = (await tester.runAsync(() async {
          note = await store.importDocument(
            title: 'Slide',
            fileName: 'slide.pptx',
            bytes: input,
          );
          return store.readLatest(note);
        }))!;
        final picker = _PptxPhotoPicker(_PptxPhotoFile(replacement.bytes));
        final previousPicker = FilePickerPlatform.instance;
        FilePickerPlatform.instance = picker;
        addTearDown(() => FilePickerPlatform.instance = previousPicker);
        final pdf = annotationPdf('photo-replacement');
        var rendered = 0;
        OfficeEdition? arrived;
        final finishPreview = Completer<void>();
        final preview = FixtureOfficePreview((path, id) async {
          final bytes = await File(path).readAsBytes();
          final photos = listPptxPhotos(bytes);
          expect(readPptxPhotoPreview(bytes, photos.first), replacement.bytes);
          expect(
            readPptxPhotoPreview(bytes, photos[1]),
            readPptxPhotoPreview(input, listPptxPhotos(input)[1]),
          );
          if (concurrentEdit) {
            arrived = await store.commitEdited(
              await store.beginEdit(note),
              originalBytes: input,
              pdfBytes: annotationPdf('arrived'),
              engineVersion: 'fixture-concurrent-editor',
              pageCount: 1,
            );
            await finishPreview.future;
          }
          final output = await File(p.join(temp.path, 'photo-$id.pdf'))
              .writeAsBytes(pdf);
          rendered++;
          return OfficePreviewResult(
            pdfPath: output.path,
            pdfSha256: sha256.convert(pdf).toString(),
            pageCount: 1,
            sourceSha256: sha256.convert(bytes).toString(),
            engineVersion: 'fixture-photo-preview',
          );
        });
        final key = await mount(
          tester,
          FixtureOfficeEngine(),
          previewEngine: preview,
        );
        final launch = find.byKey(const ValueKey('office-replace-pptx-photo'));
        expect(launch, findsOneWidget);
        await tester.runAsync(() => tester.tap(launch));
        final target = find.byKey(const ValueKey('pptx-photo-target-1-1'));
        for (var i = 0; i < 12 && target.evaluate().isEmpty; i++) {
          await drain(tester);
        }
        await tester.tap(target);
        await tester.pump();
        await tester.runAsync(
          () => tester.tap(find.byKey(const ValueKey('pptx-photo-pick'))),
        );
        await drain(tester);
        await tester.tap(find.byKey(const ValueKey('pptx-photo-apply')));
        await tester.pump();
        if (concurrentEdit) {
          for (var i = 0; i < 12 && arrived == null; i++) {
            await drain(tester);
          }
          expect(arrived, isNotNull);
          await tester.pump(const Duration(milliseconds: 300));
          finishPreview.complete();
          for (
            var i = 0;
            i < 12 &&
                find.byType(LinearProgressIndicator).evaluate().isNotEmpty;
            i++
          ) {
            await drain(tester);
          }
          expect(find.byType(LinearProgressIndicator), findsNothing);
          for (
            var i = 0;
            i < 12 &&
                find
                    .textContaining('Revision heads changed')
                    .evaluate()
                    .isEmpty;
            i++
          ) {
            await drain(tester);
          }
        } else {
          await withPumping(tester, key.currentState!.save);
        }
        await tester.pump();
        final latest = (await tester.runAsync(() => store.readLatest(note)))!;
        expect(picker.calls, 1);
        expect(rendered, 1);
        expect(latest.revision.parentRevisionIds, [first.revision.revisionId]);
        expect(
          (await tester.runAsync(
            () => store.readLatest(note, revisionId: first.revision.revisionId),
          ))!.originalBytes,
          input,
        );
        if (concurrentEdit) {
          expect(latest.revision.revisionId, arrived!.revision.revisionId);
          expect(latest.originalBytes, input);
          expect(find.textContaining('Revision heads changed'), findsOneWidget);
          final selector = tester.widget<DropdownButton<String>>(
            find.byKey(const ValueKey('office-edition-selector')),
          );
          expect(
            selector.items!.map((item) => item.value),
            contains(arrived!.revision.revisionId),
          );
          expect(tester.widget<OutlinedButton>(launch).onPressed, isNull);
        } else {
          expect(latest.pdfBytes, pdf);
          expect(
            readPptxPhotoPreview(
              latest.originalBytes,
              listPptxPhotos(latest.originalBytes).first,
            ),
            replacement.bytes,
          );
          expect(find.text('사진을 교체하고 새 원본과 PDF를 저장했습니다.'), findsOneWidget);
        }
      },
    );
  }

  for (final (action, outcome) in [
    ('rotation', 'save'),
    ('rotation', 'system back'),
    ('rotation', 'wrong preview'),
    ('rotation', 'newer source'),
    ('rotation', 'newer source before apply'),
    ('deletion', 'save'),
    ('deletion', 'system back'),
    ('deletion', 'wrong preview'),
    ('deletion', 'newer source'),
    ('deletion', 'newer source before apply'),
  ]) {
    testWidgets('Android PPTX photo $action handles $outcome', (tester) async {
      final removing = action == 'deletion';
      final verb = removing ? 'delete' : 'rotate';
      final input = pptxPhotoFixture();
      final oldPdf = annotationPdf('before PPTX $action');
      final newPdf = annotationPdf('after PPTX $action');
      final ink = Uint8List.fromList([2, 4, 6]);
      final (prior, inkRevision) = await withPumping(tester, () async {
        note = await store.importDocument(
          title: 'Slides',
          fileName: 'slides.pptx',
          bytes: input,
        );
        final prior = await store.commitEdited(
          await store.beginEdit(note),
          originalBytes: input,
          pdfBytes: oldPdf,
          engineVersion: 'before-photo-edit',
          pageCount: 1,
        );
        final annotations = await OfficeAnnotationStore(repository)
            .open(note, prior);
        return (prior, await annotations.saveFiles({'main.sbn2': ink}));
      });
      final picker = _PptxPhotoPicker(
        _PptxPhotoFile(pptxReplacementPhoto().bytes),
      );
      final previousPicker = FilePickerPlatform.instance;
      FilePickerPlatform.instance = picker;
      addTearDown(() => FilePickerPlatform.instance = previousPicker);
      var rendered = 0;
      Uint8List? draft;
      OfficeEdition? arrived;
      Future<void> receiveNewerSource() async {
        arrived = await store.commitEdited(
          await store.beginEdit(note),
          originalBytes: input,
          pdfBytes: annotationPdf('newer PPTX'),
          engineVersion: 'peer',
          pageCount: 1,
        );
      }

      final preview = FixtureOfficePreview((path, id) async {
        rendered++;
        final bytes = draft = await File(path).readAsBytes();
        final archive = ZipDecoder().decodeBytes(bytes);
        final xml = XmlDocument.parse(
          utf8.decode(archive.findFile('ppt/slides/slide1.xml')!.content),
        );
        final pictures = xml.descendants.whereType<XmlElement>().where(
          (element) => element.name.local == 'pic',
        );
        if (removing) {
          expect(listPptxPhotos(bytes).map((photo) => photo.name), [
            'Target photo',
            'Shared media',
          ]);
        } else {
          expect(
            pictures.map(
              (picture) => picture.descendants
                  .whereType<XmlElement>()
                  .singleWhere((element) => element.name.local == 'xfrm')
                  .getAttribute('rot'),
            ),
            ['900000', '6300000', '900000'],
          );
        }
        if (outcome == 'newer source') await receiveNewerSource();
        final file = await File(p.join(temp.path, '$verb-$id.pdf'))
            .writeAsBytes(newPdf);
        return OfficePreviewResult(
          pdfPath: file.path,
          pdfSha256: sha256.convert(newPdf).toString(),
          pageCount: 1,
          sourceSha256: sha256
              .convert(outcome == 'wrong preview' ? input : bytes)
              .toString(),
          engineVersion: 'edited-photo',
        );
      });
      final key = await mount(
        tester,
        FixtureOfficeEngine(),
        previewEngine: preview,
      );
      final launch = find.byKey(ValueKey('office-$verb-pptx-photo'));
      expect(launch, findsOneWidget);
      await tester.ensureVisible(launch);
      await tester.runAsync(() => tester.tap(launch));
      final target = find.byKey(ValueKey('pptx-photo-$verb-target-1-2'));
      for (var i = 0; i < 12 && target.evaluate().isEmpty; i++) {
        await drain(tester);
      }
      expect(target, findsOneWidget);
      if (outcome == 'system back') {
        await tester.binding.handlePopRoute();
      } else {
        await tester.tap(target);
        await tester.pump();
        final thumb = find.byKey(ValueKey('pptx-photo-$verb-thumbnail'));
        for (var i = 0; i < 12 && thumb.evaluate().isEmpty; i++) {
          await drain(tester);
        }
        expect(thumb, findsOneWidget);
        expect(find.byKey(ValueKey('pptx-photo-$verb-pick')), findsNothing);
        if (outcome == 'newer source before apply') {
          await withPumping(tester, receiveNewerSource);
        }
        await tester.tap(find.byKey(ValueKey('pptx-photo-$verb-apply')));
      }
      await tester.pump();
      if (outcome == 'save') {
        await withPumping(tester, key.currentState!.save);
      } else {
        for (var i = 0; i < 12; i++) {
          await drain(tester);
          if (find.byType(LinearProgressIndicator).evaluate().isEmpty) break;
        }
        expect(find.byType(LinearProgressIndicator), findsNothing);
        if (outcome == 'wrong preview') {
          expect(find.textContaining('원본에 연결된 미리보기'), findsOneWidget);
        }
      }
      final latest = await withPumping(tester, () => store.readLatest(note));
      final savedPrior = await withPumping(
        tester,
        () => store.readLatest(note, revisionId: prior.revision.revisionId),
      );
      final savedInk = await withPumping(
        tester,
        () => repository.readFiles(inkRevision),
      );
      expect(picker.calls, 0);
      expect(
        rendered,
        {'system back', 'newer source before apply'}.contains(outcome) ? 0 : 1,
      );
      expect(savedPrior.originalBytes, input);
      expect(savedPrior.pdfBytes, oldPdf);
      expect(savedInk['main.sbn2'], ink);
      if (outcome == 'save') {
        expect(latest.originalBytes, draft);
        expect(latest.pdfBytes, newPdf);
        expect(latest.bindingId, isNot(prior.bindingId));
        expect(latest.revision.parentRevisionIds, [prior.revision.revisionId]);
      } else {
        expect(latest.originalBytes, input);
        expect(
          latest.revision.revisionId,
          arrived?.revision.revisionId ?? prior.revision.revisionId,
        );
      }
    });
  }

  for (final outcome in [
    'save before',
    'save after',
    'system back',
    'newer source',
  ]) {
    testWidgets('Android DOCX paragraph insertion handles $outcome', (
      tester,
    ) async {
      final after = outcome == 'save after';
      final saving = outcome.startsWith('save');
      const inserted = '  새 문단 & 🙂  ';
      final input = annotationOfficeFile('<p>Summary</p><p>Results</p>');
      final edited = annotationOfficeFile(
        after
            ? '<p>Summary</p><p>Results</p><p>새 문단 &amp; 🙂</p>'
            : '<p>새 문단 &amp; 🙂</p><p>Summary</p><p>Results</p>',
      );
      final oldPdf = annotationPdf('before DOCX paragraph insertion');
      final newPdf = annotationPdf('after DOCX paragraph insertion');
      final oldInk = Uint8List.fromList([4, 5, 6]);
      final (prior, priorInk) = await withPumping(tester, () async {
        note = await store.importDocument(
          title: 'Paragraph note',
          fileName: 'report.docx',
          bytes: input,
        );
        final prior = await store.commitEdited(
          await store.beginEdit(note),
          originalBytes: input,
          pdfBytes: oldPdf,
          engineVersion: 'before-paragraph',
          pageCount: 1,
        );
        final annotations = await OfficeAnnotationStore(repository)
            .open(note, prior);
        return (prior, await annotations.saveFiles({'main.sbn2': oldInk}));
      });
      final inserter = _FixtureDocxParagraphInsert(input, edited);
      var previews = 0;
      final preview = FixtureOfficePreview((path, id) async {
        previews++;
        expect(path, inserter.outputPath);
        expect(await File(path).readAsBytes(), edited);
        final output = await File(p.join(temp.path, 'docx-paragraph-$id.pdf'))
            .writeAsBytes(newPdf);
        return OfficePreviewResult(
          pdfPath: output.path,
          pdfSha256: sha256.convert(newPdf).toString(),
          pageCount: 1,
          sourceSha256: sha256.convert(edited).toString(),
          engineVersion: 'docx-paragraph-preview',
        );
      });
      await mount(
        tester,
        FixtureOfficeEngine(),
        previewEngine: preview,
        docxParagraphInsert: inserter,
      );
      final launch = find.byKey(const ValueKey('office-insert-docx-paragraph'));
      await tester.ensureVisible(launch);
      await tester.runAsync(() => tester.tap(launch));
      final field = find.byKey(const ValueKey('docx-paragraph-text'));
      for (var i = 0; i < 12 && field.evaluate().isEmpty; i++) {
        await drain(tester);
      }
      expect(field, findsOneWidget);
      final apply = find.byKey(const ValueKey('docx-paragraph-apply'));
      final afterChip = find.byKey(const ValueKey('docx-paragraph-after'));
      expect(tester.widget<FilledButton>(apply).onPressed, isNull);
      expect(tester.widget<ChoiceChip>(afterChip).onSelected, isNull);
      OfficeEdition? arrived;
      if (outcome == 'system back') {
        await tester.binding.handlePopRoute();
      } else {
        if (after) {
          await tester.tap(find.byKey(const ValueKey('docx-paragraph-anchor')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 350));
          await tester.tap(find.text('2번 문단 · Results').last);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 350));
          await tester.tap(afterChip);
          await tester.pump();
        }
        await tester.enterText(field, inserted);
        await tester.pump();
        if (outcome == 'newer source') {
          arrived = await withPumping(
            tester,
            () async => store.commitEdited(
              await store.beginEdit(note),
              originalBytes: input,
              pdfBytes: annotationPdf('newer DOCX'),
              engineVersion: 'peer',
              pageCount: 1,
            ),
          );
        }
        await tester.tap(apply);
      }
      await tester.pump();
      for (var i = 0; i < 12; i++) {
        await drain(tester);
        if (!File(inserter.sourcePath!).parent.existsSync()) break;
      }
      expect(File(inserter.sourcePath!).parent.existsSync(), isFalse);
      expect(previews, saving ? 1 : 0);
      expect(inserter.insertedText, saving ? inserted : null);
      if (saving) {
        expect(inserter.anchor, after ? 1 : 0);
        expect(
          inserter.position,
          after ? DocxParagraphPosition.after : DocxParagraphPosition.before,
        );
      }
      final latest = await withPumping(tester, () => store.readLatest(note));
      final savedPrior = await withPumping(
        tester,
        () => store.readLatest(note, revisionId: prior.revision.revisionId),
      );
      final savedInk = await withPumping(
        tester,
        () => repository.readFiles(priorInk),
      );
      expect(savedPrior.originalBytes, input);
      expect(savedPrior.pdfBytes, oldPdf);
      expect(savedInk['main.sbn2'], oldInk);
      if (saving) {
        expect(latest.originalBytes, edited);
        expect(latest.pdfBytes, newPdf);
        expect(latest.bindingId, isNot(prior.bindingId));
        expect(latest.revision.parentRevisionIds, [prior.revision.revisionId]);
        expect(find.text('본문 문단을 추가하고 새 원본과 PDF를 저장했습니다.'), findsOneWidget);
      } else {
        expect(latest.originalBytes, input);
        expect(
          latest.revision.revisionId,
          arrived?.revision.revisionId ?? prior.revision.revisionId,
        );
      }
    });
  }

  testWidgets('Android DOCX offers original table insertion', (tester) async {
    await mount(tester, FixtureOfficeEngine());
    expect(
      find.byKey(const ValueKey('office-insert-docx-table')),
      findsOneWidget,
    );
  });

  testWidgets('Android DOCX offers original body text editing', (tester) async {
    await mount(tester, FixtureOfficeEngine());
    expect(
      find.byKey(const ValueKey('office-edit-docx-body-text')),
      findsOneWidget,
    );
  });

  testWidgets('Android DOCX offers original table cell text editing', (
    tester,
  ) async {
    await mount(tester, FixtureOfficeEngine());
    expect(
      find.byKey(const ValueKey('office-edit-docx-table-cell')),
      findsOneWidget,
    );
  });

  for (final outcome in ['save', 'system back', 'wrong cell', 'newer source']) {
    testWidgets('Android DOCX existing table cell edit handles $outcome', (
      tester,
    ) async {
      const changedText = '빈 셀에 넣은 글자';
      final input = annotationOfficeFile(
        '<tbl><tr><tc>left</tc><tc/></tr></tbl>',
      );
      final edited = annotationOfficeFile(
        '<tbl><tr><tc>left</tc><tc>$changedText</tc></tr></tbl>',
      );
      final originalPdf = annotationPdf('Original table');
      final editedPdf = annotationPdf('Populated table cell');
      final ink = Uint8List.fromList([9, 7, 5]);
      final (before, annotation) = await withPumping(tester, () async {
        note = await store.importDocument(
          title: 'Word table',
          fileName: 'word-table.docx',
          bytes: input,
        );
        final edition = await store.commitEdited(
          await store.beginEdit(note),
          originalBytes: input,
          pdfBytes: originalPdf,
          pageCount: 1,
          engineVersion: 'fixture-before-cell',
        );
        final session = await OfficeAnnotationStore(repository)
            .open(note, edition);
        return (edition, await session.saveFiles({'main.sbn2': ink}));
      });
      final editor = _FixtureDocxCellText(
        input,
        edited,
        wrongAddress: outcome == 'wrong cell',
      );
      var previews = 0;
      final preview = FixtureOfficePreview((sourcePath, sessionId) async {
        previews++;
        expect(sourcePath, editor.outputPath);
        expect(await File(sourcePath).readAsBytes(), edited);
        final path = p.join(temp.path, 'docx-cell-$sessionId.pdf');
        await File(path).writeAsBytes(editedPdf);
        return OfficePreviewResult(
          pdfPath: path,
          pdfSha256: sha256.convert(editedPdf).toString(),
          pageCount: 1,
          sourceSha256: sha256.convert(edited).toString(),
          engineVersion: 'fixture-cell-preview',
        );
      });
      await mount(
        tester,
        FixtureOfficeEngine(),
        previewEngine: preview,
        docxBodyText: editor,
      );
      final launch = find.byKey(const ValueKey('office-edit-docx-table-cell'));
      await Scrollable.ensureVisible(tester.element(launch), alignment: 0.5);
      await tester.pump();
      await tester.runAsync(() => tester.tap(launch));
      final field = find.byKey(const ValueKey('docx-body-text-input'));
      for (var i = 0; i < 12 && field.evaluate().isEmpty; i++) {
        await drain(tester);
      }
      expect(find.text('DOCX 표 셀 글자 수정'), findsOneWidget);
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      await tester.enterText(field, changedText);
      await tester.pump();
      OfficeEdition? newer;
      if (outcome == 'newer source') {
        newer = await withPumping(tester, () async {
          return store.commitEdited(
            await store.beginEdit(note),
            originalBytes: input,
            pdfBytes: annotationPdf('Peer table revision'),
            pageCount: 1,
            engineVersion: 'fixture-peer',
          );
        });
      }
      if (outcome == 'system back') {
        await tester.binding.handlePopRoute();
      } else {
        await tester.tap(find.byKey(const ValueKey('docx-body-text-confirm')));
      }
      await tester.pump();
      for (var i = 0; i < 12; i++) {
        await drain(tester);
        if (!File(editor.sourcePath!).parent.existsSync()) break;
      }
      expect(File(editor.sourcePath!).parent.existsSync(), isFalse);
      expect(
        editor.replacement,
        ['save', 'wrong cell'].contains(outcome) ? changedText : isNull,
      );
      expect(previews, outcome == 'save' ? 1 : 0);
      final latest = await withPumping(tester, () => store.readLatest(note));
      final prior = await withPumping(
        tester,
        () => store.readLatest(note, revisionId: before.revision.revisionId),
      );
      final savedInk = await withPumping(
        tester,
        () => repository.readFiles(annotation),
      );
      expect(prior.originalBytes, input);
      expect(prior.pdfBytes, originalPdf);
      expect(savedInk['main.sbn2'], ink);
      if (outcome == 'save') {
        expect(latest.originalBytes, edited);
        expect(latest.pdfBytes, editedPdf);
        expect(latest.revision.parentRevisionIds, [before.revision.revisionId]);
        expect(latest.bindingId, isNot(before.bindingId));
      } else {
        expect(latest.originalBytes, input);
        expect(
          latest.revision.revisionId,
          (newer ?? before).revision.revisionId,
        );
      }
    });
  }

  for (final (windows, outcome) in [
    (false, 'save'),
    (true, 'save'),
    (true, 'stale source'),
    (false, 'wrong count'),
    (false, 'cancel pending'),
  ]) {
    testWidgets(
      '${windows ? 'Windows' : 'Android'} DOCX find and replace handles $outcome',
      (tester) async {
        final original = annotationOfficeFile('DOCX body with repeated words');
        final edited = annotationOfficeFile('DOCX body with replacements');
        final originalPdf = annotationPdf('before replacement');
        final editedPdf = annotationPdf('after replacement');
        final oldInk = Uint8List.fromList([7, 8, 9]);
        final (before, ink) = await withPumping(tester, () async {
          note = await store.importDocument(
            title: 'Find words',
            fileName: 'words.docx',
            bytes: original,
          );
          final edition = await store.commitEdited(
            await store.beginEdit(note),
            originalBytes: original,
            pdfBytes: originalPdf,
            engineVersion: 'fixture-before',
            pageCount: 1,
          );
          final annotations = await OfficeAnnotationStore(repository)
              .open(note, edition);
          return (edition, await annotations.saveFiles({'main.sbn2': oldInk}));
        });
        final release = outcome == 'cancel pending' ? Completer<void>() : null;
        final editor = _FixtureDocxFindReplace(
          original,
          edited,
          wrongCount: outcome == 'wrong count',
          releasePreview: release,
        );
        final editedHash = sha256.convert(edited).toString();
        var renders = 0;
        Future<File> render(String path) async {
          renders++;
          expect(path, editor.outputPath);
          expect(await File(path).readAsBytes(), edited);
          return File(p.join(temp.path, 'find-replace-preview.pdf'))
              .writeAsBytes(editedPdf);
        }

        final windowsEngine = WindowsOfficeEngine(
          runner: (request) async {
            expect(request['mode'], 'inspect');
            expect(request['preview'], true);
            final pdf = await render(request['sourcePath'] as String);
            return {
              'snapshot': {
                ...wordPreviewSnapshot(editedHash),
                'previewPdfPath': pdf.path,
                'previewPageCount': 1,
              },
            };
          },
        );
        final androidPreview = FixtureOfficePreview((path, _) async {
          final pdf = await render(path);
          return OfficePreviewResult(
            pdfPath: pdf.path,
            pdfSha256: sha256.convert(editedPdf).toString(),
            pageCount: 1,
            sourceSha256: editedHash,
            engineVersion: 'android-test',
          );
        });
        await mount(
          tester,
          windows ? null : FixtureOfficeEngine(),
          windowsEngine: windows ? windowsEngine : null,
          previewEngine: windows ? null : androidPreview,
          docxFindReplace: editor,
        );
        if (release != null) {
          addTearDown(() {
            if (!release.isCompleted) release.complete();
          });
        }
        final launch = find.byKey(
          const ValueKey('office-edit-docx-find-replace'),
        );
        expect(launch, findsOneWidget);
        await tester.ensureVisible(launch);
        await tester.runAsync(() => tester.tap(launch));
        Finder control(String name) =>
            find.byKey(ValueKey('docx-find-replace-$name'));
        final findField = control('find');
        final confirm = control('confirm');
        for (var i = 0; i < 12 && findField.evaluate().isEmpty; i++) {
          await drain(tester);
        }
        expect(findField, findsOneWidget);
        bool canConfirm() =>
            tester.widget<FilledButton>(confirm).onPressed != null;
        expect(canConfirm(), isFalse);

        Future<void> search(String find) async {
          await tester.ensureVisible(findField);
          await tester.enterText(findField, find);
          await tester.pump();
          expect(canConfirm(), isFalse);
          await tester.ensureVisible(control('preview'));
          await tester.runAsync(() => tester.tap(control('preview')));
          await drain(tester);
        }

        await search('First');
        final draft = File(editor.sourcePath!).parent;
        OfficeEdition? newer;
        final replacement = windows ? '' : 'Second';
        if (release != null) {
          expect(canConfirm(), isFalse);
          await tester.tap(control('cancel'));
          await drain(tester);
          expect(draft.existsSync(), isTrue);
          release.complete();
        } else {
          expect(find.text('2곳 · 1개 문단'), findsOneWidget);
          expect(find.textContaining('First draft · First'), findsOneWidget);
          expect(canConfirm(), isTrue);
          if (outcome == 'save') {
            await search('first');
            expect(find.text('일치하는 본문 글자가 없습니다.'), findsOneWidget);
            expect(canConfirm(), isFalse);
            await search('First');
          }
          final replacementField = control('replacement');
          await tester.ensureVisible(replacementField);
          await tester.enterText(replacementField, 'First');
          await tester.pump();
          expect(canConfirm(), isFalse);
          await tester.enterText(replacementField, replacement);
          await tester.pump();
          expect(canConfirm(), isTrue);
          if (outcome == 'stale source') {
            newer = await withPumping(
              tester,
              () async => store.commitEdited(
                await store.beginEdit(note),
                originalBytes: original,
                pdfBytes: annotationPdf('peer'),
                engineVersion: 'peer',
                pageCount: 1,
              ),
            );
          }
          await tester.runAsync(() => tester.tap(confirm));
        }
        for (var i = 0; i < 24 && draft.existsSync(); i++) {
          await drain(tester);
        }
        expect(draft.existsSync(), isFalse);
        expect(
          editor.replacement,
          ['save', 'wrong count'].contains(outcome) ? replacement : null,
        );
        expect(renders, outcome == 'save' ? 1 : 0);
        final latest = await withPumping(tester, () => store.readLatest(note));
        final prior = await withPumping(
          tester,
          () => store.readLatest(note, revisionId: before.revision.revisionId),
        );
        final savedInk = await withPumping(
          tester,
          () => repository.readFiles(ink),
        );
        expect(prior.originalBytes, original);
        expect(prior.pdfBytes, originalPdf);
        expect(savedInk['main.sbn2'], oldInk);
        expect(latest.originalBytes, outcome == 'save' ? edited : original);
        if (outcome == 'save') {
          expect(latest.pdfBytes, editedPdf);
          expect(latest.revision.parentRevisionIds, [
            before.revision.revisionId,
          ]);
        } else {
          expect(
            latest.revision.revisionId,
            (newer ?? before).revision.revisionId,
          );
        }
      },
    );
  }

  for (final outcome in [
    'save',
    'unrelated pending revision',
    'related pending revision',
    'stale source',
    'wrong target',
    'wrong PDF',
  ]) {
    testWidgets('Android DOCX body edit handles $outcome', (tester) async {
      final saves =
          outcome == 'save' || outcome == 'unrelated pending revision';
      final input = OfficeTemplates.create(
        OfficeTemplateKind.document,
        title: 'First draft',
      ).bytes;
      const changedText = '수정한 본문 & 결과';
      final edited = OfficeTemplates.create(
        OfficeTemplateKind.document,
        title: changedText,
      ).bytes;
      final originalPdf = annotationPdf('First draft');
      final editedPdf = annotationPdf('Edited result');
      final ink = Uint8List.fromList([9, 7, 5]);
      final (before, annotation) = await withPumping(tester, () async {
        note = await store.importDocument(
          title: 'Word note',
          fileName: 'word-note.docx',
          bytes: input,
        );
        final before = await store.commitEdited(
          await store.beginEdit(note),
          originalBytes: input,
          pdfBytes: originalPdf,
          pageCount: 1,
          engineVersion: 'fixture-before',
        );
        final session = await OfficeAnnotationStore(repository)
            .open(note, before);
        return (before, await session.saveFiles({'main.sbn2': ink}));
      });
      final editor = _FixtureDocxBodyText(
        input,
        edited,
        wrongTarget: outcome == 'wrong target',
      );
      var previews = 0;
      final preview = FixtureOfficePreview((sourcePath, sessionId) async {
        previews++;
        expect(sourcePath, editor.outputPath);
        expect(await File(sourcePath).readAsBytes(), edited);
        final path = p.join(temp.path, 'body-$sessionId.pdf');
        await File(path).writeAsBytes(editedPdf);
        return OfficePreviewResult(
          pdfPath: path,
          pdfSha256: sha256.convert(editedPdf).toString(),
          pageCount: 1,
          sourceSha256: sha256
              .convert(outcome == 'wrong PDF' ? input : edited)
              .toString(),
          engineVersion: 'fixture-body-preview',
        );
      });
      await mount(
        tester,
        FixtureOfficeEngine(),
        previewEngine: preview,
        docxBodyText: editor,
      );
      final launch = find.byKey(const ValueKey('office-edit-docx-body-text'));
      await tester.ensureVisible(launch);
      await tester.runAsync(() => tester.tap(launch));
      final field = find.byKey(const ValueKey('docx-body-text-input'));
      for (var i = 0; i < 12 && field.evaluate().isEmpty; i++) {
        await drain(tester);
      }
      expect(field, findsOneWidget);
      await tester.enterText(field, changedText);
      await tester.pump();
      if (outcome.endsWith('pending revision')) {
        await withPumping(
          tester,
          () => receiveIncompleteSource(
            related: outcome == 'related pending revision' ? note : null,
          ),
        );
      }
      OfficeEdition? newer;
      if (outcome == 'stale source') {
        newer = await withPumping(tester, () async {
          return store.commitEdited(
            await store.beginEdit(note),
            originalBytes: input,
            pdfBytes: annotationPdf('Peer revision'),
            pageCount: 1,
            engineVersion: 'fixture-peer',
          );
        });
      }
      await tester.tap(find.byKey(const ValueKey('docx-body-text-confirm')));
      await tester.pump();
      for (var i = 0; i < 12; i++) {
        await drain(tester);
        if (!File(editor.sourcePath!).parent.existsSync()) break;
      }
      expect(File(editor.sourcePath!).parent.existsSync(), isFalse);
      expect(
        editor.replacement,
        outcome == 'stale source' ? isNull : changedText,
      );
      expect(
        previews,
        saves || outcome == 'wrong PDF' || outcome == 'related pending revision'
            ? 1
            : 0,
      );
      final latest = await withPumping(tester, () => store.readLatest(note));
      final prior = await withPumping(
        tester,
        () => store.readLatest(note, revisionId: before.revision.revisionId),
      );
      final savedInk = await withPumping(
        tester,
        () => repository.readFiles(annotation),
      );
      expect(prior.originalBytes, input);
      expect(prior.pdfBytes, originalPdf);
      expect(savedInk['main.sbn2'], ink);
      if (outcome.endsWith('pending revision')) {
        expect(repository.pendingRevisionCount, 1);
      }
      if (saves) {
        expect(latest.originalBytes, edited);
        expect(latest.pdfBytes, editedPdf);
        expect(latest.revision.parentRevisionIds, [before.revision.revisionId]);
        expect(latest.bindingId, isNot(before.bindingId));
      } else {
        expect(latest.originalBytes, input);
        expect(
          latest.revision.revisionId,
          (newer ?? before).revision.revisionId,
        );
        if (outcome == 'related pending revision') {
          expect(
            find.textContaining('Repair or finish receiving revisions'),
            findsOneWidget,
          );
        }
      }
    });
  }

  for (final (windows, outcome) in [
    (false, 'save'),
    (true, 'save'),
    (false, 'wrong size'),
    (true, 'newer source'),
  ]) {
    testWidgets(
      '${windows ? 'Windows' : 'Android'} DOCX table structure handles $outcome',
      (tester) async {
        final original = annotationOfficeFile('DOCX table with two rows');
        final candidate = annotationOfficeFile('DOCX table with three rows');
        final originalPdf = annotationPdf('before table edit');
        final editedPdf = annotationPdf('after table edit');
        final oldInk = Uint8List.fromList([9, 2, 7]);
        final (before, ink) = await withPumping(tester, () async {
          note = await store.importDocument(
            title: 'Edit table',
            fileName: 'table.docx',
            bytes: original,
          );
          final prior = await store.commitEdited(
            await store.beginEdit(note),
            originalBytes: original,
            pdfBytes: originalPdf,
            engineVersion: 'before',
            pageCount: 1,
          );
          final annotations = await OfficeAnnotationStore(repository)
              .open(note, prior);
          return (prior, await annotations.saveFiles({'main.sbn2': oldInk}));
        });
        final editor = _FixtureDocxTableStructure(
          original,
          candidate,
          wrongSize: outcome == 'wrong size',
        );
        var renders = 0;
        Future<File> render(String path) async {
          renders++;
          expect(path, editor.outputPath);
          expect(await File(path).readAsBytes(), candidate);
          return File(p.join(temp.path, 'docx-structure-preview.pdf'))
              .writeAsBytes(editedPdf);
        }

        final candidateHash = sha256.convert(candidate).toString();
        final windowsEngine = WindowsOfficeEngine(
          runner: (request) async {
            expect(request['mode'], 'inspect');
            expect(request['preview'], true);
            final pdf = await render(request['sourcePath'] as String);
            return {
              'snapshot': {
                ...wordPreviewSnapshot(candidateHash),
                'previewPdfPath': pdf.path,
                'previewPageCount': 1,
              },
            };
          },
        );
        final androidPreview = FixtureOfficePreview((path, _) async {
          final pdf = await render(path);
          return OfficePreviewResult(
            pdfPath: pdf.path,
            pdfSha256: sha256.convert(editedPdf).toString(),
            pageCount: 1,
            sourceSha256: candidateHash,
            engineVersion: 'android-test',
          );
        });
        await mount(
          tester,
          windows ? null : FixtureOfficeEngine(),
          windowsEngine: windows ? windowsEngine : null,
          previewEngine: windows ? null : androidPreview,
          docxTableStructure: editor,
        );
        final launch = find.byKey(
          const ValueKey('office-edit-docx-table-structure'),
        );
        await tester.ensureVisible(launch);
        await tester.runAsync(() => tester.tap(launch));
        Finder control(String name) =>
            find.byKey(ValueKey('docx-table-structure-$name'));
        final action = control('action');
        for (var i = 0; i < 12 && action.evaluate().isEmpty; i++) {
          await drain(tester);
        }
        Future<void> choose(Finder menu, String option) async {
          await tester.ensureVisible(menu);
          await tester.tap(menu);
          await tester.pump(const Duration(milliseconds: 350));
          await tester.tap(find.text(option).last);
          await tester.pump(const Duration(milliseconds: 350));
        }

        await choose(action, '행 추가');
        await choose(control('position'), '1행');
        OfficeEdition? received;
        if (outcome == 'newer source') {
          received = await withPumping(
            tester,
            () async => store.commitEdited(
              await store.beginEdit(note),
              originalBytes: original,
              pdfBytes: annotationPdf('peer'),
              engineVersion: 'peer',
              pageCount: 1,
            ),
          );
        }
        await tester.runAsync(() => tester.tap(control('confirm')));
        final draft = File(editor.sourcePath!).parent;
        for (var i = 0; i < 24 && draft.existsSync(); i++) {
          await drain(tester);
        }
        expect(draft.existsSync(), isFalse);
        expect(editor.edits, outcome == 'newer source' ? 0 : 1);
        expect(renders, outcome == 'save' ? 1 : 0);
        final latest = await withPumping(tester, () => store.readLatest(note));
        final prior = await withPumping(
          tester,
          () => store.readLatest(note, revisionId: before.revision.revisionId),
        );
        final savedInk = await withPumping(
          tester,
          () => repository.readFiles(ink),
        );
        expect(prior.originalBytes, original);
        expect(prior.pdfBytes, originalPdf);
        expect(savedInk['main.sbn2'], oldInk);
        if (outcome == 'save') {
          expect(latest.originalBytes, candidate);
          expect(latest.pdfBytes, editedPdf);
          expect(latest.revision.parentRevisionIds, [
            before.revision.revisionId,
          ]);
        } else {
          expect(
            latest.revision.revisionId,
            (received ?? before).revision.revisionId,
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final outcome in [
    'save',
    'prepend',
    'system back',
    'wrong table reply',
    'wrong preview',
    'newer source before apply',
    'newer source during preview',
  ]) {
    testWidgets('Android DOCX table handles $outcome', (tester) async {
      final prepend = outcome == 'prepend';
      final input = annotationOfficeFile('<p>Summary</p><p>Results</p>');
      const table = '<tbl><tr><tc>행 1</tc></tr></tbl>';
      final edited = annotationOfficeFile(
        prepend
            ? '$table<p>Summary</p><p>Results</p>'
            : '<p>Summary</p><p>Results</p>$table',
      );
      final oldPdf = annotationPdf('before DOCX table');
      final newPdf =
          await (pw.Document()
                ..addPage(pw.Page(build: (_) => pw.Container()))
                ..addPage(pw.Page(build: (_) => pw.Container())))
              .save();
      final oldInk = Uint8List.fromList([4, 5, 6]);
      final (prior, priorInk) = await withPumping(tester, () async {
        note = await store.importDocument(
          title: 'Table note',
          fileName: 'report.docx',
          bytes: input,
        );
        final prior = await store.commitEdited(
          await store.beginEdit(note),
          originalBytes: input,
          pdfBytes: oldPdf,
          engineVersion: 'before-table',
          pageCount: 1,
        );
        final annotations = await OfficeAnnotationStore(repository)
            .open(note, prior);
        return (prior, await annotations.saveFiles({'main.sbn2': oldInk}));
      });
      final inserter = _FixtureDocxTableInsert(
        input,
        edited,
        wrongTablePosition: outcome == 'wrong table reply',
      );
      OfficeEdition? arrived;
      Future<OfficeEdition> receiveNewerSource() async => store.commitEdited(
        await store.beginEdit(note),
        originalBytes: input,
        pdfBytes: annotationPdf('newer DOCX'),
        engineVersion: 'peer',
        pageCount: 1,
      );

      var previews = 0;
      final preview = FixtureOfficePreview((path, id) async {
        previews++;
        expect(path, inserter.outputPath);
        expect(await File(path).readAsBytes(), edited);
        if (outcome == 'newer source during preview') {
          arrived = await receiveNewerSource();
        }
        final output = await File(p.join(temp.path, 'docx-table-$id.pdf'))
            .writeAsBytes(newPdf);
        return OfficePreviewResult(
          pdfPath: output.path,
          pdfSha256: sha256.convert(newPdf).toString(),
          pageCount: 2,
          sourceSha256: sha256
              .convert(outcome == 'wrong preview' ? input : edited)
              .toString(),
          engineVersion: 'docx-table-preview',
        );
      });
      await mount(
        tester,
        FixtureOfficeEngine(),
        previewEngine: preview,
        docxTableInsert: inserter,
      );
      final launch = find.byKey(const ValueKey('office-insert-docx-table'));
      await tester.ensureVisible(launch);
      await tester.runAsync(() => tester.tap(launch));
      final location = find.byKey(const ValueKey('docx-table-location'));
      for (var i = 0; i < 12 && location.evaluate().isEmpty; i++) {
        await drain(tester);
      }
      expect(location, findsOneWidget);
      Future<void> selectOption(Finder field, String option) async {
        await tester.tap(field);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.tap(find.text(option).last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
      }

      if (outcome == 'system back') {
        await tester.binding.handlePopRoute();
      } else {
        if (prepend) {
          await selectOption(
            find.byKey(const ValueKey('docx-table-rows')),
            '1',
          );
          await selectOption(
            find.byKey(const ValueKey('docx-table-columns')),
            '1',
          );
        } else {
          await selectOption(location, '2번 문단 뒤 · Results');
        }
        if (outcome == 'save') {
          await tester.enterText(
            find.byKey(const ValueKey('docx-table-cell-1-1')),
            '  제목 & 값  ',
          );
          await tester.tap(find.byKey(const ValueKey('docx-table-row-2')));
          await tester.pump();
          await tester.enterText(
            find.byKey(const ValueKey('docx-table-cell-2-2')),
            '둘째 행',
          );
        }
        if (outcome == 'newer source before apply') {
          arrived = await withPumping(tester, receiveNewerSource);
        }
        await tester.tap(find.byKey(const ValueKey('docx-table-apply')));
      }
      await tester.pump();
      for (var i = 0; i < 12; i++) {
        await drain(tester);
        if (!File(inserter.sourcePath!).parent.existsSync()) break;
      }
      expect(File(inserter.sourcePath!).parent.existsSync(), isFalse);
      if ({'system back', 'newer source before apply'}.contains(outcome)) {
        expect(inserter.insertedCells, isNull);
      } else if (outcome == 'save') {
        expect(inserter.anchor, 1);
        expect(inserter.insertedCells, [
          ['  제목 & 값  ', ''],
          ['', '둘째 행'],
        ]);
      } else if (prepend) {
        expect(inserter.anchor, isNull);
        expect(inserter.insertedCells, [
          [''],
        ]);
      } else {
        expect(inserter.anchor, 1);
        expect(inserter.insertedCells, [
          ['', ''],
          ['', ''],
        ]);
      }
      expect(
        previews,
        {
              'save',
              'prepend',
              'wrong preview',
              'newer source during preview',
            }.contains(outcome)
            ? 1
            : 0,
      );
      final latest = await withPumping(tester, () => store.readLatest(note));
      final savedPrior = await withPumping(
        tester,
        () => store.readLatest(note, revisionId: prior.revision.revisionId),
      );
      final savedInk = await withPumping(
        tester,
        () => repository.readFiles(priorInk),
      );
      expect(savedPrior.originalBytes, input);
      expect(savedPrior.pdfBytes, oldPdf);
      expect(savedPrior.bindingId, prior.bindingId);
      expect(savedInk['main.sbn2'], oldInk);
      if (outcome == 'save' || prepend) {
        expect(latest.originalBytes, edited);
        expect(latest.pdfBytes, newPdf);
        expect(latest.pageCount, 2);
        expect(latest.bindingId, isNot(prior.bindingId));
        expect(latest.revision.parentRevisionIds, [prior.revision.revisionId]);
        expect(find.text('표를 추가하고 새 원본과 PDF를 저장했습니다.'), findsOneWidget);
      } else {
        expect(latest.originalBytes, input);
        expect(
          latest.revision.revisionId,
          arrived?.revision.revisionId ?? prior.revision.revisionId,
        );
      }
    });
  }

  testWidgets(
    'Android DOCX inserts a photo and preserves the previous PDF and ink',
    (tester) async {
      final image = pptxReplacementPhoto();
      final input = OfficeTemplates.create(
        OfficeTemplateKind.document,
        title: 'Photo note',
      ).bytes;
      final candidate = docxPhotoFixture(image.bytes, removeSecond: true);
      final oldPdf = annotationPdf('before photo insertion');
      final newPdf = annotationPdf('after photo insertion');
      final ink = Uint8List.fromList([1, 3, 5]);
      final (prior, inkRevision) = await withPumping(tester, () async {
        note = await store.importDocument(
          title: 'Photo note',
          fileName: 'photos.docx',
          bytes: input,
        );
        final prior = await store.commitEdited(
          await store.beginEdit(note),
          originalBytes: input,
          pdfBytes: oldPdf,
          engineVersion: 'before-photo',
          pageCount: 1,
        );
        final annotations = await OfficeAnnotationStore(repository)
            .open(note, prior);
        return (prior, await annotations.saveFiles({'main.sbn2': ink}));
      });
      final inserter = _FixtureDocxPhotoInsert(input, candidate, image);
      final picker = _PptxPhotoPicker(_PptxPhotoFile(image.bytes));
      final previousPicker = FilePickerPlatform.instance;
      FilePickerPlatform.instance = picker;
      addTearDown(() => FilePickerPlatform.instance = previousPicker);
      var rendered = 0;
      final preview = FixtureOfficePreview((path, id) async {
        rendered++;
        expect(path, inserter.outputPath);
        expect(await File(path).readAsBytes(), candidate);
        final pdf = await File(p.join(temp.path, 'docx-photo-insert-$id.pdf'))
            .writeAsBytes(newPdf);
        return OfficePreviewResult(
          pdfPath: pdf.path,
          pdfSha256: sha256.convert(newPdf).toString(),
          sourceSha256: sha256.convert(candidate).toString(),
          pageCount: 1,
          engineVersion: 'photo-insertion',
        );
      });
      await mount(
        tester,
        FixtureOfficeEngine(),
        previewEngine: preview,
        docxParagraphInsert: inserter,
      );
      final launch = find.byKey(const ValueKey('office-add-docx-photo'));
      expect(launch, findsOneWidget);
      await tester.ensureVisible(launch);
      await tester.runAsync(() => tester.tap(launch));
      final target = find.byKey(
        const ValueKey('docx-photo-add-target-1-after'),
      );
      for (var i = 0; i < 12 && target.evaluate().isEmpty; i++) {
        await drain(tester);
      }
      expect(target, findsOneWidget);
      expect(
        find.byKey(const ValueKey('docx-photo-add-target-0-after')),
        findsNothing,
      );
      final apply = find.byKey(const ValueKey('docx-photo-add-apply'));
      expect(tester.widget<FilledButton>(apply).onPressed, isNull);
      await tester.ensureVisible(target);
      await tester.pump();
      await tester.tap(target);
      await tester.pump();
      await tester.runAsync(
        () => tester.tap(find.byKey(const ValueKey('docx-photo-add-pick'))),
      );
      for (
        var i = 0;
        i < 12 && tester.widget<FilledButton>(apply).onPressed == null;
        i++
      ) {
        await drain(tester);
      }
      expect(tester.widget<FilledButton>(apply).onPressed, isNotNull);
      await tester.tap(apply);
      await tester.pump();
      final work = File(inserter.sourcePath!).parent;
      for (var i = 0; i < 12 && work.existsSync(); i++) {
        await drain(tester);
      }
      expect(work.existsSync(), isFalse);
      expect(picker.calls, 1);
      expect(inserter.anchor, 1);
      expect(inserter.position, DocxParagraphPosition.after);
      expect(rendered, 1);
      final latest = await withPumping(tester, () => store.readLatest(note));
      final savedPrior = await withPumping(
        tester,
        () => store.readLatest(note, revisionId: prior.revision.revisionId),
      );
      final savedInk = await withPumping(
        tester,
        () => repository.readFiles(inkRevision),
      );
      expect(latest.originalBytes, candidate);
      expect(latest.pdfBytes, newPdf);
      expect(latest.bindingId, isNot(prior.bindingId));
      expect(latest.revision.parentRevisionIds, [prior.revision.revisionId]);
      expect(savedPrior.originalBytes, input);
      expect(savedPrior.pdfBytes, oldPdf);
      expect(savedInk['main.sbn2'], ink);
    },
  );

  testWidgets('Android DOCX offers targeted original photo replacement', (
    tester,
  ) async {
    await mount(tester, FixtureOfficeEngine());
    expect(find.byKey(const ValueKey('office-edit-original')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('office-replace-docx-photo')),
      findsOneWidget,
    );
  });

  for (final (action, outcome) in [
    ('replacement', 'save'),
    ('replacement', 'system back'),
    ('replacement', 'same photo'),
    ('replacement', 'wrong preview'),
    ('replacement', 'newer source'),
    ('deletion', 'save'),
    ('deletion', 'system back'),
    ('deletion', 'wrong preview'),
    ('deletion', 'newer source'),
    ('deletion', 'newer source before apply'),
    ('rotation', 'save'),
    ('rotation', 'system back'),
    ('rotation', 'wrong preview'),
    ('rotation', 'newer source'),
    ('rotation', 'newer source before apply'),
  ]) {
    final replacing = action == 'replacement';
    final removing = action == 'deletion';
    final rotating = action == 'rotation';
    testWidgets('Android DOCX photo $action handles $outcome', (tester) async {
      final photoSource = pptxPhotoFixture();
      final originalPhoto = readPptxPhotoPreview(
        photoSource,
        listPptxPhotos(photoSource).first,
      )!;
      final image = pptxReplacementPhoto();
      final input = docxPhotoFixture(originalPhoto);
      final candidate = docxPhotoFixture(
        originalPhoto,
        replacement: replacing ? image.bytes : null,
        removeSecond: removing,
        rotateSecond: rotating,
      );
      final oldPdf = annotationPdf('before DOCX photo');
      final newPdf = annotationPdf('after DOCX photo');
      final ink = Uint8List.fromList([1, 3, 5]);
      final (prior, inkRevision) = await withPumping(tester, () async {
        note = await store.importDocument(
          title: 'Photo note',
          fileName: 'photos.docx',
          bytes: input,
        );
        final prior = await store.commitEdited(
          await store.beginEdit(note),
          originalBytes: input,
          pdfBytes: oldPdf,
          engineVersion: 'before-photo',
          pageCount: 1,
        );
        final annotations = await OfficeAnnotationStore(repository)
            .open(note, prior);
        return (prior, await annotations.saveFiles({'main.sbn2': ink}));
      });
      final replacement = _FixtureDocxPhotoReplacement(
        input,
        candidate,
        originalPhoto,
      );
      final picker = _PptxPhotoPicker(
        _PptxPhotoFile(outcome == 'same photo' ? originalPhoto : image.bytes),
      );
      final previousPicker = FilePickerPlatform.instance;
      FilePickerPlatform.instance = picker;
      addTearDown(() => FilePickerPlatform.instance = previousPicker);
      var rendered = 0;
      OfficeEdition? arrived;
      Future<OfficeEdition> receiveNewerSource() async => store.commitEdited(
        await store.beginEdit(note),
        originalBytes: input,
        pdfBytes: annotationPdf('newer peer DOCX'),
        engineVersion: 'peer',
        pageCount: 1,
      );
      final preview = FixtureOfficePreview((path, id) async {
        rendered++;
        expect(path, replacement.outputPath);
        expect(p.extension(path), '.docx');
        expect(await File(path).readAsBytes(), candidate);
        if (outcome == 'newer source') {
          arrived = await receiveNewerSource();
        }
        final output = await File(p.join(temp.path, 'docx-photo-$id.pdf'))
            .writeAsBytes(newPdf);
        return OfficePreviewResult(
          pdfPath: output.path,
          pdfSha256: sha256.convert(newPdf).toString(),
          pageCount: 1,
          sourceSha256: sha256
              .convert(outcome == 'wrong preview' ? input : candidate)
              .toString(),
          engineVersion: 'docx-photo',
        );
      });
      await mount(
        tester,
        FixtureOfficeEngine(),
        previewEngine: preview,
        docxPhotoReplacement: replacement,
      );
      final launch = find.byKey(
        ValueKey(switch (action) {
          'deletion' => 'office-delete-docx-photo',
          'rotation' => 'office-rotate-docx-photo',
          _ => 'office-replace-docx-photo',
        }),
      );
      expect(launch, findsOneWidget);
      await tester.ensureVisible(launch);
      await tester.runAsync(() => tester.tap(launch));
      final keyPrefix = switch (action) {
        'deletion' => 'docx-photo-delete',
        'rotation' => 'docx-photo-rotate',
        _ => 'docx-photo',
      };
      final target = find.byKey(ValueKey('$keyPrefix-target-2'));
      for (var i = 0; i < 12 && target.evaluate().isEmpty; i++) {
        await drain(tester);
      }
      expect(find.text('공유 원본 2'), findsOneWidget);
      if (outcome == 'system back') {
        await tester.binding.handlePopRoute();
      } else {
        await tester.tap(target);
        await tester.pump();
        final thumbnail = find.byKey(ValueKey('$keyPrefix-thumbnail'));
        for (var i = 0; i < 12 && thumbnail.evaluate().isEmpty; i++) {
          await drain(tester);
        }
        expect(thumbnail, findsOneWidget);
        final pick = find.byKey(ValueKey('$keyPrefix-pick'));
        if (!replacing) {
          expect(pick, findsNothing);
        } else {
          await tester.runAsync(() => tester.tap(pick));
          await drain(tester);
        }
        if (outcome == 'newer source before apply') {
          arrived = await withPumping(tester, receiveNewerSource);
        }
        await tester.tap(find.byKey(ValueKey('$keyPrefix-apply')));
      }
      await tester.pump();
      for (var i = 0; i < 12; i++) {
        await drain(tester);
        if (!File(replacement.sourcePath!).parent.existsSync()) break;
      }
      expect(File(replacement.sourcePath!).parent.existsSync(), isFalse);
      final drafts =
          {
            'system back',
            'same photo',
            'newer source before apply',
          }.contains(outcome)
          ? 0
          : 1;
      expect(picker.calls, replacing && outcome != 'system back' ? 1 : 0);
      expect(replacement.replacements, replacing ? drafts : 0);
      expect(replacement.removals, removing ? drafts : 0);
      expect(replacement.rotations, rotating ? drafts : 0);
      expect(rendered, drafts);
      final latest = await withPumping(tester, () => store.readLatest(note));
      final savedPrior = await withPumping(
        tester,
        () => store.readLatest(note, revisionId: prior.revision.revisionId),
      );
      final savedInk = await withPumping(
        tester,
        () => repository.readFiles(inkRevision),
      );
      expect(savedPrior.originalBytes, input);
      expect(savedPrior.pdfBytes, oldPdf);
      expect(savedPrior.bindingId, prior.bindingId);
      expect(savedInk['main.sbn2'], ink);
      if (outcome == 'save') {
        expect(latest.originalBytes, candidate);
        expect(latest.pdfBytes, newPdf);
        expect(latest.bindingId, isNot(prior.bindingId));
        expect(latest.revision.parentRevisionIds, [prior.revision.revisionId]);
      } else {
        expect(latest.originalBytes, input);
        expect(
          latest.revision.revisionId,
          arrived?.revision.revisionId ?? prior.revision.revisionId,
        );
      }
    });
  }

  testWidgets('Android PPTX exposes photo insertion', (tester) async {
    note = await withPumping(
      tester,
      () => store.importDocument(
        title: 'Lecture PPTX',
        fileName: 'lecture.pptx',
        bytes: pptxPhotoFixture(),
      ),
    );
    await mount(tester, FixtureOfficeEngine());
    expect(find.byKey(const ValueKey('office-add-pptx-photo')), findsOneWidget);
  });

  for (final outcome in [
    'save',
    'cancel',
    'wrong slide',
    'wrong PDF',
    'newer source during preview',
  ]) {
    testWidgets('Android PPTX photo insertion handles $outcome', (
      tester,
    ) async {
      final original = pptxPhotoFixture();
      final image = pptxReplacementPhoto();
      final candidate = replacePptxPhoto(
        original,
        listPptxPhotos(original).first,
        image,
      );
      final oldPdf = annotationPdf('before photo addition');
      final newPdf = annotationPdf('after photo addition');
      final oldInk = Uint8List.fromList([2, 8, 4]);
      final (prior, priorInk) = await withPumping(tester, () async {
        note = await store.importDocument(
          title: 'PPTX 사진 실습',
          fileName: 'lecture.pptx',
          bytes: original,
        );
        final prior = await store.commitEdited(
          await store.beginEdit(note),
          originalBytes: original,
          pdfBytes: oldPdf,
          engineVersion: 'before-photo-add',
          pageCount: 2,
        );
        final ink = await OfficeAnnotationStore(repository).open(note, prior);
        return (prior, await ink.saveFiles({'main.sbn2': oldInk}));
      });
      final picker = _PptxPhotoPicker(_PptxPhotoFile(image.bytes));
      final priorPicker = FilePickerPlatform.instance;
      FilePickerPlatform.instance = picker;
      addTearDown(() => FilePickerPlatform.instance = priorPicker);
      final adapter = _FixturePptxPhotoAddition(
        original,
        candidate,
        image,
        wrongSlide: outcome == 'wrong slide',
      );
      var rendered = 0, disposed = 0;
      OfficeEdition? arrived;
      final engine = _FixtureAndroidCloneEngine((path, id, sourceHash) async {
        rendered++;
        expect(path, adapter.output);
        expect(sourceHash, sha256.convert(candidate).toString());
        expect(await File(path).readAsBytes(), candidate);
        if (outcome == 'newer source during preview') {
          arrived = await store.commitEdited(
            await store.beginEdit(note),
            originalBytes: original,
            pdfBytes: annotationPdf('arrived'),
            engineVersion: 'peer-photo-add',
            pageCount: 2,
          );
        }
        final output = await File(p.join(temp.path, 'photo-add-$id.pdf'))
            .writeAsBytes(newPdf);
        return _FixtureAndroidCloneObservation(
          sessionId: id,
          sourceSha256: sourceHash,
          pdf: output,
          pdfSha256: sha256.convert(newPdf).toString(),
          partCount: 2,
          pageCount: outcome == 'wrong PDF' ? 1 : 2,
          onDispose: () => disposed++,
        );
      });
      await mount(tester, engine, pptxPhotoAddition: adapter);
      final launch = find.byKey(const ValueKey('office-add-pptx-photo'));
      await tester.ensureVisible(launch);
      await tester.runAsync(() => tester.tap(launch));
      final target = find.byKey(const ValueKey('pptx-photo-add-target-1'));
      for (var i = 0; i < 12 && target.evaluate().isEmpty; i++) {
        await drain(tester);
      }
      expect(target, findsOneWidget);
      expect(
        find.byKey(const ValueKey('pptx-photo-add-target-0')),
        findsNothing,
      );
      expect(find.text('슬라이드 2 · 숨김'), findsOneWidget);
      final apply = find.byKey(const ValueKey('pptx-photo-add-apply'));
      expect(tester.widget<FilledButton>(apply).onPressed, isNull);
      if (outcome == 'cancel') {
        await tester.binding.handlePopRoute();
      } else {
        await tester.tap(target);
        await tester.pump();
        await tester.runAsync(
          () => tester.tap(find.byKey(const ValueKey('pptx-photo-add-pick'))),
        );
        for (
          var i = 0;
          i < 12 && tester.widget<FilledButton>(apply).onPressed == null;
          i++
        ) {
          await drain(tester);
        }
        expect(tester.widget<FilledButton>(apply).onPressed, isNotNull);
        await tester.tap(apply);
      }
      await tester.pump();
      final work = File(adapter.source!).parent;
      for (var i = 0; i < 12 && work.existsSync(); i++) {
        await drain(tester);
      }
      expect(work.existsSync(), isFalse);
      expect(picker.calls, outcome == 'cancel' ? 0 : 1);
      expect(adapter.adds, outcome == 'cancel' ? 0 : 1);
      expect(rendered, {'cancel', 'wrong slide'}.contains(outcome) ? 0 : 1);
      expect(disposed, rendered);
      final latest = await withPumping(tester, () => store.readLatest(note));
      final preserved = await withPumping(
        tester,
        () => store.readLatest(note, revisionId: prior.revision.revisionId),
      );
      final ink = await withPumping(
        tester,
        () => repository.readFiles(priorInk),
      );
      expect(preserved.originalBytes, original);
      expect(preserved.pdfBytes, oldPdf);
      expect(ink['main.sbn2'], oldInk);
      if (outcome == 'save') {
        expect(latest.originalBytes, candidate);
        expect(latest.pdfBytes, newPdf);
        expect(latest.revision.parentRevisionIds, [prior.revision.revisionId]);
        expect(find.text('사진을 추가하고 새 원본과 PDF를 저장했습니다.'), findsOneWidget);
      } else {
        expect(latest.originalBytes, original);
        expect(
          latest.revision.revisionId,
          arrived?.revision.revisionId ?? prior.revision.revisionId,
        );
      }
    });
  }

  testWidgets('Android PPTX exposes text box insertion', (tester) async {
    note = await withPumping(
      tester,
      () => store.importDocument(
        title: 'Lecture PPTX',
        fileName: 'lecture.pptx',
        bytes: pptxPhotoFixture(),
      ),
    );
    await mount(tester, FixtureOfficeEngine());
    expect(
      find.byKey(const ValueKey('office-add-pptx-text-box')),
      findsOneWidget,
    );
  });

  testWidgets('Android PPTX exposes existing shape text editing', (
    tester,
  ) async {
    note = await withPumping(
      tester,
      () => store.importDocument(
        title: 'Lecture PPTX',
        fileName: 'lecture.pptx',
        bytes: pptxPhotoFixture(),
      ),
    );
    await mount(tester, FixtureOfficeEngine());
    expect(
      find.byKey(const ValueKey('office-edit-pptx-shape-text')),
      findsOneWidget,
    );
  });

  testWidgets('Android PPTX exposes selected shape text formatting', (
    tester,
  ) async {
    note = await withPumping(
      tester,
      () => store.importDocument(
        title: 'Lecture PPTX',
        fileName: 'lecture.pptx',
        bytes: pptxPhotoFixture(),
      ),
    );
    await mount(tester, FixtureOfficeEngine());
    expect(
      find.byKey(const ValueKey('office-format-pptx-shape-text')),
      findsOneWidget,
    );
  });

  testWidgets('Android PPTX exposes existing shape geometry editing', (
    tester,
  ) async {
    note = await withPumping(
      tester,
      () => store.importDocument(
        title: 'Lecture PPTX',
        fileName: 'lecture.pptx',
        bytes: pptxPhotoFixture(),
      ),
    );
    await mount(tester, FixtureOfficeEngine());
    expect(
      find.byKey(const ValueKey('office-edit-pptx-shape-geometry')),
      findsOneWidget,
    );
  });

  testWidgets('Android PPTX exposes existing shape deletion', (tester) async {
    note = await withPumping(
      tester,
      () => store.importDocument(
        title: 'Lecture PPTX',
        fileName: 'lecture.pptx',
        bytes: pptxPhotoFixture(),
      ),
    );
    await mount(tester, FixtureOfficeEngine());
    expect(
      find.byKey(const ValueKey('office-delete-pptx-shape')),
      findsOneWidget,
    );
  });

  for (final outcome in ['save', 'cancel', 'wrong dimensions', 'wrong PDF']) {
    testWidgets('Android PPTX table insertion handles $outcome', (
      tester,
    ) async {
      final original = pptxPhotoFixture();
      final candidate = replacePptxPhoto(
        original,
        listPptxPhotos(original).first,
        pptxReplacementPhoto(),
      );
      final oldPdf = annotationPdf('before table addition');
      final newPdf = annotationPdf('verified table addition');
      final oldInk = Uint8List.fromList([2, 4, 8]);
      final (prior, priorInkRevision) = await withPumping(tester, () async {
        note = await store.importDocument(
          title: 'Lecture PPTX',
          fileName: 'lecture.pptx',
          bytes: original,
        );
        final prior = await store.commitEdited(
          await store.beginEdit(note),
          originalBytes: original,
          pdfBytes: oldPdf,
          engineVersion: 'before-table-add',
          pageCount: 2,
        );
        final ink = await OfficeAnnotationStore(repository).open(note, prior);
        return (prior, await ink.saveFiles({'main.sbn2': oldInk}));
      });
      final adapter = _FixturePptxTableAdd(
        original,
        candidate,
        wrongDimensions: outcome == 'wrong dimensions',
      );
      var rendered = 0, disposed = 0;
      final engine = _FixtureAndroidCloneEngine((path, id, sourceHash) async {
        rendered++;
        expect(path, adapter.outputPath);
        expect(sourceHash, sha256.convert(candidate).toString());
        expect(await File(path).readAsBytes(), candidate);
        final output = await File(p.join(temp.path, 'table-add-$id.pdf'))
            .writeAsBytes(newPdf);
        return _FixtureAndroidCloneObservation(
          sessionId: id,
          sourceSha256: sourceHash,
          pdf: output,
          pdfSha256: sha256.convert(newPdf).toString(),
          partCount: 2,
          pageCount: outcome == 'wrong PDF' ? 1 : 2,
          onDispose: () => disposed++,
        );
      });
      await mount(tester, engine, pptxTableAdd: adapter);
      final launch = find.byKey(const ValueKey('office-add-pptx-table'));
      final slide = find.byKey(const ValueKey('pptx-table-add-slide'));
      final rows = find.byKey(const ValueKey('pptx-table-add-rows'));
      final columns = find.byKey(const ValueKey('pptx-table-add-columns'));
      final confirm = find.byKey(const ValueKey('pptx-table-add-confirm'));
      await tester.ensureVisible(launch);
      await tester.runAsync(() => tester.tap(launch));
      for (var i = 0; i < 12 && slide.evaluate().isEmpty; i++) {
        await drain(tester);
      }
      expect(tester.widget<DropdownButtonFormField<int>>(rows).initialValue, 2);
      expect(
        tester.widget<DropdownButtonFormField<int>>(columns).initialValue,
        2,
      );
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      Future<void> select(Finder menu, String option) async {
        await tester.ensureVisible(menu);
        await tester.tap(menu);
        await tester.pump(const Duration(milliseconds: 350));
        await tester.tap(find.text(option).last);
        await tester.pump(const Duration(milliseconds: 350));
      }

      await select(slide, '슬라이드 2 · 숨김 · 예시');
      await select(rows, '3');
      await select(columns, '4');
      await tester.tap(
        outcome == 'cancel'
            ? find.byKey(const ValueKey('pptx-table-add-cancel'))
            : confirm,
      );
      for (var i = 0; i < 12; i++) {
        await drain(tester);
        if (!File(adapter.sourcePath!).parent.existsSync()) break;
      }
      expect(File(adapter.sourcePath!).parent.existsSync(), isFalse);
      expect(
        adapter.added,
        outcome == 'cancel' ? null : (slideIndex: 1, rows: 3, columns: 4),
      );
      expect(rendered, outcome == 'save' || outcome == 'wrong PDF' ? 1 : 0);
      expect(disposed, rendered);
      final latest = await withPumping(tester, () => store.readLatest(note));
      final priorAgain = await withPumping(
        tester,
        () => store.readLatest(note, revisionId: prior.revision.revisionId),
      );
      final savedInk = await withPumping(
        tester,
        () => repository.readFiles(priorInkRevision),
      );
      expect(priorAgain.originalBytes, original);
      expect(priorAgain.pdfBytes, oldPdf);
      expect(savedInk['main.sbn2'], oldInk);
      if (outcome == 'save') {
        expect(latest.originalBytes, candidate);
        expect(latest.pdfBytes, newPdf);
        expect(latest.bindingId, isNot(prior.bindingId));
        expect(latest.revision.parentRevisionIds, [prior.revision.revisionId]);
        expect(find.text('표를 추가하고 새 원본과 PDF를 저장했습니다.'), findsOneWidget);
      } else {
        expect(latest.revision.revisionId, prior.revision.revisionId);
      }
    });
  }

  for (final outcome in [
    'save',
    'cancel',
    'wrong target',
    'wrong PDF',
    'newer source before apply',
  ]) {
    testWidgets('Android PPTX table cell text handles $outcome', (
      tester,
    ) async {
      final original = pptxPhotoFixture();
      final candidate = replacePptxPhoto(
        original,
        listPptxPhotos(original).first,
        pptxReplacementPhoto(),
      );
      final oldPdf = annotationPdf('before PPTX table cell text');
      final newPdf = annotationPdf('verified PPTX table cell text');
      final oldInk = Uint8List.fromList([2, 8, 16]);
      final (prior, priorInkRevision) = await withPumping(tester, () async {
        note = await store.importDocument(
          title: 'Lecture PPTX',
          fileName: 'lecture.pptx',
          bytes: original,
        );
        final prior = await store.commitEdited(
          await store.beginEdit(note),
          originalBytes: original,
          pdfBytes: oldPdf,
          engineVersion: 'before-table-cell-text',
          pageCount: 2,
        );
        final ink = await OfficeAnnotationStore(repository).open(note, prior);
        return (prior, await ink.saveFiles({'main.sbn2': oldInk}));
      });
      final adapter = _FixturePptxTableCellText(
        original,
        candidate,
        wrongTarget: outcome == 'wrong target',
      );
      var rendered = 0, disposed = 0;
      final engine = _FixtureAndroidCloneEngine((path, id, sourceHash) async {
        rendered++;
        expect(path, adapter.outputPath);
        expect(sourceHash, sha256.convert(candidate).toString());
        expect(await File(path).readAsBytes(), candidate);
        final output = await File(p.join(temp.path, 'table-cell-text-$id.pdf'))
            .writeAsBytes(newPdf);
        return _FixtureAndroidCloneObservation(
          sessionId: id,
          sourceSha256: sourceHash,
          pdf: output,
          pdfSha256: sha256.convert(newPdf).toString(),
          partCount: 2,
          pageCount: outcome == 'wrong PDF' ? 1 : 2,
          onDispose: () => disposed++,
        );
      });
      await mount(tester, engine, pptxTableCellText: adapter);
      final launch = find.byKey(
        const ValueKey('office-edit-pptx-table-cell-text'),
      );
      final slide = find.byKey(const ValueKey('pptx-table-cell-text-slide'));
      final table = find.byKey(const ValueKey('pptx-table-cell-text-table'));
      final row = find.byKey(const ValueKey('pptx-table-cell-text-row'));
      final column = find.byKey(const ValueKey('pptx-table-cell-text-column'));
      final confirm = find.byKey(
        const ValueKey('pptx-table-cell-text-confirm'),
      );
      await tester.ensureVisible(launch);
      await tester.runAsync(() => tester.tap(launch));
      for (var i = 0; i < 12 && slide.evaluate().isEmpty; i++) {
        await drain(tester);
      }
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      Future<void> choose(Finder menu, String option) async {
        await tester.ensureVisible(menu);
        await tester.tap(menu);
        await tester.pump(const Duration(milliseconds: 350));
        await tester.tap(find.text(option).last);
        await tester.pump(const Duration(milliseconds: 350));
      }

      await choose(slide, '슬라이드 1 · 표지');
      final noCells = find.text('이 슬라이드에 수정할 수 있는 표 셀이 없습니다.');
      for (var i = 0; i < 12 && noCells.evaluate().isEmpty; i++) {
        await drain(tester);
      }
      expect(noCells, findsOneWidget);
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      await choose(slide, '슬라이드 2 · 숨김 · 표 실습');
      for (var i = 0; i < 12 && table.evaluate().isEmpty; i++) {
        await drain(tester);
      }
      await choose(table, '표 2 · 실습 표 · 3행×4열');
      await choose(row, '2행');
      await choose(column, '3열');
      expect(adapter.loadedSlides, [0, 1]);
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      final emptyRun = find.byKey(
        const ValueKey('pptx-table-cell-text-run-0-0'),
      );
      final oldRun = find.byKey(const ValueKey('pptx-table-cell-text-run-0-8'));
      expect(tester.widget<TextFormField>(emptyRun).initialValue, '');
      await tester.ensureVisible(emptyRun);
      await tester.enterText(emptyRun, '새 & <셀 문구> 🧭');
      await tester.scrollUntilVisible(
        oldRun,
        120,
        scrollable: find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.enterText(oldRun, '');
      await tester.pump();
      expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);

      final arrived = outcome == 'newer source before apply'
          ? await withPumping(
              tester,
              () async => store.commitEdited(
                await store.beginEdit(note),
                originalBytes: original,
                pdfBytes: annotationPdf('newer PPTX from a peer'),
                engineVersion: 'peer-editor',
                pageCount: 2,
              ),
            )
          : null;
      final cancelled = outcome == 'cancel';
      await tester.tap(
        cancelled
            ? find.byKey(const ValueKey('pptx-table-cell-text-cancel'))
            : confirm,
      );
      for (var i = 0; i < 12; i++) {
        await drain(tester);
        if (!File(adapter.sourcePath!).parent.existsSync()) break;
      }
      expect(File(adapter.sourcePath!).parent.existsSync(), isFalse);
      expect(
        adapter.replaced,
        cancelled || arrived != null
            ? null
            : (slideIndex: 1, shapeId: 12, row: 1, column: 2),
      );
      expect(
        adapter.changes?.map(
          (change) => (change.paragraphIndex, change.runIndex, change.text),
        ),
        cancelled || arrived != null
            ? null
            : [(0, 0, '새 & <셀 문구> 🧭'), (0, 8, '')],
      );
      expect(rendered, outcome == 'save' || outcome == 'wrong PDF' ? 1 : 0);
      expect(disposed, rendered);
      final latest = await withPumping(tester, () => store.readLatest(note));
      final savedPrior = await withPumping(
        tester,
        () => store.readLatest(note, revisionId: prior.revision.revisionId),
      );
      final savedInk = await withPumping(
        tester,
        () => repository.readFiles(priorInkRevision),
      );
      expect(savedPrior.originalBytes, original);
      expect(savedPrior.pdfBytes, oldPdf);
      expect(savedInk['main.sbn2'], oldInk);
      if (outcome == 'save') {
        expect(latest.originalBytes, candidate);
        expect(latest.pdfBytes, newPdf);
        expect(latest.bindingId, isNot(prior.bindingId));
        expect(latest.revision.parentRevisionIds, [prior.revision.revisionId]);
        expect(find.text('표 셀 글자를 수정하고 새 원본과 PDF를 저장했습니다.'), findsOneWidget);
      } else {
        expect(latest.originalBytes, original);
        expect(
          latest.revision.revisionId,
          arrived?.revision.revisionId ?? prior.revision.revisionId,
        );
      }
    });
  }

  for (final (platform, legacy, kind, modern, outcome) in const [
    ('Windows', 'doc', OfficeTemplateKind.document, 'docx', 'saved'),
    ('Windows', 'ppt', OfficeTemplateKind.presentation, 'pptx', 'saved'),
    ('Android', 'doc', OfficeTemplateKind.document, 'docx', 'saved'),
    ('Android', 'ppt', OfficeTemplateKind.presentation, 'pptx', 'saved'),
    (
      'Android',
      'doc',
      OfficeTemplateKind.document,
      'docx',
      'unrelated pending revision',
    ),
    (
      'Android',
      'ppt',
      OfficeTemplateKind.presentation,
      'pptx',
      'unrelated pending revision',
    ),
    (
      'Android',
      'ppt',
      OfficeTemplateKind.presentation,
      'pptx',
      'related pending revision',
    ),
    ('Android', 'doc', OfficeTemplateKind.document, 'docx', 'cancelled'),
    ('Android', 'doc', OfficeTemplateKind.document, 'docx', 'unsupported'),
  ]) {
    testWidgets('$platform editable $modern copy of $legacy: $outcome', (
      tester,
    ) async {
      final original = Uint8List.fromList([
        0xd0,
        0xcf,
        0x11,
        0xe0,
        0xa1,
        0xb1,
        0x1a,
        0xe1,
        1,
      ]);
      final starter = OfficeTemplates.create(kind, title: 'Lecture copy');
      final oldPdf = annotationPdf('legacy preview');
      final newPdf = annotationPdf('converted preview');
      note = await withPumping(
        tester,
        () => store.importDocument(
          title: 'Legacy lecture',
          fileName: 'lecture.$legacy',
          bytes: original,
        ),
      );
      final originalEdition = await withPumping(
        tester,
        () async => store.commitEdited(
          await store.beginEdit(note),
          originalBytes: original,
          pdfBytes: oldPdf,
          engineVersion: 'previous',
          pageCount: 1,
        ),
      );
      VaultNote? created;
      var busy = false;
      var conversions = 0;
      File? draft;
      final androidEngine = _FixtureAndroidLegacyEngine(
        outcome != 'unsupported',
        (input, expectedSourceSha256) async {
          draft = input;
          expect(p.basename(input.path), 'source.$legacy');
          expect(expectedSourceSha256, sha256.convert(original).toString());
          expect(await input.readAsBytes(), original);
          conversions++;
          if (outcome == 'cancelled') return null;
          if (outcome.endsWith('pending revision')) {
            await receiveIncompleteSource(
              related: outcome == 'related pending revision' ? note : null,
            );
          }
          return OfficeConversionResult(
            originalBytes: starter.bytes,
            pdfBytes: newPdf,
            engineVersion: 'conversion-test',
            pageCount: 1,
            targetExtension: modern,
          );
        },
      );
      final engine = WindowsOfficeEngine(
        runner: (request) async {
          expect(request['mode'], 'convertLegacy');
          final input = File(request['sourcePath'] as String);
          draft = input;
          final hash = sha256.convert(original).toString();
          expect(request['expectedSourceSha256'], hash);
          expect(await input.readAsBytes(), original);
          final candidate = await File(
            p.join(input.parent.path, 'copy.$modern'),
          ).writeAsBytes(starter.bytes);
          final pdf = await File(p.join(input.parent.path, 'preview.pdf'))
              .writeAsBytes(newPdf);
          conversions++;
          return {
            'sessionId': request['sessionId'],
            'inputSourceSha256': hash,
            'targetExtension': modern,
            'sourcePath': candidate.path,
            'sourceSha256': sha256.convert(starter.bytes).toString(),
            'pdfPath': pdf.path,
            'pdfSha256': sha256.convert(newPdf).toString(),
            'pdfPageCount': 1,
            'engineVersion': 'conversion-test',
          };
        },
      );
      await mount(
        tester,
        platform == 'Android' ? androidEngine : null,
        windowsEngine: platform == 'Windows' ? engine : null,
        busy: (value) => busy = value,
        onConvertedCopy: (value) async {
          expect(busy, isFalse);
          created = value;
        },
      );
      final button = find.byKey(const ValueKey('office-make-legacy-copy'));
      if (outcome == 'unsupported') {
        expect(button, findsNothing);
        expect(conversions, 0);
        return;
      }
      expect(find.text('${modern.toUpperCase()} 편집용 복사본 만들기'), findsOneWidget);
      await tester.ensureVisible(button);
      await tester.runAsync(() => tester.tap(button));
      for (var i = 0; i < 18 && (conversions == 0 || busy); i++) {
        await drain(tester);
      }
      expect(conversions, 1);
      expect(busy, isFalse);
      expect(draft!.existsSync(), isFalse);
      if (outcome.endsWith('pending revision')) {
        expect(repository.pendingRevisionCount, 1);
      }
      if (outcome == 'cancelled' || outcome == 'related pending revision') {
        expect(created, isNull);
        final prior = await withPumping(tester, () => store.readLatest(note));
        expect(prior.revision.revisionId, originalEdition.revision.revisionId);
        if (outcome == 'related pending revision') {
          expect(
            find.textContaining('Repair or finish receiving revisions'),
            findsOneWidget,
          );
        }
        return;
      }
      expect(created?.title, 'Legacy lecture (편집용)');
      expect(created?.id, isNot(note.id));
      final copy = await withPumping(tester, () => store.readLatest(created!));
      final originalAfter = await withPumping(
        tester,
        () => store.readLatest(note),
      );
      expect(copy.originalFileName, 'lecture.$modern');
      expect(copy.originalBytes, starter.bytes);
      expect(copy.pdfBytes, newPdf);
      expect(copy.revision.parentRevisionIds, isEmpty);
      expect(
        originalAfter.revision.revisionId,
        originalEdition.revision.revisionId,
      );
      expect(originalAfter.originalBytes, original);
      expect(originalAfter.pdfBytes, oldPdf);
    });
  }

  for (final (platform, outcome) in const [
    ('Android', 'save'),
    ('Android', 'unconfirmed deletion'),
    ('Windows', 'save'),
    ('Windows', 'wrong candidate hash'),
    ('Windows', 'wrong PDF page count'),
    ('Windows', 'newer source during rendering'),
  ]) {
    final windows = platform == 'Windows';
    final cancelDelete = outcome == 'unconfirmed deletion';
    testWidgets('$platform PPTX table structure handles $outcome', (
      tester,
    ) async {
      final template = pptxPhotoFixture();
      Uint8List withRows(List<String> labels) {
        final archive = Archive();
        for (final file in ZipDecoder().decodeBytes(template).files) {
          if (!file.isFile) continue;
          var bytes = file.content;
          if (file.name == 'ppt/slides/slide1.xml') {
            final rows = labels
                .map(
                  (label) =>
                      '<a:tr h="360000"><a:tc><a:txBody><a:bodyPr/><a:lstStyle/>'
                      '<a:p><a:r><a:t>$label</a:t></a:r></a:p></a:txBody><a:tcPr/></a:tc></a:tr>',
                )
                .join();
            final table =
                '<p:graphicFrame><p:nvGraphicFramePr>'
                '<p:cNvPr id="12" name="실습 표"/><p:cNvGraphicFramePr/><p:nvPr/>'
                '</p:nvGraphicFramePr><p:xfrm><a:off x="800000" y="800000"/>'
                '<a:ext cx="1800000" cy="${360000 * labels.length}"/></p:xfrm>'
                '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/table">'
                '<a:tbl><a:tblPr/><a:tblGrid><a:gridCol w="1800000"/></a:tblGrid>$rows'
                '</a:tbl></a:graphicData></a:graphic></p:graphicFrame>';
            bytes = utf8.encode(
              utf8
                  .decode(bytes)
                  .replaceFirst('</p:spTree>', '$table</p:spTree>'),
            );
          }
          archive.addFile(ArchiveFile.bytes(file.name, bytes));
        }
        return Uint8List.fromList(ZipEncoder().encode(archive));
      }

      final original = withRows(const ['첫 행', '두 번째 행', '마지막 행']);
      final candidate = withRows(const ['첫 행', '두 번째 행', '', '마지막 행']);
      final oldPdf = annotationPdf('before PPTX table structure');
      final newPdf = annotationPdf('after PPTX table structure');
      final oldInk = Uint8List.fromList([3, 7, 11]);
      final (prior, priorInkRevision) = await withPumping(tester, () async {
        note = await store.importDocument(
          title: 'Lecture PPTX',
          fileName: 'lecture.pptx',
          bytes: original,
        );
        final prior = await store.commitEdited(
          await store.beginEdit(note),
          originalBytes: original,
          pdfBytes: oldPdf,
          engineVersion: 'before-table-structure',
          pageCount: 1,
        );
        final ink = await OfficeAnnotationStore(repository).open(note, prior);
        return (prior, await ink.saveFiles({'main.sbn2': oldInk}));
      });
      final wrongCandidateHash = outcome == 'wrong candidate hash';
      final adapter = _FixturePptxTableStructure(
        original,
        candidate,
        wrongCandidateHash: wrongCandidateHash,
      );
      var rendered = 0, disposed = 0;
      final candidateHash = sha256.convert(candidate).toString();
      final androidEngine = _FixtureAndroidCloneEngine((
        path,
        id,
        sourceHash,
      ) async {
        rendered++;
        expect(path, adapter.outputPath);
        expect(sourceHash, candidateHash);
        expect(await File(path).readAsBytes(), candidate);
        final output = await File(p.join(temp.path, 'table-structure-$id.pdf'))
            .writeAsBytes(newPdf);
        return _FixtureAndroidCloneObservation(
          sessionId: id,
          sourceSha256: sourceHash,
          pdf: output,
          pdfSha256: sha256.convert(newPdf).toString(),
          partCount: 1,
          pageCount: 1,
          onDispose: () => disposed++,
        );
      });
      OfficeEdition? arrived;
      final windowsEngine = WindowsOfficeEngine(
        runner: (request) async {
          rendered++;
          expect(request['mode'], 'inspect');
          expect(request['preview'], true);
          expect(request['sourcePath'], adapter.outputPath);
          expect(await File(adapter.outputPath!).readAsBytes(), candidate);
          if (outcome == 'newer source during rendering') {
            arrived = await store.commitEdited(
              await store.beginEdit(note),
              originalBytes: withRows(const ['다른 기기에서 편집한 행']),
              pdfBytes: annotationPdf('newer source'),
              engineVersion: 'newer-source',
              pageCount: 1,
            );
          }
          final pdf = await File(p.join(temp.path, 'table-structure.pdf'))
              .writeAsBytes(newPdf);
          return {
            'snapshot': {
              'kind': 'presentation',
              'sourceSha256': candidateHash,
              'paragraphs': [],
              'tables': [],
              'slides': [
                {'id': 'slide-0', 'width': 280, 'height': 157.5, 'shapes': []},
              ],
              'previewPdfPath': pdf.path,
              'previewPageCount': outcome == 'wrong PDF page count' ? 2 : 1,
            },
          };
        },
      );
      await mount(
        tester,
        windows ? null : androidEngine,
        windowsEngine: windows ? windowsEngine : null,
        pptxTableStructure: adapter,
      );
      final launch = find.byKey(
        const ValueKey('office-edit-pptx-table-structure'),
      );
      expect(launch, findsOneWidget);
      if (windows) {
        expect(
          find.byKey(const ValueKey('office-add-pptx-photo')),
          findsNothing,
        );
      }
      Finder control(String name) =>
          find.byKey(ValueKey('pptx-table-structure-$name'));
      final slide = control('slide');
      final table = control('table');
      final action = control('action');
      final position = control('position');
      final confirm = control('confirm');
      await tester.ensureVisible(launch);
      await tester.runAsync(() => tester.tap(launch));
      for (var i = 0; i < 12 && slide.evaluate().isEmpty; i++) {
        await drain(tester);
      }
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      final fields = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(SingleChildScrollView),
      );
      final fieldViewport = tester.getRect(fields);

      Future<void> choose(Finder menu, String option) async {
        await tester.ensureVisible(menu);
        await tester.tap(menu);
        await tester.pump(const Duration(milliseconds: 350));
        await tester.tap(find.text(option).last);
        await tester.pump(const Duration(milliseconds: 350));
      }

      await choose(slide, '슬라이드 1 · 표 실습');
      for (var i = 0; i < 12 && table.evaluate().isEmpty; i++) {
        await drain(tester);
      }
      await choose(table, '표 1 · 실습 표 · 3행×1열');
      final actions = tester
          .widget<DropdownButton<PptxTableStructureAction>>(action)
          .items!;
      expect(
        actions
            .singleWhere(
              (item) => item.value == PptxTableStructureAction.deleteColumn,
            )
            .enabled,
        isFalse,
      );
      await choose(action, cancelDelete ? '행 삭제' : '위에 행 추가');
      if (windows) {
        expect(tester.getRect(fields), fieldViewport);
        expect(
          tester.getBottomRight(position).dy,
          lessThanOrEqualTo(fieldViewport.bottom),
        );
        expect(
          tester.getBottomRight(position).dy,
          lessThan(tester.getTopLeft(confirm).dy),
        );
      }
      expect(
        tester
            .widget<DropdownButton<int>>(position)
            .items!
            .map((item) => item.value),
        cancelDelete ? [2] : [0, 2],
      );
      await choose(position, '3행');
      await tester.tap(confirm);
      if (cancelDelete) {
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.text('3행을 삭제할까요?'), findsOneWidget);
        expect(adapter.edited, isNull);
        await tester.tap(control('delete-cancel'));
        await tester.pump(const Duration(milliseconds: 350));
        expect(adapter.edited, isNull);
        await tester.tap(control('cancel'));
      }
      for (var i = 0; i < 12; i++) {
        await drain(tester);
        if (!File(adapter.sourcePath!).parent.existsSync()) break;
      }
      expect(File(adapter.sourcePath!).parent.existsSync(), isFalse);
      expect(
        adapter.edited,
        cancelDelete
            ? null
            : (
                slideIndex: 0,
                shapeId: 12,
                action: PptxTableStructureAction.insertRowBefore,
                index: 2,
              ),
      );
      expect(rendered, cancelDelete || wrongCandidateHash ? 0 : 1);
      expect(disposed, windows ? 0 : rendered);
      final latest = await withPumping(tester, () => store.readLatest(note));
      if (outcome == 'save') {
        expect(latest.originalBytes, candidate);
        expect(latest.pdfBytes, newPdf);
        expect(latest.revision.parentRevisionIds, [prior.revision.revisionId]);
        expect(latest.bindingId, isNot(prior.bindingId));
        expect(find.text('표 행·열을 편집하고 새 원본과 PDF를 저장했습니다.'), findsOneWidget);
      } else {
        final expected = arrived ?? prior;
        expect(latest.revision.revisionId, expected.revision.revisionId);
        expect(latest.originalBytes, expected.originalBytes);
        expect(latest.pdfBytes, expected.pdfBytes);
      }
      final savedPrior = await withPumping(
        tester,
        () => store.readLatest(note, revisionId: prior.revision.revisionId),
      );
      final savedInk = await withPumping(
        tester,
        () => repository.readFiles(priorInkRevision),
      );
      expect(savedPrior.originalBytes, original);
      expect(savedPrior.pdfBytes, oldPdf);
      expect(savedInk['main.sbn2'], oldInk);
    });
  }

  test('PPTX table merge protects fully covered rows and columns', () {
    const top = (row: 0, column: 0, rowSpan: 1, columnSpan: 2);
    const bottom = (row: 1, column: 0, rowSpan: 2, columnSpan: 2);
    final table = PptxTableMergeTable(
      shapeId: 12,
      name: '표',
      rows: 3,
      columns: 3,
      mergedRanges: [top],
    );
    expect(table.allows(PptxTableMergeAction.merge, bottom), isFalse);
    expect(table.allows(PptxTableMergeAction.unmerge, top), isTrue);
    final interior = PptxTableMergeTable(
      shapeId: 12,
      name: '표',
      rows: 3,
      columns: 3,
      mergedRanges: [],
    );
    expect(interior.allows(PptxTableMergeAction.merge, bottom), isTrue);
  });

  for (final (windows, outcome) in [
    (false, 'save'),
    (true, 'save'),
    (true, 'stale source'),
    (false, 'wrong count'),
    (false, 'cancel pending'),
  ]) {
    testWidgets(
      '${windows ? 'Windows' : 'Android'} PPTX find and replace handles $outcome',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = windows
            ? const Size(1280, 720)
            : const Size(360, 640);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final original = OfficeTemplates.create(
          OfficeTemplateKind.presentation,
          title: 'First draft · First',
        ).bytes;
        final replacement = windows ? '' : 'Second';
        final edited = OfficeTemplates.create(
          OfficeTemplateKind.presentation,
          title: 'First draft · First'.replaceAll('First', replacement),
        ).bytes;
        final originalPdf = annotationPdf('before replacement');
        final editedPdf = annotationPdf('after replacement');
        final oldInk = Uint8List.fromList([7, 8, 9]);
        final (before, ink) = await withPumping(tester, () async {
          note = await store.importDocument(
            title: 'Find words',
            fileName: 'words.pptx',
            bytes: original,
          );
          final edition = await store.commitEdited(
            await store.beginEdit(note),
            originalBytes: original,
            pdfBytes: originalPdf,
            engineVersion: 'fixture-before',
            pageCount: 1,
          );
          final annotations = await OfficeAnnotationStore(repository)
              .open(note, edition);
          return (edition, await annotations.saveFiles({'main.sbn2': oldInk}));
        });
        final cancelPending = outcome == 'cancel pending';
        final changeDuringSearch = outcome == 'save' && !windows;
        final release = cancelPending || changeDuringSearch
            ? Completer<void>()
            : null;
        final editor = _FixturePptxFindReplace(
          original,
          edited,
          wrongCount: outcome == 'wrong count',
          releasePreview: release,
        );
        final editedHash = sha256.convert(edited).toString();
        var renders = 0;
        Future<File> render(String path) async {
          renders++;
          expect(path, editor.outputPath);
          expect(await File(path).readAsBytes(), edited);
          return File(p.join(temp.path, 'pptx-find-replace-preview.pdf'))
              .writeAsBytes(editedPdf);
        }

        final windowsEngine = WindowsOfficeEngine(
          runner: (request) async {
            expect(request['mode'], 'inspect');
            expect(request['preview'], true);
            final pdf = await render(request['sourcePath'] as String);
            return {
              'snapshot': {
                'kind': 'presentation',
                'sourceSha256': editedHash,
                'paragraphs': [],
                'tables': [],
                'slides': [
                  {
                    'id': 'slide-0',
                    'width': 280,
                    'height': 157.5,
                    'shapes': [],
                  },
                ],
                'previewPdfPath': pdf.path,
                'previewPageCount': 1,
              },
            };
          },
        );
        final android = _FixtureAndroidCloneEngine((path, id, hash) async {
          expect(hash, editedHash);
          final pdf = await render(path);
          return _FixtureAndroidCloneObservation(
            sessionId: id,
            sourceSha256: hash,
            pdf: pdf,
            pdfSha256: sha256.convert(editedPdf).toString(),
            partCount: 1,
            pageCount: 1,
            onDispose: () {},
          );
        });
        await mount(
          tester,
          windows ? null : android,
          windowsEngine: windows ? windowsEngine : null,
          pptxFindReplace: editor,
        );
        if (release != null) {
          addTearDown(() {
            if (!release.isCompleted) release.complete();
          });
        }
        final launch = find.byKey(
          const ValueKey('office-edit-pptx-find-replace'),
        );
        expect(launch, findsOneWidget);
        await tester.ensureVisible(launch);
        await tester.runAsync(() => tester.tap(launch));
        Finder control(String name) =>
            find.byKey(ValueKey('pptx-find-replace-$name'));
        final query = control('find');
        final confirm = control('confirm');
        for (var i = 0; i < 12 && query.evaluate().isEmpty; i++) {
          await drain(tester);
        }
        expect(query, findsOneWidget);
        bool canConfirm() =>
            tester.widget<FilledButton>(confirm).onPressed != null;
        expect(canConfirm(), isFalse);

        Future<void> search(String value) async {
          await tester.ensureVisible(query);
          await tester.enterText(query, value);
          await tester.pump();
          expect(canConfirm(), isFalse);
          await tester.ensureVisible(control('preview'));
          await tester.runAsync(() => tester.tap(control('preview')));
          await drain(tester);
        }

        await search('First');
        final draft = File(editor.sourcePath!).parent;
        OfficeEdition? newer;
        if (cancelPending) {
          expect(canConfirm(), isFalse);
          await tester.tap(control('cancel'));
          await drain(tester);
          expect(draft.existsSync(), isTrue);
          release!.complete();
        } else {
          if (changeDuringSearch) {
            await tester.ensureVisible(query);
            await tester.enterText(query, 'first');
            await tester.pump();
            release!.complete();
            await drain(tester);
            expect(find.textContaining('First draft · First'), findsNothing);
            expect(canConfirm(), isFalse);
          }
          if (outcome == 'save') {
            await search('first');
            expect(find.text('일치하는 슬라이드 글자가 없습니다.'), findsOneWidget);
            expect(canConfirm(), isFalse);
            await search('First');
          }
          expect(find.text('2곳 · 1개 슬라이드'), findsOneWidget);
          expect(find.textContaining('슬라이드 1 · 2곳'), findsOneWidget);
          expect(find.textContaining('First draft · First'), findsOneWidget);
          expect(canConfirm(), isTrue);
          final replacementField = control('replacement');
          await tester.ensureVisible(replacementField);
          await tester.enterText(replacementField, 'First');
          await tester.pump();
          expect(canConfirm(), isFalse);
          await tester.enterText(replacementField, replacement);
          await tester.pump();
          expect(canConfirm(), isTrue);
          expect(editor.replacement, isNull);
          expect(renders, 0);
          if (outcome == 'stale source') {
            newer = await withPumping(
              tester,
              () async => store.commitEdited(
                await store.beginEdit(note),
                originalBytes: original,
                pdfBytes: annotationPdf('peer'),
                engineVersion: 'peer',
                pageCount: 1,
              ),
            );
          }
          await tester.runAsync(() => tester.tap(confirm));
        }
        for (var i = 0; i < 24 && draft.existsSync(); i++) {
          await drain(tester);
        }
        expect(draft.existsSync(), isFalse);
        expect(
          editor.replacement,
          ['save', 'wrong count'].contains(outcome) ? replacement : null,
        );
        expect(renders, outcome == 'save' ? 1 : 0);
        final latest = await withPumping(tester, () => store.readLatest(note));
        final prior = await withPumping(
          tester,
          () => store.readLatest(note, revisionId: before.revision.revisionId),
        );
        final savedInk = await withPumping(
          tester,
          () => repository.readFiles(ink),
        );
        expect(prior.originalBytes, original);
        expect(prior.pdfBytes, originalPdf);
        expect(savedInk['main.sbn2'], oldInk);
        expect(latest.originalBytes, outcome == 'save' ? edited : original);
        if (outcome == 'save') {
          expect(latest.pdfBytes, editedPdf);
          expect(latest.revision.parentRevisionIds, [
            before.revision.revisionId,
          ]);
        } else {
          expect(
            latest.revision.revisionId,
            (newer ?? before).revision.revisionId,
          );
        }
      },
    );
  }

  for (final windows in [false, true]) {
    testWidgets(
      '${windows ? 'Windows' : 'Android'} current PPTX offers object stacking',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = windows
            ? const Size(1280, 720)
            : const Size(360, 640);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final original = pptxPhotoFixture();
        final archive = ZipDecoder().decodeBytes(original);
        archive.addFile(ArchiveFile.string('order-fixture.txt', 'edited'));
        final candidate = Uint8List.fromList(ZipEncoder().encode(archive));
        final candidateHash = sha256.convert(candidate).toString();
        final oldPdf = annotationPdf('old stacking order');
        final newPdf = annotationPdf('new stacking order');
        final inkBytes = Uint8List.fromList([2, 3, 4]);
        final (prior, inkRevision) = await withPumping(tester, () async {
          note = await store.importDocument(
            title: 'Stacking lesson',
            fileName: 'lesson.pptx',
            bytes: original,
          );
          final edition = await store.commitEdited(
            await store.beginEdit(note),
            originalBytes: original,
            pdfBytes: oldPdf,
            engineVersion: 'before-order',
            pageCount: 1,
          );
          final ink = await OfficeAnnotationStore(repository)
              .open(note, edition);
          return (edition, await ink.saveFiles({'main.sbn2': inkBytes}));
        });
        final editor = _FixturePptxShapeOrder(original, candidate);
        final android = _FixtureAndroidCloneEngine((path, id, hash) async {
          expect(hash, candidateHash);
          expect(await File(path).readAsBytes(), candidate);
          final pdf = await File(p.join(temp.path, 'stacking-$id.pdf'))
              .writeAsBytes(newPdf);
          return _FixtureAndroidCloneObservation(
            sessionId: id,
            sourceSha256: hash,
            pdf: pdf,
            pdfSha256: sha256.convert(newPdf).toString(),
            partCount: 1,
            pageCount: 1,
            onDispose: () {},
          );
        });
        final desktop = WindowsOfficeEngine(
          runner: (request) async {
            expect(request['mode'], 'inspect');
            expect(request['preview'], isTrue);
            expect(
              await File(request['sourcePath'] as String).readAsBytes(),
              candidate,
            );
            final pdf = await File(p.join(temp.path, 'stacking-windows.pdf'))
                .writeAsBytes(newPdf);
            return {
              'snapshot': {
                'kind': 'presentation',
                'sourceSha256': candidateHash,
                'paragraphs': [],
                'tables': [],
                'slides': [
                  {
                    'id': 'slide-0',
                    'width': 280,
                    'height': 157.5,
                    'shapes': [],
                  },
                ],
                'previewPdfPath': pdf.path,
                'previewPageCount': 1,
              },
            };
          },
        );
        await mount(
          tester,
          windows ? null : android,
          windowsEngine: windows ? desktop : null,
          pptxShapeOrder: editor,
        );
        final launch = find.byKey(
          const ValueKey('office-edit-pptx-shape-order'),
        );
        expect(launch, findsOneWidget);
        await tester.ensureVisible(launch);
        await tester.runAsync(() => tester.tap(launch));
        Finder control(String name) =>
            find.byKey(ValueKey('pptx-shape-order-$name'));
        for (var i = 0; i < 12 && control('slide').evaluate().isEmpty; i++) {
          await drain(tester);
        }

        Future<void> select(String name, String label) async {
          final picker = control(name);
          await tester.ensureVisible(picker);
          await tester.pump();
          expect(picker.hitTestable(), findsOneWidget);
          await tester.tap(picker);
          await tester.pump(const Duration(milliseconds: 350));
          final option = find.text(label).last;
          expect(option.hitTestable(), findsOneWidget);
          await tester.tap(option);
          await tester.pump(const Duration(milliseconds: 350));
        }

        await select('slide', '슬라이드 1');
        for (var i = 0; i < 12 && control('target').evaluate().isEmpty; i++) {
          await drain(tester);
        }
        await select('target', windows ? '3단 · 사진 · 자료' : '1단 · 도형 · 배경');
        final confirm = control('confirm');
        expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
        final options = tester
            .widget<DropdownButton<PptxShapeOrderDirection>>(
              control('direction'),
            )
            .items!;
        expect(
          options
              .where((option) => option.enabled)
              .map((option) => option.value),
          windows
              ? [PptxShapeOrderDirection.backward, PptxShapeOrderDirection.back]
              : [
                  PptxShapeOrderDirection.front,
                  PptxShapeOrderDirection.forward,
                ],
        );
        final direction = windows
            ? PptxShapeOrderDirection.back
            : PptxShapeOrderDirection.forward;
        await select('direction', direction.label);
        await tester.runAsync(() => tester.tap(confirm));
        for (
          var i = 0;
          i < 15 &&
              find.text('개체 겹침 순서를 변경하고 새 원본과 PDF를 저장했습니다.').evaluate().isEmpty;
          i++
        ) {
          await drain(tester);
        }
        expect(
          editor.applied,
          windows ? (4, direction, 2, 0) : (2, direction, 0, 1),
        );
        final latest = await withPumping(tester, () => store.readLatest(note));
        final previous = await withPumping(
          tester,
          () => store.readLatest(note, revisionId: prior.revision.revisionId),
        );
        final savedInk = await withPumping(
          tester,
          () => repository.readFiles(inkRevision),
        );
        expect(latest.originalBytes, candidate);
        expect(latest.pdfBytes, newPdf);
        expect(latest.revision.parentRevisionIds, [prior.revision.revisionId]);
        expect(previous.originalBytes, original);
        expect(previous.pdfBytes, oldPdf);
        expect(savedInk['main.sbn2'], inkBytes);
      },
    );
  }

  for (final windows in [false, true]) {
    testWidgets(
      '${windows ? 'Windows' : 'Android'} PPTX table merge saves the original and PDF together',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = windows
            ? const Size(1280, 720)
            : const Size(360, 640);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final original = pptxPhotoFixture();
        final archive = ZipDecoder().decodeBytes(original);
        archive.addFile(ArchiveFile.string('merge-fixture.txt', 'edited'));
        final candidate = Uint8List.fromList(ZipEncoder().encode(archive));
        final oldPdf = annotationPdf('before cell merge');
        final newPdf = annotationPdf('after cell merge');
        final oldInk = Uint8List.fromList([3, 7, 11]);
        final (prior, inkRevision) = await withPumping(tester, () async {
          note = await store.importDocument(
            title: 'Table lesson',
            fileName: 'lecture.pptx',
            bytes: original,
          );
          final prior = await store.commitEdited(
            await store.beginEdit(note),
            originalBytes: original,
            pdfBytes: oldPdf,
            engineVersion: 'before-merge',
            pageCount: 1,
          );
          final ink = await OfficeAnnotationStore(repository).open(note, prior);
          return (prior, await ink.saveFiles({'main.sbn2': oldInk}));
        });
        final adapter = _FixturePptxTableMerge(
          original,
          candidate,
          alreadyMerged: windows,
        );
        final candidateHash = sha256.convert(candidate).toString();
        final renderer = _FixtureAndroidCloneEngine((path, id, hash) async {
          expect(hash, candidateHash);
          expect(await File(path).readAsBytes(), candidate);
          final pdf = await File(p.join(temp.path, 'cell-merge-$id.pdf'))
              .writeAsBytes(newPdf);
          return _FixtureAndroidCloneObservation(
            sessionId: id,
            sourceSha256: hash,
            pdf: pdf,
            pdfSha256: sha256.convert(newPdf).toString(),
            partCount: 1,
            pageCount: 1,
            onDispose: () {},
          );
        });
        final windowsRenderer = WindowsOfficeEngine(
          runner: (request) async {
            expect(request['mode'], 'inspect');
            expect(request['preview'], isTrue);
            expect(
              await File(request['sourcePath'] as String).readAsBytes(),
              candidate,
            );
            final pdf = await File(p.join(temp.path, 'cell-merge.pdf'))
                .writeAsBytes(newPdf);
            return {
              'snapshot': {
                'kind': 'presentation',
                'sourceSha256': candidateHash,
                'paragraphs': [],
                'tables': [],
                'slides': [
                  {
                    'id': 'slide-0',
                    'width': 280,
                    'height': 157.5,
                    'shapes': [],
                  },
                ],
                'previewPdfPath': pdf.path,
                'previewPageCount': 1,
              },
            };
          },
        );
        await mount(
          tester,
          windows ? null : renderer,
          windowsEngine: windows ? windowsRenderer : null,
          pptxTableMerge: adapter,
        );
        final launch = find.byKey(
          const ValueKey('office-edit-pptx-table-merge'),
        );
        await tester.ensureVisible(launch);
        await tester.runAsync(() => tester.tap(launch));
        Finder control(String name) =>
            find.byKey(ValueKey('pptx-table-merge-$name'));
        for (var i = 0; i < 12 && control('slide').evaluate().isEmpty; i++) {
          await drain(tester);
        }

        Future<void> select(String name, String label) async {
          final picker = control(name);
          await tester.ensureVisible(picker);
          await tester.pump();
          expect(picker.hitTestable(), findsOneWidget);
          await tester.tap(picker);
          await tester.pump(const Duration(milliseconds: 350));
          final option = find.text(label).last;
          expect(option.hitTestable(), findsOneWidget);
          await tester.tap(option);
          await tester.pump(const Duration(milliseconds: 350));
        }

        await select('slide', '슬라이드 1');
        for (var i = 0; i < 12 && control('table').evaluate().isEmpty; i++) {
          await drain(tester);
        }
        await select(
          'table',
          windows ? '표 1 · 실습 표 · 2행×2열' : '표 1 · 실습 표 · 3행×3열',
        );
        final confirm = control('confirm');
        expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
        final action = windows
            ? PptxTableMergeAction.unmerge
            : PptxTableMergeAction.merge;
        if (windows) {
          await select('action', '병합 해제');
          await select('merged-range', '1행 1열 · 2행×2열');
        } else {
          await select('last-row', '2');
          await select('last-column', '2');
        }
        await tester.runAsync(() => tester.tap(confirm));
        for (
          var i = 0;
          i < 15 &&
              find.text('표 셀 병합을 편집하고 새 원본과 PDF를 저장했습니다.').evaluate().isEmpty;
          i++
        ) {
          await drain(tester);
        }
        expect(adapter.applied, (action, _FixturePptxTableMerge.range));
        final latest = await withPumping(tester, () => store.readLatest(note));
        final previous = await withPumping(
          tester,
          () => store.readLatest(note, revisionId: prior.revision.revisionId),
        );
        final savedInk = await withPumping(
          tester,
          () => repository.readFiles(inkRevision),
        );
        expect(latest.originalBytes, candidate);
        expect(latest.pdfBytes, newPdf);
        expect(latest.revision.parentRevisionIds, [prior.revision.revisionId]);
        expect(previous.originalBytes, original);
        expect(previous.pdfBytes, oldPdf);
        expect(savedInk['main.sbn2'], oldInk);
      },
    );
  }

  test('PPTX speaker notes text bounds match the native request', () {
    const valid = PptxSpeakerNotesEngine.validText;
    expect(valid('첫 줄\n\t둘째 줄 🧭'), isTrue);
    expect(valid('🧭' * 4000), isTrue);
    expect(valid('🧭' * 4001), isFalse);
    expect(valid('\n' * 127), isTrue);
    expect(valid('\n' * 128), isFalse);
    expect(valid('a\rb'), isFalse);
    expect(valid('a\u0085b'), isFalse);
  });

  for (final (platform, outcome) in const [
    ('Android', 'create multiline notes'),
    ('Windows', 'clear existing notes'),
    ('Windows', 'system back'),
    ('Android', 'newer source before apply'),
    ('Android', 'read-only notes'),
  ]) {
    testWidgets('$platform PPTX speaker notes handle $outcome', (tester) async {
      final windows = platform == 'Windows';
      final clear = outcome == 'clear existing notes';
      final readOnly = outcome == 'read-only notes';
      final save = outcome == 'create multiline notes' || clear;
      final original = pptxPhotoFixture();
      final archive = ZipDecoder().decodeBytes(original);
      archive.addFile(
        ArchiveFile.string(
          'ppt/notesSlides/notesSlide1.xml',
          '<p:notes xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">'
              '${clear ? '' : 'fixture note'}'
              '</p:notes>',
        ),
      );
      final candidate = Uint8List.fromList(ZipEncoder().encode(archive));
      final oldPdf = annotationPdf('before PPTX notes');
      final newPdf = annotationPdf('after PPTX notes');
      final oldInk = Uint8List.fromList([3, 7, 11]);
      final (prior, priorInkRevision) = await withPumping(tester, () async {
        note = await store.importDocument(
          title: 'Lecture PPTX',
          fileName: 'lecture.pptx',
          bytes: original,
        );
        final prior = await store.commitEdited(
          await store.beginEdit(note),
          originalBytes: original,
          pdfBytes: oldPdf,
          engineVersion: 'before-notes',
          pageCount: 1,
        );
        final ink = await OfficeAnnotationStore(repository).open(note, prior);
        return (prior, await ink.saveFiles({'main.sbn2': oldInk}));
      });

      final oldText = clear || readOnly ? '기존 발표자 노트\n두 번째 줄' : '';
      final adapter = _FixturePptxSpeakerNotes(original, candidate, (
        text: oldText,
        editable: !readOnly,
        hasNotes: oldText.isNotEmpty,
      ));
      var rendered = 0;
      var disposed = 0;
      final candidateHash = sha256.convert(candidate).toString();
      final androidEngine = _FixtureAndroidCloneEngine((
        path,
        id,
        sourceHash,
      ) async {
        rendered++;
        expect(path, adapter.outputPath);
        expect(sourceHash, candidateHash);
        expect(await File(path).readAsBytes(), candidate);
        final pdf = await File(p.join(temp.path, 'notes-$id.pdf'))
            .writeAsBytes(newPdf);
        return _FixtureAndroidCloneObservation(
          sessionId: id,
          sourceSha256: sourceHash,
          pdf: pdf,
          pdfSha256: sha256.convert(newPdf).toString(),
          partCount: 1,
          pageCount: 1,
          onDispose: () => disposed++,
        );
      });
      final windowsEngine = WindowsOfficeEngine(
        runner: (request) async {
          rendered++;
          expect(request['mode'], 'inspect');
          expect(request['preview'], true);
          expect(request['sourcePath'], adapter.outputPath);
          expect(await File(adapter.outputPath!).readAsBytes(), candidate);
          final pdf = await File(p.join(temp.path, 'notes.pdf'))
              .writeAsBytes(newPdf);
          return {
            'snapshot': {
              'kind': 'presentation',
              'sourceSha256': candidateHash,
              'paragraphs': [],
              'tables': [],
              'slides': [
                {'id': 'slide-0', 'width': 280, 'height': 157.5, 'shapes': []},
              ],
              'previewPdfPath': pdf.path,
              'previewPageCount': 1,
            },
          };
        },
      );
      await mount(
        tester,
        windows ? null : androidEngine,
        windowsEngine: windows ? windowsEngine : null,
        pptxSpeakerNotes: adapter,
      );
      final launch = find.byKey(
        const ValueKey('office-edit-pptx-speaker-notes'),
      );
      final slide = find.byKey(const ValueKey('pptx-speaker-notes-slide'));
      final text = find.byKey(const ValueKey('pptx-speaker-notes-text'));
      final submit = find.byKey(const ValueKey('pptx-speaker-notes-save'));
      await tester.ensureVisible(launch);
      await tester.runAsync(() => tester.tap(launch));
      for (var i = 0; i < 12 && slide.evaluate().isEmpty; i++) {
        await drain(tester);
      }
      await tester.tap(slide);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.text('슬라이드 1 · 발표 실습').last);
      await tester.pump(const Duration(milliseconds: 350));
      for (var i = 0; i < 12 && text.evaluate().isEmpty; i++) {
        await drain(tester);
      }
      final field = tester.widget<TextField>(text);
      expect(field.controller!.text, oldText);
      expect(field.readOnly, readOnly);
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);

      OfficeEdition? arrived;
      final replacement = clear ? '' : '첫 줄 & <노트>\n\t둘째 줄 🧭';
      if (!readOnly) {
        if (oldText.isEmpty) {
          await tester.enterText(text, ' \t\n');
          await tester.pump();
          expect(tester.widget<FilledButton>(submit).onPressed, isNull);
        }
        await tester.enterText(text, replacement);
        await tester.pump();
        expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);
      }
      if (outcome == 'newer source before apply') {
        arrived = await withPumping(
          tester,
          () async => store.commitEdited(
            await store.beginEdit(note),
            originalBytes: original,
            pdfBytes: annotationPdf('peer notes'),
            engineVersion: 'peer-editor',
            pageCount: 1,
          ),
        );
      }
      if (outcome == 'system back') {
        await tester.binding.handlePopRoute();
      } else if (readOnly) {
        await tester.tap(
          find.byKey(const ValueKey('pptx-speaker-notes-cancel')),
        );
      } else {
        await tester.tap(submit);
      }
      for (var i = 0; i < 12; i++) {
        await drain(tester);
        if (!File(adapter.sourcePath!).parent.existsSync()) break;
      }
      expect(File(adapter.sourcePath!).parent.existsSync(), isFalse);
      expect(adapter.edited, save ? (slideIndex: 0, text: replacement) : null);
      expect(rendered, save ? 1 : 0);
      expect(disposed, windows ? 0 : rendered);
      final latest = await withPumping(tester, () => store.readLatest(note));
      if (save) {
        expect(latest.originalBytes, candidate);
        expect(latest.pdfBytes, newPdf);
        expect(latest.revision.parentRevisionIds, [prior.revision.revisionId]);
        expect(latest.bindingId, isNot(prior.bindingId));
      } else {
        expect(
          latest.revision.revisionId,
          (arrived ?? prior).revision.revisionId,
        );
      }
      final savedPrior = await withPumping(
        tester,
        () => store.readLatest(note, revisionId: prior.revision.revisionId),
      );
      final savedInk = await withPumping(
        tester,
        () => repository.readFiles(priorInkRevision),
      );
      expect(savedPrior.originalBytes, original);
      expect(savedPrior.pdfBytes, oldPdf);
      expect(savedInk['main.sbn2'], oldInk);
    });
  }

  for (final outcome in [
    'save',
    'cancel',
    'newer source before apply',
    'wrong target',
    'wrong PDF',
  ]) {
    testWidgets('Android PPTX shape deletion handles $outcome', (tester) async {
      final original = pptxPhotoFixture();
      final archive = Archive();
      for (final file in ZipDecoder().decodeBytes(original).files) {
        if (!file.isFile) continue;
        var bytes = file.content;
        if (file.name == 'ppt/slides/slide1.xml') {
          final xml = utf8.decode(bytes);
          final target = RegExp(r'<p:sp>[\s\S]*?</p:sp>').firstMatch(xml)!;
          bytes = utf8.encode(xml.replaceRange(target.start, target.end, ''));
        }
        archive.addFile(ArchiveFile.bytes(file.name, bytes));
      }
      final candidate = Uint8List.fromList(ZipEncoder().encode(archive));
      final oldPdf = annotationPdf('before shape deletion');
      final newPdf = annotationPdf('after shape deletion');
      final oldInk = Uint8List.fromList([2, 8, 16]);
      final (prior, priorInkRevision) = await withPumping(tester, () async {
        note = await store.importDocument(
          title: 'Lecture PPTX',
          fileName: 'lecture.pptx',
          bytes: original,
        );
        final prior = await store.commitEdited(
          await store.beginEdit(note),
          originalBytes: original,
          pdfBytes: oldPdf,
          engineVersion: 'before-shape-delete',
          pageCount: 1,
        );
        final ink = await OfficeAnnotationStore(repository).open(note, prior);
        return (prior, await ink.saveFiles({'main.sbn2': oldInk}));
      });
      final editor = _FixturePptxShapeDelete(
        original,
        candidate,
        wrongTarget: outcome == 'wrong target',
      );
      var rendered = 0, disposed = 0;
      final engine = _FixtureAndroidCloneEngine((path, id, sourceHash) async {
        rendered++;
        expect(path, editor.outputPath);
        expect(sourceHash, sha256.convert(candidate).toString());
        expect(await File(path).readAsBytes(), candidate);
        final output = await File(p.join(temp.path, 'shape-deletion-$id.pdf'))
            .writeAsBytes(newPdf);
        return _FixtureAndroidCloneObservation(
          sessionId: id,
          sourceSha256: sourceHash,
          pdf: output,
          pdfSha256: sha256
              .convert(outcome == 'wrong PDF' ? oldPdf : newPdf)
              .toString(),
          partCount: 1,
          pageCount: 1,
          onDispose: () => disposed++,
        );
      });
      await mount(tester, engine, pptxShapeDelete: editor);
      final launch = find.byKey(const ValueKey('office-delete-pptx-shape'));
      final slide = find.byKey(const ValueKey('pptx-shape-delete-slide'));
      final shapes = find.byKey(const ValueKey('pptx-shape-delete-target'));
      final confirm = find.byKey(const ValueKey('pptx-shape-delete-confirm'));
      await tester.ensureVisible(launch);
      await tester.runAsync(() => tester.tap(launch));
      for (var i = 0; i < 12 && slide.evaluate().isEmpty; i++) {
        await drain(tester);
      }
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      Future<void> choose(Finder dropdown, String option) async {
        await tester.tap(dropdown);
        await tester.pump(const Duration(milliseconds: 350));
        await tester.tap(find.byKey(ValueKey(option)).last);
        await tester.pump(const Duration(milliseconds: 350));
      }

      await choose(slide, 'pptx-shape-delete-slide-0');
      for (var i = 0; i < 12 && shapes.evaluate().isEmpty; i++) {
        await drain(tester);
      }
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      await choose(shapes, 'pptx-shape-delete-target-2');
      expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
      expect(editor.deleteCalls, 0);
      final stale = outcome == 'newer source before apply';
      final arrived = stale
          ? await withPumping(
              tester,
              () async => store.commitEdited(
                await store.beginEdit(note),
                originalBytes: original,
                pdfBytes: annotationPdf('newer source from a peer'),
                engineVersion: 'peer',
                pageCount: 1,
              ),
            )
          : null;
      final cancel = outcome == 'cancel';
      await tester.tap(
        cancel
            ? find.byKey(const ValueKey('pptx-shape-delete-cancel'))
            : confirm,
      );
      for (var i = 0; i < 12; i++) {
        await drain(tester);
        if (!File(editor.sourcePath!).parent.existsSync()) break;
      }
      expect(File(editor.sourcePath!).parent.existsSync(), isFalse);
      expect(editor.deleteCalls, cancel || stale ? 0 : 1);
      expect(rendered, outcome == 'save' || outcome == 'wrong PDF' ? 1 : 0);
      expect(disposed, rendered);
      final latest = await withPumping(tester, () => store.readLatest(note));
      final priorAgain = await withPumping(
        tester,
        () => store.readLatest(note, revisionId: prior.revision.revisionId),
      );
      final savedInk = await withPumping(
        tester,
        () => repository.readFiles(priorInkRevision),
      );
      expect(priorAgain.originalBytes, original);
      expect(priorAgain.pdfBytes, oldPdf);
      expect(savedInk['main.sbn2'], oldInk);
      if (outcome == 'save') {
        expect(latest.originalBytes, candidate);
        expect(latest.pdfBytes, newPdf);
        expect(latest.bindingId, isNot(prior.bindingId));
        expect(latest.revision.parentRevisionIds, [prior.revision.revisionId]);
        expect(find.text('도형을 삭제하고 새 원본과 PDF를 저장했습니다.'), findsOneWidget);
      } else {
        expect(latest.originalBytes, original);
        expect(
          latest.revision.revisionId,
          arrived?.revision.revisionId ?? prior.revision.revisionId,
        );
      }
    });
  }

  for (final outcome in [
    'save',
    'wrong geometry',
    'wrong PDF',
    'newer source',
  ]) {
    testWidgets('Android PPTX shape geometry handles $outcome', (tester) async {
      final original = pptxPhotoFixture();
      final candidateArchive = Archive();
      for (final entry in ZipDecoder().decodeBytes(original).files) {
        if (!entry.isFile) continue;
        final bytes = entry.name == 'ppt/slides/slide1.xml'
            ? utf8.encode(
                utf8
                    .decode(entry.content)
                    .replaceFirst(
                      '<a:off x="800000" y="2900000"/><a:ext cx="2650000"',
                      '<a:off x="-378000" y="2900000"/><a:ext cx="2700000"',
                    ),
              )
            : entry.content;
        candidateArchive.addFile(ArchiveFile.bytes(entry.name, bytes));
      }
      final candidate = Uint8List.fromList(
        ZipEncoder().encode(candidateArchive),
      );
      final oldPdf = annotationPdf('before shape geometry');
      final newPdf = annotationPdf('after shape geometry');
      final oldInk = Uint8List.fromList([8, 16, 32]);
      final (prior, priorInkRevision) = await withPumping(tester, () async {
        note = await store.importDocument(
          title: 'Lecture PPTX',
          fileName: 'lecture.pptx',
          bytes: original,
        );
        final prior = await store.commitEdited(
          await store.beginEdit(note),
          originalBytes: original,
          pdfBytes: oldPdf,
          engineVersion: 'before-geometry',
          pageCount: 1,
        );
        final ink = await OfficeAnnotationStore(repository).open(note, prior);
        return (prior, await ink.saveFiles({'main.sbn2': oldInk}));
      });
      final editor = _FixturePptxShapeGeometry(
        original,
        candidate,
        wrongReply: outcome == 'wrong geometry',
      );
      OfficeEdition? peer;
      var rendered = 0, disposed = 0;
      final engine = _FixtureAndroidCloneEngine((path, id, sourceHash) async {
        rendered++;
        expect(path, editor.outputPath);
        expect(sourceHash, sha256.convert(candidate).toString());
        expect(await File(path).readAsBytes(), candidate);
        if (outcome == 'newer source') {
          peer = await store.commitEdited(
            await store.beginEdit(note),
            originalBytes: original,
            pdfBytes: annotationPdf('newer geometry from a peer'),
            engineVersion: 'peer',
            pageCount: 1,
          );
        }
        final output = await File(p.join(temp.path, 'shape-geometry-$id.pdf'))
            .writeAsBytes(newPdf);
        return _FixtureAndroidCloneObservation(
          sessionId: id,
          sourceSha256: sourceHash,
          pdf: output,
          pdfSha256: sha256
              .convert(outcome == 'wrong PDF' ? oldPdf : newPdf)
              .toString(),
          partCount: 1,
          pageCount: 1,
          onDispose: () => disposed++,
        );
      });
      await mount(tester, engine, pptxShapeGeometry: editor);
      final launch = find.byKey(
        const ValueKey('office-edit-pptx-shape-geometry'),
      );
      await tester.ensureVisible(launch);
      await tester.runAsync(() => tester.tap(launch));
      final slides = find.byKey(const ValueKey('pptx-shape-geometry-slide'));
      for (var i = 0; i < 12 && slides.evaluate().isEmpty; i++) {
        await drain(tester);
      }
      Future<void> select(Finder menu, String option) async {
        await tester.tap(menu);
        await tester.pump(const Duration(milliseconds: 350));
        await tester.tap(find.byKey(ValueKey(option)).last);
        await tester.pump(const Duration(milliseconds: 350));
      }

      await select(slides, 'pptx-shape-geometry-slide-0');
      final shapes = find.byKey(const ValueKey('pptx-shape-geometry-shape'));
      for (var i = 0; i < 12 && shapes.evaluate().isEmpty; i++) {
        await drain(tester);
      }
      await select(shapes, 'pptx-shape-geometry-shape-100');
      for (final (field, value) in [('x', '-10.5'), ('width', '75')]) {
        final input = find.byKey(ValueKey('pptx-shape-geometry-$field'));
        await tester.ensureVisible(input);
        await tester.enterText(input, value);
        if (field == 'x' || outcome != 'save') await tester.pump();
      }
      final save = find.byKey(const ValueKey('pptx-shape-geometry-save'));
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pump();
      for (var i = 0; i < 12; i++) {
        await drain(tester);
        if (!File(editor.sourcePath!).parent.existsSync()) break;
      }
      expect(File(editor.sourcePath!).parent.existsSync(), isFalse);
      final applied = editor.applied!;
      expect(
        (applied.xEmu, applied.yEmu, applied.widthEmu, applied.heightEmu),
        (-378000, 2900000, 2700000, 1600000),
      );
      expect(rendered, outcome == 'wrong geometry' ? 0 : 1);
      expect(disposed, rendered);
      final latest = await withPumping(tester, () => store.readLatest(note));
      final priorAgain = await withPumping(
        tester,
        () => store.readLatest(note, revisionId: prior.revision.revisionId),
      );
      final savedInk = await withPumping(
        tester,
        () => repository.readFiles(priorInkRevision),
      );
      expect(priorAgain.originalBytes, original);
      expect(priorAgain.pdfBytes, oldPdf);
      expect(priorAgain.bindingId, prior.bindingId);
      expect(savedInk['main.sbn2'], oldInk);
      if (outcome == 'save') {
        expect(latest.originalBytes, candidate);
        expect(latest.pdfBytes, newPdf);
        expect(latest.bindingId, isNot(prior.bindingId));
        expect(latest.revision.parentRevisionIds, [prior.revision.revisionId]);
      } else {
        expect(latest.originalBytes, original);
        expect(
          latest.revision.revisionId,
          peer?.revision.revisionId ?? prior.revision.revisionId,
        );
      }
    });
  }

  for (final outcome in [
    'save',
    'unrelated pending revision',
    'wrong shape',
    'newer source before apply',
  ]) {
    testWidgets('Android PPTX existing shape text handles $outcome', (
      tester,
    ) async {
      final saves =
          outcome == 'save' || outcome == 'unrelated pending revision';
      final original = pptxPhotoFixture();
      final candidate = replacePptxPhoto(
        original,
        listPptxPhotos(original).first,
        pptxReplacementPhoto(),
      );
      final oldPdf = annotationPdf('before shape text');
      final newPdf = annotationPdf('verified shape text');
      final oldInk = Uint8List.fromList([4, 8, 16]);
      final (prior, priorInkRevision) = await withPumping(tester, () async {
        note = await store.importDocument(
          title: 'Lecture PPTX',
          fileName: 'lecture.pptx',
          bytes: original,
        );
        final prior = await store.commitEdited(
          await store.beginEdit(note),
          originalBytes: original,
          pdfBytes: oldPdf,
          engineVersion: 'before-shape-text',
          pageCount: 2,
        );
        final ink = await OfficeAnnotationStore(repository).open(note, prior);
        return (prior, await ink.saveFiles({'main.sbn2': oldInk}));
      });
      final adapter = _FixturePptxShapeText(
        original,
        candidate,
        wrongShape: outcome == 'wrong shape',
      );
      var rendered = 0, disposed = 0;
      final engine = _FixtureAndroidCloneEngine((path, id, sourceHash) async {
        rendered++;
        expect(path, adapter.outputPath);
        expect(sourceHash, sha256.convert(candidate).toString());
        expect(await File(path).readAsBytes(), candidate);
        final output = await File(p.join(temp.path, 'shape-text-$id.pdf'))
            .writeAsBytes(newPdf);
        return _FixtureAndroidCloneObservation(
          sessionId: id,
          sourceSha256: sourceHash,
          pdf: output,
          pdfSha256: sha256.convert(newPdf).toString(),
          partCount: 2,
          pageCount: 2,
          onDispose: () => disposed++,
        );
      });
      await mount(tester, engine, pptxShapeText: adapter);
      final launch = find.byKey(const ValueKey('office-edit-pptx-shape-text'));
      await tester.ensureVisible(launch);
      await tester.runAsync(() => tester.tap(launch));
      final slide = find.byKey(const ValueKey('pptx-shape-text-slide'));
      for (var i = 0; i < 12 && slide.evaluate().isEmpty; i++) {
        await drain(tester);
      }
      expect(slide, findsOneWidget);
      Future<void> choose(Finder menu, String label) async {
        await tester.tap(menu);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.tap(find.textContaining(label).last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
      }

      await choose(slide, '슬라이드 2');
      final shape = find.byKey(const ValueKey('pptx-shape-text-shape'));
      for (var i = 0; i < 12 && shape.evaluate().isEmpty; i++) {
        await drain(tester);
      }
      final first = find.byKey(const ValueKey('pptx-shape-text-run-0-0'));
      await choose(shape, '요점 도형');
      final second = find.byKey(const ValueKey('pptx-shape-text-run-1-0'));
      expect(first, findsOneWidget);
      expect(second, findsOneWidget);
      expect(adapter.loadedSlides.last, 1);
      await tester.enterText(first, '새 & <문구> 🧭');
      await tester.ensureVisible(second);
      await tester.enterText(second, '');

      if (outcome == 'unrelated pending revision') {
        await withPumping(tester, receiveIncompleteSource);
      }
      OfficeEdition? arrived;
      if (outcome == 'newer source before apply') {
        arrived = await withPumping(
          tester,
          () async => store.commitEdited(
            await store.beginEdit(note),
            originalBytes: original,
            pdfBytes: annotationPdf('arrived from peer'),
            engineVersion: 'peer-editor',
            pageCount: 2,
          ),
        );
      }
      await tester.tap(find.byKey(const ValueKey('pptx-shape-text-confirm')));
      await tester.pump();
      for (var i = 0; i < 12; i++) {
        await drain(tester);
        if (!File(adapter.sourcePath!).parent.existsSync()) break;
      }
      expect(File(adapter.sourcePath!).parent.existsSync(), isFalse);
      if (arrived != null) {
        expect(adapter.appliedChanges, isNull);
      } else {
        expect(
          adapter.appliedChanges!.map(
            (change) => (change.paragraphIndex, change.runIndex, change.text),
          ),
          [(0, 0, '새 & <문구> 🧭'), (1, 0, '')],
        );
      }
      expect(rendered, saves ? 1 : 0);
      expect(disposed, rendered);
      final latest = await withPumping(tester, () => store.readLatest(note));
      final savedPrior = await withPumping(
        tester,
        () => store.readLatest(note, revisionId: prior.revision.revisionId),
      );
      final savedInk = await withPumping(
        tester,
        () => repository.readFiles(priorInkRevision),
      );
      expect(savedPrior.originalBytes, original);
      expect(savedPrior.pdfBytes, oldPdf);
      expect(savedInk['main.sbn2'], oldInk);
      if (outcome == 'unrelated pending revision') {
        expect(repository.pendingRevisionCount, 1);
      }
      if (saves) {
        expect(latest.originalBytes, candidate);
        expect(latest.pdfBytes, newPdf);
        expect(latest.revision.parentRevisionIds, [prior.revision.revisionId]);
        expect(find.text('도형 텍스트를 수정하고 새 원본과 PDF를 저장했습니다.'), findsOneWidget);
      } else {
        expect(latest.originalBytes, original);
        expect(
          latest.revision.revisionId,
          arrived?.revision.revisionId ?? prior.revision.revisionId,
        );
      }
    });
  }

  for (final outcome in ['save', 'system back', 'newer source before apply']) {
    testWidgets('Android PPTX selected shape formatting handles $outcome', (
      tester,
    ) async {
      final original = pptxPhotoFixture();
      final archive = Archive();
      for (final entry in ZipDecoder().decodeBytes(original).files) {
        if (!entry.isFile) continue;
        final bytes = entry.name == 'ppt/slides/slide1.xml'
            ? utf8.encode(
                utf8
                    .decode(entry.content)
                    .replaceFirst(
                      '<a:rPr lang="ko-KR"',
                      '<a:rPr b="1" i="0" u="sng" sz="2450" lang="ko-KR"',
                    ),
              )
            : entry.content;
        archive.addFile(ArchiveFile.bytes(entry.name, bytes));
      }
      final candidate = Uint8List.fromList(ZipEncoder().encode(archive));
      final oldPdf = annotationPdf('before shape format');
      final newPdf = annotationPdf('verified shape format');
      final oldInk = Uint8List.fromList([12, 24, 48]);
      final (prior, priorInkRevision) = await withPumping(tester, () async {
        note = await store.importDocument(
          title: 'Lecture PPTX',
          fileName: 'lecture.pptx',
          bytes: original,
        );
        final prior = await store.commitEdited(
          await store.beginEdit(note),
          originalBytes: original,
          pdfBytes: oldPdf,
          engineVersion: 'before-shape-format',
          pageCount: 2,
        );
        final ink = await OfficeAnnotationStore(repository).open(note, prior);
        return (prior, await ink.saveFiles({'main.sbn2': oldInk}));
      });
      final adapter = _FixturePptxShapeText(
        original,
        candidate,
        wrongShape: false,
      );
      var rendered = 0, disposed = 0;
      final engine = _FixtureAndroidCloneEngine((path, id, sourceHash) async {
        rendered++;
        expect(path, adapter.outputPath);
        expect(sourceHash, sha256.convert(candidate).toString());
        expect(await File(path).readAsBytes(), candidate);
        final output = await File(p.join(temp.path, 'shape-format-$id.pdf'))
            .writeAsBytes(newPdf);
        return _FixtureAndroidCloneObservation(
          sessionId: id,
          sourceSha256: sourceHash,
          pdf: output,
          pdfSha256: sha256.convert(newPdf).toString(),
          partCount: 2,
          pageCount: 2,
          onDispose: () => disposed++,
        );
      });
      await mount(tester, engine, pptxShapeText: adapter);
      final launch = find.byKey(
        const ValueKey('office-format-pptx-shape-text'),
      );
      await tester.ensureVisible(launch);
      await tester.runAsync(() => tester.tap(launch));
      final slide = find.byKey(const ValueKey('pptx-shape-text-slide'));
      for (var i = 0; i < 12 && slide.evaluate().isEmpty; i++) {
        await drain(tester);
      }
      Future<void> choose(Finder menu, Finder option) async {
        await tester.ensureVisible(menu);
        await tester.tap(menu);
        await tester.pump(const Duration(milliseconds: 350));
        await tester.tap(option.last);
        await tester.pump(const Duration(milliseconds: 350));
      }

      await choose(slide, find.textContaining('슬라이드 2'));
      final shape = find.byKey(const ValueKey('pptx-shape-text-shape'));
      for (var i = 0; i < 12 && shape.evaluate().isEmpty; i++) {
        await drain(tester);
      }
      await choose(shape, find.text('요점 도형'));
      final first = find.byKey(const ValueKey('pptx-shape-format-run-0-0'));
      final second = find.byKey(const ValueKey('pptx-shape-format-run-1-0'));
      final bold = find.byKey(const ValueKey('pptx-shape-format-bold'));
      final confirm = find.byKey(const ValueKey('pptx-shape-format-confirm'));
      Future<void> select(Finder field, int start, int end) async {
        await Scrollable.ensureVisible(tester.element(field), alignment: 0.5);
        await tester.pump();
        expect(field.hitTestable(), findsOneWidget);
        await tester.tap(field);
        final textField = tester.widget<TextField>(field);
        expect(textField.readOnly, isTrue);
        textField.controller!.selection = TextSelection(
          baseOffset: start,
          extentOffset: end,
        );
        await tester.pump();
      }

      await select(first, 3, 4);
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      await select(first, 3, 8);
      expect(find.text('선택한 글자  🧑‍🔬'), findsOneWidget);
      await choose(bold, find.text('굵게 적용'));
      expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
      await select(second, 0, 2);
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      await select(first, 3, 8);
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      for (final (style, option) in [
        ('bold', '굵게 적용'),
        ('italic', '기울임 해제'),
        ('underline', '밑줄 적용'),
      ]) {
        await choose(
          find.byKey(ValueKey('pptx-shape-format-$style')),
          find.text(option),
        );
      }
      final fontSize = find.byKey(
        const ValueKey('pptx-shape-format-font-size'),
      );
      final fontColor = find.byKey(
        const ValueKey('pptx-shape-format-font-color'),
      );
      await tester.ensureVisible(fontSize);
      await tester.enterText(fontSize, '24.5');
      await tester.ensureVisible(fontColor);
      await tester.enterText(fontColor, '#3366cc');
      await tester.pump();

      OfficeEdition? arrived;
      if (outcome == 'newer source before apply') {
        arrived = await withPumping(
          tester,
          () async => store.commitEdited(
            await store.beginEdit(note),
            originalBytes: original,
            pdfBytes: annotationPdf('peer shape format'),
            engineVersion: 'peer-editor',
            pageCount: 2,
          ),
        );
      }
      if (outcome == 'system back') {
        await tester.binding.handlePopRoute();
      } else {
        await tester.ensureVisible(confirm);
        await tester.tap(confirm);
      }
      await tester.pump();
      for (var i = 0; i < 12; i++) {
        await drain(tester);
        if (!File(adapter.sourcePath!).parent.existsSync()) break;
      }
      expect(File(adapter.sourcePath!).parent.existsSync(), isFalse);
      expect(adapter.appliedChanges, isNull);
      final latest = await withPumping(tester, () => store.readLatest(note));
      final savedPrior = await withPumping(
        tester,
        () => store.readLatest(note, revisionId: prior.revision.revisionId),
      );
      final savedInk = await withPumping(
        tester,
        () => repository.readFiles(priorInkRevision),
      );
      expect(savedPrior.originalBytes, original);
      expect(savedPrior.pdfBytes, oldPdf);
      expect(savedInk['main.sbn2'], oldInk);
      if (outcome == 'save') {
        final format = adapter.appliedFormat!;
        expect(
          (format.paragraphIndex, format.runIndex, format.start, format.end),
          (0, 0, 3, 8),
        );
        expect(
          (format.bold, format.italic, format.underline),
          (true, false, true),
        );
        expect((format.fontSize, format.fontColor), (2450, '3366CC'));
        expect(latest.originalBytes, candidate);
        expect(latest.pdfBytes, newPdf);
        expect(latest.revision.parentRevisionIds, [prior.revision.revisionId]);
        expect(find.text('도형 글자 서식을 적용하고 새 원본과 PDF를 저장했습니다.'), findsOneWidget);
      } else {
        expect(adapter.appliedFormat, isNull);
        expect(latest.originalBytes, original);
        expect(
          latest.revision.revisionId,
          arrived?.revision.revisionId ?? prior.revision.revisionId,
        );
      }
      expect(rendered, outcome == 'save' ? 1 : 0);
      expect(disposed, rendered);
    });
  }

  test('PPTX text boxes accept plain Unicode with normalized line breaks', () {
    final text = PptxTextBoxEngine.normalizeText('  한글 🧭\r\n다음\r끝  ');
    expect(text, '  한글 🧭\n다음\n끝  ');
    expect(PptxTextBoxEngine.validText(text), isTrue);
    expect(
      PptxTextBoxEngine.validText(List.filled(8, '문구').join('\n')),
      isTrue,
    );
    for (final invalid in [
      '\n ',
      '문구\t입력',
      List.filled(9, '문구').join('\n'),
      List.filled(301, '🧭').join(),
      String.fromCharCode(0xd800),
    ]) {
      expect(PptxTextBoxEngine.validText(invalid), isFalse);
    }
  });

  for (final outcome in [
    'save',
    'system back',
    'wrong slide',
    'wrong PDF',
    'newer source before apply',
    'newer source during preview',
  ]) {
    testWidgets('Android PPTX text box handles $outcome', (tester) async {
      final original = pptxPhotoFixture();
      final candidate = replacePptxPhoto(
        original,
        listPptxPhotos(original).first,
        pptxReplacementPhoto(),
      );
      final oldPdf = annotationPdf('before text box');
      final newPdf = annotationPdf('verified text box');
      final oldInk = Uint8List.fromList([2, 4, 8]);
      final (prior, priorInkRevision) = await withPumping(tester, () async {
        note = await store.importDocument(
          title: 'Lecture PPTX',
          fileName: 'lecture.pptx',
          bytes: original,
        );
        final prior = await store.commitEdited(
          await store.beginEdit(note),
          originalBytes: original,
          pdfBytes: oldPdf,
          engineVersion: 'before-text-box',
          pageCount: 2,
        );
        final ink = await OfficeAnnotationStore(repository).open(note, prior);
        return (prior, await ink.saveFiles({'main.sbn2': oldInk}));
      });
      final adapter = _FixturePptxTextBox(
        original,
        candidate,
        wrongSlide: outcome == 'wrong slide',
      );
      var rendered = 0, disposed = 0;
      OfficeEdition? arrived;
      Future<OfficeEdition> receiveNewerSource() async => store.commitEdited(
        await store.beginEdit(note),
        originalBytes: original,
        pdfBytes: annotationPdf('arrived from peer'),
        engineVersion: 'peer-editor',
        pageCount: 2,
      );
      final engine = _FixtureAndroidCloneEngine((path, id, sourceHash) async {
        rendered++;
        expect(path, adapter.outputPath);
        expect(sourceHash, sha256.convert(candidate).toString());
        expect(await File(path).readAsBytes(), candidate);
        if (outcome == 'newer source during preview') {
          arrived = await receiveNewerSource();
        }
        final output = await File(p.join(temp.path, 'text-box-$id.pdf'))
            .writeAsBytes(newPdf);
        return _FixtureAndroidCloneObservation(
          sessionId: id,
          sourceSha256: sourceHash,
          pdf: output,
          pdfSha256: sha256.convert(newPdf).toString(),
          partCount: 2,
          pageCount: outcome == 'wrong PDF' ? 1 : 2,
          onDispose: () => disposed++,
        );
      });
      await mount(tester, engine, pptxTextBox: adapter);
      final launch = find.byKey(const ValueKey('office-add-pptx-text-box'));
      await tester.ensureVisible(launch);
      await tester.runAsync(() => tester.tap(launch));
      final slide = find.byKey(const ValueKey('pptx-text-box-slide'));
      for (var i = 0; i < 12 && slide.evaluate().isEmpty; i++) {
        await drain(tester);
      }
      expect(slide, findsOneWidget);
      final confirm = find.byKey(const ValueKey('pptx-text-box-confirm'));
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

      Future<void> selectOption(Finder menu, String option) async {
        await tester.ensureVisible(menu);
        await tester.tap(menu);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.tap(find.text(option).last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
      }

      if (outcome == 'system back') {
        await tester.binding.handlePopRoute();
      } else {
        await selectOption(slide, '슬라이드 2 · 숨김 · 예시 · 실습 구역');
        await selectOption(
          find.byKey(const ValueKey('pptx-text-box-placement')),
          '아래쪽',
        );
        if (outcome == 'save') {
          await tester.tap(confirm);
          await tester.pump();
          expect(find.textContaining('범위에서 텍스트를 입력'), findsOneWidget);
          expect(adapter.added, isNull);
        }
        if (outcome == 'newer source before apply') {
          arrived = await withPumping(tester, receiveNewerSource);
        }
        await tester.enterText(
          find.byKey(const ValueKey('pptx-text-box-size')),
          '32',
        );
        await tester.enterText(
          find.byKey(const ValueKey('pptx-text-box-text')),
          '  한글 & <문구> 🧭\n마지막 글자  ',
        );
        await tester.tap(confirm);
      }
      await tester.pump();
      for (var i = 0; i < 12; i++) {
        await drain(tester);
        if (!File(adapter.sourcePath!).parent.existsSync()) break;
      }
      expect(File(adapter.sourcePath!).parent.existsSync(), isFalse);
      if ({'system back', 'newer source before apply'}.contains(outcome)) {
        expect(adapter.added, isNull);
      } else {
        expect(adapter.added, (
          index: 1,
          text: '  한글 & <문구> 🧭\n마지막 글자  ',
          placement: PptxTextBoxPlacement.bottom,
          size: 32,
        ));
      }
      expect(
        rendered,
        {'save', 'wrong PDF', 'newer source during preview'}.contains(outcome)
            ? 1
            : 0,
      );
      expect(disposed, rendered);
      final latest = await withPumping(tester, () => store.readLatest(note));
      final savedPrior = await withPumping(
        tester,
        () => store.readLatest(note, revisionId: prior.revision.revisionId),
      );
      final savedInk = await withPumping(
        tester,
        () => repository.readFiles(priorInkRevision),
      );
      expect(savedPrior.originalBytes, original);
      expect(savedPrior.pdfBytes, oldPdf);
      expect(savedPrior.bindingId, prior.bindingId);
      expect(savedInk['main.sbn2'], oldInk);
      if (outcome == 'save') {
        expect(latest.originalBytes, candidate);
        expect(latest.pdfBytes, newPdf);
        expect(latest.pageCount, 2);
        expect(latest.bindingId, isNot(prior.bindingId));
        expect(latest.revision.parentRevisionIds, [prior.revision.revisionId]);
        expect(find.text('텍스트 상자를 추가하고 새 원본과 PDF를 저장했습니다.'), findsOneWidget);
      } else {
        expect(latest.originalBytes, original);
        expect(
          latest.revision.revisionId,
          arrived?.revision.revisionId ?? prior.revision.revisionId,
        );
      }
    });
  }

  testWidgets('Android PPTX exposes blank slide and preset shape insertion', (
    tester,
  ) async {
    note = await withPumping(
      tester,
      () => store.importDocument(
        title: 'Lecture PPTX',
        fileName: 'lecture.pptx',
        bytes: pptxPhotoFixture(),
      ),
    );
    await mount(tester, FixtureOfficeEngine());
    expect(
      find.byKey(const ValueKey('office-duplicate-pptx-slide')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('office-delete-pptx-slide')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('office-insert-pptx-slide')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('office-change-pptx-slide-layout')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('office-add-pptx-preset-shape')),
      findsOneWidget,
    );
  });

  for (final outcome in ['save', 'wrong slide', 'newer source']) {
    testWidgets('Android PPTX preset shape handles $outcome', (tester) async {
      final original = pptxPhotoFixture();
      final candidate = replacePptxPhoto(
        original,
        listPptxPhotos(original).first,
        pptxReplacementPhoto(),
      );
      final oldPdf = annotationPdf('before preset shape');
      final newPdf = annotationPdf('verified preset shape');
      final oldInk = Uint8List.fromList([4, 7, 2]);
      final (prior, priorInkRevision) = await withPumping(tester, () async {
        note = await store.importDocument(
          title: 'Lecture PPTX',
          fileName: 'lecture.pptx',
          bytes: original,
        );
        final prior = await store.commitEdited(
          await store.beginEdit(note),
          originalBytes: original,
          pdfBytes: oldPdf,
          engineVersion: 'before-preset-shape',
          pageCount: 2,
        );
        final ink = await OfficeAnnotationStore(repository).open(note, prior);
        return (prior, await ink.saveFiles({'main.sbn2': oldInk}));
      });
      final adapter = _FixturePptxPresetShape(
        original,
        candidate,
        wrongSlide: outcome == 'wrong slide',
      );
      var rendered = 0, disposed = 0;
      final engine = _FixtureAndroidCloneEngine((path, id, sourceHash) async {
        rendered++;
        expect(path, adapter.outputPath);
        expect(sourceHash, sha256.convert(candidate).toString());
        expect(await File(path).readAsBytes(), candidate);
        final output = await File(p.join(temp.path, 'preset-shape-$id.pdf'))
            .writeAsBytes(newPdf);
        return _FixtureAndroidCloneObservation(
          sessionId: id,
          sourceSha256: sourceHash,
          pdf: output,
          pdfSha256: sha256.convert(newPdf).toString(),
          partCount: 2,
          pageCount: 2,
          onDispose: () => disposed++,
        );
      });
      await mount(tester, engine, pptxTextBox: adapter);
      final launch = find.byKey(const ValueKey('office-add-pptx-preset-shape'));
      await tester.ensureVisible(launch);
      await tester.runAsync(() => tester.tap(launch));
      final slide = find.byKey(const ValueKey('pptx-preset-shape-slide'));
      for (var i = 0; i < 12 && slide.evaluate().isEmpty; i++) {
        await drain(tester);
      }
      expect(slide, findsOneWidget);
      final confirm = find.byKey(const ValueKey('pptx-preset-shape-confirm'));
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

      Future<void> select(String field, String option) async {
        final menu = find.byKey(ValueKey('pptx-preset-shape-$field'));
        await tester.ensureVisible(menu);
        await tester.tap(menu);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.tap(find.text(option).last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
      }

      await select('slide', '슬라이드 2 · 숨김 · 예시 · 실습 구역');
      await select('kind', '오른쪽 화살표');
      await select('fill', '없음');
      await select('line', '빨강');
      await select('placement', '아래쪽');
      OfficeEdition? arrived;
      if (outcome == 'newer source') {
        arrived = await withPumping(
          tester,
          () async => store.commitEdited(
            await store.beginEdit(note),
            originalBytes: original,
            pdfBytes: annotationPdf('arrived from peer'),
            engineVersion: 'peer-editor',
            pageCount: 2,
          ),
        );
      }
      await tester.tap(confirm);
      await tester.pump();
      for (var i = 0; i < 12; i++) {
        await drain(tester);
        if (!File(adapter.sourcePath!).parent.existsSync()) break;
      }
      expect(File(adapter.sourcePath!).parent.existsSync(), isFalse);
      if (outcome == 'newer source') {
        expect(adapter.shape, isNull);
      } else {
        expect(adapter.shape, (
          kind: PptxPresetShape.rightArrow,
          fill: null,
          line: 'B91C1C',
        ));
        expect(adapter.added, (
          index: 1,
          text: '',
          placement: PptxTextBoxPlacement.bottom,
          size: 24,
        ));
      }
      expect(disposed, rendered);
      final latest = await withPumping(tester, () => store.readLatest(note));
      final savedInk = await withPumping(
        tester,
        () => repository.readFiles(priorInkRevision),
      );
      expect(savedInk['main.sbn2'], oldInk);
      if (outcome == 'save') {
        expect(rendered, 1);
        expect(latest.originalBytes, candidate);
        expect(latest.pdfBytes, newPdf);
        expect(latest.bindingId, isNot(prior.bindingId));
        expect(latest.revision.parentRevisionIds, [prior.revision.revisionId]);
        expect(find.text('도형을 추가하고 새 원본과 PDF를 저장했습니다.'), findsOneWidget);
      } else {
        expect(rendered, 0);
        expect(latest.originalBytes, original);
        expect(
          latest.revision.revisionId,
          arrived?.revision.revisionId ?? prior.revision.revisionId,
        );
      }
    });
  }

  for (final outcome in [
    'save',
    'layout cancel',
    'no compatible slide',
    'wrong slide ID',
    'PDF count mismatch',
    'newer source',
  ]) {
    testWidgets('Android PPTX layout change handles $outcome', (tester) async {
      final original = pptxPhotoFixture();
      final candidate = replacePptxPhoto(
        original,
        listPptxPhotos(original).first,
        pptxReplacementPhoto(),
      );
      final oldPdf = annotationPdf('before layout');
      final newPdf = annotationPdf('verified layout');
      final oldInk = Uint8List.fromList([1, 2, 3]);
      final (prior, priorInkRevision) = await withPumping(tester, () async {
        note = await store.importDocument(
          title: 'Lecture PPTX',
          fileName: 'lecture.pptx',
          bytes: original,
        );
        final prior = await store.commitEdited(
          await store.beginEdit(note),
          originalBytes: original,
          pdfBytes: oldPdf,
          engineVersion: 'before-layout',
          pageCount: 2,
        );
        final ink = await OfficeAnnotationStore(repository).open(note, prior);
        return (prior, await ink.saveFiles({'main.sbn2': oldInk}));
      });
      final adapter = _FixturePptxSlideLayout(
        original,
        candidate,
        unavailable: outcome == 'no compatible slide',
        wrongSlide: outcome == 'wrong slide ID',
      );
      var rendered = 0, disposed = 0;
      OfficeEdition? arrived;
      final engine = _FixtureAndroidCloneEngine((path, id, sourceHash) async {
        rendered++;
        expect(path, adapter.outputPath);
        expect(sourceHash, sha256.convert(candidate).toString());
        expect(await File(path).readAsBytes(), candidate);
        if (outcome == 'newer source') {
          arrived = await store.commitEdited(
            await store.beginEdit(note),
            originalBytes: original,
            pdfBytes: annotationPdf('arrived from peer'),
            engineVersion: 'peer-editor',
            pageCount: 2,
          );
        }
        final output = await File(p.join(temp.path, 'layout-$id.pdf'))
            .writeAsBytes(newPdf);
        return _FixtureAndroidCloneObservation(
          sessionId: id,
          sourceSha256: sourceHash,
          pdf: output,
          pdfSha256: sha256.convert(newPdf).toString(),
          partCount: 2,
          pageCount: outcome == 'PDF count mismatch' ? 1 : 2,
          onDispose: () => disposed++,
        );
      });
      await mount(tester, engine, pptxSlideLayout: adapter);
      final launch = find.byKey(
        const ValueKey('office-change-pptx-slide-layout'),
      );
      await tester.ensureVisible(launch);
      await tester.runAsync(() => tester.tap(launch));
      final selected = find.byKey(const ValueKey('pptx-slide-change-target-2'));
      if (outcome != 'no compatible slide') {
        for (var i = 0; i < 12 && selected.evaluate().isEmpty; i++) {
          await drain(tester);
        }
        expect(find.text('슬라이드 2 · 숨김'), findsOneWidget);
        expect(find.textContaining('실습 구역'), findsOneWidget);
        final unavailable = find.byKey(
          const ValueKey('pptx-slide-change-target-1'),
        );
        expect(tester.widget<ListTile>(unavailable).enabled, isFalse);
        await tester.tap(selected);
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('pptx-slide-change-confirm')),
        );
        await tester.pump();
        final field = find.byKey(const ValueKey('pptx-slide-change-layout'));
        for (var i = 0; i < 12 && field.evaluate().isEmpty; i++) {
          await drain(tester);
        }
        expect(field, findsOneWidget);
        final confirm = find.byKey(
          const ValueKey('pptx-slide-change-layout-confirm'),
        );
        expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
        if (outcome == 'layout cancel') {
          await tester.binding.handlePopRoute();
        } else {
          await tester.tap(field);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 350));
          expect(find.text('빈 슬라이드'), findsNothing);
          expect(find.text('1 · 실습 레이아웃'), findsOneWidget);
          expect(find.text('요약 레이아웃'), findsOneWidget);
          expect(find.text('4 · 제목 및 내용'), findsOneWidget);
          expect(find.text('5 · 제목 및 내용'), findsOneWidget);
          await tester.tap(find.text('2 · 실습 레이아웃'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 350));
          expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
          await tester.tap(confirm);
        }
        await tester.pump();
      }
      for (var i = 0; i < 12; i++) {
        await drain(tester);
        if (adapter.sourcePath case final path?
            when !File(path).parent.existsSync()) {
          break;
        }
      }
      expect(File(adapter.sourcePath!).parent.existsSync(), isFalse);
      expect(
        adapter.applyCount,
        {'layout cancel', 'no compatible slide'}.contains(outcome) ? 0 : 1,
      );
      expect(
        rendered,
        {'save', 'PDF count mismatch', 'newer source'}.contains(outcome)
            ? 1
            : 0,
      );
      expect(disposed, rendered);
      final latest = await withPumping(tester, () => store.readLatest(note));
      final savedPrior = await withPumping(
        tester,
        () => store.readLatest(note, revisionId: prior.revision.revisionId),
      );
      final savedInk = await withPumping(
        tester,
        () => repository.readFiles(priorInkRevision),
      );
      expect(savedPrior.originalBytes, original);
      expect(savedPrior.pdfBytes, oldPdf);
      expect(savedPrior.bindingId, prior.bindingId);
      expect(savedInk['main.sbn2'], oldInk);
      if (outcome == 'save') {
        expect(latest.originalBytes, candidate);
        expect(latest.pdfBytes, newPdf);
        expect(latest.pageCount, 2);
        expect(latest.bindingId, isNot(prior.bindingId));
        expect(latest.revision.parentRevisionIds, [prior.revision.revisionId]);
        expect(find.text('슬라이드 레이아웃을 변경하고 새 원본과 PDF를 저장했습니다.'), findsOneWidget);
      } else {
        expect(
          latest.revision.revisionId,
          arrived?.revision.revisionId ?? prior.revision.revisionId,
        );
        final message = switch (outcome) {
          'no compatible slide' => '적용할 수 있는 호환 레이아웃이 없습니다.',
          'wrong slide ID' => '변경한 슬라이드와 PPTX 판본',
          'PDF count mismatch' => '슬라이드 수와 PDF 쪽 수',
          _ => null,
        };
        if (message != null)
          expect(find.textContaining(message), findsOneWidget);
      }
    });
  }

  for (final outcome in [
    'save',
    'save chosen layout',
    'save blank with layouts',
    'layout cancel',
    'wrong layout result',
    'picker cancel',
    'system back',
    'no eligible position',
    'wrong inserted index',
    'PDF count mismatch',
    'newer source',
  ]) {
    testWidgets('Android PPTX insert handles $outcome', (tester) async {
      final hasLayouts = outcome.contains('layout');
      final choosesLayout = {
        'save chosen layout',
        'wrong layout result',
      }.contains(outcome);
      final saves = {
        'save',
        'save chosen layout',
        'save blank with layouts',
      }.contains(outcome);
      final original = pptxPhotoFixture();
      final candidate = replacePptxPhoto(
        original,
        listPptxPhotos(original).first,
        pptxReplacementPhoto(),
      );
      final oldPdf = annotationPdf('before insert');
      final newPdf = annotationPdf('verified insert');
      final oldInk = Uint8List.fromList([1, 2, 3]);
      final (prior, priorInkRevision) = await withPumping(tester, () async {
        note = await store.importDocument(
          title: 'Lecture PPTX',
          fileName: 'lecture.pptx',
          bytes: original,
        );
        final prior = await store.commitEdited(
          await store.beginEdit(note),
          originalBytes: original,
          pdfBytes: oldPdf,
          engineVersion: 'before-insert',
          pageCount: 2,
        );
        final ink = await OfficeAnnotationStore(repository).open(note, prior);
        return (prior, await ink.saveFiles({'main.sbn2': oldInk}));
      });
      final adapter = _FixturePptxSlideInsert(
        original,
        candidate,
        noEligiblePosition: outcome == 'no eligible position',
        reportedIndex: outcome == 'wrong inserted index' ? 1 : 2,
        wrongLayout: outcome == 'wrong layout result',
        layouts: hasLayouts
            ? const [
                PptxSlideInsertLayout(
                  id: 2147483650,
                  name: '강의 레이아웃',
                  kind: 'obj',
                ),
              ]
            : const [],
      );
      var rendered = 0, disposed = 0;
      OfficeEdition? arrived;
      final engine = _FixtureAndroidCloneEngine((path, id, sourceHash) async {
        rendered++;
        expect(path, adapter.outputPath);
        expect(sourceHash, sha256.convert(candidate).toString());
        expect(await File(path).readAsBytes(), candidate);
        if (outcome == 'newer source') {
          arrived = await store.commitEdited(
            await store.beginEdit(note),
            originalBytes: original,
            pdfBytes: annotationPdf('arrived from peer'),
            engineVersion: 'peer-editor',
            pageCount: 2,
          );
        }
        final output = await File(p.join(temp.path, 'insert-$id.pdf'))
            .writeAsBytes(newPdf);
        return _FixtureAndroidCloneObservation(
          sessionId: id,
          sourceSha256: sourceHash,
          pdf: output,
          pdfSha256: sha256.convert(newPdf).toString(),
          partCount: 3,
          pageCount: outcome == 'PDF count mismatch' ? 2 : 3,
          onDispose: () => disposed++,
        );
      });
      await mount(tester, engine, pptxSlideInsert: adapter);
      final launch = find.byKey(const ValueKey('office-insert-pptx-slide'));
      await tester.ensureVisible(launch);
      await tester.runAsync(() => tester.tap(launch));
      final selected = find.byKey(const ValueKey('pptx-slide-insert-target-2'));
      if (outcome != 'no eligible position') {
        for (var i = 0; i < 12 && selected.evaluate().isEmpty; i++) {
          await drain(tester);
        }
        expect(find.text('슬라이드 2 · 숨김'), findsOneWidget);
        expect(find.textContaining('실습 구역'), findsOneWidget);
        final unavailable = find.byKey(
          const ValueKey('pptx-slide-insert-target-1'),
        );
        expect(tester.widget<ListTile>(unavailable).enabled, isFalse);
        final confirm = find.byKey(const ValueKey('pptx-slide-insert-confirm'));
        expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
        await tester.tap(selected);
        await tester.pump();
        expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
        if (outcome == 'system back') {
          await tester.binding.handlePopRoute();
        } else {
          await tester.tap(
            outcome == 'picker cancel'
                ? find.byKey(const ValueKey('pptx-slide-insert-cancel'))
                : confirm,
          );
        }
        await tester.pump();
        if (hasLayouts) {
          final field = find.byKey(const ValueKey('pptx-slide-insert-layout'));
          for (var i = 0; i < 12 && field.evaluate().isEmpty; i++) {
            await drain(tester);
          }
          expect(field, findsOneWidget);
          if (outcome == 'layout cancel') {
            await tester.binding.handlePopRoute();
          } else {
            if (choosesLayout) {
              await tester.tap(field);
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 350));
              await tester.tap(find.text('강의 레이아웃').last);
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 350));
            }
            await tester.tap(
              find.byKey(const ValueKey('pptx-slide-insert-layout-confirm')),
            );
          }
          await tester.pump();
        }
      }
      for (var i = 0; i < 12; i++) {
        await drain(tester);
        if (adapter.sourcePath case final path?
            when !File(path).parent.existsSync()) {
          break;
        }
      }
      expect(File(adapter.sourcePath!).parent.existsSync(), isFalse);
      expect(
        adapter.applyCount,
        {
              'picker cancel',
              'layout cancel',
              'system back',
              'no eligible position',
            }.contains(outcome)
            ? 0
            : 1,
      );
      expect(adapter.requestedLayoutId, choosesLayout ? 2147483650 : null);
      expect(
        rendered,
        saves || {'PDF count mismatch', 'newer source'}.contains(outcome)
            ? 1
            : 0,
      );
      expect(disposed, rendered);
      final latest = await withPumping(tester, () => store.readLatest(note));
      final savedPrior = await withPumping(
        tester,
        () => store.readLatest(note, revisionId: prior.revision.revisionId),
      );
      final savedInk = await withPumping(
        tester,
        () => repository.readFiles(priorInkRevision),
      );
      expect(savedPrior.originalBytes, original);
      expect(savedPrior.pdfBytes, oldPdf);
      expect(savedPrior.bindingId, prior.bindingId);
      expect(savedInk['main.sbn2'], oldInk);
      if (saves) {
        expect(latest.originalBytes, candidate);
        expect(latest.pdfBytes, newPdf);
        expect(latest.pageCount, 3);
        expect(latest.bindingId, isNot(prior.bindingId));
        expect(latest.revision.parentRevisionIds, [prior.revision.revisionId]);
        final notice = choosesLayout
            ? '선택한 레이아웃으로 슬라이드를 추가하고 새 원본과 PDF를 저장했습니다.'
            : '빈 슬라이드를 추가하고 새 원본과 PDF를 저장했습니다.';
        expect(find.text(notice), findsOneWidget);
      } else if (outcome == 'newer source') {
        expect(latest.revision.revisionId, arrived!.revision.revisionId);
        expect(latest.originalBytes, original);
      } else {
        expect(latest.revision.revisionId, prior.revision.revisionId);
        final message = switch (outcome) {
          'no eligible position' => '빈 슬라이드를 추가할 수 있는 위치가 없습니다.',
          'wrong inserted index' ||
          'wrong layout result' => '추가한 슬라이드의 위치와 PPTX 판본',
          'PDF count mismatch' => '슬라이드 수와 PDF 쪽 수',
          _ => null,
        };
        if (message != null) {
          expect(find.textContaining(message), findsOneWidget);
        }
      }
    });
  }

  for (final outcome in [
    'save',
    'picker cancel',
    'system back',
    'last slide',
    'wrong slide',
    'PDF count mismatch',
    'newer source',
  ]) {
    testWidgets('Android PPTX delete handles $outcome', (tester) async {
      final original = pptxPhotoFixture();
      final candidate = replacePptxPhoto(
        original,
        listPptxPhotos(original).first,
        pptxReplacementPhoto(),
      );
      final oldPdf = annotationPdf('before delete');
      final newPdf = annotationPdf('verified delete');
      final oldInk = Uint8List.fromList([1, 2, 3]);
      final (prior, priorInkRevision) = await withPumping(tester, () async {
        note = await store.importDocument(
          title: 'Lecture PPTX',
          fileName: 'lecture.pptx',
          bytes: original,
        );
        final prior = await store.commitEdited(
          await store.beginEdit(note),
          originalBytes: original,
          pdfBytes: oldPdf,
          engineVersion: 'before-delete',
          pageCount: 2,
        );
        final ink = await OfficeAnnotationStore(repository).open(note, prior);
        return (prior, await ink.saveFiles({'main.sbn2': oldInk}));
      });
      final adapter = _FixturePptxSlideDelete(
        original,
        candidate,
        singleSlide: outcome == 'last slide',
        reportedIndex: outcome == 'wrong slide' ? 0 : 1,
      );
      var rendered = 0, disposed = 0;
      OfficeEdition? arrived;
      final engine = _FixtureAndroidCloneEngine((path, id, sourceHash) async {
        rendered++;
        expect(path, adapter.outputPath);
        expect(sourceHash, sha256.convert(candidate).toString());
        expect(await File(path).readAsBytes(), candidate);
        if (outcome == 'newer source') {
          arrived = await store.commitEdited(
            await store.beginEdit(note),
            originalBytes: original,
            pdfBytes: annotationPdf('arrived from peer'),
            engineVersion: 'peer-editor',
            pageCount: 2,
          );
        }
        final output = await File(p.join(temp.path, 'delete-$id.pdf'))
            .writeAsBytes(newPdf);
        return _FixtureAndroidCloneObservation(
          sessionId: id,
          sourceSha256: sourceHash,
          pdf: output,
          pdfSha256: sha256.convert(newPdf).toString(),
          partCount: 1,
          pageCount: outcome == 'PDF count mismatch' ? 2 : 1,
          onDispose: () => disposed++,
        );
      });
      await mount(tester, engine, pptxSlideDelete: adapter);
      final launch = find.byKey(const ValueKey('office-delete-pptx-slide'));
      await tester.ensureVisible(launch);
      await tester.runAsync(() => tester.tap(launch));
      final selected = find.byKey(const ValueKey('pptx-slide-delete-target-2'));
      if (outcome != 'last slide') {
        for (var i = 0; i < 12 && selected.evaluate().isEmpty; i++) {
          await drain(tester);
        }
        expect(find.text('슬라이드 2 · 숨김'), findsOneWidget);
        expect(find.textContaining('실습 구역'), findsOneWidget);
        final unavailable = find.byKey(
          const ValueKey('pptx-slide-delete-target-1'),
        );
        expect(tester.widget<ListTile>(unavailable).enabled, isFalse);
        final confirm = find.byKey(const ValueKey('pptx-slide-delete-confirm'));
        expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
        await tester.tap(selected);
        await tester.pump();
        expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
        if (outcome == 'system back') {
          await tester.binding.handlePopRoute();
        } else {
          await tester.tap(
            outcome == 'picker cancel'
                ? find.byKey(const ValueKey('pptx-slide-delete-cancel'))
                : confirm,
          );
        }
        await tester.pump();
      }
      for (var i = 0; i < 12; i++) {
        await drain(tester);
        if (adapter.sourcePath case final path?
            when !File(path).parent.existsSync()) {
          break;
        }
      }
      expect(File(adapter.sourcePath!).parent.existsSync(), isFalse);
      expect(
        adapter.applyCount,
        {'picker cancel', 'system back', 'last slide'}.contains(outcome)
            ? 0
            : 1,
      );
      expect(
        rendered,
        {'save', 'PDF count mismatch', 'newer source'}.contains(outcome)
            ? 1
            : 0,
      );
      expect(disposed, rendered);
      final latest = await withPumping(tester, () => store.readLatest(note));
      final savedPrior = await withPumping(
        tester,
        () => store.readLatest(note, revisionId: prior.revision.revisionId),
      );
      final savedInk = await withPumping(
        tester,
        () => repository.readFiles(priorInkRevision),
      );
      expect(savedPrior.originalBytes, original);
      expect(savedPrior.pdfBytes, oldPdf);
      expect(savedPrior.bindingId, prior.bindingId);
      expect(savedInk['main.sbn2'], oldInk);
      if (outcome == 'save') {
        expect(latest.originalBytes, candidate);
        expect(latest.pdfBytes, newPdf);
        expect(latest.pageCount, 1);
        expect(latest.bindingId, isNot(prior.bindingId));
        expect(latest.revision.parentRevisionIds, [prior.revision.revisionId]);
        expect(find.text('슬라이드를 삭제하고 새 원본과 PDF를 저장했습니다.'), findsOneWidget);
      } else if (outcome == 'newer source') {
        expect(latest.revision.revisionId, arrived!.revision.revisionId);
        expect(latest.originalBytes, original);
      } else {
        expect(latest.revision.revisionId, prior.revision.revisionId);
        final message = switch (outcome) {
          'last slide' => '마지막 슬라이드는 삭제할 수 없습니다.',
          'wrong slide' => '삭제한 슬라이드와 PPTX 판본',
          'PDF count mismatch' => '슬라이드 수와 PDF 쪽 수',
          _ => null,
        };
        if (message != null) {
          expect(find.textContaining(message), findsOneWidget);
        }
      }
    });
  }

  for (final (initial, requested, wrongPdf) in [
    ('inherited', '#F0E0D0', false),
    ('#F0E0D0', 'inherited', false),
    ('#ABCDEF', '#F0E0D0', true),
  ]) {
    testWidgets(
      'Android PPTX slide background $initial to $requested wrongPdf=$wrongPdf',
      (tester) async {
        final source = _pptxDisplayFixture(pptxPhotoFixture(), hidden: true);
        final original = _pptxBackgroundFixture(source, initial);
        final candidate = _pptxBackgroundFixture(source, requested);
        final oldPdf = annotationPdf('before slide background');
        final newPdf = annotationPdf('after slide background');
        final oldInk = Uint8List.fromList([2, 3, 4]);
        final (prior, inkRevision) = await withPumping(tester, () async {
          note = await store.importDocument(
            title: 'Lecture PPTX',
            fileName: 'lecture.pptx',
            bytes: original,
          );
          final prior = await store.commitEdited(
            await store.beginEdit(note),
            originalBytes: original,
            pdfBytes: oldPdf,
            engineVersion: 'before-slide-background',
            pageCount: 2,
          );
          final ink = await OfficeAnnotationStore(repository).open(note, prior);
          return (prior, await ink.saveFiles({'main.sbn2': oldInk}));
        });
        final adapter = _FixturePptxSlideBackground(
          original,
          candidate,
          initial,
          requested,
        );
        var rendered = 0, disposed = 0;
        final engine = _FixtureAndroidCloneEngine((path, id, hash) async {
          rendered++;
          expect(await File(path).readAsBytes(), candidate);
          expect(hash, sha256.convert(candidate).toString());
          final pdf = await File(p.join(temp.path, 'background-$id.pdf'))
              .writeAsBytes(newPdf);
          return _FixtureAndroidCloneObservation(
            sessionId: id,
            sourceSha256: hash,
            pdf: pdf,
            pdfSha256: sha256.convert(newPdf).toString(),
            partCount: 2,
            pageCount: wrongPdf ? 1 : 2,
            onDispose: () => disposed++,
          );
        });
        await mount(tester, engine, pptxSlideReorder: adapter);
        final launch = find.byKey(
          const ValueKey('office-edit-pptx-background'),
        );
        expect(launch, findsOneWidget);
        await tester.ensureVisible(launch);
        await tester.runAsync(() => tester.tap(launch));
        final slide = find.byKey(
          const ValueKey('pptx-slide-background-target-1'),
        );
        for (var i = 0; i < 12 && slide.evaluate().isEmpty; i++) {
          await drain(tester);
        }
        expect(find.text('슬라이드 1 · 숨김'), findsOneWidget);
        final unsupported = find.byKey(
          const ValueKey('pptx-slide-background-target-2'),
        );
        expect(tester.widget<ListTile>(unsupported).enabled, isFalse);
        await tester.tap(slide);
        await tester.pump();
        final continueButton = find.byKey(
          const ValueKey('pptx-slide-background-confirm'),
        );
        expect(
          tester.widget<FilledButton>(continueButton).onPressed,
          isNotNull,
        );
        await tester.tap(continueButton);
        final picker = find.byKey(
          const ValueKey('pptx-slide-background-picker'),
        );
        for (var i = 0; i < 12 && picker.evaluate().isEmpty; i++) {
          await drain(tester);
        }
        expect(picker, findsOneWidget);
        if (requested == 'inherited') {
          await tester.tap(
            find.byKey(const ValueKey('pptx-slide-background-reset')),
          );
        } else {
          tester
              .widget<ColorPicker>(picker)
              .onColorChanged(const Color(0xfff0e0d0));
          await tester.pump();
          await tester.tap(
            find.byKey(const ValueKey('pptx-slide-background-save')),
          );
        }
        await tester.pump();
        for (var i = 0; i < 12; i++) {
          await drain(tester);
          if (!File(adapter.sourcePath!).parent.existsSync()) break;
        }
        expect(File(adapter.sourcePath!).parent.existsSync(), isFalse);
        expect((adapter.applyCount, rendered, disposed), (1, 1, 1));
        final latest = await withPumping(tester, () => store.readLatest(note));
        final previous = await withPumping(
          tester,
          () => store.readLatest(note, revisionId: prior.revision.revisionId),
        );
        final ink = await withPumping(
          tester,
          () => repository.readFiles(inkRevision),
        );
        expect(previous.originalBytes, original);
        expect(previous.pdfBytes, oldPdf);
        expect(ink['main.sbn2'], oldInk);
        if (wrongPdf) {
          expect(latest.revision.revisionId, prior.revision.revisionId);
          expect(find.textContaining('슬라이드 수와 PDF 쪽 수'), findsOneWidget);
        } else {
          expect(latest.originalBytes, candidate);
          expect(latest.pdfBytes, newPdf);
          expect(latest.pageCount, 2);
          expect(latest.bindingId, isNot(prior.bindingId));
          expect(latest.revision.parentRevisionIds, [
            prior.revision.revisionId,
          ]);
        }
      },
    );
  }

  for (final (originalHidden, wrongPdf) in [
    (false, false),
    (true, false),
    (false, true),
  ]) {
    testWidgets(
      'Android PPTX slide display handles hidden=$originalHidden wrongPdf=$wrongPdf',
      (tester) async {
        final original = _pptxDisplayFixture(
          pptxPhotoFixture(),
          hidden: originalHidden,
        );
        final candidate = _pptxDisplayFixture(
          original,
          hidden: !originalHidden,
        );
        final oldPdf = annotationPdf('before slide display');
        final newPdf = annotationPdf('verified slide display');
        final oldInk = Uint8List.fromList([1, 2, 3]);
        final (prior, priorInkRevision) = await withPumping(tester, () async {
          note = await store.importDocument(
            title: 'Lecture PPTX',
            fileName: 'lecture.pptx',
            bytes: original,
          );
          final prior = await store.commitEdited(
            await store.beginEdit(note),
            originalBytes: original,
            pdfBytes: oldPdf,
            engineVersion: 'before-slide-display',
            pageCount: 1,
          );
          final ink = await OfficeAnnotationStore(repository).open(note, prior);
          return (prior, await ink.saveFiles({'main.sbn2': oldInk}));
        });
        final adapter = _FixturePptxSlideDisplay(
          original,
          candidate,
          originalHidden: originalHidden,
        );
        var rendered = 0, disposed = 0;
        final engine = _FixtureAndroidCloneEngine((path, id, sourceHash) async {
          rendered++;
          expect(path, adapter.outputPath);
          expect(sourceHash, sha256.convert(candidate).toString());
          expect(await File(path).readAsBytes(), candidate);
          final output = await File(p.join(temp.path, 'display-$id.pdf'))
              .writeAsBytes(newPdf);
          return _FixtureAndroidCloneObservation(
            sessionId: id,
            sourceSha256: sourceHash,
            pdf: output,
            pdfSha256: sha256.convert(newPdf).toString(),
            partCount: 1,
            pageCount: wrongPdf ? 2 : 1,
            onDispose: () => disposed++,
          );
        });
        await mount(tester, engine, pptxSlideReorder: adapter);
        final launch = find.byKey(const ValueKey('office-display-pptx-slide'));
        expect(launch, findsOneWidget);
        await tester.ensureVisible(launch);
        await tester.runAsync(() => tester.tap(launch));
        final slide = find.byKey(const ValueKey('pptx-slide-display-target-1'));
        for (var i = 0; i < 12 && slide.evaluate().isEmpty; i++) {
          await drain(tester);
        }
        expect(slide, findsOneWidget);
        expect(
          find.text(originalHidden ? '슬라이드 1 · 숨김' : '슬라이드 1'),
          findsOneWidget,
        );
        final confirm = find.byKey(
          const ValueKey('pptx-slide-display-confirm'),
        );
        expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
        await tester.tap(slide);
        await tester.pump();
        expect(
          find.descendant(
            of: confirm,
            matching: find.text(originalHidden ? '표시하고 저장' : '숨기고 저장'),
          ),
          findsOneWidget,
        );
        await tester.tap(confirm);
        await tester.pump();
        for (var i = 0; i < 12; i++) {
          await drain(tester);
          if (!File(adapter.sourcePath!).parent.existsSync()) break;
        }
        expect(File(adapter.sourcePath!).parent.existsSync(), isFalse);
        expect((adapter.applyCount, rendered, disposed), (1, 1, 1));
        final latest = await withPumping(tester, () => store.readLatest(note));
        final savedPrior = await withPumping(
          tester,
          () => store.readLatest(note, revisionId: prior.revision.revisionId),
        );
        final savedInk = await withPumping(
          tester,
          () => repository.readFiles(priorInkRevision),
        );
        expect(savedPrior.originalBytes, original);
        expect(savedPrior.pdfBytes, oldPdf);
        expect(savedPrior.bindingId, prior.bindingId);
        expect(savedInk['main.sbn2'], oldInk);
        if (wrongPdf) {
          expect(latest.revision.revisionId, prior.revision.revisionId);
          expect(find.textContaining('슬라이드 수와 PDF 쪽 수'), findsOneWidget);
        } else {
          expect(latest.originalBytes, candidate);
          expect(latest.pdfBytes, newPdf);
          expect(latest.pageCount, 1);
          expect(latest.bindingId, isNot(prior.bindingId));
          expect(latest.revision.parentRevisionIds, [
            prior.revision.revisionId,
          ]);
        }
      },
    );
  }

  for (final outcome in [
    'save',
    'same-position move between same-named sections',
    'same-position no-op inside the same section',
    'picker cancel',
    'destination mismatch',
    'PDF count mismatch',
    'newer source',
  ]) {
    testWidgets('Android PPTX reorder handles $outcome', (tester) async {
      final samePosition =
          outcome == 'same-position move between same-named sections';
      final sectionNoOp =
          outcome == 'same-position no-op inside the same section';
      final cancel = outcome == 'picker cancel' || sectionNoOp;
      final original = pptxPhotoFixture();
      final candidate = replacePptxPhoto(
        original,
        listPptxPhotos(original).first,
        pptxReplacementPhoto(),
      );
      final oldPdf = annotationPdf('before reorder');
      final newPdf = annotationPdf('verified reorder');
      final oldInk = Uint8List.fromList([1, 2, 3]);
      final (prior, priorInkRevision) = await withPumping(tester, () async {
        note = await store.importDocument(
          title: 'Lecture PPTX',
          fileName: 'lecture.pptx',
          bytes: original,
        );
        final prior = await store.commitEdited(
          await store.beginEdit(note),
          originalBytes: original,
          pdfBytes: oldPdf,
          engineVersion: 'before-reorder',
          pageCount: 2,
        );
        final ink = await OfficeAnnotationStore(repository).open(note, prior);
        final savedInk = await ink.saveFiles({'main.sbn2': oldInk});
        return (prior, savedInk);
      });
      final adapter = _FixturePptxSlideReorder(
        original,
        candidate,
        reportedDestination: samePosition || outcome == 'destination mismatch'
            ? 0
            : 1,
        sectionGroups: samePosition ? (0, 1) : (sectionNoOp ? (0, 0) : null),
      );
      var rendered = 0, disposed = 0;
      OfficeEdition? arrived;
      final engine = _FixtureAndroidCloneEngine((path, id, sourceHash) async {
        rendered++;
        expect(path, adapter.outputPath);
        expect(sourceHash, sha256.convert(candidate).toString());
        expect(await File(path).readAsBytes(), candidate);
        if (outcome == 'newer source') {
          arrived = await store.commitEdited(
            await store.beginEdit(note),
            originalBytes: original,
            pdfBytes: annotationPdf('arrived from peer'),
            engineVersion: 'peer-editor',
            pageCount: 2,
          );
        }
        final output = await File(p.join(temp.path, 'reorder-$id.pdf'))
            .writeAsBytes(newPdf);
        return _FixtureAndroidCloneObservation(
          sessionId: id,
          sourceSha256: sourceHash,
          pdf: output,
          pdfSha256: sha256.convert(newPdf).toString(),
          partCount: 2,
          pageCount: outcome == 'PDF count mismatch' ? 1 : 2,
          onDispose: () => disposed++,
        );
      });
      await mount(tester, engine, pptxSlideReorder: adapter);
      final launch = find.byKey(const ValueKey('office-reorder-pptx-slides'));
      expect(launch, findsOneWidget);
      await tester.ensureVisible(launch);
      await tester.runAsync(() => tester.tap(launch));
      final source = find.byKey(const ValueKey('pptx-slide-reorder-source-1'));
      for (var i = 0; i < 12 && source.evaluate().isEmpty; i++) {
        await drain(tester);
      }
      expect(source, findsOneWidget);
      expect(find.text('슬라이드 2 · 숨김'), findsOneWidget);
      expect(
        find.textContaining('실습 구역'),
        findsNWidgets(samePosition || sectionNoOp ? 2 : 1),
      );
      final confirm = find.byKey(const ValueKey('pptx-slide-reorder-confirm'));
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      await tester.tap(source);
      await tester.pump();
      final same = find.byKey(const ValueKey('pptx-slide-reorder-target-1'));
      expect(tester.widget<ListTile>(same).enabled, isFalse);
      final target = find.byKey(const ValueKey('pptx-slide-reorder-target-2'));
      await tester.tap(target);
      await tester.pump();
      if (samePosition) {
        expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
        expect(find.text('번호는 그대로 두고 대상 슬라이드의 구역으로 옮깁니다.'), findsOneWidget);
        expect(find.text('구역을 바꾸고 저장'), findsOneWidget);
      } else {
        expect(find.text('선택한 위치는 현재 순서와 같습니다.'), findsOneWidget);
        expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
        if (!sectionNoOp) {
          await tester.tap(
            find.byKey(const ValueKey('pptx-slide-reorder-after')),
          );
          await tester.pump();
          expect(find.text('이동 후 2번 슬라이드가 됩니다.'), findsOneWidget);
        }
      }
      if (!sectionNoOp) {
        expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
      }
      if (cancel) {
        await tester.tap(
          find.byKey(const ValueKey('pptx-slide-reorder-cancel')),
        );
      } else {
        await tester.tap(confirm);
      }
      await tester.pump();
      for (var i = 0; i < 12; i++) {
        await drain(tester);
        if (!File(adapter.sourcePath!).parent.existsSync()) break;
      }
      expect(File(adapter.sourcePath!).parent.existsSync(), isFalse);
      expect(adapter.applyCount, cancel ? 0 : 1);
      expect(rendered, cancel || outcome == 'destination mismatch' ? 0 : 1);
      expect(disposed, rendered);
      final latest = await withPumping(tester, () => store.readLatest(note));
      final savedPrior = await withPumping(
        tester,
        () => store.readLatest(note, revisionId: prior.revision.revisionId),
      );
      final savedInk = await withPumping(
        tester,
        () => repository.readFiles(priorInkRevision),
      );
      expect(savedPrior.originalBytes, original);
      expect(savedPrior.pdfBytes, oldPdf);
      expect(savedPrior.bindingId, prior.bindingId);
      expect(savedInk['main.sbn2'], oldInk);
      switch (outcome) {
        case 'save':
        case 'same-position move between same-named sections':
          expect(latest.originalBytes, candidate);
          expect(latest.pdfBytes, newPdf);
          expect(latest.pageCount, prior.pageCount);
          expect(latest.bindingId, isNot(prior.bindingId));
          expect(latest.revision.parentRevisionIds, [
            prior.revision.revisionId,
          ]);
          expect(
            find.text(
              samePosition
                  ? '슬라이드 구역을 변경하고 새 원본과 PDF를 저장했습니다.'
                  : '슬라이드 순서를 변경하고 새 원본과 PDF를 저장했습니다.',
            ),
            findsOneWidget,
          );
        case 'newer source':
          expect(latest.revision.revisionId, arrived!.revision.revisionId);
          expect(latest.originalBytes, original);
          expect(find.textContaining('Revision heads changed'), findsOneWidget);
        case 'destination mismatch':
          expect(latest.revision.revisionId, prior.revision.revisionId);
          expect(find.textContaining('판본과 위치'), findsOneWidget);
        case 'PDF count mismatch':
          expect(latest.revision.revisionId, prior.revision.revisionId);
          expect(find.textContaining('슬라이드 수와 PDF 쪽 수'), findsOneWidget);
        default:
          expect(latest.revision.revisionId, prior.revision.revisionId);
      }
    });
  }

  for (final outcome in [
    'save',
    'picker cancel',
    'native cancel',
    'part count mismatch',
    'PDF count mismatch',
    'newer source',
  ]) {
    testWidgets('Android PPTX duplicate handles $outcome', (tester) async {
      final original = pptxPhotoFixture();
      final candidate = replacePptxPhoto(
        original,
        listPptxPhotos(original).first,
        pptxReplacementPhoto(),
      );
      final oldPdf = annotationPdf('before clone');
      final newPdf = annotationPdf('verified clone');
      final oldInk = Uint8List.fromList([1, 2, 3]);
      final (prior, priorInkRevision) = await withPumping(tester, () async {
        note = await store.importDocument(
          title: 'Lecture PPTX',
          fileName: 'lecture.pptx',
          bytes: original,
        );
        final prior = await store.commitEdited(
          await store.beginEdit(note),
          originalBytes: original,
          pdfBytes: oldPdf,
          engineVersion: 'before-clone',
          pageCount: 2,
        );
        final ink = await OfficeAnnotationStore(repository).open(note, prior);
        final savedInk = await ink.saveFiles({'main.sbn2': oldInk});
        return (prior, savedInk);
      });
      final adapter = _FixturePptxSlideClone(original, candidate);
      var rendered = 0, disposed = 0;
      OfficeEdition? arrived;
      final engine = _FixtureAndroidCloneEngine((path, id, sourceHash) async {
        rendered++;
        expect(path, adapter.outputPath);
        expect(sourceHash, sha256.convert(candidate).toString());
        expect(await File(path).readAsBytes(), candidate);
        if (outcome == 'native cancel') return null;
        if (outcome == 'newer source') {
          arrived = await store.commitEdited(
            await store.beginEdit(note),
            originalBytes: original,
            pdfBytes: annotationPdf('arrived from peer'),
            engineVersion: 'peer-editor',
            pageCount: 2,
          );
        }
        final output = await File(p.join(temp.path, 'clone-$id.pdf'))
            .writeAsBytes(newPdf);
        return _FixtureAndroidCloneObservation(
          sessionId: id,
          sourceSha256: sourceHash,
          pdf: output,
          pdfSha256: sha256.convert(newPdf).toString(),
          partCount: outcome == 'part count mismatch' ? 2 : 3,
          pageCount: outcome == 'PDF count mismatch' ? 2 : 3,
          onDispose: () => disposed++,
        );
      });
      await mount(tester, engine, pptxSlideClone: adapter);
      final launch = find.byKey(const ValueKey('office-duplicate-pptx-slide'));
      expect(launch, findsOneWidget);
      await tester.ensureVisible(launch);
      await tester.runAsync(() => tester.tap(launch));
      final target = find.byKey(const ValueKey('pptx-slide-clone-target-1'));
      for (var i = 0; i < 12 && target.evaluate().isEmpty; i++) {
        await drain(tester);
      }
      expect(target, findsOneWidget);
      expect(find.text('강의 시작'), findsOneWidget);
      final unsupported = tester.widget<ListTile>(
        find.byKey(const ValueKey('pptx-slide-clone-target-2')),
      );
      expect(unsupported.enabled, isFalse);
      final confirm = find.byKey(const ValueKey('pptx-slide-clone-confirm'));
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      if (outcome == 'picker cancel') {
        await tester.tap(find.byKey(const ValueKey('pptx-slide-clone-cancel')));
      } else {
        await tester.tap(target);
        await tester.pump();
        expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
        await tester.tap(confirm);
      }
      await tester.pump();
      for (var i = 0; i < 12; i++) {
        await drain(tester);
        final draft = adapter.sourcePath;
        if (draft != null && !File(draft).parent.existsSync()) break;
      }
      expect(File(adapter.sourcePath!).parent.existsSync(), isFalse);
      final latest = await withPumping(tester, () => store.readLatest(note));
      final savedPrior = await withPumping(
        tester,
        () => store.readLatest(note, revisionId: prior.revision.revisionId),
      );
      final savedInk = await withPumping(
        tester,
        () => repository.readFiles(priorInkRevision),
      );
      expect(savedPrior.originalBytes, original);
      expect(savedPrior.pdfBytes, oldPdf);
      expect(savedPrior.bindingId, prior.bindingId);
      expect(savedInk['main.sbn2'], oldInk);
      expect(adapter.applyCount, outcome == 'picker cancel' ? 0 : 1);
      expect(rendered, adapter.applyCount);
      expect(
        disposed,
        const {'picker cancel', 'native cancel'}.contains(outcome) ? 0 : 1,
      );
      switch (outcome) {
        case 'save':
          expect(latest.originalBytes, candidate);
          expect(latest.pdfBytes, newPdf);
          expect(latest.pageCount, 3);
          expect(latest.bindingId, isNot(prior.bindingId));
          expect(latest.revision.parentRevisionIds, [
            prior.revision.revisionId,
          ]);
          expect(find.text('슬라이드를 복제하고 새 원본과 PDF를 저장했습니다.'), findsOneWidget);
        case 'newer source':
          expect(latest.revision.revisionId, arrived!.revision.revisionId);
          expect(latest.originalBytes, original);
          expect(find.textContaining('Revision heads changed'), findsOneWidget);
        default:
          expect(latest.revision.revisionId, prior.revision.revisionId);
          if (outcome.endsWith('mismatch')) {
            expect(find.textContaining('복제한 슬라이드 수'), findsOneWidget);
          }
      }
    });
  }

  testWidgets(
    'save waits for native cancellation and does not create a source revision',
    (tester) async {
      late Completer<AndroidOfficeEditResult> result;
      await tester.runAsync(() async {
        result = Completer<AndroidOfficeEditResult>();
      });
      final busy = <bool>[];
      final key = await mount(
        tester,
        FixtureOfficeEngine(
          onEdit: (_, _) => result.future,
          cleanup: () {
            if (!result.isCompleted)
              result.complete(
                const AndroidOfficeEditResult(
                  status: AndroidOfficeEditStatus.cancelled,
                  engineVersion: 'fixture-engine',
                ),
              );
          },
        ),
        busy: busy.add,
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('office-edit-original')));
      });
      await drain(tester);
      var finished = false;
      late Future<void> save;
      await tester.runAsync(() async {
        save = key.currentState!.save().then((_) {
          finished = true;
        });
      });
      await tester.pump();
      expect(finished, isFalse);
      result.complete(
        const AndroidOfficeEditResult(
          status: AndroidOfficeEditStatus.cancelled,
          engineVersion: 'fixture-engine',
        ),
      );
      await withPumping(tester, () => save);
      await drain(tester);
      expect(
        (await tester.runAsync(() => store.readEditions(note)))!.length,
        1,
      );
      expect(busy, contains(true));
      expect(busy.last, isFalse);
    },
  );

  testWidgets(
    'hash mismatch keeps source unchanged and retains failed working files',
    (tester) async {
      final original = (await tester.runAsync(() => store.readLatest(note)))!;
      final busy = <bool>[];
      await mount(
        tester,
        FixtureOfficeEngine(
          onEdit: (path, id) => savedResult(path, id, badHash: true),
        ),
        busy: busy.add,
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('office-edit-original')));
      });
      final elapsed = Stopwatch()..start();
      while ((find.textContaining('무결성').evaluate().isEmpty ||
              busy.isEmpty ||
              busy.last) &&
          elapsed.elapsed < const Duration(seconds: 15)) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 15));
        });
        await tester.pump(const Duration(milliseconds: 15));
      }
      expect(
        busy.isNotEmpty && !busy.last,
        isTrue,
        reason:
            'Native hash verification must finish before checking the source',
      );
      expect(
        (await tester.runAsync(() => store.readLatest(note)))!
            .revision
            .revisionId,
        original.revision.revisionId,
      );
      expect(find.textContaining('무결성'), findsWidgets);
      expect(
        await tester.runAsync(
          () =>
              Directory('${temp.path}/native')
                  .list(recursive: true)
                  .where((f) => f.path.endsWith('edited.docx'))
                  .length,
        ),
        1,
      );
    },
  );

  for (final (hasLocalDraft, lateDraft) in [
    (false, false),
    (true, false),
    (true, true),
  ]) {
    testWidgets(
      lateDraft
          ? 'incoming Office ink keeps a late edit during manual reload'
          : hasLocalDraft
          ? 'incoming Office ink protects local strokes and offers both branches'
          : 'incoming Office ink reloads a clean editor on its visible page',
      (tester) async {
        final edition = await withPumping(tester, () async {
          final document = pw.Document()
            ..addPage(pw.Page(build: (_) => pw.Text('First PDF page')))
            ..addPage(pw.Page(build: (_) => pw.Text('Second PDF page')));
          final edition = await store.commitEdited(
            await store.beginEdit(note),
            originalBytes: importedOriginal,
            pdfBytes: await document.save(),
            engineVersion: 'incoming-ink-fixture',
            pageCount: 2,
          );
          final annotation = await OfficeAnnotationStore(repository)
              .open(note, edition);
          final core = EditorCoreInfo(filePath: annotation.workingPath)
            ..pages = [EditorPage(), EditorPage()];
          try {
            await annotation.saveSnapshot(core, 0);
            await OfficeViewStore(repository, note.id).save(
              OfficeViewState(
                vaultId: repository.vaultId,
                noteId: note.id,
                sourceRevisionId: edition.revision.revisionId,
                bindingId: edition.bindingId,
                pdfMode: true,
                pageId: core.pages[1].pageId,
              ),
            );
          } finally {
            core.dispose();
          }
          return edition;
        });
        final dirty = <bool>[];
        final workspace = await mount(
          tester,
          FixtureOfficeEngine(),
          dirty: dirty.add,
        );
        final editor = find.byType(Editor);
        final progress = find.byType(LinearProgressIndicator);
        final incoming = find.byKey(
          const ValueKey('office-incoming-annotation'),
        );
        for (
          var i = 0;
          i < 12 &&
              (editor.evaluate().isEmpty || progress.evaluate().isNotEmpty);
          i++
        ) {
          await drain(tester);
        }
        expect(editor, findsOneWidget);
        expect(progress, findsNothing);
        final previousEditor = tester.state<EditorState>(editor);
        expect(previousEditor.currentPageIndex, 1);
        final initialHead = await withPumping(
          tester,
          () async => (await repository.heads(edition.bindingId!)).single,
        );
        previousEditor.drawTestStroke();
        expect(dirty.last, isTrue);
        final strokeCount = previousEditor.coreInfo.pages.first.strokes.length;
        expect(strokeCount, greaterThan(0));
        if (!hasLocalDraft) {
          await tester.pump(const Duration(seconds: 11));
          for (var i = 0; i < 12 && dirty.last; i++) {
            await drain(tester);
          }
          expect(dirty.last, isFalse);
          await tester.pump(const Duration(milliseconds: 300));
          await drain(tester);
          expect(tester.state<EditorState>(editor), same(previousEditor));
          expect(incoming, findsNothing);
        }

        const remoteText = 'Ink from the other device';
        final received = await withPumping(tester, () async {
          final peer = await NoteRepository.open(
            Directory('${temp.path}/peer-vault'),
            vaultId: repository.vaultId,
            createFormatVersion: 2,
          );
          try {
            for (final record in await repository.revisions()) {
              await peer.importRevision(
                record,
                blobsByHash: {
                  for (final ref in record.blobs.values)
                    ref.hash: await repository.readBlob(ref.hash),
                },
              );
            }
            final annotation = await OfficeAnnotationStore(peer)
                .open(note, edition);
            expect(
              annotation.revision!.revisionId == initialHead.revisionId,
              hasLocalDraft,
            );
            final core = await annotation.load();
            try {
              core.pages[1].quill.controller.document.insert(0, remoteText);
              await annotation.saveSnapshot(core, 0);
            } finally {
              core.dispose();
            }
            final record = annotation.revision!;
            expect(record.deviceId, isNot(repository.deviceId));
            await repository.importRevision(
              record,
              blobsByHash: {
                for (final ref in record.blobs.values)
                  ref.hash: await peer.readBlob(ref.hash),
              },
            );
            return record;
          } finally {
            await peer.close();
          }
        });
        expect(
          await withPumping(
            tester,
            () async =>
                (await repository.heads(note.sourceEntityId!))
                    .single
                    .revisionId,
          ),
          edition.revision.revisionId,
        );

        if (hasLocalDraft) {
          for (var i = 0; i < 12 && incoming.evaluate().isEmpty; i++) {
            await drain(tester);
          }
          expect(incoming, findsOneWidget);
          expect(tester.state<EditorState>(editor), same(previousEditor));
          expect(
            previousEditor.coreInfo.pages.first.strokes,
            hasLength(strokeCount),
          );
          expect(dirty.last, isTrue);
          if (lateDraft) {
            late Completer<void> entered;
            late Completer<void> release;
            addTearDown(() {
              if (!release.isCompleted) release.complete();
            });
            final pdf = FileManager.getFile(
              '/.working/office/${note.id}/${edition.revision.revisionId}/preview.pdf',
            );
            final reload = tester.widget<TextButton>(incoming).onPressed!;
            await tester.runAsync(() async {
              entered = Completer<void>();
              release = Completer<void>();
              final outerZone = Zone.current;
              IOOverrides.runZoned(
                reload,
                createFile: (path) => p.equals(path, pdf.path)
                    ? DelayedOfficeSourceFile(pdf, entered, release)
                    : outerZone.run(() => File(path)),
              );
            });
            await tester.runAsync(
              () => entered.future.timeout(const Duration(seconds: 5)),
            );
            previousEditor.drawTestStroke();
            final lateStrokeCount =
                previousEditor.coreInfo.pages.first.strokes.length;
            expect(lateStrokeCount, greaterThan(strokeCount));
            release.complete();
            await drain(tester);
            expect(tester.state<EditorState>(editor), same(previousEditor));
            expect(incoming, findsOneWidget);
            expect(dirty.last, isTrue);
            await withPumping(tester, workspace.currentState!.save);
            final local = await withPumping(tester, () async {
              final heads = await repository.heads(edition.bindingId!);
              return SaberInkAdapter.load(
                repository,
                heads.singleWhere(
                  (head) => head.deviceId == repository.deviceId,
                ),
              );
            });
            try {
              expect(local.pages.first.strokes, hasLength(lateStrokeCount));
            } finally {
              local.dispose();
            }
            return;
          }
          await tester.runAsync(() => tester.tap(incoming));
          final remoteBranch = find.byKey(
            ValueKey('office-annotation-${received.revisionId}'),
          );
          for (var i = 0; i < 12 && remoteBranch.evaluate().isEmpty; i++) {
            await drain(tester);
          }
          expect(remoteBranch, findsOneWidget);
          final branches = await withPumping(
            tester,
            () => repository.heads(edition.bindingId!),
          );
          expect(branches, hasLength(2));
          final local = branches.singleWhere(
            (record) => record.deviceId == repository.deviceId,
          );
          expect(local.parentRevisionIds, [initialHead.revisionId]);
          final savedLocal = await withPumping(
            tester,
            () => SaberInkAdapter.load(repository, local),
          );
          try {
            expect(savedLocal.pages.first.strokes, hasLength(strokeCount));
          } finally {
            savedLocal.dispose();
          }
        } else {
          for (
            var i = 0;
            i < 12 &&
                (editor.evaluate().isEmpty ||
                    progress.evaluate().isNotEmpty ||
                    identical(
                      tester.state<EditorState>(editor),
                      previousEditor,
                    ));
            i++
          ) {
            await drain(tester);
          }
          final refreshed = tester.state<EditorState>(editor);
          expect(refreshed, isNot(same(previousEditor)));
          expect(refreshed.currentPageIndex, 1);
          expect(
            refreshed.coreInfo.pages[1].quill.controller.document.toPlainText(),
            contains(remoteText),
          );
          expect(
            refreshed.coreInfo.pages.first.strokes,
            hasLength(strokeCount),
          );
          expect(incoming, findsNothing);
        }
      },
    );
  }

  testWidgets('multiple source heads require explicit revision selection', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final a = await store.beginEdit(note);
      final b = await store.beginEdit(note);
      await store.commitEdited(
        a,
        originalBytes: annotationOfficeFile('a'),
        pdfBytes: annotationPdf('a'),
        engineVersion: 'fixture',
        pageCount: 1,
      );
      await store.commitEdited(
        b,
        originalBytes: annotationOfficeFile('b'),
        pdfBytes: annotationPdf('b'),
        engineVersion: 'fixture',
        pageCount: 1,
      );
    });
    await mount(tester, FixtureOfficeEngine());
    expect(find.text('서로 다른 원본 버전이 있습니다. 버전을 선택하세요.'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('office-edition-selector')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('office-edit-original')), findsNothing);
  });

  testWidgets(
    'a corrupt existing annotation can return to the preserved original',
    (tester) async {
      await tester.runAsync(() async {
        final edition = await store.commitEdited(
          await store.beginEdit(note),
          originalBytes: annotationOfficeFile('edition'),
          pdfBytes: annotationPdf('edition'),
          engineVersion: 'fixture',
          pageCount: 1,
        );
        await repository.commit(
          entityId: edition.bindingId!,
          kind: EntityKind.ink,
          ownerNoteId: note.id,
          files: {
            'main.sbn2': Uint8List.fromList([1, 2, 3]),
          },
          parentRevisionIds: [],
        );
      });
      await mount(tester, FixtureOfficeEngine(available: false));
      await tester.runAsync(() async {
        await tester.tap(find.text('PDF 필기'));
      });
      for (var i = 0; i < 160; i++) {
        if (find.textContaining('필기를 열 수 없습니다').evaluate().isNotEmpty &&
            tester
                    .widget<SegmentedButton<bool>>(
                      find.byType(SegmentedButton<bool>),
                    )
                    .onSelectionChanged !=
                null) {
          break;
        }
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        });
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(
        find.textContaining('필기를 열 수 없습니다'),
        findsWidgets,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((text) => text.data)
            .toList()
            .toString(),
      );
      expect(
        tester
            .widget<SegmentedButton<bool>>(find.byType(SegmentedButton<bool>))
            .onSelectionChanged,
        isNotNull,
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('원본'));
      });
      await drain(tester);
      expect(find.text('lecture.docx'), findsOneWidget);
    },
  );

  testWidgets(
    'ink arriving during target edition read is saved before the old editor is replaced',
    (tester) async {
      late String targetRevision;
      late String targetBlobPath;
      late String currentBinding;
      late Completer<void> entered;
      late Completer<void> release;
      await tester.runAsync(() async {
        final first = await store.commitEdited(
          await store.beginEdit(note),
          originalBytes: annotationOfficeFile('first'),
          pdfBytes: annotationPdf('first'),
          engineVersion: 'fixture',
          pageCount: 1,
        );
        final second = await store.commitEdited(
          await store.beginEdit(note),
          originalBytes: annotationOfficeFile('second'),
          pdfBytes: annotationPdf('second'),
          engineVersion: 'fixture',
          pageCount: 1,
        );
        targetRevision = first.revision.revisionId;
        targetBlobPath = File(
          '${repository.root.path}/blobs/${first.originalSha256}',
        ).absolute.path;
        currentBinding = second.bindingId!;
        entered = Completer<void>();
        release = Completer<void>();
        final core = EditorCoreInfo(filePath: '/office-transition')
          ..pages.add(EditorPage());
        core.pages.first.quill.controller.document.insert(
          0,
          'Saved annotation',
        );
        try {
          await repository.commit(
            entityId: currentBinding,
            kind: EntityKind.ink,
            ownerNoteId: note.id,
            files: await SaberInkAdapter.capture(core, 0),
            parentRevisionIds: [],
          );
        } finally {
          core.dispose();
        }
      });
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      await mount(tester, FixtureOfficeEngine(available: false));
      await tester.runAsync(() async {
        await tester.tap(find.text('PDF 필기'));
      });
      for (var i = 0; i < 8; i++) {
        await drain(tester);
        if (find.byType(Editor).evaluate().isNotEmpty &&
            tester
                    .widget<SegmentedButton<bool>>(
                      find.byType(SegmentedButton<bool>),
                    )
                    .onSelectionChanged !=
                null)
          break;
      }
      final editor = tester.state<EditorState>(find.byType(Editor));
      final chooser = tester.widget<DropdownButton<String>>(
        find.byKey(const ValueKey('office-edition-selector')),
      );
      await tester.runAsync(() async {
        final outerZone = Zone.current;
        final targetFile = File(targetBlobPath);
        IOOverrides.runZoned(
          () {
            chooser.onChanged!(targetRevision);
          },
          createFile: (path) {
            if (p.equals(
              p.normalize(p.absolute(path)),
              p.normalize(targetBlobPath),
            )) {
              return DelayedOfficeSourceFile(targetFile, entered, release);
            }
            return outerZone.run(() => File(path));
          },
        );
      });
      await tester.runAsync(() => entered.future);
      editor.drawTestStroke();
      final expected = editor.coreInfo.pages.first.strokes.length;
      release.complete();
      await drain(tester);
      await tester.runAsync(() async {
        final head = (await repository.heads(currentBinding)).single;
        final saved = await SaberInkAdapter.load(repository, head);
        try {
          expect(saved.pages.first.strokes, hasLength(expected));
        } finally {
          saved.dispose();
        }
      });
    },
  );
}

class DelayedOfficeSourceFile implements File {
  final File actual;
  final Completer<void> entered;
  final Completer<void> release;
  new(this.actual, this.entered, this.release);
  @override
  String get path => actual.path;
  @override
  Directory get parent => actual.parent;
  @override
  bool existsSync() => actual.existsSync();
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) =>
      actual.open(mode: mode);
  @override
  Future<Uint8List> readAsBytes() async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
    return actual.readAsBytes();
  }

  @override
  Stream<List<int>> openRead([int? start, int? end]) async* {
    if (!entered.isCompleted) entered.complete();
    await release.future;
    yield* actual.openRead(start, end);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TransientOfficeSourceFile implements File {
  new(this.actual, this.shouldFail);
  final File actual;
  final bool Function() shouldFail;
  @override
  String get path => actual.path;
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) =>
      actual.open(mode: mode);
  @override
  Future<Uint8List> readAsBytes() async {
    if (shouldFail())
      throw FileSystemException('Transient history read failure', path);
    return actual.readAsBytes();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
