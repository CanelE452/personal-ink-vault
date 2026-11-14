import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_media.dart';
import 'package:saber/data/vault/block_page_snapshot.dart';
import 'package:saber/data/vault/block_page_table.dart';
import 'package:saber/data/vault/database_media_snapshot.dart';
import 'package:saber/data/vault/database_query.dart';
import 'package:saber/data/vault/portable_document_export.dart';
import 'package:saber/data/vault/portable_document_pdf.dart';
import 'package:saber/data/vault/workspace_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ByteData> font() async => ByteData.sublistView(
    await File('build/native/fonts/NotoSansKR-Portable.ttf').readAsBytes(),
  );

  PortableExportSource pageSource(BlockPageMediaSnapshot snapshot) =>
      PortableExportSource.page(
        noteId: newId(),
        title: '한국어 내보내기 검증',
        bodyRevisionId: newId(),
        metadataRevisionIds: [newId()],
        snapshot: snapshot,
      );

  int pages(Uint8List bytes) =>
      RegExp(r'/Type\s*/Page\b').allMatches(latin1.decode(bytes)).length;

  void expectPdf(PortablePdfResult result) {
    final text = latin1.decode(result.bytes);
    expect(text, startsWith('%PDF-'));
    expect(text, contains('/ToUnicode'));
    expect(text, contains('/FontFile2'));
    expect(pages(result.bytes), greaterThan(0));
  }

  Future<void> retain(String name, PortablePdfResult result) async {
    final directory = Platform.environment['INK_VAULT_PORTABLE_PDF_PROOF_DIR'];
    if (directory == null) return;
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.pdf').writeAsBytes(result.bytes);
  }

  test(
    'searchable Korean PDF retains supported blocks and original snapshot',
    () async {
      final toggle = BlockPageBlock.create(type: 'toggle', text: '접힌 본문');
      final page = const BlockPageDocument.empty().copyWith(
        blocks: [
          BlockPageBlock.create(type: 'heading1', text: '강의 핵심 개념'),
          BlockPageBlock.create(text: '한글 본문과 English 123'),
          BlockPageBlock.create(
            type: 'todo',
            text: '복습할 항목',
          ).copyWith(checked: true),
          BlockPageBlock.create(type: 'bullet', text: '글머리 기호'),
          BlockPageBlock.create(type: 'numbered', text: '번호 목록'),
          BlockPageBlock.create(type: 'quote', text: '인용 내용\n두 번째 줄'),
          BlockPageBlock.create(
            type: 'code',
            text: '<script>neverExecute()</script>',
          ),
          toggle.copyWith(
            collapsed: true,
            children: [BlockPageBlock.create(text: '숨기지 않는 하위 내용')],
          ),
          BlockPageBlock.create(
            type: 'table',
            text: '간단한 표',
          ).copyWith(table: BlockPageTable.create().copyWith(headerRow: true)),
          BlockPageBlock.create(type: 'divider'),
        ],
      );
      final snapshot = BlockPageMediaSnapshot.prepare(page);
      final original = snapshot.files.map(
        (key, value) => MapEntry(key, base64Encode(value)),
      );
      final result = await renderPortableDocumentPdf(
        pageSource(snapshot),
        fontData: await font(),
      );
      expectPdf(result);
      expect(result.warnings, isEmpty);
      expect(
        snapshot.files.map((key, value) => MapEntry(key, base64Encode(value))),
        original,
      );
      await retain('korean-page', result);
    },
  );

  test(
    'one long paragraph and tall wide table paginate without dropping content',
    () async {
      var table = BlockPageTable.create(
        rows: 18,
        columns: 10,
      ).copyWith(headerRow: true);
      for (var r = 0; r < table.rows.length; r++) {
        for (var c = 0; c < table.columnCount; c++) {
          table = table.setCellText(
            table.rows[r].id,
            table.columns[c],
            r == 0 ? '열 $c' : '행$r 열$c ${'긴 셀 내용 ' * 16}',
          );
        }
      }
      final document = const BlockPageDocument.empty().copyWith(
        blocks: [
          BlockPageBlock.create(type: 'heading1', text: '긴 문서 검증'),
          BlockPageBlock.create(text: '${'연속된한글문장 ' * 1800} 마지막문단표식'),
          BlockPageBlock.create(
            type: 'table',
            text: '표 제목',
          ).copyWith(table: table),
          BlockPageBlock.create(text: '문서 마지막 표식 END-OF-EXPORT'),
        ],
      );
      final result = await renderPortableDocumentPdf(
        pageSource(BlockPageMediaSnapshot.prepare(document)),
        fontData: await font(),
      );
      expectPdf(result);
      expect(pages(result.bytes), greaterThan(5));
      expect(result.warnings, contains(startsWith('pdf.table_as_records:')));
      await retain('long-page-and-table', result);
    },
  );

  test(
    'a narrow 128-row table spans beyond the top-level widget count',
    () async {
      final raw = BlockPageTable.create(
        rows: 128,
        columns: 5,
      ).copyWith(headerRow: true).toJson();
      final rows = raw['rows'] as List;
      for (var r = 0; r < rows.length; r++) {
        final cells = (rows[r] as Map)['cells'] as List;
        for (var c = 0; c < cells.length; c++) {
          (cells[c] as Map)['text'] = r == 0 ? '머리글 $c' : '한' * 90;
        }
      }
      (((rows.last as Map)['cells'] as List).last as Map)['text'] =
          'NARROW-TABLE-LAST-CELL ${'끝' * 60}';
      final table = BlockPageTable.fromJson(raw);
      final document = const BlockPageDocument.empty().copyWith(
        blocks: [
          BlockPageBlock.create(
            type: 'table',
            text: '길고 좁은 표',
          ).copyWith(table: table),
          BlockPageBlock.create(text: 'NARROW-TABLE-END-128'),
        ],
      );
      final result = await renderPortableDocumentPdf(
        pageSource(BlockPageMediaSnapshot.prepare(document)),
        fontData: await font(),
      );
      expectPdf(result);
      expect(pages(result.bytes), greaterThan(10));
      expect(
        result.warnings.where(
          (value) => value.startsWith('pdf.table_as_records:'),
        ),
        isEmpty,
      );
      await retain('narrow-table', result);
    },
  );

  test('registered image is embedded and attachment and unsupported meanings are reported', () async {
    final pixels = image.Image(width: 20, height: 10);
    image.fill(pixels, color: image.ColorRgb8(30, 130, 210));
    final asset = BlockPageMediaAsset.image(
      name: '작은 그림.png',
      bytes: image.encodePng(pixels),
    );
    final attachment = BlockPageMediaAsset.attachment(
      name: '자료.txt',
      bytes: utf8.encode('첨부 원문'),
    );
    final picture = BlockPageBlock.create(type: 'image', text: '그림 설명');
    final file = BlockPageBlock.create(type: 'attachment', text: '다운로드 자료');
    final equation = BlockPageBlock.create(
      type: 'equation',
      text: r'\frac{가}{나}',
    );
    final unknown = BlockPageBlock.create(
      type: 'future-widget',
      text: '알 수 없는 블록 본문',
    );
    final document = const BlockPageDocument.empty().copyWith(
      blocks: [picture, file, equation, unknown],
      media: {picture.id: asset.reference, file.id: attachment.reference},
    );
    final snapshot = BlockPageMediaSnapshot.prepare(
      document,
      addedFiles: {
        asset.reference.path: asset.bytes,
        attachment.reference.path: attachment.bytes,
      },
    );
    final result = await renderPortableDocumentPdf(
      pageSource(snapshot),
      fontData: await font(),
    );
    expectPdf(result);
    expect(
      latin1.decode(result.bytes),
      contains(RegExp(r'/Subtype\s*/Image\b')),
    );
    expect(result.warnings, contains('pdf.attachment_not_embedded:${file.id}'));
    expect(result.warnings, contains('pdf.equation_as_text:${equation.id}'));
    expect(
      result.warnings,
      contains('pdf.unknown_block:${unknown.id}:future-widget'),
    );
    expect(
      result.warnings.where((warning) => warning.contains('image')),
      isEmpty,
    );
    await retain('image-and-attachment', result);
  });

  test(
    'database PDF exports computed values, archived rows and row bodies',
    () async {
      final title = DatabaseProperty.create(name: '이름', type: 'title');
      final formula = DatabaseProperty.create(name: '계산 결과', type: 'formula');
      final relation = DatabaseProperty.create(name: '관련 행', type: 'relation');
      final one = DatabaseRow.create(
        values: {title.id: '현재 행'},
        body: const BlockPageDocument.empty()
            .copyWith(blocks: [BlockPageBlock.create(text: '현재 행 본문 한글')])
            .toJson(),
      );
      final archived = DatabaseRow.create(
        values: {title.id: '보관된 행'},
        body: const BlockPageDocument.empty()
            .copyWith(blocks: [BlockPageBlock.create(text: '보관된 행 본문도 포함')])
            .toJson(),
      ).copyWith(archived: true);
      final database = WorkspaceDatabase.empty().copyWith(
        properties: [title, formula, relation],
        rows: [one, archived],
      );
      final source = PortableExportSource.database(
        noteId: newId(),
        title: '연구 데이터베이스',
        bodyRevisionId: newId(),
        metadataRevisionIds: [newId()],
        snapshot: DatabaseMediaSnapshot.prepare(database),
        values: {
          one.id: {formula.id: const DatabaseValue(42)},
          archived.id: {
            formula.id: const DatabaseValue(
              null,
              error: DatabaseCalculationError('test_error', '계산 실패'),
            ),
          },
        },
      );
      final before = jsonEncode(database.toJson());
      final result = await renderPortableDocumentPdf(
        source,
        fontData: await font(),
      );
      expectPdf(result);
      expect(
        result.warnings,
        contains(
          'pdf.computed_value_error:${archived.id}:${formula.id}:test_error',
        ),
      );
      expect(jsonEncode(database.toJson()), before);
      await retain('database-rows', result);
    },
  );

  test('invalid font bytes fail explicitly rather than falling back to missing Korean glyphs', () async {
    final source = pageSource(
      BlockPageMediaSnapshot.prepare(const BlockPageDocument.empty()),
    );
    await expectLater(
      renderPortableDocumentPdf(source, fontData: ByteData(12)),
      throwsFormatException,
    );
  });
}
