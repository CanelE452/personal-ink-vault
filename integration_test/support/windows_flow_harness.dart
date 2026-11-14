import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:saber/pages/workspace/library_home.dart';

class WindowsFlowHarness {
  new({
    required this.tester,
    required this.profile,
    required this.fixturePdf,
    required this.artifacts,
  });

  static const folderTitle = '통합 자료';
  final WidgetTester tester;
  final Directory profile;
  final File fixturePdf;
  final Directory artifacts;
  final _clock = Stopwatch()..start();

  Future<void> waitUntil(
    String step,
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final timer = Stopwatch()..start();
    while (true) {
      await tester.pump(const Duration(milliseconds: 50));
      final error = tester.takeException();
      if (error != null) {
        throw StateError('$step: Flutter reported $error');
      }
      if (condition()) return;
      if (timer.elapsed >= timeout) {
        final titles = find
            .byType(AppBar)
            .evaluate()
            .map((element) => (element.widget as AppBar).title)
            .toList();
        throw StateError('$step timed out after $timeout. App bars: $titles');
      }
    }
  }

  Future<void> tap(
    Finder target,
    String step, {
    bool reveal = false,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    await waitUntil(
      step,
      () => target.evaluate().length == 1,
      timeout: timeout,
    );
    if (reveal) await tester.ensureVisible(target);
    await waitUntil(
      '$step is tappable',
      () => target.hitTestable().evaluate().length == 1,
      timeout: timeout,
    );
    await tester.tap(target);
  }

  Future<void> createDocument(String menuLabel, String title) async {
    await tap(
      find.byKey(const ValueKey('library-create-button')),
      'open create menu',
    );
    await tap(find.text(menuLabel).last, 'choose $menuLabel', reveal: true);
    final dialog = find.byType(AlertDialog);
    final name = find.descendant(of: dialog, matching: find.byType(TextField));
    await waitUntil(
      'name dialog for $menuLabel',
      () => name.evaluate().length == 1,
    );
    await tester.enterText(name, title);
    await tap(
      find.descendant(of: dialog, matching: find.text('확인')),
      'confirm $title',
    );
    await waitUntil(
      'creation dialog closed for $title',
      () => dialog.evaluate().isEmpty,
    );
  }

  Future<void> openCard(String title, {bool folder = false}) async {
    final home = find.byType(LibraryHome);
    await waitUntil(
      'library before opening $title',
      () => home.evaluate().length == 1,
    );
    final library = tester.widget<LibraryHome>(home);
    final key = folder
        ? 'library-folder-${library.folders.singleWhere((item) => item.title == title).id}'
        : 'library-note-${library.notes.singleWhere((item) => item.title == title).revision.revisionId}';
    final card = find.descendant(of: home, matching: find.byKey(ValueKey(key)));
    if (card.evaluate().isEmpty) {
      final scroll = find.descendant(
        of: find.descendant(of: home, matching: find.byType(CustomScrollView)),
        matching: find.byType(Scrollable),
      );
      if (scroll.evaluate().length == 1) {
        await tester.scrollUntilVisible(
          card,
          160,
          scrollable: scroll,
          maxScrolls: 12,
        );
      }
    }
    await tap(
      find.descendant(of: card, matching: find.text(title)),
      'open card $title',
      reveal: true,
    );
  }

  Future<void> backToLibrary() async {
    await tapAppBarBack('문서 목록으로');
    await waitUntil(
      'library after back',
      () => find.byType(LibraryHome).evaluate().length == 1,
    );
  }

  Future<void> tapAppBarBack(String tooltip) async {
    final back = find.descendant(
      of: find.byType(AppBar),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is IconButton &&
            widget.tooltip == tooltip &&
            widget.onPressed != null,
      ),
    );
    await tap(back, 'app bar: $tooltip');
  }

  Future<void> capture(String name) async {
    if (!RegExp(r'^[a-z0-9-]+$').hasMatch(name)) {
      throw ArgumentError.value(name, 'name', 'Invalid frame name');
    }
    await tester.pump();
    final view = tester.binding.renderViews.single;
    final layer = view.debugLayer;
    if (layer is! OffsetLayer) {
      throw StateError('No Flutter render layer for $name: $layer');
    }
    final image = await layer.toImage(view.semanticBounds);
    try {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      if (png == null) throw StateError('Could not encode frame $name');
      final file = File(path.join(artifacts.path, '$name.png'));
      await file.create(exclusive: true);
      await file.writeAsBytes(
        png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
        flush: true,
      );
      await record('captured Flutter frame', {
        'file': file.path,
        'width': image.width,
        'height': image.height,
      });
    } finally {
      image.dispose();
    }
  }

  Future<void> record(
    String step, [
    Map<String, Object?> details = const {},
  ]) => File(path.join(artifacts.path, 'steps.jsonl'))
      .writeAsString(
        '${jsonEncode({'step': step, 'elapsedMs': _clock.elapsedMilliseconds, ...details})}\n',
        mode: FileMode.append,
        flush: true,
      )
      .then((_) {});
}
