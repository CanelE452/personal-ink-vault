import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/editor/editor_history.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/editor/page_link.dart';
import 'package:saber/data/editor/page_list.dart';

void main() {
  late List<EditorPage> pages;
  late EditorHistory history;
  late List<EditorPage> added;
  late int tidied;
  late PageList list;

  /// A page that is not empty (it has its own pattern).
  EditorPage content() => EditorPage(backgroundPattern: .lined);

  setUp(() {
    pages = [];
    history = EditorHistory();
    added = [];
    tidied = 0;
    list = PageList(
      pages: () => pages,
      history: () => history,
      onPageAdded: added.add,
      onEndTidied: () => tidied++,
    );
  });

  test('fillTo adds pages up to the index plus one blank', () {
    pages = [content()];
    list.fillTo(3, firstPageId: 'abcdefghij');
    expect(pages.length, 5);
    expect(pages[1].pageId, 'abcdefghij');
    expect(pages[2].pageId, isNot('abcdefghij'));
    expect(added, pages.sublist(1));
  });

  test('fillTo adds nothing when a page follows the index already', () {
    pages = [content(), content()];
    list.fillTo(0, firstPageId: 'abcdefghij');
    expect(pages.length, 2);
    expect(added, isEmpty);
  });

  test('fillTo(-1) on an empty list makes one page with the given id', () {
    list.fillTo(-1, firstPageId: 'abcdefghij');
    expect(pages.length, 1);
    expect(pages.single.pageId, 'abcdefghij');
  });

  test('tidyEnd removes trailing empty pages and stops at a held page', () {
    final a = content();
    final held = EditorPage();
    final first = EditorPage();
    pages = [a, first, held, EditorPage()];
    history.recordChange(
      EditorHistoryItem(
        type: .insertPage,
        pageIndex: 2,
        strokes: const [],
        images: const [],
        page: held,
      ),
    );
    // the page after the held one goes, the held page and those before stay
    expect(list.tidyEnd(), isTrue);
    expect(pages, [a, first, held]);
    expect(tidied, 1);
    expect(list.tidyEnd(), isFalse);
    expect(tidied, 1);

    // a note of empty pages is tidied down to its first page
    history = EditorHistory();
    pages = [EditorPage(), EditorPage(), EditorPage()];
    final firstEmpty = pages.first;
    expect(list.tidyEnd(), isTrue);
    expect(pages.length, 1);
    expect(pages.first, same(firstEmpty));
    expect(tidied, 2);
  });

  test('tidyEnd keeps a page with a link and the empty page after it', () {
    final a = content();
    final linked = EditorPage()
      ..links.add(
        const PageLink(
          id: 'only-link',
          rect: Rect.fromLTWH(100, 100, 200, 40),
          target: 'https://example.com/a',
        ),
      );
    final spare = EditorPage();
    pages = [a, linked, spare];
    expect(list.tidyEnd(), isFalse);
    expect(pages, [a, linked, spare]);
    expect(tidied, 0);
  });

  test('move past the end pads with blank pages and puts one after a page '
      'with content', () {
    final a = content();
    pages = [a, EditorPage(), EditorPage()];
    list.move(a, 5);
    expect(pages.length, 7);
    expect(pages[5], same(a));
    for (final i in [0, 1, 2, 3, 4, 6]) {
      expect(pages[i].isEmpty, isTrue, reason: 'page $i');
    }
  });

  test('an empty page moved past the end is the last page', () {
    final a = content();
    final e = EditorPage();
    pages = [a, e, EditorPage()];
    list.move(e, 5);
    expect(pages.length, 6);
    expect(pages[5], same(e));
  });

  test('a move inside the note adds no page', () {
    final a = content();
    final b = content();
    final c = content();
    final spare = EditorPage();
    pages = [a, b, c, spare];
    list.move(a, 2);
    expect(pages, [b, c, a, spare]);
    expect(added, isEmpty);
  });

  test('put puts the page in, tells it, and records it unless told not '
      'to', () {
    final a = content();
    final b = content();
    final x = content();
    final y = content();
    pages = [a, b];
    list.put(1, x);
    expect(pages, [a, x, b]);
    expect(added, [x]);
    expect(history.holds(x), isTrue);

    list.put(0, y, record: false);
    expect(pages, [y, a, x, b]);
    expect(added, [x, y]);
    expect(history.holds(y), isFalse);
  });

  test('recordThenTidy keeps the page the record holds', () {
    final a = EditorPage();
    final x = EditorPage();
    final s = EditorPage();
    pages = [a, x, s];
    final item = EditorHistoryItem(
      type: .movePage,
      pageIndex: 1,
      toIndex: 1,
      strokes: const [],
      images: const [],
      page: x,
    );
    expect(list.recordThenTidy(item), isTrue);
    expect(pages, [a, x]);
    expect(tidied, 1);

    // tidying first would take x off too
    final b = EditorPage();
    pages = [b, EditorPage(), EditorPage()];
    history = EditorHistory();
    list.tidyEnd();
    expect(pages, [b]);
  });

  test('the history is read at every use', () {
    final a = content();
    final x = EditorPage();
    pages = [a];
    history = EditorHistory();
    list.put(1, x);
    expect(history.holds(x), isTrue);
  });
}
