"""Private PPTX source-to-actual refs; no document escapes with auxiliary shapes."""
from contextlib import contextmanager
import copy
import os
from pathlib import Path
import re
import tempfile
from types import MappingProxyType
import uuid
import zipfile

import office_presentation_source as source_reader
import office_presentation_tables as tables


P = 'http://schemas.openxmlformats.org/presentationml/2006/main'
A = 'http://schemas.openxmlformats.org/drawingml/2006/main'
TABLE_TYPE = 'com.sun.star.drawing.TableShape'
CONNECTOR_TYPE = 'com.sun.star.drawing.ConnectorShape'
CHUNK_BYTES = 1024 * 1024
MAX_COPY_BYTES = 128 * 1024 * 1024


def _require(condition, message):
    if not condition:
        raise ValueError(message)


def _auxiliary_shape(identifier, token, target=None):
    namespaces = 'xmlns:pivp="' + P + '" xmlns:piva="' + A + '"'
    identity = '<pivp:cNvPr id="' + str(identifier) + '" name="' + token + '" hidden="1"/>'
    geometry = ('<pivp:spPr><piva:xfrm><piva:off x="0" y="0"/><piva:ext cx="360" cy="360"/>'
        '</piva:xfrm><piva:prstGeom prst="' + ('rect' if target is None else 'line') +
        '"><piva:avLst/></piva:prstGeom></pivp:spPr>')
    if target is None:
        xml = ('<pivp:sp ' + namespaces + '><pivp:nvSpPr>' + identity +
            '<pivp:cNvSpPr/><pivp:nvPr/></pivp:nvSpPr>' + geometry + '</pivp:sp>')
    else:
        xml = ('<pivp:cxnSp ' + namespaces + '><pivp:nvCxnSpPr>' + identity +
            '<pivp:cNvCxnSpPr><piva:stCxn id="' + target + '" idx="0"/></pivp:cNvCxnSpPr>'
            '<pivp:nvPr/></pivp:nvCxnSpPr>' + geometry + '</pivp:cxnSp>')
    return xml.encode('ascii')


def _tagged_parts(catalog):
    _require(len(catalog['tables']) <= tables.TABLE_LIMIT, 'The source binding table budget is exceeded')
    roots, names = {}, set()
    for part, data in catalog['parts'].items():
        root = source_reader._xml(data, {'nodes': 0})
        roots[part] = root
        names.update(item.attributes.get('name') for item in source_reader._walk(root)
            if item.name == P + '|cNvPr')
    issued, result, counts = {}, {}, {}
    for part, root in roots.items():
        data = catalog['parts'][part]
        tree = source_reader._one(source_reader._one(root, P + '|cSld'), P + '|spTree')
        original_shapes = [item for item in tree.children if item.name not in (P + '|nvGrpSpPr', P + '|grpSpPr')]
        allowed = {P + '|' + name for name in ('sp', 'grpSp', 'graphicFrame', 'cxnSp', 'pic')}
        _require(all(item.name in allowed for item in original_shapes), 'Unsupported source shape-tree child')
        counts[part] = len(original_shapes)
        next_id = max(source_reader._identity(item.attributes.get('id'))
            for item in source_reader._walk(root) if item.name == P + '|cNvPr') + 1
        source_tables = [item for item in catalog['tables'] if item['sourcePart'] == part]
        for table in source_tables:
            _require(len(table['rowHeightsEmu']) * len(table['columnWidthsEmu']) <= tables.CELL_LIMIT,
                'The source binding cell budget is exceeded')
        additions = []
        for table in [None, *source_tables]:
            _require(next_id <= 0xFFFFFFFF, 'An auxiliary shape ID exceeds the source identity range')
            while True:
                token = 'piv-binding-' + uuid.uuid4().hex
                if token not in names and token not in issued:
                    break
            target = None if table is None else table['shapeId']
            issued[token] = {'sourcePart': part, 'shapeId': target}
            additions.append(_auxiliary_shape(next_id, token, target))
            next_id += 1
        _require(not tree.empty, 'The source shape tree has no exact insertion boundary')
        position = data.rfind(b'</', tree.tag_end, tree.end)
        _require(position >= tree.tag_end and source_reader._tag_end(data, position) == tree.end,
            'The source shape-tree closing span is not exact')
        changed = data[:position] + b''.join(additions) + data[position:]
        _require(len(changed) <= source_reader.PART_BYTES, 'Tagged source XML part budget exceeded')
        result[part] = changed
    _require(sum(map(len, result.values())) <= source_reader.TOTAL_XML_BYTES,
        'Tagged source slide XML total budget exceeded')
    return result, issued, counts


def _copy_archive(archive, destination, changed):
    information_list = archive.infolist()
    total = 0
    for information in information_list:
        size = len(changed[information.filename]) if information.filename in changed else information.file_size
        _require(type(size) is int and 0 <= size <= MAX_COPY_BYTES, 'Private ZIP member expanded-copy budget exceeded')
        total += size
        _require(total <= MAX_COPY_BYTES, 'Private ZIP aggregate expanded-copy budget exceeded')
    metadata_parts = ('[Content_Types].xml', '_rels/.rels', 'ppt/presentation.xml', 'ppt/_rels/presentation.xml.rels')
    _require(sum(map(len, changed.values())) + sum(archive.getinfo(name).file_size for name in metadata_parts)
        <= source_reader.TOTAL_XML_BYTES, 'Tagged referenced XML total budget exceeded')
    with zipfile.ZipFile(destination, 'w') as output:
        output.comment = archive.comment
        for information in information_list:
            copied = copy.copy(information)
            if information.filename in changed:
                output.writestr(copied, changed[information.filename])
                continue
            with archive.open(information, 'r') as original, output.open(copied, 'w') as target:
                remaining = information.file_size
                while remaining:
                    data = original.read(min(remaining, CHUNK_BYTES))
                    _require(data and len(data) <= remaining, 'The source member length changed while copying')
                    _require(target.write(data) == len(data), 'The private member copy is incomplete')
                    remaining -= len(data)
                _require(not original.read(1), 'The source member exceeds its declared length')


def _verify_file(path, stamp, expected_hash):
    with path.open('rb', buffering=0) as stream:
        _require(source_reader._stamp(os.fstat(stream.fileno())) == stamp and
            source_reader._stamp(path.stat()) == stamp, 'The bound file identity changed')
        _require(source_reader._digest(stream, stamp[2]) == expected_hash and
            source_reader._stamp(os.fstat(stream.fileno())) == stamp and
            source_reader._stamp(path.stat()) == stamp, 'The bound file bytes changed')



class _WindowsReadLease:
    def __init__(self, path):
        import ctypes
        from ctypes import wintypes

        self._ctypes = ctypes
        self._kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        self._kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
            ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
        self._kernel.CreateFileW.restype = wintypes.HANDLE
        self._kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        self._kernel.CloseHandle.restype = wintypes.BOOL
        self._handle = self._kernel.CreateFileW(str(path), 0x80000000, 0x00000001, None, 3, 0x80, None)
        if self._handle in (None, ctypes.c_void_p(-1).value):
            self._handle = None
            raise ctypes.WinError(ctypes.get_last_error())

    def close(self):
        if self._handle is not None:
            if not self._kernel.CloseHandle(self._handle):
                raise self._ctypes.WinError(self._ctypes.get_last_error())
            self._handle = None


class PreparedPptxBinding:
    def __init__(self, source, stamp, catalog, tagged, tagged_stamp, tagged_hash, issued, counts):
        self._catalog = catalog
        self.source_catalog = copy.deepcopy(catalog)
        self.owner_refs, self.table_refs, self.model_refs, self.cell_refs = {}, {}, {}, {}
        self._bound_refs = None
        self._source, self._stamp, self._tagged = source, stamp, tagged
        self._tagged_stamp, self._tagged_hash = tagged_stamp, tagged_hash
        self._issued, self._counts = issued, counts
        self._attempted, self._active = False, True
        self._budget = tables.DocBudget()

    def _read(self, getter):
        self._budget.core_read()
        return getter()

    def _items(self, collection, limit, *, exact=None):
        count = self._read(lambda: collection.Count)
        _require(type(count) is int and 0 <= count <= limit and (exact is None or count == exact),
            'The actual collection count differs from the source')
        return [self._read(lambda index=index: collection.getByIndex(index)) for index in range(count)]

    def _metadata(self, shape):
        if self._budget.interface_type is None:
            self._budget.interface_type = type(shape)
        _require(type(shape) is self._budget.interface_type, 'The actual table interface type changed')
        result = {name: tables.raw_property(shape, name, budget=self._budget) for name in ('Name', 'Description')}
        _require(not tables.has_unknown(result), 'Original table metadata state is unknown')
        return result

    def _model_cells(self, shape, source):
        model = self._read(lambda: shape.getPropertyValue('Model'))
        _require(model is not None, 'An actual table Model is missing')
        rows = self._read(lambda: model.getRows().getCount())
        columns = self._read(lambda: model.getColumns().getCount())
        _require(type(rows) is int and type(columns) is int and
            (rows, columns) == (len(source['rowHeightsEmu']), len(source['columnWidthsEmu'])),
            'The actual table grid differs from the source')
        cells = {}
        for expected in source['cells']:
            key = expected['row'], expected['column']
            cell = self._read(lambda key=key: model.getCellByPosition(key[1], key[0]))
            _require(cell is not None and all(cell != previous for previous in cells.values()),
                'An actual cell ref is missing or reused')
            row_span = self._read(cell.getRowSpan)
            column_span = self._read(cell.getColumnSpan)
            covered = self._read(cell.isMerged)
            _require(tables.matches_source_cell_topology(row_span, column_span, covered, expected),
                'Actual anchor/covered topology differs from the source')
            cells[key] = cell
        return model, cells

    def _bind_and_clean(self, document):
        owners, bound, models, cells, metadata = {}, {}, {}, {}, {}
        owner_count = len(self._catalog['parts'])
        pages = self._items(document.DrawPages, owner_count, exact=owner_count)
        maximum = sum(self._counts.values()) + len(self._issued)
        inventories = [(page, self._items(page, maximum)) for page in pages]
        found = {}
        for page, shapes in inventories:
            for shape in shapes:
                name = self._read(shape.getName)
                if name in self._issued:
                    _require(name not in found, 'An exact issued token is duplicated')
                    found[name] = page, shape
        _require(set(found) == set(self._issued), 'An exact issued token is missing')
        for token, record in self._issued.items():
            if record['shapeId'] is None:
                page = found[token][0]
                _require(all(page != previous for previous in owners.values()), 'An actual owner ref is reused')
                owners[record['sourcePart']] = page
        _require(set(owners) == set(self._catalog['parts']), 'The exact owner binding is incomplete')
        original_shapes = {}
        for part, page in owners.items():
            shapes = next(shapes for actual_page, shapes in inventories if actual_page == page)
            original_shapes[part] = [shape for shape in shapes
                if self._read(shape.getName) not in self._issued]
            _require(len(original_shapes[part]) == self._counts[part], 'The actual original shape count differs')
        original_metadata = {part: [self._metadata(shape) for shape in shapes]
            for part, shapes in original_shapes.items()}
        for token, record in self._issued.items():
            page, marker = found[token]
            _require(page == owners[record['sourcePart']], 'An issued marker belongs to a foreign owner')
            if record['shapeId'] is None:
                continue
            _require(self._read(marker.getShapeType) == CONNECTOR_TYPE, 'An issued connector has another actual type')
            actual = self._read(lambda: marker.getPropertyValue('StartShape'))
            _require(actual is not None and self._read(actual.getShapeType) == TABLE_TYPE,
                'StartShape is not an actual table')
            originals = original_shapes[record['sourcePart']]
            _require(sum(shape == actual for shape in originals) == 1 and
                all(actual != previous for previous in bound.values()), 'StartShape is foreign or reused')
            key = record['sourcePart'], record['shapeId']
            source = next(item for item in self._catalog['tables']
                if (item['sourcePart'], item['shapeId']) == key)
            model, actual_cells = self._model_cells(actual, source)
            _require(all(model != previous for previous in models.values()), 'An actual Model ref is reused')
            for coordinate, cell in actual_cells.items():
                _require(all(cell != previous for previous in cells.values()), 'An actual cell ref is reused across tables')
                cells[(*key, *coordinate)] = cell
            bound[key], models[key], metadata[key] = actual, model, self._metadata(actual)
        _require(len(bound) == len(self._catalog['tables']), 'The exact table binding is incomplete')
        for part, originals in original_shapes.items():
            actual_tables = [shape for shape in originals if self._read(shape.getShapeType) == TABLE_TYPE]
            _require(len(actual_tables) == sum(key[0] == part for key in bound), 'An actual table has no source binding')
        for connector in (True, False):
            for token, record in self._issued.items():
                if (record['shapeId'] is not None) == connector:
                    page, marker = found[token]
                    self._read(lambda: page.remove(marker))
        current_pages = self._items(document.DrawPages, owner_count, exact=owner_count)
        _require(all(current == previous for current, previous in zip(current_pages, pages)),
            'An actual owner ref or owner order changed during auxiliary removal')
        for part, page in owners.items():
            shapes = self._items(page, self._counts[part], exact=self._counts[part])
            _require(all(current == previous for current, previous in zip(shapes, original_shapes[part])),
                'An original actual shape ref or order changed during auxiliary removal')
            _require(all(self._read(shape.getName) not in self._issued for shape in shapes),
                'An issued auxiliary shape remains')
            _require([self._metadata(shape) for shape in shapes] == original_metadata[part],
                'Original shape Name/Description state changed during auxiliary removal')
        for source in self._catalog['tables']:
            key = source['sourcePart'], source['shapeId']
            model, actual_cells = self._model_cells(bound[key], source)
            _require(model == models[key] and all(cell == cells[(*key, *coordinate)]
                for coordinate, cell in actual_cells.items()), 'An actual Model or cell ref changed during auxiliary removal')
            _require(self._metadata(bound[key]) == metadata[key], 'Original Name/Description state changed')
        return owners, bound, models, cells

    def load(self, loader):
        _require(self._active and not self._attempted, 'A prepared binding can load exactly once inside its context')
        self._attempted = True
        document = None
        try:
            _verify_file(self._source, self._stamp, self._catalog['sourceSha256'])
            _verify_file(self._tagged, self._tagged_stamp, self._tagged_hash)
            document = loader(self._tagged)
            _require(document is not None, 'The private tagged document did not load')
            owners, bound, models, cells = self._bind_and_clean(document)
            _verify_file(self._source, self._stamp, self._catalog['sourceSha256'])
            _verify_file(self._tagged, self._tagged_stamp, self._tagged_hash)
            self._bound_refs = MappingProxyType({name: MappingProxyType(dict(refs)) for name, refs in (
                ('owner_refs', owners), ('table_refs', bound), ('model_refs', models), ('cell_refs', cells))})
        except BaseException as error:
            if document is not None:
                try:
                    document.close(True)
                except BaseException as close_error:
                    error.add_note('Owned binding document close failed: ' + type(close_error).__name__)
            raise
        self.owner_refs, self.table_refs, self.model_refs, self.cell_refs = owners, bound, models, cells
        return document


@contextmanager
def prepare_pptx_binding(source, directory, expected_sha256):
    """Yield one private binding; caller closes a successful document before exit."""
    _require(isinstance(expected_sha256, str) and re.fullmatch(r'[0-9a-f]{64}', expected_sha256) is not None,
        'An exact source SHA-256 is required')
    _require(os.name == 'nt', 'Native PPTX binding requires a Windows read lease')
    source, directory = Path(source), Path(directory)
    stamp = source_reader._stamp(source.stat())
    tagged, owned_identity, prepared, body_error, lease = None, None, None, None, None
    with source_reader.open_pptx_tables(source) as image:
        _require(image.catalog['sourceSha256'] == expected_sha256, 'The expected source hash does not match')
        try:
            changed, issued, counts = _tagged_parts(image.catalog)
            descriptor, name = tempfile.mkstemp(prefix='piv-binding-', suffix='.pptx', dir=directory)
            tagged = Path(name)
            with os.fdopen(descriptor, 'w+b') as destination:
                owned_identity = source_reader._stamp(os.fstat(destination.fileno()))[:2]
                _copy_archive(image.archive, destination, changed)
                destination.flush()
                tagged_stamp = source_reader._stamp(os.fstat(destination.fileno()))
                tagged_hash = source_reader._digest(destination, tagged_stamp[2])
            lease = _WindowsReadLease(tagged)
            _verify_file(tagged, tagged_stamp, tagged_hash)
            prepared = PreparedPptxBinding(source, stamp, image.catalog, tagged, tagged_stamp, tagged_hash, issued, counts)
            _verify_file(source, stamp, expected_sha256)
            yield prepared
        except BaseException as error:
            body_error = error
            raise
        finally:
            if prepared is not None:
                prepared._active = False
            cleanup_error = None
            try:
                _verify_file(source, stamp, expected_sha256)
                if lease is not None:
                    _verify_file(tagged, tagged_stamp, tagged_hash)
            except Exception as error:
                cleanup_error = error
            try:
                if lease is not None:
                    lease.close()
            except Exception as error:
                if cleanup_error is None:
                    cleanup_error = error
                else:
                    cleanup_error.add_note('Owned tagged read-lease close also failed: ' + type(error).__name__)
            try:
                if tagged is not None:
                    _require(source_reader._stamp(tagged.stat())[:2] == owned_identity,
                        'The owned tagged file was replaced; preserve the foreign file')
                    tagged.unlink()
            except Exception as error:
                if cleanup_error is None:
                    cleanup_error = error
                else:
                    cleanup_error.add_note('Owned tagged file cleanup also failed: ' + type(error).__name__)
            if cleanup_error is not None:
                if body_error is None:
                    raise cleanup_error
                body_error.add_note('Binding final verification/cleanup failed: ' + type(cleanup_error).__name__)
