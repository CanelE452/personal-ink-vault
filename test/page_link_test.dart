import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/canvas/_asset_cache.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/editor/page_link.dart';
import 'package:saber/data/flavor_config.dart';

/// Notein's hyperlinks as a handwritten page stores them: a list `lk` of
/// `{i, x, y, w, h, t}` that older builds skip.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();

  const pageId = '5b0c1f3e-2d4a-4f6b-8c7d-9e0f1a2b3c4d';
  const noteId = '0f9e8d7c-6b5a-4c3d-9e2f-1a0b9c8d7e6f';

  EditorPage parse(Map<String, dynamic> json) => EditorPage.fromJson(
    json,
    inlineAssets: null,
    readOnly: false,
    fileVersion: EditorCoreInfo.sbnVersion,
    sbnPath: '/links',
    assetCache: AssetCache(),
  );

  (String, Rect, String) fields(PageLink link) => (link.id, link.rect, link.target);

  test('a page without links still parses', () {
    final page = parse({'pageId': pageId, 'w': 1000.0, 'h': 1400.0});
    expect(page.pageId, pageId);
    expect(page.links, isEmpty);
    // An unlinked page is written exactly as before links existed.
    expect(
      page.toJson(OrderedAssetCache(), notePattern: .none).containsKey('lk'),
      isFalse,
    );
    page.dispose();
  });

  test('links survive save, reload and page duplication', () async {
    final target = EditorPage();
    final page = EditorPage(
      links: [
        PageLink(
          id: 'a6c1d3e5-7f90-4b2c-8d4e-6f8091a2b3c4',
          rect: const Rect.fromLTWH(10, 20, 300, 40.5),
          target: 'page:${target.pageId}',
        ),
        const PageLink(
          id: 'b7d2e4f6-8091-4c3d-9e5f-708192a3b4c5',
          rect: Rect.fromLTWH(500, 600, 0, 0),
          target: 'https://example.com/x?y=1',
        ),
        const PageLink(
          id: 'c8e3f5a7-9102-4d4e-8f60-8192a3b4c5d6',
          rect: Rect.fromLTWH(0, 0, 1000, 1400),
          target: 'inkvault://note/$noteId?page=$pageId',
        ),
      ],
    );
    final core = EditorCoreInfo(filePath: '/links')..pages.addAll([page, target]);
    final (bson, _) = core.saveToBinary(currentPageIndex: 0);
    final reloaded = await EditorCoreInfo.loadFromFileContents(
      bsonBytes: bson,
      path: '/links',
      onlyFirstPage: false,
    );
    expect(reloaded.readOnlyReason, isNull);
    expect(reloaded.pages.first.links.map(fields), page.links.map(fields));
    expect(reloaded.pages[1].links, isEmpty);
    expect(reloaded.pages[1].pageId, target.pageId);

    final copy = page.copyWith(newIdentity: true);
    expect(copy.pageId, isNot(page.pageId));
    expect(copy.links, isNot(same(page.links)));
    expect(
      copy.links.map((link) => (link.rect, link.target)),
      page.links.map((link) => (link.rect, link.target)),
    );
    for (final link in copy.links) {
      expect(page.links.map((link) => link.id), isNot(contains(link.id)));
    }
    expect(copy.links.map((link) => link.id).toSet(), hasLength(copy.links.length));
    // The copy shares the page's text box, so only the originals are disposed.
    reloaded.dispose();
    core.dispose();
  });

  test('links do not make a page count as written', () {
    // Links are not content (new blank pages, PDF export); the editor still
    // keeps a page that carries one (editor_link_test).
    final page = EditorPage(
      links: const [
        PageLink(
          id: 'd9f4a6b8-0213-4e5f-9071-92a3b4c5d6e7',
          rect: Rect.fromLTWH(1, 2, 0, 0),
          target: 'https://example.com',
        ),
      ],
    );
    expect(page.isEmpty, isTrue);
    page.dispose();
  });

  test('bad link entries are dropped', () {
    final good = <String, Object>{
      'i': 'e0a5b7c9-1324-4f60-8182-a3b4c5d6e7f8',
      'x': 1,
      'y': Int64(2),
      'w': 3.5,
      'h': 0,
      't': 'https://example.com',
    };
    final page = parse({
      'pageId': pageId,
      'lk': [
        good,
        'not a map',
        null,
        {...good, 'i': ''},
        {...good, 'i': 7},
        {...good, 'x': 'left'},
        {...good, 'w': -1.0},
        {...good, 'y': double.nan},
        {...good, 'h': double.infinity},
        {...good, 't': 'javascript:alert(1)'},
        {...good, 't': 'page:not-a-page'},
        {...good, 't': 'inkvault://note/not-a-note'},
        {...good, 't': 42},
        {'i': 'f1b6c8d0-2435-4071-9293-b4c5d6e7f809', 'x': 1.0},
      ],
    });
    expect(page.links.map(fields), [
      ('e0a5b7c9-1324-4f60-8182-a3b4c5d6e7f8', const Rect.fromLTWH(1, 2, 3.5, 0), 'https://example.com'),
    ]);
    expect(PageLink.fromJson('not a map'), isNull);
    final notAList = parse({'pageId': pageId, 'lk': {'i': 'x'}});
    expect(notAList.links, isEmpty);
    page.dispose();
    notAList.dispose();
  });

  test('kinds are read from the target', () {
    PageLink link(String target) =>
        PageLink(id: 'k', rect: Rect.zero, target: target);
    expect(link('page:$pageId').kind, PageLinkKind.page);
    expect(link('page:$pageId').pageId, pageId);
    expect(link('inkvault://note/$noteId').kind, PageLinkKind.note);
    expect(link('inkvault://note/$noteId?page=$pageId').kind, PageLinkKind.note);
    expect(link('https://example.com/a?b=1').kind, PageLinkKind.web);
    expect(link('http://example.com').kind, PageLinkKind.web);
    expect(link('https://example.com').pageId, isNull);
    expect(PageLink.kindOf('page:'), isNull);
    expect(PageLink.kindOf('page:not-a-page'), isNull);
    expect(PageLink.kindOf('inkvault://note/not-a-note'), isNull);
    expect(PageLink.kindOf('ftp://example.com'), isNull);
    expect(PageLink.kindOf('https://user@example.com'), isNull);
    expect(PageLink.kindOf(''), isNull);
  });
}
