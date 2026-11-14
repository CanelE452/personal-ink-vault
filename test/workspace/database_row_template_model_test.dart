import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart' show newId;
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_media.dart';
import 'package:saber/data/vault/database_media_snapshot.dart';
import 'package:saber/data/vault/workspace_database.dart';

const _namespace = 'pivRowTemplates';

void main() {
  test('a scheduled template stays available until the rule is archived', () {
    final row = DatabaseRow.create();
    final templateId = newId();
    final database = WorkspaceDatabase.empty()
        .addRow(row)
        .captureRowTemplate(
          rowId: row.id,
          templateId: templateId,
          name: 'Weekly',
        );
    WorkspaceDatabase withRule({required bool archived}) =>
        WorkspaceDatabase.fromJson({
          ...database.toJson(),
          'automationRules': [
            {
              'enabled': false,
              'archived': archived,
              'actions': [
                {'type': 'addRowFromTemplate', 'templateId': templateId},
              ],
            },
          ],
        });
    expect(
      () => withRule(archived: false).removeRowTemplate(templateId),
      throwsFormatException,
    );
    expect(
      withRule(archived: true).removeRowTemplate(templateId).rowTemplates,
      isEmpty,
    );
  });

  test(
    'round-trips a row template and creates independent deterministic copies',
    () {
      final title = DatabaseProperty.create(name: 'Title', type: 'title');
      final nested = BlockPageBlock.create(type: 'todo', text: 'Read');
      final heading = BlockPageBlock.create(
        type: 'toggle',
        text: 'Agenda',
      ).copyWith(children: [nested]);
      final row = DatabaseRow.create(
        values: {title.id: 'Weekly review'},
        body: const BlockPageDocument.empty()
            .copyWith(blocks: [heading])
            .toJson(),
      );
      final original = WorkspaceDatabase.empty().copyWith(
        properties: [title],
        rows: [row],
      );
      final templateId = newId();
      final captured = original.captureRowTemplate(
        rowId: row.id,
        templateId: templateId,
        name: '  Weekly  ',
      );
      expect(captured.toJson()[_namespace], {
        'schemaVersion': 1,
        'items': [captured.rowTemplates.single.toJson()],
      });
      final reopened = WorkspaceDatabase.fromJson(captured.toJson())
          .removeRow(row.id);
      expect(reopened.rowTemplates.single.name, 'Weekly');
      expect(reopened.rowTemplates.single.values, {title.id: 'Weekly review'});
      final rowId = newId();
      final first = reopened.instantiateRowTemplate(
        templateId: templateId,
        rowId: rowId,
        overrides: {title.id: 'New week'},
      );
      final retry = reopened.instantiateRowTemplate(
        templateId: templateId,
        rowId: rowId,
        overrides: {title.id: 'New week'},
      );
      final second = reopened.instantiateRowTemplate(
        templateId: templateId,
        rowId: newId(),
      );
      expect(first.toJson(), retry.toJson());
      expect(first.id, rowId);
      expect(first.values, {title.id: 'New week'});
      expect(second.values, {title.id: 'Weekly review'});
      final firstHeading = BlockPageDocument.fromJson(first.body).blocks.single;
      final secondHeading = BlockPageDocument.fromJson(second.body)
          .blocks
          .single;
      expect(firstHeading.id, isNot(heading.id));
      expect(firstHeading.id, isNot(secondHeading.id));
      expect(firstHeading.text, 'Agenda');
      expect(firstHeading.children.single.id, isNot(nested.id));
      expect(firstHeading.children.single.text, 'Read');
      expect(original.toJson().containsKey(_namespace), isFalse);
      expect(
        reopened.removeRowTemplate(templateId).toJson().containsKey(_namespace),
        isFalse,
      );
    },
  );

  test(
    'legacy opaque row templates survive edits and do not get overwritten',
    () {
      final initial = WorkspaceDatabase.empty().addRow(DatabaseRow.create());
      final rowId = initial.rows.single.id;
      final titleId = initial.properties.single.id;
      final vendorField = {
        'vendor': ['opaque'],
      };
      final old = WorkspaceDatabase.fromJson({
        ...initial.toJson(),
        'rowTemplates': vendorField,
      });
      expect(old.rowTemplates, isEmpty);
      final captured = old
          .renameProperty(titleId, 'Changed')
          .captureRowTemplate(
            rowId: rowId,
            templateId: newId(),
            name: 'New template',
          );
      expect(captured.toJson()['rowTemplates'], vendorField);
      expect(
        WorkspaceDatabase.fromJson(captured.toJson()).toJson(),
        captured.toJson(),
      );

      final reservedVendorField = {
        'schemaVersion': 2,
        'items': ['opaque'],
      };
      final occupied = WorkspaceDatabase.fromJson({
        ...old.toJson(),
        _namespace: reservedVendorField,
      });
      expect(occupied.rowTemplates, isEmpty);
      expect(
        occupied.renameProperty(titleId, 'Another edit').toJson()[_namespace],
        reservedVendorField,
      );
      expect(
        () => occupied.captureRowTemplate(
          rowId: rowId,
          templateId: newId(),
          name: 'Cannot overwrite',
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'template envelope preserves bodies already at the v1 nesting limit',
    () {
      Object nested = 'boundary';
      for (var index = 0; index < 60; index++) {
        nested = [nested];
      }
      final row = DatabaseRow.create(
        body: {'version': 1, 'blocks': [], 'opaque': nested},
      );
      final loaded = WorkspaceDatabase.fromJson(
        WorkspaceDatabase.empty().addRow(row).toJson(),
      );
      final templateId = newId();
      final captured = loaded.captureRowTemplate(
        rowId: row.id,
        templateId: templateId,
        name: 'Nested data',
      );
      final reopened = WorkspaceDatabase.fromJson(captured.toJson());
      final copy = reopened.instantiateRowTemplate(
        templateId: templateId,
        rowId: newId(),
      );
      expect(copy.body, row.body);
    },
  );

  test('drops obsolete defaults and validates current property overrides', () {
    final removed = DatabaseProperty.create(name: 'Removed');
    final changed = DatabaseProperty.create(name: 'Changed');
    final option = DatabaseProperty.create(
      name: 'Status',
      type: 'select',
      config: {
        'options': ['open', 'closed'],
      },
    );
    final row = DatabaseRow.create(
      values: {
        removed.id: 'remove me',
        changed.id: 'compatible string',
        option.id: 'open',
      },
    );
    final templateId = newId();
    final database = WorkspaceDatabase.empty()
        .copyWith(properties: [removed, changed, option], rows: [row])
        .captureRowTemplate(
          rowId: row.id,
          templateId: templateId,
          name: 'Saved',
        )
        .removeRow(row.id)
        .removeProperty(removed.id)
        .updateProperty(changed.copyWith(type: 'phone'))
        .updateProperty(
          option.copyWith(
            config: {
              'options': ['closed'],
            },
          ),
        );
    expect(
      database
          .instantiateRowTemplate(templateId: templateId, rowId: newId())
          .values,
      isEmpty,
    );
    expect(
      database
          .instantiateRowTemplate(
            templateId: templateId,
            rowId: newId(),
            overrides: {option.id: 'closed'},
          )
          .values,
      {option.id: 'closed'},
    );
    expect(
      () => database.instantiateRowTemplate(
        templateId: templateId,
        rowId: newId(),
        overrides: {option.id: 'open'},
      ),
      throwsFormatException,
    );
    expect(
      () => database.instantiateRowTemplate(
        templateId: templateId,
        rowId: newId(),
        overrides: {removed.id: 'missing'},
      ),
      throwsFormatException,
    );
  });

  test(
    'validates template-only media and rekeys references on instantiation',
    () {
      final block = BlockPageBlock.create(
        type: 'attachment',
        text: 'Reference',
      );
      final asset = BlockPageMediaAsset.attachment(
        name: 'source.txt',
        bytes: utf8.encode('source'),
      );
      final row = DatabaseRow.create(
        body: const BlockPageDocument.empty()
            .copyWith(blocks: [block], media: {block.id: asset.reference})
            .toJson(),
      );
      final templateId = newId();
      final database = WorkspaceDatabase.empty()
          .addRow(row)
          .captureRowTemplate(
            rowId: row.id,
            templateId: templateId,
            name: 'With attachment',
          )
          .removeRow(row.id);
      expect(
        () => DatabaseMediaSnapshot.prepare(database),
        throwsFormatException,
      );
      final snapshot = DatabaseMediaSnapshot.prepare(
        database,
        addedFiles: {asset.reference.path: asset.bytes},
      );
      final reopened = DatabaseMediaSnapshot.fromFiles(snapshot.files);
      final instance = reopened.database.instantiateRowTemplate(
        templateId: templateId,
        rowId: newId(),
      );
      final body = BlockPageDocument.fromJson(instance.body);
      final clonedId = body.blocks.single.id;
      expect(clonedId, isNot(block.id));
      expect(body.media.keys, [clonedId]);
      final published = DatabaseMediaSnapshot.prepare(
        reopened.database.addRow(instance),
        existingFiles: reopened.files,
      );
      expect(published.mediaBytes(instance.id, clonedId), asset.bytes);
      expect(
        published.files.keys,
        unorderedEquals(['database.json', asset.reference.path]),
      );
    },
  );

  test('rejects archived source rows and ambiguous local block references', () {
    final target = BlockPageBlock.create(type: 'paragraph', text: 'Target');
    final row = DatabaseRow.create(
      body: {
        'version': 1,
        'blocks': [
          target.toJson(),
          {
            ...BlockPageBlock.create(type: 'paragraph').toJson(),
            'futureTarget': target.id,
          },
        ],
      },
    );
    final database = WorkspaceDatabase.empty().addRow(row);
    expect(
      () => database.captureRowTemplate(
        rowId: row.id,
        templateId: newId(),
        name: 'Ambiguous',
      ),
      throwsFormatException,
    );
    expect(
      () => database
          .archiveRow(row.id)
          .captureRowTemplate(
            rowId: row.id,
            templateId: newId(),
            name: 'Archived',
          ),
      throwsFormatException,
    );
  });
}
