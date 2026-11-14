import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/office/windows_office_engine.dart';

const sourceStructureHash =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const sourceStructurePartHash =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const sourceStructureInventoryHash =
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';

Map<String, dynamic> sourceStructureAuthorityWire({bool canAdd = true}) => {
  'kind': 'sourceStructure',
  'version': 1,
  'sourceSha256': sourceStructureHash,
  'sourcePart': 'ppt/slides/slide1.xml',
  'partSha256': sourceStructurePartHash,
  'shapeIdInventorySha256': sourceStructureInventoryHash,
  'shapeIdCount': 1,
  'canAddTable': canAdd,
};

Map<String, dynamic> sourceStructureSnapshotWire({bool authority = true}) => {
  'kind': 'presentation',
  'sourceSha256': sourceStructureHash,
  'paragraphs': [],
  'tables': [],
  'masters': [],
  'slides': [
    <String, dynamic>{
      'id': 'slide-0',
      'width': 280,
      'height': 157.5,
      'presentationTableCount': 0,
      'presentationTablesTruncated': false,
      'presentationTablesUnknownReason': null,
      'canAddTable': false,
      'shapes': [],
      'presentationTables': [],
      if (authority) 'sourceStructureAuthority': sourceStructureAuthorityWire(),
    },
  ],
};

Map<String, dynamic> _slide(Map<String, dynamic> value) =>
    value['slides'][0] as Map<String, dynamic>;

dynamic _authority(WindowsOfficeSnapshot value) {
  try {
    return (value.slides.single as dynamic).sourceStructureAuthority;
  } on NoSuchMethodError {
    return null;
  }
}

void main() {
  test(
    'verified table-free slide exposes separate source creation authority',
    () {
      final snapshot = WindowsOfficeSnapshot.fromJson(
        sourceStructureSnapshotWire(),
      );
      final dynamic authority = _authority(snapshot);
      expect(
        authority,
        isNotNull,
        reason:
            'Source creation authority must be parsed, not silently discarded',
      );
      expect(authority.kind, 'sourceStructure');
      expect(authority.version, 1);
      expect(authority.sourceSha256, sourceStructureHash);
      expect(authority.sourcePart, 'ppt/slides/slide1.xml');
      expect(authority.partSha256, sourceStructurePartHash);
      expect(authority.shapeIdInventorySha256, sourceStructureInventoryHash);
      expect(authority.shapeIdCount, 1);
      expect(authority.canAddTable, isTrue);
      expect(snapshot.slides.single.canAddTable, isFalse);
    },
  );

  test(
    'legacy absence and explicit false never invent creation permission',
    () {
      expect(
        _authority(
          WindowsOfficeSnapshot.fromJson(
            sourceStructureSnapshotWire(authority: false),
          ),
        ),
        isNull,
      );
      final value = sourceStructureSnapshotWire();
      _slide(value)['sourceStructureAuthority'] = sourceStructureAuthorityWire(
        canAdd: false,
      );
      final dynamic authority = _authority(
        WindowsOfficeSnapshot.fromJson(value),
      );
      expect(authority, isNotNull);
      expect(authority.canAddTable, isFalse);
    },
  );

  test('source structure fields and serialized maps are detached', () {
    final value = sourceStructureSnapshotWire();
    final dynamic authority = _authority(WindowsOfficeSnapshot.fromJson(value));
    expect(authority, isNotNull);
    _slide(value)['sourceStructureAuthority']['partSha256'] = 'd' * 64;
    final Map<String, dynamic> json = Map<String, dynamic>.from(
      authority.toJson() as Map,
    );
    json['shapeIdCount'] = 99;
    expect(authority.partSha256, sourceStructurePartHash);
    expect(authority.shapeIdCount, 1);
    expect(authority.toJson(), sourceStructureAuthorityWire());
  });

  test('closed authority validates version hashes canonical source part and inventory count', () {
    final mutations = <void Function(Map<String, dynamic>)>[
      (a) => a['extra'] = true,
      (a) => a['kind'] = 'sourceTextPatch',
      (a) => a['version'] = 2,
      (a) => a['version'] = true,
      (a) => a['sourceSha256'] = 'd' * 64,
      (a) => a['partSha256'] = 'B' * 64,
      (a) => a['shapeIdInventorySha256'] = 'x' * 64,
      (a) => a['sourcePart'] = '../slide.xml',
      (a) => a['sourcePart'] = r'ppt\slides\slide1.xml',
      (a) => a['sourcePart'] = 'ppt/slides/a%20.xml',
      (a) => a['shapeIdCount'] = -1,
      (a) => a['shapeIdCount'] = 131073,
      (a) => a['shapeIdCount'] = true,
      (a) => a['canAddTable'] = 1,
      (a) => a['canAddTable'] = null,
    ];
    for (final mutate in mutations) {
      final value = sourceStructureSnapshotWire();
      mutate(_slide(value)['sourceStructureAuthority'] as Map<String, dynamic>);
      expect(
        () => WindowsOfficeSnapshot.fromJson(value),
        throwsFormatException,
      );
    }
    for (final key in sourceStructureAuthorityWire().keys) {
      final value = sourceStructureSnapshotWire();
      (_slide(value)['sourceStructureAuthority'] as Map).remove(key);
      expect(
        () => WindowsOfficeSnapshot.fromJson(value),
        throwsFormatException,
        reason: key,
      );
    }
  });

  test('creation authority requires complete known owner inventory', () {
    for (final mutate in <void Function(Map<String, dynamic>)>[
      (s) => s['presentationTables'] = null,
      (s) => s['presentationTableCount'] = null,
      (s) => s['presentationTableCount'] = 1,
      (s) => s['presentationTablesTruncated'] = true,
      (s) => s['presentationTablesUnknownReason'] = 'source_binding_failed',
    ]) {
      final value = sourceStructureSnapshotWire();
      mutate(_slide(value));
      expect(
        () => WindowsOfficeSnapshot.fromJson(value),
        throwsFormatException,
      );
    }
    final wrongKind = sourceStructureSnapshotWire()..['kind'] = 'text';
    expect(
      () => WindowsOfficeSnapshot.fromJson(wrongKind),
      throwsFormatException,
    );
  });

  test('one source part cannot authorize two regular owners', () {
    final value = sourceStructureSnapshotWire();
    final second = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(_slide(value))) as Map,
    )..['id'] = 'slide-1';
    (value['slides'] as List).add(second);
    expect(() => WindowsOfficeSnapshot.fromJson(value), throwsFormatException);
  });

  test('master owners cannot acquire source structure authority', () {
    final value = sourceStructureSnapshotWire();
    final master = _slide(value);
    master['id'] = 'master-0';
    master['name'] = 'Master';
    value['masters'] = [master];
    value['slides'] = [];
    expect(() => WindowsOfficeSnapshot.fromJson(value), throwsFormatException);
  });

  test(
    'zero and maximum source inventory counts stay exact read-only data',
    () {
      for (final count in [0, 131072]) {
        final value = sourceStructureSnapshotWire();
        _slide(value)['sourceStructureAuthority'] = {
          ...sourceStructureAuthorityWire(canAdd: false),
          'shapeIdCount': count,
        };
        final dynamic authority = _authority(
          WindowsOfficeSnapshot.fromJson(value),
        );
        expect(authority, isNotNull);
        expect(authority.shapeIdCount, count);
      }
    },
  );
}
