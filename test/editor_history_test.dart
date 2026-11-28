import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/editor/editor_history.dart';

void main() {
  test('Test editor history', () {
    final history = EditorHistory();

    final item1 = EditorHistoryItem(
      type: .draw,
      pageIndex: 0,
      strokes: [],
      images: [],
    );
    final item2 = EditorHistoryItem(
      type: .draw,
      pageIndex: 0,
      strokes: [],
      images: [],
    );

    expect(history.canUndo, false, reason: 'History should be empty');
    expect(history.canRedo, false, reason: 'History should be empty');

    expect(
      () => history.undo(),
      throwsA(anything),
      reason: 'Undo should throw an exception if history is empty',
    );
    expect(
      () => history.redo(),
      throwsA(anything),
      reason: 'Redo should throw an exception if history is empty',
    );

    history.recordChange(item1);
    expect(history.canUndo, true);
    expect(history.canRedo, false);

    expect(history.undo(), item1, reason: 'Undo should return the last item');
    history.canRedo = true;
    expect(history.canUndo, false);
    expect(history.canRedo, true);

    expect(history.redo(), item1, reason: 'Redo should return the last item');
    expect(history.canUndo, true);
    expect(history.canRedo, false);

    expect(history.undo(), item1, reason: 'Undo should return the last item');
    history.canRedo = true;
    expect(history.canUndo, false);
    expect(history.canRedo, true);

    history.recordChange(item2);
    expect(history.canUndo, true);
    expect(history.canRedo, false);

    expect(history.undo(), item2, reason: 'Undo should return the last item');
  });

  test('listeners hear record, undo and redo', () {
    final history = EditorHistory();
    var heard = 0;
    history.addListener(() => heard++);
    EditorHistoryItem item() =>
        EditorHistoryItem(type: .draw, pageIndex: 0, strokes: [], images: []);

    history.recordChange(item());
    expect(heard, 1);
    history.undo();
    expect(heard, 2);
    history.canRedo = true;
    history.redo();
    expect(heard, 3);

    // These stay quiet: the editor builds after each, and the lasso's start
    // setting canRedo would take the undo notice away.
    history.markLastChangeAsSaved();
    history.canRedo = false;
    history.clearRedo();
    expect(heard, 3);
  });
}
