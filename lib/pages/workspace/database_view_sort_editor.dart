import 'package:flutter/material.dart';
import 'package:saber/data/vault/workspace_database.dart';

class DatabaseViewSortEditor extends StatelessWidget {
  const new({
    required this.database,
    required this.sort,
    required this.onChanged,
    super.key,
  });

  final WorkspaceDatabase database;
  final List<Map<String, Object?>> sort;
  final ValueChanged<List<Map<String, Object?>>> onChanged;

  static const _maxCriteria = 16;

  String? _propertyId(Map<String, Object?> criterion) {
    final reference = criterion['propertyId'] ?? criterion['property'];
    if (reference is! String) return null;
    final properties = database.properties;
    if (properties.any((property) => property.id == reference)) return reference;
    return properties.where((p) => p.name == reference).singleOrNull?.id;
  }

  static String? _direction(Map<String, Object?> criterion) =>
      switch (criterion['direction']) {
        null || 'ascending' || 'asc' => 'ascending',
        'descending' || 'desc' => 'descending',
        _ => null,
      };

  void _replace(int index, Map<String, Object?> criterion) {
    onChanged([...sort]..[index] = criterion);
  }

  void _move(int from, int to) {
    final reordered = [...sort];
    final criterion = reordered.removeAt(from);
    reordered.insert(to, criterion);
    onChanged(reordered);
  }

  @override
  Widget build(BuildContext context) {
    final used = sort.map(_propertyId).toSet();
    final available = database.properties
        .where((property) => !used.contains(property.id))
        .firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (sort.isNotEmpty) const Text('위에서부터 순서대로 적용합니다.'),
        for (var index = 0; index < sort.length; index++)
          _criterion(index, used),
        OutlinedButton.icon(
          key: const ValueKey('database-view-sort-add'),
          onPressed: available == null || sort.length >= _maxCriteria
              ? null
              : () => onChanged([
                  ...sort,
                  {'propertyId': available.id, 'direction': 'ascending'},
                ]),
          icon: const Icon(Icons.add),
          label: const Text('정렬 기준 추가'),
        ),
      ],
    );
  }

  Widget _criterion(int index, Set<String?> used) {
    final criterion = sort[index];
    final id = _propertyId(criterion);
    final direction = _direction(criterion);
    final properties = database.properties.where(
      (property) => property.id == id || !used.contains(property.id),
    );
    final available =
        direction != null && properties.any((property) => property.id == id);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text('${index + 1}순위')),
                IconButton(
                  key: ValueKey('database-view-sort-up-$index'),
                  onPressed: index > 0 ? () => _move(index, index - 1) : null,
                  icon: const Icon(Icons.arrow_upward),
                  tooltip: '${index + 1}순위 위로 이동',
                ),
                IconButton(
                  key: ValueKey('database-view-sort-down-$index'),
                  onPressed: index + 1 < sort.length
                      ? () => _move(index, index + 1)
                      : null,
                  icon: const Icon(Icons.arrow_downward),
                  tooltip: '${index + 1}순위 아래로 이동',
                ),
                IconButton(
                  key: ValueKey('database-view-sort-remove-$index'),
                  onPressed: () => onChanged([...sort]..removeAt(index)),
                  icon: const Icon(Icons.delete_outline),
                  tooltip: '${index + 1}순위 정렬 기준 삭제',
                ),
              ],
            ),
            if (!available)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text('지원하지 않는 정렬 기준'),
              )
            else
              Row(
                children: [
                  Expanded(
                    child: InputDecorator(
                      decoration: const InputDecoration(labelText: '정렬 속성'),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          key: ValueKey('database-view-sort-property-$index'),
                          value: id,
                          isExpanded: true,
                          items: [
                            for (final property in properties)
                              DropdownMenuItem(
                                value: property.id,
                                child: Text(
                                  property.name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (next) {
                            if (next == null || next == id) return;
                            final key =
                                criterion['propertyId'] == null &&
                                    criterion.containsKey('property')
                                ? 'property'
                                : 'propertyId';
                            _replace(index, {...criterion, key: next});
                          },
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: InputDecorator(
                      decoration: const InputDecoration(labelText: '순서'),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          key: ValueKey('database-view-sort-direction-$index'),
                          value: direction,
                          isExpanded: true,
                          items: const [
                            DropdownMenuItem(
                              value: 'ascending',
                              child: Text('오름차순'),
                            ),
                            DropdownMenuItem(
                              value: 'descending',
                              child: Text('내림차순'),
                            ),
                          ],
                          onChanged: (next) {
                            if (next == null || next == direction) return;
                            _replace(index, {...criterion, 'direction': next});
                          },
                        ),
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
