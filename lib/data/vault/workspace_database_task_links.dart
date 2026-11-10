part of 'workspace_database.dart';

final class DatabaseTaskLink {
  new _(this.parentId, List<String> predecessorIds)
    : predecessorIds = List.unmodifiable(predecessorIds);

  static const maxPredecessors = 64;

  final String? parentId;
  final List<String> predecessorIds;
}

const _maxTaskLinkRows = 10000;
const _maxTaskLinkEdges = 20000;

Map<String, DatabaseTaskLink>? _readTaskLinks(Object? raw) {
  try {
    final envelope = _object(raw);
    if (envelope.length != 2 || !identical(envelope['schemaVersion'], 1))
      return null;
    final items = _object(envelope['items']);
    if (items.length > _maxTaskLinkRows) return null;
    final result = <String, DatabaseTaskLink>{};
    var edgeCount = 0;
    for (final entry in items.entries) {
      final rowId = _taskLinkId(entry.key);
      final link = _object(entry.value);
      if (link.keys.any((key) => key != 'parentId' && key != 'predecessorIds'))
        return null;
      final parentId = link.containsKey('parentId')
          ? _taskLinkId(link['parentId'])
          : null;
      final rawPredecessors = link.containsKey('predecessorIds')
          ? _list(link['predecessorIds'])
          : const [];
      if (parentId == rowId ||
          rawPredecessors.length > DatabaseTaskLink.maxPredecessors) {
        return null;
      }
      final predecessors = rawPredecessors.map(_taskLinkId).toSet();
      if (predecessors.length != rawPredecessors.length ||
          predecessors.contains(rowId)) {
        return null;
      }
      edgeCount += predecessors.length + (parentId == null ? 0 : 1);
      if (edgeCount > _maxTaskLinkEdges) return null;
      result[rowId] = DatabaseTaskLink._(parentId, predecessors.toList());
    }
    return Map.unmodifiable(result);
  } on FormatException {
    return null;
  }
}

String _taskLinkId(Object? value) {
  if (value is! String) throw const FormatException('Expected task row UUID');
  validateId(value);
  return value;
}

Map<String, dynamic>? _pruneTaskLinksForRow(
  WorkspaceDatabase database,
  String rowId,
) {
  final links = database.taskLinks;
  if (links.isEmpty) return null;
  final envelope = database.taskLinksEnvelope!;
  final items = _object(envelope['items']);
  var changed = items.remove(rowId) != null;
  for (final entry in links.entries) {
    if (entry.key == rowId) continue;
    final link = entry.value;
    final parentRemoved = link.parentId == rowId;
    final predecessorRemoved = link.predecessorIds.contains(rowId);
    if (!parentRemoved && !predecessorRemoved) continue;
    changed = true;
    final parentId = parentRemoved ? null : link.parentId;
    final predecessors = link.predecessorIds
        .where((id) => id != rowId)
        .toList();
    if (parentId == null && predecessors.isEmpty) {
      items.remove(entry.key);
    } else {
      items[entry.key] = {
        'parentId': ?parentId,
        if (predecessors.isNotEmpty) 'predecessorIds': predecessors,
      };
    }
  }
  return changed ? {...envelope, 'items': items} : null;
}
