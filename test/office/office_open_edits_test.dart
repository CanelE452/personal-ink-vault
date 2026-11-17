import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/office/office_open_edits.dart';

void main() {
  late Directory temp;
  late File file;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('office-open-edits-');
    file = File(p.join(temp.path, '.workspace', 'office-open-edits.json'));
  });
  tearDown(() => temp.delete(recursive: true));

  OfficeOpenEdit edit(String noteId, OfficeEditorKind kind) => OfficeOpenEdit(
    noteId: noteId,
    title: 'T-$noteId',
    sessionId: 's-$noteId',
    kind: kind,
    workingPath: '/w/$noteId/original.docx',
    inputSourceSha256: 'a' * 64,
  );

  test('an open edit survives a restart of the app', () async {
    final edits = OfficeOpenEdits(file);
    await edits.load();
    await edits.put(edit('n1', OfficeEditorKind.office));
    final restarted = OfficeOpenEdits(file);
    await restarted.load();
    final restored = restarted.forNote('n1')!;
    expect(restored.title, 'T-n1');
    expect(restored.sessionId, 's-n1');
    expect(restored.kind, OfficeEditorKind.office);
    expect(restored.workingPath, '/w/n1/original.docx');
    expect(restored.inputSourceSha256, 'a' * 64);
    expect(restarted.forKind(OfficeEditorKind.office)!.noteId, 'n1');
    expect(restarted.forKind(OfficeEditorKind.hwp), isNull);
    // 228 opens editors over the current screen, so nothing records a screen to return to.
    expect(await file.readAsString(), isNot(contains('return')));
  });

  test('a list written by 227, with the screens to return to, still loads', () async {
    await file.parent.create(recursive: true);
    await file.writeAsString(
      '{"version":1,"edits":[{"noteId":"n1","title":"T-n1","sessionId":"s-n1",'
      '"kind":"hwp","workingPath":"/w/n1/original.hwp","inputSourceSha256":"${'a' * 64}",'
      '"returnNoteId":"n9","returnFolderId":null}]}',
    );
    final edits = OfficeOpenEdits(file);
    await edits.load();
    expect(edits.forNote('n1')?.sessionId, 's-n1');
    expect(edits.forKind(OfficeEditorKind.hwp)?.noteId, 'n1');
  });

  test('one editor of each kind: a second document of the same kind is refused', () async {
    final edits = OfficeOpenEdits(file);
    await edits.load();
    await edits.put(edit('n1', OfficeEditorKind.office));
    await edits.put(edit('n2', OfficeEditorKind.hwp));
    await expectLater(edits.put(edit('n3', OfficeEditorKind.office)), throwsStateError);
    // The same document may be put again: its editor was brought back.
    await edits.put(edit('n1', OfficeEditorKind.office));
    expect(edits.forNote('n1')?.sessionId, 's-n1');
    expect(edits.entries, hasLength(2));
  });

  test('removing an edit tells listeners and is written down', () async {
    final edits = OfficeOpenEdits(file);
    await edits.load();
    await edits.put(edit('n1', OfficeEditorKind.office));
    var notified = 0;
    edits.addListener(() => notified++);
    await edits.remove('n1');
    await edits.remove('n1');
    expect(notified, 1);
    final restarted = OfficeOpenEdits(file);
    await restarted.load();
    expect(restarted.entries, isEmpty);
  });

  test('a call waiting for an editor is marked, and marked closing once the editor returns', () async {
    final edits = OfficeOpenEdits(file);
    await edits.load();
    await edits.put(edit('n1', OfficeEditorKind.office));
    expect(edits.waitsFor('n1'), isFalse);
    edits.waiting('n1');
    expect(edits.waitsFor('n1'), isTrue);
    expect(edits.closing('n1'), isFalse);
    var notified = 0;
    edits.addListener(() => notified++);
    edits.closed('n1');
    expect(edits.closing('n1'), isTrue);
    expect(notified, 1);
    // A restarted app has no waiting calls.
    final restarted = OfficeOpenEdits(file);
    await restarted.load();
    expect(restarted.waitsFor('n1'), isFalse);
    await edits.remove('n1', outcome: OfficeEditorOutcome.saved);
    expect(edits.waitsFor('n1'), isFalse);
    expect(edits.closing('n1'), isFalse);
    expect(edits.takeOutcome('n1'), OfficeEditorOutcome.saved);
  });

  test('an outcome for an entry that is already gone is still kept and announced', () async {
    final edits = OfficeOpenEdits(file);
    await edits.load();
    await edits.put(edit('n1', OfficeEditorKind.office));
    await edits.remove('n1');
    var notified = 0;
    edits.addListener(() => notified++);
    await edits.remove('n1', outcome: OfficeEditorOutcome.discarded);
    expect(notified, 1);
    expect(edits.takeOutcome('n1'), OfficeEditorOutcome.discarded);
  });

  test('a damaged list is read as empty', () async {
    await file.parent.create(recursive: true);
    await file.writeAsString('{not json');
    final edits = OfficeOpenEdits(file);
    await edits.load();
    expect(edits.entries, isEmpty);
  });
}
