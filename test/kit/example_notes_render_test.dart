import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golden_screenshot/golden_screenshot.dart';
import 'package:saber/components/canvas/canvas.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/components/canvas/pencil_shader.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/tools/laser_pointer.dart';
import 'package:saber/data/tools/stroke_properties.dart';
import 'package:saber/i18n/strings.g.dart';

import '../utils/test_mock_channel_handlers.dart';

const _laserSbn = 'v17_laser_pointer.sbn2';

/// A fixed list, so a new example cannot appear without its baseline pictures.
const _exampleNotes = [
  'v11_image_svg.sbn',
  'v17_squiggles.sbn2',
  _laserSbn,
  'v18_highlighter.sbn2',
  'v18_pencil.sbn2',
  'v19_pens.sbn2',
  'v19_quill_languages.sbn2',
  'v19_separate_assets.sbn2',
  'v19_shape_strokes.sbn2',
  'v6_stress_test_179.sbn',
  'v9_low_point_count.sbn',
  'v9_quill.sbn',
  'v9_single_stroke.sbn',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  BackgroundIsolateBinaryMessenger.ensureInitialized(
    ServicesBinding.rootIsolateToken!,
  );

  setupMockPathProvider();
  setupMockPrinting();

  FlavorConfig.setup();

  setUpAll(() => Future.wait([FileManager.init(), PencilShader.init()]));

  // The baseline pictures were made on Windows.
  final skip = Platform.isWindows
      ? false
      : 'Baseline pictures were made on Windows.';

  for (final sbnName in _exampleNotes) {
    group(sbnName, () {
      final path = sbnName == _laserSbn
          ? 'test/sbn_examples/v17_squiggles.sbn2'
          : 'test/sbn_examples/$sbnName';
      final pathWithoutExtension = path.substring(0, path.lastIndexOf('.'));

      late final EditorCoreInfo coreInfo;
      late final page = coreInfo.pages.first;

      setUpAll(() async {
        StrokeOptionsExtension.setDefaults();
        FileManager.shouldUseRawFilePath = true;
        EditorImage.shouldLoadOutImmediately = true;
        if (sbnName.endsWith('.sbn2')) {
          coreInfo = await EditorCoreInfo.loadFromFileContents(
            bsonBytes: File(path).readAsBytesSync(),
            path: pathWithoutExtension,
            onlyFirstPage: true,
          );
        } else {
          coreInfo = await EditorCoreInfo.loadFromFileContents(
            jsonString: File(path).readAsStringSync(),
            path: pathWithoutExtension,
            onlyFirstPage: true,
          );
        }
        if (sbnName == _laserSbn) {
          final page = coreInfo.pages.first;
          page.laserStrokes.addAll(page.strokes.map(LaserStroke.convertStroke));
          page.strokes.clear();
        }
        if (coreInfo.pages.length > 1 && coreInfo.pages.last.isEmpty) {
          coreInfo.pages.removeLast();
        }
      });
      tearDownAll(() {
        FileManager.shouldUseRawFilePath = false;
        EditorImage.shouldLoadOutImmediately = false;
      });

      for (final (label, brightness) in [
        ('light', Brightness.light),
        ('dark', Brightness.dark),
      ]) {
        testGoldens('renders the same ($label)', (tester) async {
          await tester.runAsync(
            () => _precacheImages(
              context: tester.binding.rootElement!,
              page: page,
            ),
          );
          await tester.pumpWidget(
            _buildCanvas(
              brightness: brightness,
              page: page,
              coreInfo: coreInfo,
            ),
          );
          await tester.loadAssets(alsoLoadTheseFonts: ['Dekko']);
          await tester.pumpAndSettle();

          await expectLater(
            find.byType(Canvas),
            matchesGoldenFile('goldens/sbn_examples/$sbnName.$label.png'),
          );
        });
      }
    }, skip: skip);
  }
}

Widget _buildCanvas({
  required Brightness brightness,
  required EditorPage page,
  required EditorCoreInfo coreInfo,
}) {
  return TranslationProvider(
    child: MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: Center(
        child: FittedBox(
          child: SizedBox(
            width: page.size.width,
            height: page.size.height,
            child: RepaintBoundary(
              child: Canvas(
                path: coreInfo.filePath,
                page: page,
                pageIndex: 0,
                textEditing: false,
                coreInfo: coreInfo,
                currentStroke: null,
                currentStrokeDetectedShape: null,
                currentSelection: null,
                setAsBackground: null,
                currentTool: LaserPointer.currentLaserPointer,
                currentScale: double.maxFinite,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _precacheImages({
  required BuildContext context,
  required EditorPage page,
}) async {
  // FileImages aren't working in tests, so replace them with MemoryImages
  final backgroundImage = page.backgroundImage;
  await Future.wait([
    for (final image in page.images)
      if (image is PngEditorImage)
        if (image.imageProvider is FileImage)
          (image.imageProvider as FileImage).file.readAsBytes().then(
            (bytes) => image.imageProvider = MemoryImage(bytes),
          ),
    if (backgroundImage is PngEditorImage)
      if (backgroundImage.imageProvider is FileImage)
        (backgroundImage.imageProvider as FileImage).file.readAsBytes().then(
          (bytes) => (page.backgroundImage as PngEditorImage).imageProvider =
              MemoryImage(bytes),
        ),
  ]);

  // Precache images
  await Future.wait([
    for (final image in page.images) image.precache(context),
    if (page.backgroundImage != null) page.backgroundImage!.precache(context),
  ]);
}
