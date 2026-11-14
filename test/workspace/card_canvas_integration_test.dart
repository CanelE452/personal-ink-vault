import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/card_canvas_document.dart';
import 'package:saber/data/vault/obsidian_canvas_json.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('card canvas reopens renamed groups and edges and exports the saved JSON Canvas geometry', () async {
    final root = await Directory.systemTemp.createTemp(
      'card-canvas-workspace-',
    );
    final c = WorkspaceController(
      await NoteRepository.open(root, createFormatVersion: 2),
    );
    try {
      final note = await c.createNote(
        'Research map',
        documentKind: VaultDocumentKind.canvas,
      );
      final session = c.activeSession!;
      expect((await c.loadCardCanvas(session: session)).nodes, isEmpty);
      final group = CardCanvasNode.group(
        id: newId(),
        label: '제목 없는 그룹',
        bounds: const Rect.fromLTWH(-300, 20, 480, 320),
      );
      final card = CardCanvasNode.text(
        id: newId(),
        text: 'Saved map',
        x: -200,
        y: 90,
      );
      final edge = CardCanvasEdge.connect(
        id: newId(),
        fromNode: group.id,
        toNode: card.id,
      );
      final document = const CardCanvasDocument.empty().copyWith(
        nodes: [group, card],
        edges: [edge],
      );
      await c.saveCardCanvas(document, session: session);
      final previous = (await c.repository.heads(note.inkEntityId)).single;
      final renamed = group.withGroupLabel('연구 계획');
      final namedEdge = edge.withLabel('자료 연결');
      await c.saveCardCanvas(
        document.copyWith(nodes: [renamed, card], edges: [namedEdge]),
        session: session,
      );
      await c.closeNote(session: session);
      await c.openNote(
        (await c.store.list()).singleWhere((n) => n.id == note.id),
      );
      final reopened = await c.loadCardCanvas(session: c.activeSession!);
      expect(reopened.nodes.first.toJson(), renamed.toJson());
      expect(reopened.nodes.last.toJson(), card.toJson());
      expect(reopened.edges.single.toJson(), namedEdge.toJson());
      expect(
        (await c.repository.heads(note.inkEntityId)).single.parentRevisionIds,
        [previous.revisionId],
      );
      final previousBytes = (await c.repository.readFiles(
        previous,
      ))['board.canvas']!;
      final previousBoard = CardCanvasDocument.fromJson(
        jsonObject(jsonDecode(utf8.decode(previousBytes))),
      );
      expect(previousBoard.nodes.first.label, group.label);
      expect(previousBoard.edges.single.toJson(), edge.toJson());
      final exported = encodeObsidianCanvas(
        reopened,
        filePathFor: (_) => null,
        imagePathFor: (_) => null,
        onWarning: (_, message) => fail(message),
      );
      final exportedBoard = CardCanvasDocument.fromJson(
        jsonObject(jsonDecode(utf8.decode(exported))),
      );
      expect(exportedBoard.nodes.first.toJson(), renamed.toJson());
      expect(exportedBoard.edges.single.toJson(), namedEdge.toJson());
      await expectLater(
        c.saveCardCanvas(document, session: session),
        throwsStateError,
      );
      await c.flush();
    } finally {
      c.dispose();
      await c.repository.close();
      await root.delete(recursive: true);
    }
  });
}
