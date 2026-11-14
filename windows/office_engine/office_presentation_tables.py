"""Read-only catalog of actual Impress TableShape, Model and cell references."""
import copy
import hashlib
import json
import math
from pathlib import Path

import office_text


TABLE_TYPE = 'com.sun.star.drawing.TableShape'
TABLE_LIMIT, CELL_LIMIT = 20, 100
CAPABILITIES = (
    'canEditText', 'canEditTextStyle', 'canEditAppearance',
    'canInsertRows', 'canDeleteRows', 'canInsertColumns',
    'canDeleteColumns', 'canMerge', 'canSplit', 'canDeleteTable',
)
SHAPE_PROPERTIES = (
    'Name', 'ZOrder', 'RotateAngle', 'ShearAngle', 'Visible', 'TableTemplate',
    'UseFirstRowStyle', 'UseLastRowStyle', 'UseFirstColumnStyle',
    'UseLastColumnStyle', 'UseBandingRowStyle', 'UseBandingColumnStyle',
)
CELL_PROPERTIES = (
    'CharHeight', 'CharWeight', 'CharPosture', 'CharColor', 'CharFontName',
    'ParaAdjust', 'FillStyle', 'FillColor', 'FillColorTheme', 'FillTransparence',
    'LeftBorder', 'RightBorder', 'TopBorder', 'BottomBorder',
    'LeftBorder2', 'RightBorder2', 'TopBorder2', 'BottomBorder2',
    'TextLeftDistance', 'TextRightDistance', 'TextUpperDistance', 'TextLowerDistance',
    'TextVerticalAdjust', 'VerticalJustify', 'IsProtected',
)
TEXT_PROPERTIES = (
    'TextPortionType', 'CharFontName', 'CharHeight', 'CharWeight', 'CharPosture',
    'CharUnderline', 'CharColor', 'CharBackColor', 'CharHidden', 'CharEscapement',
    'CharStrikeout', 'CharKerning', 'CharAutoKerning', 'CharStyleName', 'CharLocale',
    'ParaStyleName', 'ParaAdjust', 'ParaTopMargin', 'ParaBottomMargin',
    'ParaLeftMargin', 'ParaRightMargin', 'ParaFirstLineIndent', 'ParaLineSpacing',
    'HyperLinkURL', 'TextField', 'Bookmark',
)
STRUCT_FIELDS = {
    'com.sun.star.table.BorderLine': ('Color', 'InnerLineWidth', 'OuterLineWidth', 'LineDistance'),
    'com.sun.star.table.BorderLine2': ('Color', 'InnerLineWidth', 'OuterLineWidth',
        'LineDistance', 'LineStyle', 'LineWidth'),
    'com.sun.star.awt.Point': ('X', 'Y'),
    'com.sun.star.awt.Size': ('Width', 'Height'),
    'com.sun.star.awt.Rectangle': ('X', 'Y', 'Width', 'Height'),
    'com.sun.star.lang.Locale': ('Language', 'Country', 'Variant'),
    'com.sun.star.style.LineSpacing': ('Mode', 'Height'),
    'com.sun.star.awt.Gradient': ('Style', 'StartColor', 'EndColor', 'Angle',
        'Border', 'XOffset', 'YOffset', 'StartIntensity', 'EndIntensity', 'StepCount'),
    'com.sun.star.drawing.Hatch': ('Style', 'Color', 'Distance', 'Angle'),
    'com.sun.star.table.ShadowFormat': ('Location', 'ShadowWidth', 'IsTransparent', 'Color'),
}


class CatalogUnavailable(ValueError):
    def __init__(self, reason):
        super().__init__(reason)
        self.reason = reason


def unknown(reason):
    return {'unknown': True, 'error': reason}


class ReadBudgetExceeded(ValueError):
    pass


class DocBudget:
    READ_LIMIT, NODE_LIMIT, RAW_BYTES = 32768, 131072, 8 * 1024 * 1024
    CORE_RESERVE, NODE_RESERVE, BYTE_RESERVE = 12288, 32768, 1024 * 1024

    def __init__(self):
        self.reads, self.nodes, self.raw_bytes, self.exhausted = 0, 0, 0, False
        self.interface_type = None

    def fail(self):
        self.exhausted = True
        raise ReadBudgetExceeded('read_budget_exhausted')

    def read(self):
        if self.exhausted or self.reads >= self.READ_LIMIT - self.CORE_RESERVE:
            self.fail()
        self.reads += 1

    def core_read(self):
        if self.reads >= self.READ_LIMIT:
            self.fail()
        self.reads += 1

    def node(self, value=None):
        if self.exhausted or self.nodes >= self.NODE_LIMIT - self.NODE_RESERVE:
            self.fail()
        self.nodes += 1
        if isinstance(value, str):
            if len(value) > self.RAW_BYTES - self.BYTE_RESERVE - self.raw_bytes:
                self.fail()
            cost = 2
            for index in range(0, len(value), 4096):
                cost += len(json.dumps(value[index:index + 4096],
                    ensure_ascii=False)[1:-1].encode('utf-8'))
                if self.raw_bytes + cost > self.RAW_BYTES - self.BYTE_RESERVE:
                    self.fail()
        elif value is None or type(value) in (bool, int, float):
            cost = len(json.dumps(value, allow_nan=False).encode('utf-8'))
        else:
            cost = 2
        if self.raw_bytes + cost > self.RAW_BYTES - self.BYTE_RESERVE:
            self.fail()
        self.raw_bytes += cost

    def keep(self, value):
        stack = [value]
        while stack:
            item = stack.pop()
            self.node(item)
            if isinstance(item, dict):
                for key, child in item.items():
                    self.node(key)
                    stack.append(child)
            elif isinstance(item, list):
                stack.extend(item)

    def checkpoint(self):
        return self.reads, self.nodes, self.raw_bytes, self.exhausted

    def restore(self, checkpoint):
        self.reads, self.nodes, self.raw_bytes, self.exhausted = checkpoint


def native_value(value, hint=None, depth=0, budget=None):
    if budget is not None:
        budget.node(value)
        if type(value) is budget.interface_type:
            raise ValueError('unsupported_native_value')
    if depth > 16:
        raise ValueError('native_value_depth')
    if value is None or type(value) in (bool, int, str):
        return value
    if type(value) is float and math.isfinite(value):
        return value
    if isinstance(value, (list, tuple)):
        if len(value) > 4096:
            raise ValueError('native_sequence_budget')
        return [native_value(item, depth=depth + 1, budget=budget) for item in value]
    native_type = getattr(value, 'typeName', None)
    if isinstance(native_type, str) and hasattr(value, 'value'):
        return {'enumType': native_type,
            'value': native_value(value.value, native_type, depth + 1, budget)}
    fields = STRUCT_FIELDS.get(hint) or STRUCT_FIELDS.get(native_type)
    if fields is not None:
        return {'structType': native_type or hint,
            'fields': {name: native_value(getattr(value, name), depth=depth + 1, budget=budget)
                for name in fields}}
    raise ValueError('unsupported_native_value')


def has_unknown(value):
    if isinstance(value, dict):
        return value.get('unknown') is True or any(has_unknown(item) for item in value.values())
    if isinstance(value, list):
        return any(has_unknown(item) for item in value)
    return False


def has_budget_marker(value):
    if isinstance(value, dict):
        return value.get('error') == 'read_budget_exhausted' or any(
            has_budget_marker(item) for item in value.values())
    if isinstance(value, list):
        return any(has_budget_marker(item) for item in value)
    return False


def raw_property(target, name, *, allow_state_less=False, budget=None):
    budget = budget or DocBudget()
    try:
        budget.read()
        info = target.getPropertySetInfo()
        if not info.hasPropertyByName(name):
            return {'present': False}
        budget.read()
        descriptor = info.getPropertyByName(name)
        native_type, attributes = descriptor.Type.typeName, descriptor.Attributes
        if not isinstance(native_type, str) or type(attributes) is not int:
            raise ValueError('property_descriptor_unavailable')
        result = {'present': True, 'nativeType': native_type, 'attributes': attributes}
    except ReadBudgetExceeded:
        return unknown('read_budget_exhausted')
    except Exception:
        return unknown('property_presence_unavailable')
    readable_state = False
    try:
        state_getter = getattr(target, 'getPropertyState')
    except AttributeError:
        result['stateUnsupported'] = unknown('property_state_unsupported')
        readable_state = allow_state_less and name in ('Height', 'Width')
    except Exception:
        result['stateUnknown'] = unknown('property_state_unavailable')
    else:
        try:
            budget.read()
            if not callable(state_getter):
                raise ValueError('property_state_unavailable')
            state = state_getter(name)
            result['state'] = native_value(state, budget=budget)
            readable_state = (getattr(state, 'typeName', None) == 'com.sun.star.beans.PropertyState' and
                getattr(state, 'value', None) in ('DIRECT_VALUE', 'DEFAULT_VALUE'))
        except ReadBudgetExceeded:
            result['value'] = unknown('read_budget_exhausted')
            return result
        except Exception:
            result['stateUnknown'] = unknown('property_state_unavailable')
    if not readable_state:
        result['value'] = unknown('property_value_state_unavailable')
        return result
    try:
        budget.read()
        result['value'] = native_value(target.getPropertyValue(name), budget=budget)
    except ReadBudgetExceeded:
        result['value'] = unknown('read_budget_exhausted')
    except Exception:
        result['value'] = unknown('property_value_unavailable')
    return result


def raw_properties(target, expected, excluded=(), *, state_less=(), budget=None):
    budget = budget or DocBudget()
    result, seen = {}, set(excluded)

    def retain(name):
        if name in seen:
            return
        seen.add(name)
        raw = raw_property(target, name, allow_state_less=name in state_less, budget=budget)
        try:
            budget.keep({name: raw})
        except ReadBudgetExceeded:
            if raw.get('present') is True:
                raw['value'] = unknown('read_budget_exhausted')
            else:
                raw = unknown('read_budget_exhausted')
        result[name] = raw

    try:
        for name in sorted(set(expected) - seen):
            if budget.exhausted:
                break
            retain(name)
        if not budget.exhausted:
            budget.read()
            descriptors = iter(target.getPropertySetInfo().getProperties())
            while True:
                budget.read()
                try:
                    descriptor = next(descriptors)
                except StopIteration:
                    break
                if not isinstance(descriptor.Name, str):
                    raise ValueError('property_name_unavailable')
                retain(descriptor.Name)
                if budget.exhausted:
                    break
    except ReadBudgetExceeded:
        pass
    except Exception:
        result['_inventory'] = unknown('property_inventory_unavailable')
    if budget.exhausted:
        result['_budget'] = unknown('read_budget_exhausted')
    return result


def bounded_string(text, target, limit, budget):
    if type(limit) is not int or not 0 <= limit <= 32768:
        return None, False

    def attempt(count):
        budget.read()
        cursor = text.createTextCursorByRange(target.Start)
        remaining = count
        while remaining:
            step = min(remaining, 32767)
            budget.read()
            if not cursor.goRight(step, True):
                return False, cursor
            remaining -= step
        return True, cursor

    low, high = 0, limit
    _, best = attempt(0)
    while low < high:
        middle = (low + high + 1) // 2
        ok, cursor = attempt(middle)
        if ok:
            low, best = middle, cursor
        else:
            high = middle - 1
    budget.read()
    relation = text.compareRegionEnds(best, target.End)
    if relation == -1:
        best.gotoRange(target.End, True)
        budget.read()
        relation = text.compareRegionEnds(best, target.End)
    if relation != 0:
        return None, False
    budget.read()
    content = best.String
    if not isinstance(content, str) or office_text.utf16_length(content) > limit:
        return None, False
    budget.keep(content)
    return content, True


def style_from_raw(raw):
    def value(name):
        item = raw.get(name, {})
        return item.get('value') if item.get('present') is True else None
    size, weight, color = value('CharHeight'), value('CharWeight'), value('CharColor')
    posture, underline, family = value('CharPosture'), value('CharUnderline'), value('CharFontName')
    member = posture.get('value') if isinstance(posture, dict) else None
    return {'fontSize': float(size) if type(size) in (int, float) and size > 0 else None,
        'bold': weight >= 150 if type(weight) in (int, float) else None,
        'italic': member in ('ITALIC', 'OBLIQUE') if isinstance(member, str) else None,
        'underline': underline != 0 if type(underline) is int else None,
        'color': color if type(color) is int and color >= 0 else None,
        'fontFamily': family if isinstance(family, str) and family else None}


def cell_text(cell, budget):
    raw, runs, protected, pieces = [], [], [], []
    text, truncated, mapped, offset, portions = None, False, True, 0, 0
    try:
        text_container = cell.Text
        text, complete = bounded_string(text_container, text_container, 32768, budget)
        if not complete:
            return None, None, unknown('read_budget_exhausted'), True
        budget.node(raw)
        budget.read()
        paragraphs = text_container.createEnumeration()
        paragraph_count = 0
        while True:
            budget.read()
            if not paragraphs.hasMoreElements():
                break
            if paragraph_count == 128:
                truncated = True
                break
            budget.read()
            paragraph = paragraphs.nextElement()
            if paragraph_count:
                pieces.append('\n')
                offset += 1
            paragraph_count += 1
            if offset > 32768:
                truncated = True
                break
            paragraph_raw = raw_properties(paragraph, TEXT_PROPERTIES, budget=budget)
            portion_raw = []
            budget.node({})
            budget.node('rawStyle')
            budget.node('portions')
            budget.node(portion_raw)
            raw.append({'rawStyle': paragraph_raw, 'portions': portion_raw})
            if budget.exhausted:
                truncated = True
                break
            budget.read()
            enumeration = paragraph.createEnumeration()
            while True:
                budget.read()
                if not enumeration.hasMoreElements():
                    break
                if portions == 256:
                    truncated = True
                    break
                budget.read()
                portion = enumeration.nextElement()
                portions += 1
                piece, complete = bounded_string(text_container, portion, 32768 - offset, budget)
                if not complete:
                    truncated = True
                    break
                formatting = raw_properties(portion, TEXT_PROPERTIES, budget=budget)
                budget.node({})
                budget.node('text')
                budget.node('rawStyle')
                portion_raw.append({'text': piece, 'rawStyle': formatting})
                end = offset + office_text.utf16_length(piece)
                interval = {'startUtf16': offset, 'endUtf16': end}
                kind = formatting.get('TextPortionType', {}).get('value')
                if kind == 'Text':
                    runs.append({**interval, **style_from_raw(formatting)})
                else:
                    protected.append({**interval, 'type': kind if isinstance(kind, str) else 'Unknown'})
                pieces.append(piece)
                offset = end
                if budget.exhausted:
                    truncated = True
                    break
            if truncated:
                break
        mapped = ''.join(pieces) == text
    except ReadBudgetExceeded:
        truncated = True
    except Exception:
        return text, None, unknown('text_inventory_unavailable'), False
    if text is None:
        return None, None, unknown('read_budget_exhausted'), True
    if not mapped:
        protected = [{'startUtf16': 0, 'endUtf16': office_text.utf16_length(text),
            'type': 'Unobserved' if truncated else 'Unmapped'}]
    details = {'utf16Length': office_text.utf16_length(text),
        'textSha256': office_text.text_hash(text), 'runs': runs,
        'protectedRanges': protected, 'truncated': truncated,
        'canReplace': mapped and not truncated, 'canStyle': mapped and not truncated}
    try:
        budget.keep(details)
    except ReadBudgetExceeded:
        truncated, details['truncated'] = True, True
        details['canReplace'], details['canStyle'] = False, False
    if truncated:
        return text, details, {'observed': raw, '_budget': unknown('read_budget_exhausted')}, True
    if not mapped:
        return text, details, {'observed': raw, '_mapping': unknown('text_mapping_unavailable')}, False
    return text, details, raw, False


def positive_count(collection):
    count = collection.Count
    if type(count) is not int or count <= 0:
        raise CatalogUnavailable('model_unavailable')
    return count


def native_bounds(shape):
    values = (shape.Position.X, shape.Position.Y, shape.Size.Width, shape.Size.Height)
    if any(type(value) is not int for value in values) or any(value <= 0 for value in values[2:]):
        raise CatalogUnavailable('raw_state_unavailable')
    return dict(zip(('x', 'y', 'width', 'height'), values))


def actual_tables(presentation, owner_id):
    result = []
    try:
        for identifier, shape in presentation.shape_items(owner_id):
            if shape.getShapeType() == TABLE_TYPE:
                result.append((identifier, shape))
    except Exception as error:
        raise CatalogUnavailable('model_unavailable') from error
    return result


def matches_source_cell_topology(row_span, column_span, covered, source):
    if (type(row_span) is not int or type(column_span) is not int or
            type(covered) is not bool or covered != source['covered']):
        return False
    # Impress may report 1×1 for covered cells. The anchor's span defines the region.
    spans = row_span, column_span
    return spans == (source['rowSpan'], source['columnSpan']) or (covered and spans == (1, 1))


def partition(cells, rows, columns, complete):
    anchors, assignments = {}, {}
    for item in cells:
        row, column = item['row'], item['column']
        if not item['covered']:
            if row + item['rowSpan'] > rows or column + item['columnSpan'] > columns:
                raise CatalogUnavailable('topology_unavailable')
            anchors[(row, column)] = item
            if complete:
                for y in range(row, row + item['rowSpan']):
                    for x in range(column, column + item['columnSpan']):
                        coordinate = (y, x)
                        if coordinate in assignments:
                            raise CatalogUnavailable('topology_unavailable')
                        assignments[coordinate] = item['id']
    for item in cells:
        coordinate = (item['row'], item['column'])
        if complete:
            anchor = assignments.get(coordinate)
        else:
            matches = [candidate['id'] for candidate in anchors.values()
                if candidate['row'] <= item['row'] < candidate['row'] + candidate['rowSpan'] and
                candidate['column'] <= item['column'] < candidate['column'] + candidate['columnSpan']]
            if len(matches) > 1:
                raise CatalogUnavailable('topology_unavailable')
            anchor = matches[0] if matches else None
        if item['covered']:
            if complete and (anchor is None or anchor == item['id']):
                raise CatalogUnavailable('topology_unavailable')
            item['anchorCellId'] = anchor
        elif anchor != item['id']:
            raise CatalogUnavailable('topology_unavailable')
    if complete and len(assignments) != rows * columns:
        raise CatalogUnavailable('topology_unavailable')


def capture_table(identifier, owner_id, shape, budget):
    if budget.interface_type is None:
        budget.interface_type = type(shape)
    elif budget.interface_type is not type(shape):
        raise CatalogUnavailable('model_unavailable')
    try:
        budget.core_read()
        model = shape.getPropertyValue('Model')
        if model is None:
            raise CatalogUnavailable('model_unavailable')
        budget.core_read()
        rows = model.getRows()
        budget.core_read()
        columns = model.getColumns()
        budget.core_read()
        row_count = positive_count(rows)
        budget.core_read()
        column_count = positive_count(columns)
        row_refs, column_refs = [], []
        for index in range(min(row_count, CELL_LIMIT)):
            budget.core_read()
            row_refs.append(rows.getByIndex(index))
        for index in range(min(column_count, CELL_LIMIT)):
            budget.core_read()
            column_refs.append(columns.getByIndex(index))
    except Exception as error:
        raise CatalogUnavailable('model_unavailable') from error
    row_raw = [raw_properties(value, ('Height',), state_less=('Height',), budget=budget)
        for value in row_refs]
    column_raw = [raw_properties(value, ('Width',), state_less=('Width',), budget=budget)
        for value in column_refs]

    def dimension(raw, name):
        value = raw.get(name, {}).get('value')
        return value if type(value) is int and value >= 0 else None

    raw = raw_properties(shape, SHAPE_PROPERTIES, ('Model',), budget=budget)
    raw['_rows'], raw['_columns'] = row_raw, column_raw
    cells, cell_refs = [], []
    total, rich_truncated = row_count * column_count, False
    for index in range(min(total, CELL_LIMIT)):
        row, column = divmod(index, column_count)
        try:
            budget.core_read()
            cell = model.getCellByPosition(column, row)
            if cell is None or any(cell == previous for previous in cell_refs):
                raise CatalogUnavailable('topology_unavailable')
            budget.core_read()
            row_span = cell.getRowSpan()
            budget.core_read()
            column_span = cell.getColumnSpan()
            budget.core_read()
            covered = cell.isMerged()
            if (type(row_span) is not int or row_span <= 0 or type(column_span) is not int or
                    column_span <= 0 or type(covered) is not bool):
                raise CatalogUnavailable('topology_unavailable')
        except Exception as error:
            raise CatalogUnavailable('topology_unavailable') from error
        cell_refs.append(cell)
        cell_raw = raw_properties(cell, CELL_PROPERTIES, budget=budget)
        text, details, paragraphs, truncated = cell_text(cell, budget)
        cell_raw['_paragraphs'] = paragraphs
        rich_truncated = rich_truncated or truncated
        cells.append({'id': identifier + '/cell-' + str(index),
            'row': row, 'column': column, 'rowSpan': row_span,
            'columnSpan': column_span, 'covered': covered, 'anchorCellId': None,
            'text': text, 'textDetails': details, 'rawStyle': cell_raw})
    partition(cells, row_count, column_count, total <= CELL_LIMIT)
    result = {'id': identifier, 'ownerId': owner_id, 'tableSha256': None,
        'rowCount': row_count, 'columnCount': column_count, 'totalCellCount': total,
        'rowHeightsHmm': [dimension(value, 'Height') for value in row_raw],
        'columnWidthsHmm': [dimension(value, 'Width') for value in column_raw],
        'cells': cells, 'rawStyle': raw,
        'authoredGeometry': None, 'nativeBoundsHmm': native_bounds(shape),
        'truncated': total > CELL_LIMIT or rich_truncated or has_budget_marker(raw),
        'capabilities': {name: False for name in CAPABILITIES}}
    if not result['truncated'] and not has_unknown(result):
        encoded = json.dumps(result, sort_keys=True, separators=(',', ':'),
            ensure_ascii=False, allow_nan=False).encode('utf-8')
        result['tableSha256'] = hashlib.sha256(encoded).hexdigest()
    binding = {'shape': shape, 'model': model, 'rows': row_refs,
        'columns': column_refs, 'cells': cell_refs}
    return result, binding


def same_references(before, after):
    if before['shape'] != after['shape'] or before['model'] != after['model']:
        return False
    return all(len(before[name]) == len(after[name]) and
        all(left == right for left, right in zip(before[name], after[name]))
        for name in ('rows', 'columns', 'cells'))


def catalog_reason(items):
    if any(has_budget_marker(item) for item in items):
        return 'read_budget_exhausted'
    return 'raw_state_unavailable' if any(has_unknown(item) for item in items) else None


class PresentationTables:
    def __init__(self, presentation, document, source_path):
        self.presentation, self.document = presentation, document
        self.source_path = Path(source_path).resolve(strict=True) if source_path is not None else None
        self.source_sha256 = self._source_digest()
        self.owners, self.bindings, self.counts, self.reasons = {}, {}, {}, {}
        self.owner_refs, self.table_refs, self.attempts, self.checkpoints = {}, {}, {}, {}
        self.order = [*presentation.logical, *presentation.masters]
        self._source_attachment_attempted = False
        self._source_text_state = None
        self._source_geometries, self._source_owner_refs = {}, {}
        self._source_owner_parts = {}
        budget, remaining = DocBudget(), TABLE_LIMIT
        for owner_id in self.order:
            self.owner_refs[owner_id] = presentation.owner(owner_id)
            self.attempts[owner_id] = 0
            try:
                items = actual_tables(presentation, owner_id)
                self.table_refs[owner_id] = list(items)
                self.counts[owner_id] = len(items)
                result, bindings = [], []
                for identifier, shape in items[:remaining]:
                    remaining -= 1
                    self.attempts[owner_id] += 1
                    item, binding = capture_table(identifier, owner_id, shape, budget)
                    result.append(item)
                    bindings.append(binding)
                self.owners[owner_id], self.bindings[owner_id] = result, bindings
                self.reasons[owner_id] = catalog_reason(result)
            except CatalogUnavailable as error:
                self.owners[owner_id], self.bindings[owner_id] = None, None
                self.table_refs.setdefault(owner_id, None)
                self.counts.setdefault(owner_id, None)
                self.reasons[owner_id] = error.reason
            self.checkpoints[owner_id] = budget.checkpoint()

    def _source_digest(self):
        if self.source_path is None:
            return None
        with self.source_path.open('rb') as stream:
            return hashlib.file_digest(stream, 'sha256').hexdigest()

    def _authored_geometry(self, source, table):
        part = source['sourcePart']
        position, extent = source['positionEmu'], source['extentEmu']
        widths, heights = source['columnWidthsEmu'], source['rowHeightsEmu']
        if (type(part) is not str or not part or len(part) > 1024 or
                any(character in part for character in '\\:') or
                any(ord(character) < 32 for character in part) or
                any(segment in ('', '.', '..') for segment in part.split('/')) or
                type(source['shapeId']) is not str or not source['shapeId'] or
                type(position) is not dict or set(position) != {'x', 'y'} or
                any(type(value) is not int for value in position.values()) or
                type(extent) is not dict or set(extent) != {'width', 'height'} or
                any(type(value) is not int or value < 1 for value in extent.values()) or
                type(widths) is not list or type(heights) is not list or
                len(widths) != table['columnCount'] or len(heights) != table['rowCount'] or
                any(type(value) is not int or value < 1 for value in [*widths, *heights])):
            raise ValueError('The authored presentation geometry is outside the supported wire subset')
        return copy.deepcopy({name: source[name] for name in (
            'sourcePart', 'shapeId', 'positionEmu', 'extentEmu',
            'columnWidthsEmu', 'rowHeightsEmu')})

    def _enrich_source(self, table, geometry):
        known = table['tableSha256'] is not None
        table['authoredGeometry'] = copy.deepcopy(geometry)
        table['tableSha256'] = None
        if known:
            encoded = json.dumps(table, sort_keys=True, separators=(',', ':'),
                ensure_ascii=False, allow_nan=False).encode('utf-8')
            table['tableSha256'] = hashlib.sha256(encoded).hexdigest()

    def _live_source_owners(self, expected):
        pages = self.document.DrawPages
        count = pages.Count
        if type(count) is not int or count < len(expected) or count > DocBudget.READ_LIMIT:
            raise ValueError('The live source presentation owner inventory is invalid')
        actual = [pages.getByIndex(index) for index in range(count)]
        if any(sum(owner == page for page in actual) != 1 for owner in expected.values()):
            raise ValueError('An attached source presentation owner is missing or replaced')
        return actual

    def attach_source(self, prepared):
        from office_presentation_binding import PreparedPptxBinding

        if self._source_attachment_attempted:
            raise ValueError('A presentation catalog can attach its source only once')
        self._source_attachment_attempted = True
        if (type(prepared) is not PreparedPptxBinding or not prepared._active or
                not prepared._attempted or self.source_path is None or
                prepared._source.resolve(strict=True) != self.source_path or
                prepared._catalog['sourceSha256'] != self.source_sha256):
            raise ValueError('An active successful binding for this exact source is required')
        baseline = getattr(prepared, '_bound_refs', None)
        reference_names = ('owner_refs', 'table_refs', 'model_refs', 'cell_refs')
        if baseline is None or set(baseline) != set(reference_names):
            raise ValueError('A successful immutable actual-reference binding is required')
        for name in reference_names:
            public, frozen = getattr(prepared, name), baseline[name]
            if (type(public) is not dict or set(public) != set(frozen) or
                    any(public[key] != reference for key, reference in frozen.items())):
                raise ValueError('The public source binding differs from its successful actual refs')
        owner_refs = baseline['owner_refs']
        table_refs = baseline['table_refs']
        model_refs = baseline['model_refs']
        cell_refs = baseline['cell_refs']
        self._revalidate(False)
        source_catalog = prepared._catalog
        parts = set(source_catalog['parts'])
        sources = source_catalog['tables']
        keys = {(source['sourcePart'], source['shapeId']) for source in sources}
        cell_keys = {(*key, cell['row'], cell['column'])
            for source in sources
            for key in [(source['sourcePart'], source['shapeId'])]
            for cell in source['cells']}
        if (len(keys) != len(sources) or
                set(owner_refs) != parts or
                set(table_refs) != keys or set(model_refs) != keys or
                set(cell_refs) != cell_keys or
                len(parts) != len(self.presentation.logical)):
            raise ValueError('The complete prepared source reference coverage is required')
        actual_owners = self._live_source_owners(owner_refs)
        if len(actual_owners) != len(parts):
            raise ValueError('The live document has an unbound source owner')
        source_owners, used_owners = {}, []
        for part in parts:
            owner = owner_refs[part]
            matches = [identifier for identifier in self.presentation.logical
                if self.owner_refs[identifier] == owner]
            if len(matches) != 1 or any(owner == previous for previous in used_owners):
                raise ValueError('A source owner has no unique actual registry reference')
            owner_id = matches[0]
            if (self.owners[owner_id] is None or self.table_refs[owner_id] is None or
                    len(self.owners[owner_id]) != self.counts[owner_id]):
                raise ValueError('The source owner table inventory is incomplete')
            source_owners[part] = owner_id
            used_owners.append(owner)
        expected_count = sum(len(self.owners[owner_id]) for owner_id in source_owners.values())
        if expected_count != len(sources):
            raise ValueError('An actual source table is missing its exact source binding')
        staged = copy.deepcopy(self.owners)
        geometries, used_shapes, used_models, used_cells = {}, [], [], []
        for source in sources:
            key = source['sourcePart'], source['shapeId']
            owner_id = source_owners[source['sourcePart']]
            shape, model = table_refs[key], model_refs[key]
            matches = [(table, binding) for table, binding in
                zip(staged[owner_id], self.bindings[owner_id]) if binding['shape'] == shape]
            if (len(matches) != 1 or any(shape == previous for previous in used_shapes) or
                    any(model == previous for previous in used_models)):
                raise ValueError('A source table or Model is foreign or reused')
            table, binding = matches[0]
            if binding['model'] != model:
                raise ValueError('The source Model differs from the actual registry reference')
            if len(source['cells']) != len(table['cells']):
                raise ValueError('The complete source cell grid is required')
            native_cells = {(cell['row'], cell['column']): (cell, reference)
                for cell, reference in zip(table['cells'], binding['cells'])}
            if len(native_cells) != len(table['cells']):
                raise ValueError('The actual source cell coordinates are duplicated')
            for expected in source['cells']:
                coordinate = expected['row'], expected['column']
                if coordinate not in native_cells:
                    raise ValueError('A source cell is absent from the actual registry')
                cell, reference = native_cells[coordinate]
                anchor = expected['anchor']
                native_anchor = (native_cells[(anchor['row'], anchor['column'])][0]['id']
                    if anchor is not None else None)
                if (cell_refs[(*key, *coordinate)] != reference or
                        any(reference == previous for previous in used_cells) or
                        not matches_source_cell_topology(cell['rowSpan'], cell['columnSpan'],
                            cell['covered'], expected) or
                        cell['anchorCellId'] != native_anchor):
                    raise ValueError('A source cell reference or anchor topology differs')
                used_cells.append(reference)
            geometry = self._authored_geometry(source, table)
            self._enrich_source(table, geometry)
            geometries[table['id']] = geometry
            used_shapes.append(shape)
            used_models.append(model)
        from office_presentation_source_edit import SourcePatchBudget, build_source_state, decorate_source_table

        source_state = build_source_state(self, prepared, staged)
        source_budget = SourcePatchBudget()
        for owner_id in self.order:
            for table in staged[owner_id] or []:
                decorate_source_table(self, table, source_budget, source_state)
        self.owners = staged
        self._source_text_state = source_state
        self._source_geometries = geometries
        self._source_owner_refs = {source_owners[part]: owner_refs[part] for part in parts}
        self._source_owner_parts = {source_owners[part]: part for part in parts}

    def _revalidate(self, require_known):
        if self._source_digest() != self.source_sha256:
            raise ValueError('The inspected presentation source bytes changed')
        if self._source_owner_refs:
            self._live_source_owners(self._source_owner_refs)
        current_owners = [*self.presentation.logical, *self.presentation.masters]
        if any(owner_id not in self.owners for owner_id in current_owners):
            raise ValueError('Unknown presentation table owner')
        budget = DocBudget()
        from office_presentation_source_edit import SourcePatchBudget, decorate_source_table

        source_budget = SourcePatchBudget()
        for owner_id in self.order:
            if owner_id not in current_owners:
                budget.restore(self.checkpoints[owner_id])
                continue
            if self.presentation.owner(owner_id) != self.owner_refs[owner_id]:
                raise ValueError('An actual presentation table owner was replaced')
            items = actual_tables(self.presentation, owner_id)
            references = self.table_refs[owner_id]
            if references is None:
                if require_known:
                    raise ValueError('The source presentation table catalog is unknown')
                budget.restore(self.checkpoints[owner_id])
                continue
            if len(items) != len(references) or any(identifier != previous_id or shape != previous
                    for (identifier, shape), (previous_id, previous) in zip(items, references)):
                raise ValueError('The source presentation table inventory changed')
            expected = self.owners[owner_id]
            if expected is None:
                if require_known:
                    raise ValueError('The source presentation table catalog is unknown')
                budget.restore(self.checkpoints[owner_id])
                continue
            if require_known and (self.reasons[owner_id] is not None or
                    len(expected) != len(items) or any(item['truncated'] for item in expected)):
                raise ValueError('The complete source presentation table state is unknown')
            for (identifier, shape), previous, binding in zip(
                    items[:self.attempts[owner_id]], expected, self.bindings[owner_id]):
                current, current_binding = capture_table(identifier, owner_id, shape, budget)
                if identifier in self._source_geometries:
                    self._enrich_source(current, self._source_geometries[identifier])
                if self._source_text_state is not None:
                    decorate_source_table(self, current, source_budget, self._source_text_state)
                if not same_references(binding, current_binding) or current != previous:
                    raise ValueError('An actual presentation table reference or raw state changed')
            if budget.checkpoint() != self.checkpoints[owner_id]:
                raise ValueError('The presentation table observation plan changed')

    def snapshot_all(self):
        self._revalidate(False)
        return {owner_id: copy.deepcopy(self.owners[owner_id])
            for owner_id in [*self.presentation.logical, *self.presentation.masters]}

    def snapshot(self, owner_id):
        if owner_id not in self.owners:
            raise ValueError('Unknown presentation table owner')
        return self.snapshot_all()[owner_id]

    def register_empty_owner(self, owner_id, owner):
        if (not isinstance(owner_id, str) or owner_id in self.owners or
                owner_id in self.presentation.used or self.presentation.slides.get(owner_id) != owner or
                self.presentation.physical.count(owner_id) != 1 or self.presentation.logical.count(owner_id) != 1 or
                any(owner == previous for previous in self.owner_refs.values())):
            raise ValueError('Only a newly created presentation slide may register an empty table catalog')
        pages = self.document.DrawPages
        if (owner.Count != 0 or
                sum(owner == pages.getByIndex(index) for index in range(pages.Count)) != 1):
            raise ValueError('A new slide must be an actual empty document owner')
        self.owners[owner_id], self.bindings[owner_id] = [], []
        self.counts[owner_id], self.reasons[owner_id] = 0, None
        self.owner_refs[owner_id], self.table_refs[owner_id], self.attempts[owner_id] = owner, [], 0
        self.checkpoints[owner_id] = self.checkpoints[self.order[-1]] if self.order else DocBudget().checkpoint()
        self.order.append(owner_id)

    def metadata(self, owner_id):
        if owner_id not in self.owners:
            raise ValueError('Unknown presentation table owner')
        items, count = self.owners[owner_id], self.counts[owner_id]
        result = {'presentationTableCount': count,
            'presentationTablesTruncated': items is not None and len(items) < count,
            'presentationTablesUnknownReason': self.reasons[owner_id],
            'canAddTable': False}
        if self._source_text_state is not None and owner_id in self._source_owner_parts:
            from office_presentation_structure_edit import source_authority

            authority = source_authority(self, owner_id)
            if authority is not None:
                result['sourceStructureAuthority'] = authority
        return result

    def assert_fresh(self):
        self._revalidate(True)

    def apply(self, operation):
        raise ValueError('Presentation table mutations have not passed their native write gates')

    def verification_state(self):
        self.assert_fresh()
        return {'sourceSha256': self.source_sha256, 'owners': copy.deepcopy(self.owners)}

    def verify_reopened(self, expected):
        self.assert_fresh()
        if (not isinstance(expected, dict) or set(expected) != {'sourceSha256', 'owners'} or
                not isinstance(expected['owners'], dict) or any(expected['owners'].values()) or
                any(self.owners.values()) or expected['owners'] != self.owners):
            raise ValueError('Presentation table reopen binding has not passed its native write gate')
