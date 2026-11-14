import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_media.dart';
import 'package:saber/data/vault/block_page_snapshot.dart';
import 'package:saber/data/vault/database_media_snapshot.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/pages/workspace/block_page_editor.dart';

void main() {
  testWidgets('bold formats only the selected letters and retains selection', (
    tester,
  ) async {
    final block = BlockPageBlock.create(text: '앞 selected 뒤');
    final key = GlobalKey<BlockPageEditorState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlockPageEditor(
            key: key,
            initialDocument: const BlockPageDocument.empty().copyWith(
              blocks: [block],
            ),
            onSave: (_) async {},
            onBack: () {},
            autosaveDelay: const Duration(hours: 1),
          ),
        ),
      ),
    );
    final input = find.byKey(ValueKey('block-text-${block.id}'));
    await tester.tap(input);
    final controller = tester.widget<TextField>(input).controller!;
    const selected = TextSelection(baseOffset: 2, extentOffset: 10);
    controller.selection = selected;
    await tester.pump();

    expect(find.byTooltip('굵게'), findsOneWidget);
    await tester.tap(find.byTooltip('굵게'));
    await tester.pump();

    final savedBlock = key.currentState!.document.blocks.single;
    expect(savedBlock.text, '앞 selected 뒤');
    expect(controller.selection, selected);
    final inline = savedBlock.toJson()['inlineData'] as Map;
    expect(inline['format'], 'personal-ink-inline-1');
    expect(inline['runs'], [
      {
        'start': 2,
        'end': 10,
        'marks': ['bold'],
      },
    ]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('selection and focus alone do not dirty or autosave a page', (
    tester,
  ) async {
    final block = BlockPageBlock.create(text: '선택만 바꾸기');
    final dirty = <bool>[];
    var writes = 0;
    final key = await _mount(
      tester,
      _page(block),
      dirty: dirty.add,
      save: (_) async => writes++,
    );
    await _select(tester, block.id, 0, 2);
    _controller(tester, block.id).selection = const TextSelection.collapsed(
      offset: 4,
    );
    await tester.pump(const Duration(seconds: 1));
    await key.currentState!.save();
    expect(dirty, isEmpty);
    expect(writes, 0);
    expect(key.currentState!.document.version, 1);
    await tester.pumpWidget(const SizedBox());
  });

  for (final rowBody in [false, true]) {
    for (final withMedia in [false, true]) {
      testWidgets(
        'saved ${rowBody ? 'DB row' : 'page'} v${withMedia ? 2 : 1} can undo first formatting and save again',
        (tester) async {
          final paragraph = BlockPageBlock.create(text: '되돌릴 서식');
          final block = BlockPageBlock.fromJson(
            paragraph.toJson()..['vendor'] = {'keep': 'unknown'},
          );
          final attachment = BlockPageBlock.create(type: 'attachment');
          final asset = BlockPageMediaAsset.attachment(
            name: 'preserve.bin',
            bytes: [9, 8, 7],
          );
          final initial = const BlockPageDocument.empty().copyWith(
            blocks: [block, if (withMedia) attachment],
            media: {if (withMedia) attachment.id: asset.reference},
          );
          final row = DatabaseRow.create(body: initial.toJson());
          final other = DatabaseRow.create(
            body: _page(BlockPageBlock.create(text: '다른 행 본문')).toJson(),
          );
          var database = WorkspaceDatabase.empty().addRow(row).addRow(other);
          var pageSnapshot = BlockPageMediaSnapshot.prepare(
            initial,
            addedFiles: {if (withMedia) asset.reference.path: asset.bytes},
          );
          var databaseSnapshot = DatabaseMediaSnapshot.prepare(
            database,
            addedFiles: {if (withMedia) asset.reference.path: asset.bytes},
          );
          final dirty = <bool>[];
          final key = await _mount(
            tester,
            initial,
            dirty: dirty.add,
            save: (document) async {
              if (rowBody) {
                final next = database.updateRow(
                  row.copyWith(body: document.toJson()),
                );
                databaseSnapshot = DatabaseMediaSnapshot.prepare(
                  next,
                  existingFiles: databaseSnapshot.files,
                );
                database = databaseSnapshot.database;
              } else {
                pageSnapshot = BlockPageMediaSnapshot.prepare(
                  document,
                  existingFiles: pageSnapshot.files,
                );
              }
            },
          );
          await _select(tester, block.id, 0, 3);
          await _tapTool(tester, '굵게');
          await key.currentState!.save();
          await tester.tap(find.byTooltip('실행 취소'));
          await tester.pump();
          await key.currentState!.save();
          final persisted = rowBody
              ? BlockPageDocument.fromJson(
                  databaseSnapshot.database.rows.first.body,
                )
              : pageSnapshot.document;
          expect(persisted.version, 3);
          expect(persisted.blocks.first.text, '되돌릴 서식');
          expect(persisted.blocks.first.toJson()['vendor'], {
            'keep': 'unknown',
          });
          expect(persisted.blocks.first.inlineText?.runs ?? [], isEmpty);
          expect(dirty, [true, false, true, false]);
          if (rowBody) {
            expect(
              databaseSnapshot.database.rows.last.toJson(),
              other.toJson(),
            );
          }
          if (withMedia) {
            expect(
              persisted.media[attachment.id]!.toJson(),
              asset.reference.toJson(),
            );
            expect(
              rowBody
                  ? databaseSnapshot.mediaBytes(row.id, attachment.id)
                  : pageSnapshot.mediaBytes(attachment.id),
              [9, 8, 7],
            );
          }
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets('all six styles are painted in the editable text itself', (
    tester,
  ) async {
    final block = BlockPageBlock.create(text: '앞 selected 뒤');
    final key = await _mount(tester, _page(block));
    await _select(tester, block.id, 2, 10);
    for (final label in ['굵게', '기울임', '밑줄', '취소선', '인라인 코드', '강조']) {
      await _tapTool(tester, label);
    }
    final controller = _controller(tester, block.id);
    final span = controller.buildTextSpan(
      context: tester.element(_input(block.id)),
      style: const TextStyle(fontSize: 17),
      withComposing: true,
    );
    expect(span.toPlainText(), '앞 selected 뒤');
    final selected = span.children!.cast<TextSpan>().singleWhere(
      (span) => span.text == 'selected',
    );
    expect(selected.style!.fontWeight, FontWeight.bold);
    expect(selected.style!.fontStyle, FontStyle.italic);
    expect(selected.style!.fontFamily, 'monospace');
    expect(selected.style!.backgroundColor, isNotNull);
    expect(
      selected.style!.decoration!.contains(TextDecoration.underline),
      isTrue,
    );
    expect(
      selected.style!.decoration!.contains(TextDecoration.lineThrough),
      isTrue,
    );
    expect(
      _runs(key).single['marks'],
      containsAll([
        'bold',
        'italic',
        'underline',
        'strikethrough',
        'code',
        'highlight',
      ]),
    );
    await _tapTool(tester, '서식 지우기');
    expect(_runs(key), isEmpty);
    expect(controller.text, '앞 selected 뒤');
    await tester.tap(find.byTooltip('실행 취소'));
    await tester.pump();
    expect(_runs(key).single['marks'], hasLength(6));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('control and meta shortcuts format the retained range', (
    tester,
  ) async {
    final block = BlockPageBlock.create(text: 'shortcut');
    final key = await _mount(tester, _page(block));
    await _select(tester, block.id, 1, 5);
    for (final letter in [
      LogicalKeyboardKey.keyB,
      LogicalKeyboardKey.keyI,
      LogicalKeyboardKey.keyU,
    ]) {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(letter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
    }
    expect(_runs(key), [
      {
        'start': 1,
        'end': 5,
        'marks': ['bold', 'italic', 'underline'],
      },
    ]);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(_runs(key).single['marks'], ['italic', 'underline']);
    expect(
      _controller(tester, block.id).selection,
      const TextSelection(baseOffset: 1, extentOffset: 5),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('IME keeps its composing underline and defers formatting', (
    tester,
  ) async {
    final block = BlockPageBlock.create(text: '한글');
    final key = await _mount(tester, _page(block));
    await _select(tester, block.id, 0, 1);
    final controller = _controller(tester, block.id);
    controller.value = const TextEditingValue(
      text: '한글',
      selection: TextSelection(baseOffset: 0, extentOffset: 1),
      composing: TextRange(start: 0, end: 1),
    );
    await tester.pump();
    final span = controller.buildTextSpan(
      context: tester.element(_input(block.id)),
      style: const TextStyle(),
      withComposing: true,
    );
    expect(span.toPlainText(), '한글');
    final composing = span.children!.first as TextSpan;
    expect(
      composing.style!.decoration!.contains(TextDecoration.underline),
      isTrue,
    );
    await _tapTool(tester, '굵게');
    expect(
      key.currentState!.document.blocks.single.toJson()['inlineData'],
      isNull,
    );
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '한국글',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      ),
    );
    await tester.pump();
    expect(controller.value.composing, const TextRange(start: 0, end: 2));
    expect(key.currentState!.document.blocks.single.text, '한국글');
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '한국글',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump();
    expect(_runs(key), [
      {
        'start': 0,
        'end': 2,
        'marks': ['bold'],
      },
    ]);
    expect(controller.value.composing, TextRange.empty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'deleting an earlier repeated word moves the correct styled word',
    (tester) async {
      final block = BlockPageBlock.create(text: 'same same same');
      final key = await _mount(tester, _page(block));
      await _select(tester, block.id, 10, 14);
      await _tapTool(tester, '굵게');
      _controller(tester, block.id).selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 5,
      );
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'same same',
          selection: TextSelection.collapsed(offset: 0),
        ),
      );
      await tester.pump();
      expect(key.currentState!.document.blocks.single.text, 'same same');
      expect(_runs(key), [
        {
          'start': 5,
          'end': 9,
          'marks': ['bold'],
        },
      ]);
      await tester.tap(find.byTooltip('실행 취소'));
      await tester.pump();
      expect(_controller(tester, block.id).text, 'same same same');
      expect(_runs(key).single['start'], 10);
      await tester.tap(find.byTooltip('다시 실행'));
      await tester.pump();
      expect(_controller(tester, block.id).text, 'same same');
      expect(_runs(key).single['start'], 5);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a failed formatting save retains the draft and retry clears dirty',
    (tester) async {
      final block = BlockPageBlock.create(text: '보존할 서식');
      final dirty = <bool>[], busy = <bool>[];
      final writes = <BlockPageDocument>[];
      var failing = true;
      final key = await _mount(
        tester,
        _page(block),
        dirty: dirty.add,
        busy: busy.add,
        save: (document) async {
          writes.add(document);
          if (failing) throw StateError('disk full');
        },
      );
      await _select(tester, block.id, 0, 3);
      await _tapTool(tester, '굵게');
      await tester.tap(find.byTooltip('저장'));
      await tester.pump();
      expect(find.text('저장하지 못했습니다. 작업 내용은 열려 있습니다.'), findsOneWidget);
      expect(dirty, [true]);
      expect(_runs(key).single['marks'], ['bold']);
      failing = false;
      await tester.tap(find.text('다시 시도'));
      await tester.pump();
      expect(dirty, [true, false]);
      expect(busy, [true, false, true, false]);
      expect(writes, hasLength(2));
      expect(writes.first.toJson(), writes.last.toJson());
      expect(find.text('저장하지 못했습니다. 작업 내용은 열려 있습니다.'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('formatting during a pending save drains a second snapshot', (
    tester,
  ) async {
    final block = BlockPageBlock.create(text: '저장 중 편집');
    final release = Completer<void>();
    final writes = <BlockPageDocument>[];
    final key = await _mount(
      tester,
      _page(block),
      save: (document) async {
        writes.add(document);
        if (writes.length == 1) await release.future;
      },
    );
    await _select(tester, block.id, 0, 2);
    await _tapTool(tester, '굵게');
    final saving = key.currentState!.save();
    await tester.pump();
    await _tapTool(tester, '기울임');
    release.complete();
    await saving;
    await tester.pump();
    expect(writes, hasLength(2));
    final first = writes.first.blocks.single.toJson()['inlineData'] as Map;
    final last = writes.last.blocks.single.toJson()['inlineData'] as Map;
    expect((first['runs'] as List).single['marks'], ['bold']);
    expect((last['runs'] as List).single['marks'], ['bold', 'italic']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'link dialog rejects unsafe URLs and applies to its captured range',
    (tester) async {
      final block = BlockPageBlock.create(text: '링크할 글자 다음');
      final key = await _mount(tester, _page(block));
      await _select(tester, block.id, 0, 3);
      await _tapTool(tester, '링크');
      await tester.enterText(
        find.byKey(const ValueKey('block-inline-link-url')),
        'javascript:alert(1)',
      );
      await tester.tap(find.text('적용'));
      await tester.pump();
      expect(find.text('http 또는 https 웹 주소를 입력하세요.'), findsOneWidget);
      expect(key.currentState!.document.version, 1);
      _controller(tester, block.id).selection = const TextSelection(
        baseOffset: 4,
        extentOffset: 6,
      );
      await tester.enterText(
        find.byKey(const ValueKey('block-inline-link-url')),
        'https://example.com/path?q=한글',
      );
      await tester.tap(find.text('적용'));
      await tester.pumpAndSettle();
      expect(_runs(key), [
        {
          'start': 0,
          'end': 3,
          'marks': [],
          'link': 'https://example.com/path?q=한글',
        },
      ]);
      expect(
        _controller(tester, block.id).selection,
        const TextSelection(baseOffset: 0, extentOffset: 3),
      );
      await _tapTool(tester, '링크 제거');
      expect(_runs(key), isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('note choices save and open through the current note callback', (
    tester,
  ) async {
    const noteId = '11111111-1111-4111-8111-111111111111';
    final block = BlockPageBlock.create(text: '참고 문서');
    final opened = <String>[];
    final writes = <BlockPageDocument>[];
    final key = await _mount(
      tester,
      _page(block),
      notes: const [BlockPageNote(noteId, '연결 대상')],
      open: opened.add,
      save: (document) async => writes.add(document),
    );
    await _select(tester, block.id, 0, 2);
    await _tapTool(tester, '링크');
    await tester.tap(find.text('연결 대상'));
    await tester.pumpAndSettle();
    expect(_runs(key).single['link'], 'inkvault://note/$noteId');
    await _tapTool(tester, '링크 열기');
    expect(opened, [noteId]);
    expect(writes, hasLength(1));
    expect(writes.single.blocks.single.text, '참고 문서');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'a late link dialog cannot format a switched document with reused ids',
    (tester) async {
      final block = BlockPageBlock.create(text: '이전 문서');
      final first = _page(block);
      final second = _page(block.copyWith(text: '다른 문서'));
      final key = await _mount(tester, first);
      await _select(tester, block.id, 0, 2);
      await _tapTool(tester, '링크');
      await _mount(tester, second, key: key);
      await tester.enterText(
        find.byKey(const ValueKey('block-inline-link-url')),
        'https://example.com',
      );
      await tester.tap(find.text('적용'));
      await tester.pumpAndSettle();
      expect(key.currentState!.document.toJson(), second.toJson());
      expect(_controller(tester, block.id).text, '다른 문서');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'old save completion cannot clear a new document draft or busy owner',
    (tester) async {
      final block = BlockPageBlock.create(text: '첫 문서');
      final key = GlobalKey<BlockPageEditorState>();
      final oldBusy = <bool>[], newBusy = <bool>[], newDirty = <bool>[];
      final release = Completer<void>();
      final oldWrites = <BlockPageDocument>[];
      await _mount(
        tester,
        _page(block),
        key: key,
        busy: oldBusy.add,
        save: (document) async {
          oldWrites.add(document);
          await release.future;
        },
      );
      await _select(tester, block.id, 0, 1);
      await _tapTool(tester, '굵게');
      final oldSaving = key.currentState!.save();
      final oldResult = expectLater(oldSaving, throwsStateError);
      final second = _page(block.copyWith(text: '새 문서'));
      await _mount(
        tester,
        second,
        key: key,
        busy: newBusy.add,
        dirty: newDirty.add,
      );
      await _select(tester, block.id, 0, 1);
      await _tapTool(tester, '기울임');
      release.complete();
      await oldResult;
      await tester.pump();
      expect(oldBusy, [true, false]);
      expect(newBusy, isEmpty);
      expect(newDirty, [true]);
      expect(oldWrites.single.blocks.single.text, '첫 문서');
      expect(_runs(key).single['marks'], ['italic']);
      expect(find.text('저장하지 못했습니다. 작업 내용은 열려 있습니다.'), findsNothing);
      await key.currentState!.save();
      expect(newDirty, [true, false]);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'opaque inline metadata stays unchanged when its text is edited',
    (tester) async {
      final block = BlockPageBlock.create(text: '미래 서식');
      final raw = block.toJson()
        ..['inlineData'] = {
          'format': 'future-inline-91',
          'payload': [1, 'opaque'],
        };
      final key = await _mount(tester, _page(BlockPageBlock.fromJson(raw)));
      await tester.tap(_input(block.id));
      await tester.pump();
      expect(find.byTooltip('굵게'), findsNothing);
      await tester.enterText(_input(block.id), '미래 서식 변경');
      await tester.pump();
      expect(key.currentState!.document.blocks.single.toJson()['inlineData'], {
        'format': 'future-inline-91',
        'payload': [1, 'opaque'],
      });
      expect(key.currentState!.document.version, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'legacy familiar inline metadata blocks page promotion without losing edits',
    (tester) async {
      final editable = BlockPageBlock.create(text: '안전한 본문');
      final legacy = BlockPageBlock.create(text: '구형 불투명 본문');
      final oldPayload = {
        'format': 'personal-ink-inline-1',
        'textSha256': 'legacy-not-a-current-digest',
        'runs': ['opaque'],
      };
      final initial = BlockPageDocument.fromJson({
        'version': 1,
        'blocks': [
          editable.toJson(),
          legacy.toJson()..['inlineData'] = oldPayload,
        ],
      });
      final key = await _mount(tester, initial);
      await _select(tester, editable.id, 0, 2);
      expect(find.byTooltip('굵게'), findsNothing);
      await tester.enterText(_input(editable.id), '안전한 본문 변경');
      await tester.pump();
      expect(key.currentState!.document.version, 1);
      expect(
        key.currentState!.document.blocks.last.toJson()['inlineData'],
        oldPayload,
      );
      await tester.tap(find.byTooltip('실행 취소'));
      await tester.pump();
      expect(key.currentState!.document.toJson(), initial.toJson());
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'document link blocks retain dormant spans and do not format nested links',
    (tester) async {
      const noteId = '11111111-1111-4111-8111-111111111111';
      final block = BlockPageBlock.create(text: '문서 링크 제목', noteId: noteId);
      final key = await _mount(tester, _page(block));
      await _select(tester, block.id, 0, 2);
      await _tapTool(tester, '굵게');
      final originalInline = key.currentState!.document.blocks.single
          .toJson()['inlineData'];
      await _changeBlockType(tester, block.id, '문서 링크');
      expect(find.byTooltip('굵게'), findsNothing);
      expect(
        key.currentState!.document.blocks.single.toJson()['inlineData'],
        originalInline,
      );
      await _changeBlockType(tester, block.id, '문단');
      expect(key.currentState!.document.blocks.single.inlineText, isNotNull);
      await _select(tester, block.id, 0, 2);
      expect(find.byTooltip('굵게'), findsOneWidget);
      expect(
        key.currentState!.document.blocks.single.toJson()['inlineData'],
        originalInline,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'code and equation keep retained formatting without painting it',
    (tester) async {
      final block = BlockPageBlock.create(text: 'retained');
      final key = await _mount(tester, _page(block));
      await _select(tester, block.id, 0, 8);
      await _tapTool(tester, '굵게');
      final before = key.currentState!.document.blocks.single
          .toJson()['inlineData'];
      for (final type in ['코드', '수식']) {
        await _changeBlockType(tester, block.id, type);
        expect(find.byTooltip('굵게'), findsNothing);
        expect(
          key.currentState!.document.blocks.single.toJson()['inlineData'],
          before,
        );
        final span = _controller(tester, block.id).buildTextSpan(
          context: tester.element(_input(block.id)),
          style: const TextStyle(fontWeight: FontWeight.normal),
          withComposing: true,
        );
        expect(span.toPlainText(), 'retained');
        expect(span.style!.fontWeight, FontWeight.normal);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'formatted table captions survive type round trips and edited projections',
    (tester) async {
      final table = BlockPageBlock.createTable(text: '표 설명');
      final raw = table.toJson()..['vendor'] = {'preserve': 'unknown'};
      final key = await _mount(tester, _page(BlockPageBlock.fromJson(raw)));
      await _select(tester, table.id, 0, 1);
      await _tapTool(tester, '굵게');
      final original = key.currentState!.document.blocks.single;
      final originalInline = original.toJson()['inlineData'];
      await _changeBlockType(tester, table.id, '문단');
      expect(tester.takeException(), isNull);
      var converted = key.currentState!.document.blocks.single;
      expect(converted.type, 'paragraph');
      expect(converted.inlineText, isNotNull);
      expect(converted.text, startsWith('표 설명\n'));
      expect(converted.toJson()['vendor'], {'preserve': 'unknown'});
      expect(converted.toJson()['tableData'], raw['tableData']);
      expect('표 설명'.allMatches(converted.text), hasLength(1));
      await _changeBlockType(tester, table.id, '표');
      converted = key.currentState!.document.blocks.single;
      expect(converted.type, 'table');
      expect(converted.text, '표 설명');
      expect(converted.toJson()['inlineData'], originalInline);
      expect(converted.toJson()['tableData'], raw['tableData']);
      expect(converted.toJson().containsKey('tableTextConversion'), isFalse);
      await _changeBlockType(tester, table.id, '문단');
      final edited = '${key.currentState!.document.blocks.single.text} 사용자 수정';
      await tester.enterText(_input(table.id), edited);
      await tester.pump();
      await _changeBlockType(tester, table.id, '표');
      converted = key.currentState!.document.blocks.single;
      expect(converted.text, edited);
      expect(converted.inlineText, isNotNull);
      expect(converted.toJson()['vendor'], {'preserve': 'unknown'});
      expect(converted.toJson()['tableData'], raw['tableData']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('320 pixel toolbar scrolls to clear without overflowing', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final block = BlockPageBlock.create(text: '좁은 화면');
    final key = await _mount(tester, _page(block));
    await _select(tester, block.id, 0, 2);
    await _tapTool(tester, '굵게');
    await _tapTool(tester, '서식 지우기');
    expect(_runs(key), isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('host render shows selected rich text and its local toolbar', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final proofDirectory =
        Platform.environment['INK_VAULT_INLINE_UI_PROOF_DIR'];
    ThemeData? proofTheme;
    if (proofDirectory != null && proofDirectory.isNotEmpty) {
      await tester.runAsync(() async {
        final font = FontLoader('InlineHostProof')
          ..addFont(
            File('build/native/fonts/NotoSansKR-Portable.ttf')
                .readAsBytes()
                .then(ByteData.sublistView),
          );
        await font.load();
        final icons = File(
          'build/unit_test_assets/fonts/MaterialIcons-Regular.otf',
        );
        if (icons.existsSync()) {
          final iconFont = FontLoader('MaterialIcons')
            ..addFont(icons.readAsBytes().then(ByteData.sublistView));
          await iconFont.load();
        }
      });
      proofTheme = ThemeData(fontFamily: 'InlineHostProof');
    }
    for (final width in [320.0, 1100.0]) {
      await tester.binding.setSurfaceSize(Size(width, 700));
      final block = BlockPageBlock.create(
        text: '연구 노트 · Rich text\n선택한 글자에 서식과 링크를 담습니다.',
      );
      final boundary = GlobalKey();
      final key = await _mount(
        tester,
        _page(block),
        boundary: boundary,
        theme: proofTheme,
      );
      await _select(tester, block.id, 0, 5);
      await _tapTool(tester, '굵게');
      await _tapTool(tester, '강조');
      await tester.ensureVisible(find.byTooltip('굵게'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(_runs(key).single['marks'], ['bold', 'highlight']);
      expect(tester.takeException(), isNull);
      if (proofDirectory != null && proofDirectory.isNotEmpty) {
        final render =
            boundary.currentContext!.findRenderObject()
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final rendered = await render.toImage(pixelRatio: 1);
          final bytes = await rendered.toByteData(
            format: ui.ImageByteFormat.png,
          );
          final directory = Directory(proofDirectory);
          await directory.create(recursive: true);
          await File('${directory.path}/inline-editor-${width.toInt()}.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          rendered.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox());
    }
  });
}

BlockPageDocument _page(BlockPageBlock block) =>
    const BlockPageDocument.empty().copyWith(blocks: [block]);

Finder _input(String id) => find.byKey(ValueKey('block-text-$id'));

TextEditingController _controller(WidgetTester tester, String id) =>
    tester.widget<TextField>(_input(id)).controller!;

List<dynamic> _runs(GlobalKey<BlockPageEditorState> key) =>
    ((key.currentState!.document.blocks.single.toJson()['inlineData']
                as Map)['runs']
            as List)
        .cast<dynamic>();

Future<GlobalKey<BlockPageEditorState>> _mount(
  WidgetTester tester,
  BlockPageDocument initial, {
  GlobalKey<BlockPageEditorState>? key,
  Future<void> Function(BlockPageDocument)? save,
  ValueChanged<bool>? dirty,
  ValueChanged<bool>? busy,
  List<BlockPageNote> notes = const [],
  ValueChanged<String>? open,
  GlobalKey? boundary,
  ThemeData? theme,
}) async {
  key ??= GlobalKey<BlockPageEditorState>();
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(
        body: RepaintBoundary(
          key: boundary,
          child: BlockPageEditor(
            key: key,
            initialDocument: initial,
            onSave: save ?? (_) async {},
            onBack: () {},
            onDirtyChanged: dirty,
            onBusyChanged: busy,
            notes: notes,
            onOpenNote: open,
            autosaveDelay: const Duration(hours: 1),
          ),
        ),
      ),
    ),
  );
  return key;
}

Future<void> _select(WidgetTester tester, String id, int start, int end) async {
  await tester.tap(_input(id));
  _controller(tester, id).selection = TextSelection(
    baseOffset: start,
    extentOffset: end,
  );
  await tester.pump();
}

Future<void> _tapTool(WidgetTester tester, String label) async {
  final tool = find.byTooltip(label);
  await tester.ensureVisible(tool);
  await tester.tap(tool);
  await tester.pump();
}

Future<void> _changeBlockType(
  WidgetTester tester,
  String id,
  String label,
) async {
  await tester.tap(find.byKey(ValueKey('block-actions-$id')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('종류 바꾸기'));
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    find.text(label),
    180,
    scrollable: find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byType(Scrollable),
    ),
  );
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}
