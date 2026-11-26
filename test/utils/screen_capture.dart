import 'dart:io';

import 'package:flutter/services.dart';

/// Where a screen capture test writes its pictures: [usual], or the folder
/// in PIV_CAPTURE_DIR (Task 19 put every stage-1 screen in one folder).
String captureDir(String usual) =>
    Platform.environment['PIV_CAPTURE_DIR'] ?? usual;

/// The font families the screen captures (PIV_CAPTURE=1) set their text in:
/// the app's Latin font and a Korean font from Windows, as on a device.
const captureLatin = 'AtkinsonHyperlegibleNext';
const captureKorean = 'CaptureKorean';

/// Loads [captureLatin] from the app's assets and [captureKorean] from
/// Windows (Noto Sans KR when installed, else Malgun Gothic). Call it inside
/// `tester.runAsync`: it reads files.
Future<void> loadCaptureFonts() async {
  final latin = FontLoader(captureLatin)
    ..addFont(
      Future.value(
        ByteData.sublistView(
          File(
            'assets/google_fonts/Atkinson_Hyperlegible_Next/AtkinsonHyperlegibleNext-Regular.ttf',
          ).readAsBytesSync(),
        ),
      ),
    );
  await latin.load();
  final path = File('C:/Windows/Fonts/NotoSansKR-VF.ttf').existsSync()
      ? 'C:/Windows/Fonts/NotoSansKR-VF.ttf'
      : 'C:/Windows/Fonts/malgun.ttf';
  final korean = FontLoader(captureKorean)
    ..addFont(Future.value(ByteData.sublistView(File(path).readAsBytesSync())));
  await korean.load();
}
