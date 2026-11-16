import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/toolbar/export_dialog.dart';

void main() {
  test('export file names drop the characters file systems refuse', () {
    expect(exportFileName('수업: 1/2 <정리>', fallback: 'x'), '수업 12 정리');
    expect(exportFileName('  ', fallback: '노트?'), '노트');
    expect(exportFileName('', fallback: ''), 'note');
  });

  testWidgets('the dialog starts with the note title and passes the chosen options', (
    tester,
  ) async {
    final calls = <String>[];
    ExportFunction record(String format) =>
        (context, {String? name, bool background = true}) async =>
            calls.add('$format $name $background');
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showExportDialog(
              context,
              title: '강의: 3주차',
              pdf: record('pdf'),
              image: record('image'),
              original: record('original'),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('export-name')))
          .controller!
          .text,
      '강의 3주차',
    );
    await tester.tap(find.text('사진'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('export-background')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('export-go')));
    await tester.pumpAndSettle();
    expect(calls, ['image 강의 3주차 false']);
    expect(find.byKey(const ValueKey('export-go')), findsNothing);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('원본 파일'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('export-background')), findsNothing);
  });

  testWidgets('a running export keeps the dialog and uses the opener context', (
    tester,
  ) async {
    final pending = Completer<void>();
    BuildContext? opener;
    BuildContext? used;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            opener = context;
            return TextButton(
              onPressed: () => showExportDialog(
                context,
                title: '노트',
                pdf: (context, {String? name, bool background = true}) {
                  used = context;
                  return pending.future;
                },
                image: null,
                original: null,
              ),
              child: const Text('open'),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('export-go')));
    await tester.pump();
    // Taps outside and Back are ignored while the export runs.
    await tester.tapAt(const Offset(5, 5));
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('파일 내보내기'), findsOneWidget);
    expect(identical(used, opener), isTrue);
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.text('파일 내보내기'), findsNothing);
  });
}
