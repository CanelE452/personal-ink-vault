import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/workspace_navigation.dart';

Map<String, Object?> _location(
  String note,
  String? anchor, {
  bool markdown = true,
}) => {
  'noteId': note,
  'folderId': null,
  'pageId': null,
  'markdown': markdown,
  'markdownAnchor': anchor,
};

void _open(WorkspaceNavigation navigation, String note, String anchor) {
  navigation.openDocument(note, 'Note', markdown: true, markdownAnchor: anchor);
}

void main() {
  test('Markdown anchors remain distinct within a single document history', () {
    final note = newId();
    final a = WorkspaceLocation.fromJson(
      Map<String, dynamic>.from(_location(note, 'A')),
    );
    final b = WorkspaceLocation.fromJson(
      Map<String, dynamic>.from(_location(note, '^block')),
    );
    expect(a.toJson()['markdownAnchor'], 'A');
    expect(b.toJson()['markdownAnchor'], '^block');
    expect(a.sameAs(b), false);
    final navigation = WorkspaceNavigation();
    _open(navigation, note, 'A');
    _open(navigation, note, '^block');
    _open(navigation, note, '^block');
    expect(navigation.backLength, 2);
    navigation.goBack();
    expect(navigation.current.toJson()['markdownAnchor'], 'A');
    navigation.goForward();
    expect(navigation.current.toJson()['markdownAnchor'], '^block');
  });

  test('Markdown anchors survive version one sidecars without changing PDF IDs', () async {
    final root = await Directory.systemTemp.createTemp(
      'markdown-anchor-navigation-',
    );
    try {
      final file = File('${root.path}/navigation.json');
      final note = newId(), page = newId();
      final navigation = WorkspaceNavigation();
      navigation.openDocument(note, 'PDF', pageId: page);
      _open(navigation, note, '부모#자식');
      await navigation.save(file);
      final raw = jsonDecode(await file.readAsString()) as Map;
      expect(raw['version'], 1);
      final restored = await WorkspaceNavigation.load(file);
      expect(restored.current.toJson()['markdownAnchor'], '부모#자식');
      expect(restored.current.pageId, null);
      restored.goBack();
      expect(restored.current.pageId, page);
      expect(restored.current.toJson()['markdownAnchor'], null);
    } finally {
      final resolved = await root.resolveSymbolicLinks();
      expect(
        resolved,
        startsWith(
          '${await Directory.systemTemp.resolveSymbolicLinks()}${Platform.pathSeparator}markdown-anchor-navigation-',
        ),
      );
      await Directory(resolved).delete(recursive: true);
    }
  });

  test(
    'Markdown anchor validation rejects bad shape and non Markdown locations',
    () {
      final note = newId();
      for (final anchor in [
        0,
        true,
        <String>[],
        '',
        'unsafe\u0000anchor',
        'line\nfeed',
        'x' * 2049,
      ]) {
        expect(
          () => WorkspaceLocation.fromJson({
            ..._location(note, null),
            'markdownAnchor': anchor,
          }),
          throwsFormatException,
        );
      }
      expect(
        () => WorkspaceLocation.fromJson(
          Map<String, dynamic>.from(_location(note, 'A', markdown: false)),
        ),
        throwsFormatException,
      );
      expect(
        () => WorkspaceLocation.fromJson({
          ..._location(note, 'A'),
          'noteId': null,
        }),
        throwsFormatException,
      );
      expect(
        () => WorkspaceLocation.fromJson({
          ..._location(note, 'A'),
          'pageId': newId(),
        }),
        throwsFormatException,
      );
      expect(
        () => WorkspaceNavigation().openDocument(
          note,
          'Note',
          markdownAnchor: 'A',
        ),
        throwsFormatException,
      );
      final oldMixedLocation = WorkspaceLocation.fromJson({
        ..._location(note, null),
        'pageId': newId(),
      });
      expect(oldMixedLocation.pageId, isNotNull);
      final legacy = WorkspaceLocation.fromJson({
        'noteId': note,
        'markdown': true,
      });
      expect(legacy.toJson()['markdownAnchor'], null);
    },
  );
}
