import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/infinite_document.dart';
import 'package:saber/data/vault/workspace_navigation.dart';

void main() {
  test(
    'recent documents track visits independently of tabs and history',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'workspace-recent-state-',
      );
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/navigation.json');
      final nav = WorkspaceNavigation();
      final a = newId(), b = newId(), c = newId();
      nav.openDocument(a, 'A');
      nav.openDocument(b, 'B');
      nav.openDocument(c, 'C');
      nav.goBack();
      expect(nav.recentDocumentIds, [b, c, a]);
      nav.goForward();
      nav.closeTab(b);
      nav.showLibrary(null);
      expect(nav.recentDocumentIds, [c, b, a]);
      expect(nav.pruneDeletedDocuments({b}), isTrue);
      await nav.save(file);
      expect((await WorkspaceNavigation.load(file)).recentDocumentIds, [c, a]);
    },
  );

  test(
    'recent documents remain bounded and legacy history supplies visits',
    () {
      final nav = WorkspaceNavigation();
      final ids = [for (var i = 0; i < 105; i++) newId()];
      for (final id in ids) {
        nav.openDocument(id, 'Note');
      }
      expect(nav.recentDocumentIds, ids.reversed.take(100));
      nav.openDocument(ids.first, 'Renamed');
      expect(nav.recentDocumentIds, [ids.first, ...ids.reversed.take(99)]);
      final legacy = nav.toJson()..remove('recentDocumentIds');
      expect(
        WorkspaceNavigation.fromJson(legacy).recentDocumentIds,
        nav.recentDocumentIds,
      );
    },
  );

  test('infinite view is local and survives navigation state reload', () async {
    final root = await Directory.systemTemp.createTemp('infinite-view-state-');
    final file = File('${root.path}/navigation.json');
    final id = newId();
    final nav = WorkspaceNavigation();
    nav.setInfiniteViewport(
      id,
      const InfiniteViewport(offset: Offset(-1e9, 250), scale: .25),
    );
    await nav.save(file);
    final restored = await WorkspaceNavigation.load(file);
    expect(restored.infiniteViewport(id)!.offset, const Offset(-1e9, 250));
    expect(restored.infiniteViewport(id)!.scale, .25);
    await root.delete(recursive: true);
  });
  test('tab and history keep document and folder positions independently', () {
    final nav = WorkspaceNavigation();
    final folder = newId(), a = newId(), b = newId();
    nav.showLibrary(folder);
    nav.openDocument(a, 'A', folderId: folder);
    nav.openDocument(b, 'B', folderId: folder);
    expect(nav.tabs.map((t) => t.noteId), [a, b]);
    expect(nav.peekBack!.noteId, a);
    nav.goBack();
    expect(nav.current.noteId, a);
    expect(nav.peekForward!.noteId, b);
    nav.goBack();
    expect(nav.current.noteId, isNull);
    expect(nav.current.folderId, folder);
    nav.goForward();
    expect(nav.current.noteId, a);
    nav.openDocument(a, 'Renamed', folderId: folder);
    expect(nav.tabs.first.title, 'Renamed');
    nav.showLibrary(null);
    expect(nav.peekForward, isNull);
    nav.closeTab(a);
    expect(nav.tabs.map((t) => t.noteId), [b]);
  });

  test(
    'tab views survive history traversal, title changes and serialization',
    () {
      final nav = WorkspaceNavigation();
      final first = newId(), second = newId(), page = newId();
      nav.openDocument(first, 'First');
      nav.updateView(markdown: false, pageId: page);
      nav.openDocument(
        second,
        'Second',
        markdown: true,
        markdownAnchor: 'Methods',
      );
      nav.goBack();
      expect(nav.current.pageId, page);
      expect(nav.tabs.first.location!.pageId, page);
      nav.updateView(markdown: true, markdownAnchor: 'Results');
      nav.goForward();
      expect(nav.tabs.first.location!.markdownAnchor, 'Results');
      expect(nav.tabs.last.location!.markdownAnchor, 'Methods');
      nav.updateTitle(first, 'Renamed');
      final restored = WorkspaceNavigation.fromJson(nav.toJson());
      expect(restored.tabs.first.title, 'Renamed');
      expect(restored.tabs.first.location!.markdownAnchor, 'Results');
      expect(restored.tabs.last.location!.sameAs(restored.current), isTrue);
    },
  );

  test(
    'version 1 tabs recover known positions and leave unknown views unset',
    () {
      final active = newId(),
          background = newId(),
          forward = newId(),
          unknown = newId();
      final page = newId(), folder = newId();
      final legacy = <String, dynamic>{
        'version': 1,
        'current': {'noteId': active, 'folderId': folder, 'markdown': true},
        'tabs': [
          for (final id in [active, background, forward, unknown])
            <String, dynamic>{'noteId': id, 'title': id},
        ],
        'back': [
          {'noteId': background, 'pageId': page},
        ],
        'forward': [
          {'noteId': forward, 'markdown': true, 'markdownAnchor': 'Heading'},
        ],
      };
      final restored = WorkspaceNavigation.fromJson(legacy);
      expect(restored.tabs[0].location!.sameAs(restored.current), isTrue);
      expect(restored.tabs[1].location!.pageId, page);
      expect(restored.tabs[2].location!.markdownAnchor, 'Heading');
      expect(restored.tabs[3].location, isNull);
      expect(restored.toJson()['version'], 1);
      final tabs = legacy['tabs'] as List<Map<String, dynamic>>;
      tabs[0]['location'] = {'noteId': background};
      expect(() => WorkspaceNavigation.fromJson(legacy), throwsFormatException);
    },
  );

  test(
    'navigation preserves Unicode titles and page links in a local sidecar',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'workspace-navigation-state-',
      );
      final file = File('${root.path}/.workspace/navigation.json');
      final nav = WorkspaceNavigation();
      final note = newId(), page = newId();
      nav.openDocument(note, '연구 노트', pageId: page, markdown: true);
      await nav.save(file);
      final restored = await WorkspaceNavigation.load(file);
      expect(restored.current.noteId, note);
      expect(restored.current.pageId, page);
      expect(restored.current.markdown, isTrue);
      expect(restored.tabs.single.title, '연구 노트');
      restored.showLibrary(null);
      await restored.save(file);
      expect((await WorkspaceNavigation.load(file)).peekBack!.pageId, page);
      expect(
        await root.list(recursive: true).where((e) => e is File).length,
        1,
      );
      await root.delete(recursive: true);
    },
  );

  test('corrupt ids and unsupported sidecars are rejected without changing the file', () async {
    final root = await Directory.systemTemp.createTemp(
      'workspace-navigation-invalid-',
    );
    final file = File('${root.path}/navigation.json');
    const bad =
        '{"version":1,"current":{"noteId":"../../private"},"tabs":[],"back":[],"forward":[]}';
    await file.writeAsString(bad);
    await expectLater(WorkspaceNavigation.load(file), throwsFormatException);
    expect(await file.readAsString(), bad);
    expect(
      () => WorkspaceNavigation.fromJson({'version': 99}),
      throwsFormatException,
    );
    await root.delete(recursive: true);
  });

  test(
    'navigation history is bounded while a repeated location adds no duplicate',
    () {
      final nav = WorkspaceNavigation();
      final id = newId();
      nav.openDocument(id, 'A');
      nav.openDocument(id, 'A');
      expect(nav.backLength, 1);
      for (var i = 0; i < 160; i++) nav.showLibrary(newId());
      expect(nav.backLength, lessThanOrEqualTo(100));
    },
  );
}
