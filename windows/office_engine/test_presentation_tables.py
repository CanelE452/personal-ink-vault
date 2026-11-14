"""Source-bound PPT table catalog contracts, separate from native round trips.

The doubles below model observed UNO interfaces, not a second table catalog.
Native source evidence remains under build/validation/office-presentation-tables.
"""
import builtins
import copy
import hashlib
import importlib
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import zipfile

import office_presentation
import office_worker as worker


CAPABILITIES = (
    'canEditText', 'canEditTextStyle', 'canEditAppearance',
    'canInsertRows', 'canDeleteRows', 'canInsertColumns',
    'canDeleteColumns', 'canMerge', 'canSplit', 'canDeleteTable',
)
SOURCE_SHA = 'a' * 64
STATE_TYPE = 'com.sun.star.beans.PropertyState'


class NativeValue:
    def __init__(self, type_name, value):
        self.typeName, self.value = type_name, value


class PropertyInfo:
    def __init__(self, owner):
        self.owner = owner

    def hasPropertyByName(self, name):
        return name in self.owner.values

    def getPropertyByName(self, name):
        if not self.hasPropertyByName(name):
            raise KeyError(name)
        return SimpleNamespace(Name=name,
            Type=SimpleNamespace(typeName=self.owner.types[name]),
            Attributes=self.owner.attributes.get(name, 0))

    def getProperties(self):
        return tuple(self.getPropertyByName(name) for name in self.owner.values)


class Properties:
    def __init__(self, values=None, types=None):
        self.values = {} if values is None else dict(values)
        self.types = {} if types is None else dict(types)
        for name, value in self.values.items():
            self.types.setdefault(name, 'boolean' if type(value) is bool else
                'long' if type(value) is int else 'float' if type(value) is float else
                'string' if isinstance(value, str) else getattr(value, 'typeName', 'any'))
        self.attributes, self.states = {}, {}
        self.unreadable_values, self.unreadable_states = set(), set()

    def getPropertySetInfo(self):
        return PropertyInfo(self)

    def getPropertyValue(self, name):
        if name in self.unreadable_values:
            raise RuntimeError('Controlled unreadable property: ' + name)
        return self.values[name]

    def getPropertyState(self, name):
        if name in self.unreadable_states:
            raise RuntimeError('Controlled unreadable state: ' + name)
        if name not in self.values:
            raise KeyError(name)
        return NativeValue(STATE_TYPE, self.states.get(name, 'DIRECT_VALUE'))


class Enumeration:
    def __init__(self, items):
        self.items, self.index = list(items), 0

    def hasMoreElements(self):
        return self.index < len(self.items)

    def nextElement(self):
        value = self.items[self.index]
        self.index += 1
        return value


class Portion(Properties):
    def __init__(self, text, kind='Text', **style):
        super().__init__({'TextPortionType': kind, 'CharHeight': 18.0,
            'CharWeight': 100.0, 'CharColor': 0x112233,
            'CharFontName': '맑은 고딕', 'CharUnderline': 0,
            'CharPosture': NativeValue('com.sun.star.awt.FontSlant', 'NONE'), **style})
        self.String = text


class Paragraph(Properties):
    def __init__(self, portions):
        super().__init__({'ParaAdjust': 5, 'ParaTopMargin': 120})
        self.portions = list(portions)

    @property
    def String(self):
        return ''.join(portion.String for portion in self.portions)

    def createEnumeration(self):
        return Enumeration(self.portions)

    def supportsService(self, name):
        return name == 'com.sun.star.text.Paragraph'


class TextPoint:
    def __init__(self, start, end=None):
        self.start, self.end = start, start if end is None else end


class NativeTextCursor:
    def __init__(self, text):
        self.text, self.start, self.end = text, 0, 0

    @property
    def Start(self):
        return TextPoint(self.start)

    @property
    def End(self):
        return TextPoint(self.end)

    @property
    def String(self):
        if self.end - self.start > 32768:
            raise AssertionError('A cursor read exceeded the UTF16 prefix budget')
        encoded = self.text.cursor_content().encode('utf-16-le')
        return encoded[self.start * 2:self.end * 2].decode('utf-16-le')

    def gotoStart(self, expand):
        self.end = 0
        if not expand:
            self.start = 0

    def gotoEnd(self, expand):
        self.end = len(self.text.cursor_content().encode('utf-16-le')) // 2
        if not expand:
            self.start = self.end

    def gotoRange(self, point, expand):
        self.end = point.end
        if not expand:
            self.start = self.end

    def goRight(self, count, expand):
        if type(count) is not int or not 0 <= count <= 32767:
            raise AssertionError('XTextCursor.goRight requires a native short')
        self.text.cursor_moves.append(count)
        length = len(self.text.cursor_content().encode('utf-16-le')) // 2
        moved = min(count, length - self.end)
        self.end += moved
        if not expand:
            self.start = self.end
        return moved == count


class Text:
    def __init__(self, paragraphs):
        self.paragraphs = paragraphs
        self.cursor_moves = []

    def cursor_content(self):
        return '\n'.join(paragraph.String for paragraph in self.paragraphs)

    @property
    def Start(self):
        return TextPoint(0)

    @property
    def End(self):
        return TextPoint(len(self.cursor_content().encode('utf-16-le')) // 2)

    def createTextCursor(self):
        return NativeTextCursor(self)

    def createTextCursorByRange(self, point):
        cursor = self.createTextCursor()
        cursor.gotoRange(point, False)
        return cursor

    def compareRegionEnds(self, left, right):
        return 1 if left.end < right.end else -1 if left.end > right.end else 0

    def compareRegionStarts(self, left, right):
        return 1 if left.start < right.start else -1 if left.start > right.start else 0

    def createEnumeration(self):
        offset = 0
        for paragraph in self.paragraphs:
            paragraph.Start = TextPoint(offset)
            for portion in paragraph.portions:
                portion.Start = TextPoint(offset)
                offset += len(portion.String.encode('utf-16-le')) // 2
                portion.End = TextPoint(offset)
            paragraph.End = TextPoint(offset)
            offset += 1
        return Enumeration(self.paragraphs)


class Cell(Properties):
    def __init__(self, text='same A😀é 한글', *, row_span=1, column_span=1, covered=False):
        border = NativeValue('com.sun.star.table.BorderLine2', SimpleNamespace(
            typeName='struct', Color=-1, InnerLineWidth=0, OuterLineWidth=17,
            LineDistance=0, LineStyle=0, LineWidth=17))
        super().__init__({'CharHeight': 18.0, 'CharWeight': 100.0,
            'CharColor': -1, 'CharFontName': '맑은 고딕',
            'ParaAdjust': 5, 'FillStyle': NativeValue('com.sun.star.drawing.FillStyle', 'SOLID'),
            'FillColor': 0x18A2C3, 'FillTransparence': 0,
            'LeftBorder': border, 'RightBorder': copy.deepcopy(border),
            'TopBorder': copy.deepcopy(border), 'BottomBorder': copy.deepcopy(border),
            'TextLeftDistance': 250, 'TextRightDistance': 250,
            'TextUpperDistance': 125, 'TextLowerDistance': 125,
            'TextVerticalAdjust': NativeValue('com.sun.star.drawing.TextVerticalAdjust', 'TOP')},
            {name: 'com.sun.star.table.BorderLine' for name in
                ('LeftBorder', 'RightBorder', 'TopBorder', 'BottomBorder')})
        self.states.update(CharHeight='DEFAULT_VALUE', CharWeight='DEFAULT_VALUE',
            CharColor='DEFAULT_VALUE', CharFontName='DEFAULT_VALUE', ParaAdjust='DEFAULT_VALUE')
        self.paragraphs = [Paragraph([Portion(text)])]
        self.Text = Text(self.paragraphs)
        self.row_span, self.column_span, self.covered = row_span, column_span, covered
        self.unknown_text, self.unknown_span = False, False

    @property
    def String(self):
        if self.unknown_text:
            raise RuntimeError('Controlled unreadable cell String')
        return '\n'.join(paragraph.String for paragraph in self.paragraphs)

    def getType(self):
        return NativeValue('com.sun.star.table.CellContentType', 'EMPTY')

    def getFormula(self):
        return ''

    def isMerged(self):
        return self.covered

    def getRowSpan(self):
        if self.unknown_span:
            raise RuntimeError('Controlled unreadable span')
        return self.row_span

    def getColumnSpan(self):
        if self.unknown_span:
            raise RuntimeError('Controlled unreadable span')
        return self.column_span


class Collection:
    def __init__(self, items):
        self.items = list(items)

    @property
    def Count(self):
        return len(self.items)

    def getCount(self):
        return self.Count

    def getByIndex(self, index):
        return self.items[index]


class TableModel:
    def __init__(self, rows=2, columns=3):
        self.cells = [[Cell() for _ in range(columns)] for _ in range(rows)]
        self.rows = Collection([Properties({'Height': 3500}) for _ in range(rows)])
        self.columns = Collection([Properties({'Width': width})
            for width in ([7334, 7333, 7333] if columns == 3 else [1000] * columns)])

    def getRows(self):
        return self.rows

    def getColumns(self):
        return self.columns

    def getCellByPosition(self, column, row):
        return self.cells[row][column]


class TableShape(Properties):
    ShapeType = 'com.sun.star.drawing.TableShape'

    def __init__(self, model=None, *, attached=True):
        super().__init__({'Name': 'Duplicate table', 'IsPresentationObject': False,
            'IsEmptyPresentationObject': False, 'MoveProtect': False, 'SizeProtect': False,
            'RotateAngle': 0, 'ShearAngle': 0, 'Visible': True, 'ZOrder': 0,
            'FillStyle': NativeValue('com.sun.star.drawing.FillStyle', 'SOLID'),
            'FillColor': 0xFFFFFF, 'LineStyle': NativeValue('com.sun.star.drawing.LineStyle', 'SOLID'),
            'LineColor': 0, 'LineWidth': 17, 'TableTemplate': '',
            'UseFirstRowStyle': True, 'UseLastRowStyle': False,
            'UseFirstColumnStyle': False, 'UseLastColumnStyle': False,
            'UseBandingRowStyle': True, 'UseBandingColumnStyle': False,
            'Model': model}, {'Model': 'com.sun.star.table.XTable'})
        self.Position = SimpleNamespace(X=1000, Y=1500)
        self.Size = SimpleNamespace(Width=21999, Height=7000)
        self.attached = attached

    @property
    def String(self):
        raise RuntimeError('TableShape does not supply a generic shape String')

    def getShapeType(self):
        return self.ShapeType

    def getName(self):
        return self.values['Name']

    def getPropertyValue(self, name):
        if name == 'Model' and not self.attached:
            raise RuntimeError('Model is unavailable before attaching the TableShape')
        return super().getPropertyValue(name)


class Page(Properties):
    def __init__(self, shapes=()):
        super().__init__({'Layout': 20, 'Visible': True, 'IsBackgroundObjectsVisible': True})
        self.shapes = list(shapes)
        self.Width, self.Height = 28000, 15750

    @property
    def Count(self):
        return len(self.shapes)

    def getByIndex(self, index):
        return self.shapes[index]

    def getMasterPage(self):
        return None


class Document:
    def __init__(self, shapes=()):
        self.page = Page(shapes)
        self.DrawPages, self.MasterPages = Collection([self.page]), Collection([])
        self.closed = False

    def supportsService(self, name):
        return name == 'com.sun.star.presentation.PresentationDocument'

    def close(self, deliver_ownership):
        self.closed = True


def deck(*shapes):
    document = Document(shapes)
    _, slides, objects = worker.objects(document)
    presentation = office_presentation.Presentation(document, slides, objects)
    return SimpleNamespace(document=document, presentation=presentation, shapes=shapes)


def aggregate_state_fixture(state):
    class LiveOwner(Page):
        def __init__(self):
            super().__init__()
            self.invalid = False

        @property
        def Count(self):
            if self.invalid:
                raise RuntimeError('Controlled native owner became invalid after aggregate getter')
            return super().Count

    class AggregateCell(Cell):
        def __init__(self, owner):
            super().__init__()
            self.owner, self.unsafe_value_reads = owner, 0
            self.values['NumberingStartValue'] = 31337
            self.types['NumberingStartValue'] = 'short'
            if state is None:
                self.unreadable_states.add('NumberingStartValue')
            else:
                self.states['NumberingStartValue'] = state

        def getPropertyValue(self, name):
            if name == 'NumberingStartValue':
                self.unsafe_value_reads += 1
                self.owner.invalid = True
                raise RuntimeError('Controlled aggregate getter invalidated the document owner')
            return super().getPropertyValue(name)

    owner = LiveOwner()
    model = TableModel(1, 1)
    cell = AggregateCell(owner)
    model.cells[0][0] = cell
    owner.shapes.append(TableShape(model))
    document = Document()
    document.page, document.DrawPages = owner, Collection([owner])
    return SimpleNamespace(document=document, owner=owner, cell=cell)


def package_with_duplicate_tables(path):
    tables = ''.join(
        '<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="' + str(identifier) +
        '" name="Duplicate table"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>'
        '<p:xfrm><a:off x="360000" y="540000"/><a:ext cx="7920000" cy="2520000"/></p:xfrm>'
        '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/table">'
        '<a:tbl><a:tblPr/><a:tblGrid><a:gridCol w="2640240"/>'
        '<a:gridCol w="2639880"/><a:gridCol w="2639880"/></a:tblGrid>'
        '<a:tr h="1260000">' + ''.join(
            '<a:tc><a:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>'
            'same A😀é 한글</a:t></a:r></a:p></a:txBody><a:tcPr/></a:tc>' for _ in range(3)) +
        '</a:tr><a:tr h="1260000">' + ''.join(
            '<a:tc><a:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>'
            'same A😀é 한글</a:t></a:r></a:p></a:txBody><a:tcPr/></a:tc>' for _ in range(3)) +
        '</a:tr></a:tbl></a:graphicData></a:graphic></p:graphicFrame>'
        for identifier in (17, 29))
    namespaces = ('xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" '
        'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"')
    with zipfile.ZipFile(path, 'w') as package:
        package.writestr('ppt/presentation.xml',
            '<p:presentation ' + namespaces + '><p:sldIdLst><p:sldId id="256" r:id="rId1"/>'
            '</p:sldIdLst></p:presentation>')
        package.writestr('ppt/_rels/presentation.xml.rels',
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" '
            'Target="slides/slide1.xml"/></Relationships>')
        package.writestr('ppt/slides/slide1.xml',
            '<p:sld ' + namespaces + '><p:cSld><p:spTree>' + tables +
            '</p:spTree></p:cSld></p:sld>')


def rich_budget_fixture(kind):
    stats = SimpleNamespace(overflows=0, whole_string_reads=0, value_reads=0,
        descriptor_reads=0, node_reads=0)

    class BudgetExceeded(AssertionError):
        pass

    class CountedEnumeration:
        def __init__(self, count, limit, factory):
            self.count, self.limit, self.factory, self.index = count, limit, factory, 0

        def hasMoreElements(self):
            return self.index < self.count

        def nextElement(self):
            if self.index >= self.limit:
                stats.overflows += 1
                raise BudgetExceeded('The rich read consumed an unobserved native element')
            item = self.factory(self.index)
            self.index += 1
            return item

    def ranged_paragraph(index):
        paragraph = Paragraph([Portion('p')])
        paragraph.Start, paragraph.End = TextPoint(index * 2), TextPoint(index * 2 + 1)
        paragraph.portions[0].Start, paragraph.portions[0].End = paragraph.Start, paragraph.End
        return paragraph

    class PortionsParagraph(Paragraph):
        def __init__(self):
            super().__init__([])
            self.Start, self.End = TextPoint(0), TextPoint(257)

        def createEnumeration(self):
            def portion(index):
                item = Portion('p')
                item.Start, item.End = TextPoint(index), TextPoint(index + 1)
                return item
            return CountedEnumeration(257, 256, portion)

    class LargePortion(Properties):
        def __init__(self):
            super().__init__({'TextPortionType': 'Text', 'CharHeight': 18.0,
                'CharWeight': 100.0, 'CharColor': 0x112233, 'CharFontName': '맑은 고딕'})
            self.Start, self.End = TextPoint(0), TextPoint(32769)

        @property
        def String(self):
            stats.whole_string_reads += 1
            raise BudgetExceeded('An unbounded portion String getter was used')

    class ReadText(Text):
        def __init__(self, content):
            super().__init__([Paragraph([Portion(content)])])
            self.content = content

        def cursor_content(self):
            return self.content

        def createEnumeration(self):
            if kind == 'paragraphs':
                return CountedEnumeration(129, 128, ranged_paragraph)
            if kind == 'portions':
                return Enumeration([PortionsParagraph()])
            if kind == 'utf16':
                paragraph = Paragraph([])
                paragraph.Start, paragraph.End = TextPoint(0), TextPoint(32769)
                paragraph.portions = [LargePortion()]
                return Enumeration([paragraph])
            return super().createEnumeration()

    class ReadCell(Cell):
        @property
        def String(self):
            stats.whole_string_reads += 1
            raise BudgetExceeded('An unbounded cell String getter was used')

        def getPropertyValue(self, name):
            if name.startswith('ObservedRaw'):
                stats.value_reads += 1
                if stats.value_reads > 32768:
                    stats.overflows += 1
                    raise BudgetExceeded('The document property read budget was exceeded')
                return 0
            if name == 'LargeRawTree':
                stats.node_reads = 0
            return super().getPropertyValue(name)

        def getPropertyState(self, name):
            if name.startswith('ObservedRaw'):
                return NativeValue(STATE_TYPE, 'DIRECT_VALUE')
            return super().getPropertyState(name)

        def getPropertySetInfo(self):
            original = super().getPropertySetInfo()
            if kind != 'property_reads':
                return original

            class ManyProperties:
                def hasPropertyByName(self, name):
                    return name.startswith('ObservedRaw') or original.hasPropertyByName(name)

                def getPropertyByName(self, name):
                    if name.startswith('ObservedRaw'):
                        return SimpleNamespace(Name=name, Type=SimpleNamespace(typeName='long'), Attributes=0)
                    return original.getPropertyByName(name)

                def getProperties(self):
                    stats.descriptor_reads, stats.value_reads = 0, 0
                    yield from original.getProperties()
                    for index in range(32769):
                        if index == 32768:
                            stats.overflows += 1
                            raise BudgetExceeded('The document descriptor budget was exceeded')
                        stats.descriptor_reads += 1
                        yield self.getPropertyByName('ObservedRaw' + str(index))

            return ManyProperties()

    class CountedNodes(tuple):
        def __iter__(self):
            for item in super().__iter__():
                stats.node_reads += 1
                if stats.node_reads > 131072:
                    stats.overflows += 1
                    raise BudgetExceeded('The document JSON node observation budget was exceeded')
                yield item

    cell = ReadCell()
    content = '\n'.join('p' for _ in range(129)) if kind == 'paragraphs' else (
        'p' * 257 if kind == 'portions' else 'X' * 32769 if kind == 'utf16' else 'body')
    cell.Text = ReadText(content)
    if kind == 'raw_bytes':
        cell.values['LargeRawList'] = ('P' * 2048,) * 4096
        cell.types['LargeRawList'] = '[]string'
    if kind == 'nodes':
        tree = 'x'
        for _ in range(6):
            tree = CountedNodes((tree,) * 8)
        cell.values['LargeRawTree'] = tree
        cell.types['LargeRawTree'] = 'any'
    model = TableModel(1, 1)
    model.cells[0][0] = cell
    return SimpleNamespace(document=Document([TableShape(model)]), stats=stats, text=cell.Text)


def generic_table_read_fixture():
    class ObservedText(Text):
        def __init__(self, content, reads):
            super().__init__([Paragraph([Portion(content, CharWeight=150.0)])])
            self.reads = reads

        def createTextCursor(self):
            self.reads['cursor'] += 1
            cursor = super().createTextCursor()
            cursor.CharHeight, cursor.CharWeight, cursor.CharColor = 18.0, 150.0, 0x112233
            return cursor

        def createEnumeration(self):
            self.reads['rich'] += 1
            return super().createEnumeration()

    class ObservedTable(TableShape):
        def __init__(self):
            super().__init__(TableModel(1, 1))
            self.reads = {'string': 0, 'cursor': 0, 'rich': 0}
            self.aggregate_reads = {name: 0 for name in
                ('FillStyle', 'FillColor', 'LineStyle', 'LineColor', 'LineWidth')}
            for name in self.aggregate_reads:
                self.states[name] = 'AMBIGUOUS_VALUE'
            self.Text = ObservedText('same A😀é 한글', self.reads)

        @property
        def String(self):
            self.reads['string'] += 1
            return 'same A😀é 한글'

        def getPropertyValue(self, name):
            if name in self.aggregate_reads:
                self.aggregate_reads[name] += 1
            return super().getPropertyValue(name)

    class OrdinaryTextShape(Properties):
        ShapeType = 'com.sun.star.drawing.TextShape'

        def getShapeType(self):
            return self.ShapeType

        def __init__(self):
            super().__init__({'IsPresentationObject': False, 'IsEmptyPresentationObject': False,
                'MoveProtect': False, 'SizeProtect': False,
                'FillStyle': NativeValue('com.sun.star.drawing.FillStyle', 'SOLID'),
                'FillColor': 0x778899,
                'LineStyle': NativeValue('com.sun.star.drawing.LineStyle', 'SOLID'),
                'LineColor': 0x334455, 'LineWidth': 25})
            self.reads = {'string': 0, 'cursor': 0, 'rich': 0}
            self.Text = ObservedText('Ordinary A😀é 한글', self.reads)
            self.Position, self.Size = SimpleNamespace(X=2000, Y=3000), SimpleNamespace(Width=6000, Height=2000)

        @property
        def String(self):
            self.reads['string'] += 1
            return 'Ordinary A😀é 한글'

    table, ordinary = ObservedTable(), OrdinaryTextShape()
    return SimpleNamespace(document=Document([table, ordinary]), table=table, ordinary=ordinary)


class PresentationTableCatalogTest(unittest.TestCase):
    def slide(self, fixture, *, registry=True):
        result = worker.snapshot(fixture.document, SOURCE_SHA,
            presentation=fixture.presentation if registry else None)
        self.assertEqual(result['kind'], 'presentation')
        self.assertEqual(result['tables'], [], 'Legacy Word tables must remain separate')
        slide = result['slides'][0]
        self.assertIn('presentationTables', slide,
            'worker.snapshot must publish the actual PPT table catalog')
        self.assertIn('presentationTableCount', slide)
        self.assertIs(slide['canAddTable'], False, 'Task1 is an inventory-only gate')
        return slide

    def table(self, fixture, *, registry=True):
        slide = self.slide(fixture, registry=registry)
        self.assertIsInstance(slide['presentationTables'], list)
        self.assertEqual(len(slide['presentationTables']), 1)
        return slide['presentationTables'][0]

    def catalog(self, fixture, source_path=None):
        # The initial RED exercises the existing snapshot behavior before any
        # new module import; a missing import is not counted as behavioral RED.
        self.slide(fixture)
        module = importlib.import_module('office_presentation_tables')
        return module.PresentationTables(fixture.presentation, fixture.document, source_path)

    def assert_read_only(self, table):
        self.assertEqual(set(table['capabilities']), set(CAPABILITIES))
        self.assertTrue(all(value is False for value in table['capabilities'].values()))

    def test_worker_snapshot_publishes_verified_zero_separately_from_word_tables(self):
        for registry in (False, True):
            with self.subTest(registry=registry):
                slide = self.slide(deck(), registry=registry)
                self.assertEqual(slide['presentationTables'], [])
                self.assertEqual(slide['presentationTableCount'], 0)
                self.assertIs(slide['presentationTablesTruncated'], False)

    def test_unreadable_actual_model_is_unknown_not_a_verified_empty_catalog(self):
        for model in (None, object()):
            with self.subTest(model=model):
                slide = self.slide(deck(TableShape(model)))
                self.assertIsNone(slide['presentationTables'])
                self.assertEqual(slide['presentationTablesUnknownReason'], 'model_unavailable')
                self.assertEqual(slide['presentationTableCount'], 1)
                self.assertEqual(slide['shapes'][0]['id'], 'slide-0/shape-0')

    def test_attached_shape_uses_the_model_that_exists_only_after_attachment(self):
        shape = TableShape(attached=False)
        shape.values['Model'] = TableModel()
        shape.attached = True
        fixture = deck(shape)
        table = self.table(fixture)
        self.assertEqual(table['id'], 'slide-0/shape-0')
        self.assertEqual((table['rowCount'], table['columnCount']), (2, 3))
        self.assertEqual(table['rowHeightsHmm'], [3500, 3500])
        self.assertEqual(table['columnWidthsHmm'], [7334, 7333, 7333])
        self.assert_read_only(table)

    def test_duplicate_names_text_bounds_and_cells_keep_distinct_actual_identities(self):
        fixture = deck(TableShape(TableModel()), TableShape(TableModel()))
        slide = self.slide(fixture)
        tables = slide['presentationTables']
        self.assertEqual([item['id'] for item in tables], ['slide-0/shape-0', 'slide-0/shape-1'])
        self.assertEqual([item['ownerId'] for item in tables], ['slide-0', 'slide-0'])
        self.assertEqual(len({item['tableSha256'] for item in tables}), 2)
        identities = [{cell['id'] for cell in item['cells']} for item in tables]
        self.assertEqual([len(items) for items in identities], [6, 6])
        self.assertTrue(identities[0].isdisjoint(identities[1]))
        self.assertEqual(tables, self.slide(fixture)['presentationTables'])
        for item in tables:
            self.assert_read_only(item)

    def test_merge_anchor_and_covered_cell_form_the_actual_nonoverlapping_partition(self):
        model = TableModel()
        model.cells[0][0].column_span = 2
        model.cells[0][1].covered = True
        table = self.table(deck(TableShape(model)))
        cells = {(cell['row'], cell['column']): cell for cell in table['cells']}
        anchor, covered = cells[(0, 0)], cells[(0, 1)]
        self.assertIs(anchor['covered'], False)
        self.assertEqual((anchor['rowSpan'], anchor['columnSpan']), (1, 2))
        self.assertIs(covered['covered'], True)
        self.assertEqual((covered['rowSpan'], covered['columnSpan']), (1, 1))
        self.assertEqual(covered['anchorCellId'], anchor['id'])
        self.assertEqual(table['totalCellCount'], 6)
        self.assertEqual(len(table['cells']), 6)
        self.assert_read_only(table)

    def test_empty_content_type_does_not_drop_actual_unicode_rich_text_or_protected_field(self):
        model = TableModel(1, 1)
        cell = model.cells[0][0]
        cell.paragraphs[:] = [
            Paragraph([Portion('A😀', CharWeight=150.0), Portion('é 한글')]),
            Paragraph([Portion(''), Portion('7', 'TextField')]),
        ]
        table = self.table(deck(TableShape(model)))
        item = table['cells'][0]
        self.assertEqual(item['text'], 'A😀é 한글\n7')
        details = item['textDetails']
        self.assertEqual(details['textSha256'], hashlib.sha256(item['text'].encode('utf-8')).hexdigest())
        self.assertEqual(details['utf16Length'], len(item['text'].encode('utf-16-le')) // 2)
        self.assertIs(details['runs'][0]['bold'], True)
        self.assertEqual(details['protectedRanges'][-1]['type'], 'TextField')
        self.assert_read_only(table)

    def test_raw_properties_keep_presence_declared_type_actual_struct_and_nonempty_default(self):
        model = TableModel(1, 1)
        table = self.table(deck(TableShape(model)))
        raw = table['cells'][0]['rawStyle']
        self.assertEqual(raw['CharFontName'], {'present': True, 'nativeType': 'string',
            'attributes': 0, 'state': {'enumType': STATE_TYPE, 'value': 'DEFAULT_VALUE'},
            'value': '맑은 고딕'})
        border = raw['LeftBorder']
        self.assertEqual(border['nativeType'], 'com.sun.star.table.BorderLine')
        self.assertEqual(border['state'], {'enumType': STATE_TYPE, 'value': 'DIRECT_VALUE'})
        self.assertEqual(border['value']['enumType'], 'com.sun.star.table.BorderLine2')
        self.assertEqual(border['value']['value']['fields'], {'Color': -1, 'InnerLineWidth': 0,
            'OuterLineWidth': 17, 'LineDistance': 0, 'LineStyle': 0, 'LineWidth': 17})
        for name in ('LeftBorder2', 'RightBorder2', 'TopBorder2', 'BottomBorder2',
                'VerticalJustify', 'IsProtected'):
            self.assertEqual(raw[name], {'present': False})
        self.assert_read_only(table)
        model.cells[0][0].unreadable_states.add('CharFontName')
        partial = self.slide(deck(TableShape(model)))
        self.assertEqual(partial['presentationTablesUnknownReason'], 'raw_state_unavailable')
        observed = partial['presentationTables'][0]
        self.assertIsNone(observed['tableSha256'])
        self.assertEqual(observed['cells'][0]['rawStyle']['CharFontName']['value'],
            {'unknown': True, 'error': 'property_value_state_unavailable'})
        self.assertTrue(observed['cells'][0]['rawStyle']['CharFontName']['stateUnknown']['unknown'])
        self.assert_read_only(observed)

    def test_inspect_request_never_guesses_xml_binding_for_duplicate_actual_tables(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'source.pptx'
            package_with_duplicate_tables(source)
            fixture = deck(TableShape(TableModel()), TableShape(TableModel()))
            before = source.read_bytes()

            class Server:
                context = None

                def __init__(self, runtime, job):
                    pass

                def __enter__(self):
                    return self

                def __exit__(self, *args):
                    return False

                def load(self, path):
                    fixture.document.URL = path.as_uri()
                    return fixture.document

            with patch.object(worker, 'OfficeServer', Server):
                result = worker.run_request(root, {'mode': 'inspect',
                    'sourcePath': str(source), 'sessionId': 'duplicate-tables'}, root / 'job')
            slide = result['snapshot']['slides'][0]
            self.assertIn('presentationTables', slide,
                'The actual inspect request must expose PPT tables, not just a standalone catalog')
            self.assertEqual(len(slide['presentationTables']), 2)
            for table in slide['presentationTables']:
                self.assertIsNone(table['authoredGeometry'])
                self.assertEqual(table['nativeBoundsHmm'],
                    {'x': 1000, 'y': 1500, 'width': 21999, 'height': 7000})
                self.assertEqual(sum(table['columnWidthsHmm']), 22000)
                self.assert_read_only(table)
            self.assertEqual(source.read_bytes(), before)
            self.assertTrue(fixture.document.closed)

    def test_source_bound_registry_rejects_equal_looking_replacement_shape_model_or_cell(self):
        for replaced in ('shape', 'model', 'cell'):
            with self.subTest(replaced=replaced):
                shape = TableShape(TableModel())
                fixture = deck(shape)
                catalog = self.catalog(fixture)
                catalog.snapshot('slide-0')
                if replaced == 'shape':
                    fixture.document.page.shapes[0] = TableShape(TableModel())
                elif replaced == 'model':
                    shape.values['Model'] = TableModel()
                else:
                    shape.values['Model'].cells[0][0] = Cell()
                with self.assertRaises(ValueError):
                    catalog.assert_fresh()

    def test_source_bound_registry_rejects_same_text_raw_value_state_type_presence_and_attribute_drift(self):
        for drift in ('value', 'state', 'type', 'presence', 'attributes', 'shape'):
            with self.subTest(drift=drift):
                shape = TableShape(TableModel())
                fixture = deck(shape)
                catalog = self.catalog(fixture)
                catalog.snapshot('slide-0')
                cell = shape.values['Model'].cells[0][0]
                if drift == 'value':
                    cell.values['TextLeftDistance'] += 1
                elif drift == 'state':
                    cell.states['CharFontName'] = 'DIRECT_VALUE'
                elif drift == 'type':
                    cell.types['LeftBorder'] = 'com.sun.star.table.BorderLine2'
                elif drift == 'presence':
                    cell.values['IsProtected'] = False
                    cell.types['IsProtected'] = 'boolean'
                elif drift == 'attributes':
                    cell.attributes['FillColor'] = 16
                else:
                    shape.values['UseFirstRowStyle'] = False
                self.assertEqual(cell.String, 'same A😀é 한글')
                with self.assertRaises(ValueError):
                    catalog.assert_fresh()

    def test_initial_unknown_model_cannot_be_retrusted_after_it_becomes_readable(self):
        shape = TableShape()
        fixture = deck(shape)
        catalog = self.catalog(fixture)
        self.assertIsNone(catalog.snapshot('slide-0'))
        shape.values['Model'] = TableModel()
        with self.assertRaises(ValueError):
            catalog.assert_fresh()

    def test_inconsistent_covered_partition_is_not_published_as_a_complete_editable_grid(self):
        model = TableModel()
        model.cells[0][0].column_span = 2
        model.cells[0][1].column_span = 2
        slide = self.slide(deck(TableShape(model)))
        self.assertIsNone(slide['presentationTables'])
        self.assertEqual(slide['presentationTablesUnknownReason'], 'topology_unavailable')
        self.assertEqual(slide['presentationTableCount'], 1)

    def test_catalog_budgets_preserve_actual_totals_without_inventing_missing_cells(self):
        large = self.table(deck(TableShape(TableModel(1, 101))))
        self.assertEqual(large['totalCellCount'], 101)
        self.assertEqual((large['rowCount'], large['columnCount']), (1, 101))
        self.assertEqual(len(large['cells']), 100)
        self.assertIs(large['truncated'], True)
        self.assertEqual(len({(cell['row'], cell['column']) for cell in large['cells']}), 100)
        self.assert_read_only(large)
        slide = self.slide(deck(*(TableShape(TableModel(1, 1)) for _ in range(21))))
        self.assertEqual(slide['presentationTableCount'], 21)
        self.assertEqual(len(slide['presentationTables']), 20)
        self.assertIs(slide['presentationTablesTruncated'], True)
        for table in slide['presentationTables']:
            self.assert_read_only(table)

    def test_generic_shape_capabilities_cannot_bypass_the_table_read_only_gate(self):
        fixture = deck(TableShape(TableModel()))
        slide = self.slide(fixture)
        self.assert_read_only(slide['presentationTables'][0])
        shape = slide['shapes'][0]
        for name in ('editableText', 'canEditGeometry', 'canDelete',
                'canEditTextStyle', 'canEditFill', 'canEditLine'):
            self.assertIs(shape[name], False, name)
        for operation in ('text', 'textStyle', 'geometry', 'delete', 'content', 'image'):
            with self.assertRaises(ValueError):
                fixture.presentation.require_edit(shape['id'], operation)


    def test_new_empty_slide_survives_apply_operations_to_live_snapshot(self):
        class MutablePage(Page):
            def add(self, shape):
                self.shapes.append(shape)

        class Slides(Collection):
            def insertNewByIndex(self, index):
                page = MutablePage()
                self.items.insert(index, page)
                return page

        class ContentShape(Properties):
            ShapeType = 'com.sun.star.drawing.TextShape'

            def __init__(self):
                super().__init__({'IsPresentationObject': False,
                    'IsEmptyPresentationObject': False, 'MoveProtect': False, 'SizeProtect': False})
                self.String = ''

            def getShapeType(self):
                return self.ShapeType

        def uno_struct(name, first, second):
            if name == 'com.sun.star.awt.Point':
                return SimpleNamespace(X=first, Y=second)
            if name == 'com.sun.star.awt.Size':
                return SimpleNamespace(Width=first, Height=second)
            raise AssertionError('Unexpected native struct: ' + name)

        document = Document()
        document.DrawPages = Slides([document.page])

        def create_instance(service):
            self.assertEqual(service, 'com.sun.star.drawing.TextShape')
            return ContentShape()

        document.createInstance = create_instance
        state = {}
        with patch.object(worker, 'uno', SimpleNamespace(createUnoStruct=uno_struct), create=True):
            kind, physical, logical = worker.apply_operations(document,
                [{'op': 'slideAdd', 'id': 'created-slide', 'index': 1, 'text': 'New slide'}],
                presentation_state=state)
        self.assertEqual(kind, 'presentation')
        self.assertEqual(physical, ['slide-0', 'created-slide'])
        self.assertEqual(logical, ['slide-0', 'created-slide'])
        created = state['presentation'].shapes['created-slide/shape-0']
        self.assertEqual(created.String, 'New slide')
        try:
            result = worker.snapshot(document, SOURCE_SHA, presentation=state['presentation'])
        except ValueError as error:
            self.fail('A registered empty slide must have a readable table catalog: ' + str(error))
        self.assertEqual([slide['id'] for slide in result['slides']], ['slide-0', 'created-slide'])
        for slide in result['slides']:
            self.assertEqual(slide['presentationTables'], [])
            self.assertEqual(slide['presentationTableCount'], 0)
            self.assertIs(slide['presentationTablesTruncated'], False)
            self.assertIsNone(slide['presentationTablesUnknownReason'])
            self.assertIs(slide['canAddTable'], False)

    def test_partial_table_dimension_reads_stop_at_the_observed_prefix(self):
        class LazyDimensions:
            def __init__(self, count, name):
                self.Count, self.name = count, name
                self.prefix = [Properties({name: 1000}) for _ in range(min(count, 100))]
                self.requested = []

            def getByIndex(self, index):
                self.requested.append(index)
                if not 0 <= index < len(self.prefix):
                    raise AssertionError('Dimension read escaped the 100-item observation budget')
                return self.prefix[index]

        class LazyModel:
            def __init__(self, rows, columns):
                self.rows = LazyDimensions(rows, 'Height')
                self.columns = LazyDimensions(columns, 'Width')
                self.cells = {}

            def getRows(self):
                return self.rows

            def getColumns(self):
                return self.columns

            def getCellByPosition(self, column, row):
                if not (0 <= row < self.rows.Count and 0 <= column < self.columns.Count):
                    raise AssertionError('Cell read outside actual model bounds')
                coordinate = (row, column)
                if coordinate not in self.cells:
                    if len(self.cells) == 100:
                        raise AssertionError('Cell read escaped the 100-coordinate observation budget')
                    self.cells[coordinate] = Cell()
                return self.cells[coordinate]

        for row_count, column_count in ((200000, 1), (1, 300000), (200000, 300000)):
            with self.subTest(rows=row_count, columns=column_count):
                model = LazyModel(row_count, column_count)
                table = self.table(deck(TableShape(model)))
                self.assertEqual((table['rowCount'], table['columnCount']), (row_count, column_count))
                self.assertEqual(table['totalCellCount'], row_count * column_count)
                self.assertEqual(len(table['cells']), 100)
                self.assertEqual(table['rowHeightsHmm'], [1000] * min(row_count, 100))
                self.assertEqual(table['columnWidthsHmm'], [1000] * min(column_count, 100))
                row_prefix = list(range(min(row_count, 100)))
                self.assertEqual(model.rows.requested, row_prefix + row_prefix)
                column_prefix = list(range(min(column_count, 100)))
                self.assertEqual(model.columns.requested, column_prefix + column_prefix)
                self.assertEqual(len(model.cells), 100)
                self.assertIs(table['truncated'], True)
                self.assertIsNone(table['tableSha256'])
                self.assert_read_only(table)


    def test_ambiguous_aggregate_state_is_read_without_invalidating_the_snapshot_owner(self):
        fixture = aggregate_state_fixture('AMBIGUOUS_VALUE')
        try:
            snapshot = worker.snapshot(fixture.document, SOURCE_SHA)
        except Exception as error:
            self.fail('An aggregate getter must not invalidate the actual snapshot owner: ' + str(error))
        self.assertEqual(fixture.owner.Count, 1)
        self.assertEqual(fixture.cell.unsafe_value_reads, 0)
        slide = snapshot['slides'][0]
        table = slide['presentationTables'][0]
        raw = table['cells'][0]['rawStyle']['NumberingStartValue']
        self.assertIs(raw['present'], True)
        self.assertEqual(raw['nativeType'], 'short')
        self.assertEqual(raw['attributes'], 0)
        self.assertEqual(raw['state'], {'enumType': STATE_TYPE, 'value': 'AMBIGUOUS_VALUE'})
        self.assertIs(raw['value']['unknown'], True)
        self.assertIsNone(table['tableSha256'])
        self.assertEqual(slide['presentationTablesUnknownReason'], 'raw_state_unavailable')
        self.assert_read_only(table)

    def test_unreadable_aggregate_state_does_not_authorize_an_arbitrary_value_getter(self):
        fixture = aggregate_state_fixture(None)
        try:
            snapshot = worker.snapshot(fixture.document, SOURCE_SHA)
        except Exception as error:
            self.fail('Unknown PropertyState must not trigger an unsafe value getter: ' + str(error))
        self.assertEqual(fixture.owner.Count, 1)
        self.assertEqual(fixture.cell.unsafe_value_reads, 0)
        slide = snapshot['slides'][0]
        table = slide['presentationTables'][0]
        raw = table['cells'][0]['rawStyle']['NumberingStartValue']
        self.assertIs(raw['present'], True)
        self.assertEqual(raw['nativeType'], 'short')
        self.assertIs(raw['stateUnknown']['unknown'], True)
        self.assertNotIn('state', raw)
        self.assertIs(raw['value']['unknown'], True)
        self.assertIsNone(table['tableSha256'])
        self.assertEqual(slide['presentationTablesUnknownReason'], 'raw_state_unavailable')
        self.assert_read_only(table)


    def test_state_less_row_and_column_interfaces_preserve_verified_dimension_values(self):
        class StateLessDimension:
            def __init__(self, name, value):
                self.values, self.types, self.attributes = {name: value}, {name: 'long'}, {}
                self.value_reads = []

            def getPropertySetInfo(self):
                return PropertyInfo(self)

            def getPropertyValue(self, name):
                self.value_reads.append(name)
                return self.values[name]

        model = TableModel(2, 2)
        rows = [StateLessDimension('Height', 3500) for _ in range(2)]
        columns = [StateLessDimension('Width', 10000) for _ in range(2)]
        model.rows, model.columns = Collection(rows), Collection(columns)
        table = self.table(deck(TableShape(model)))
        self.assertEqual(table['rowHeightsHmm'], [3500, 3500])
        self.assertEqual(table['columnWidthsHmm'], [10000, 10000])
        for raw_dimensions, native_dimensions, property_name, expected in (
                (table['rawStyle']['_rows'], rows, 'Height', 3500),
                (table['rawStyle']['_columns'], columns, 'Width', 10000)):
            for raw_dimension, native_dimension in zip(raw_dimensions, native_dimensions):
                raw = raw_dimension[property_name]
                self.assertIs(raw['present'], True)
                self.assertEqual(raw['nativeType'], 'long')
                self.assertEqual(raw['attributes'], 0)
                self.assertEqual(raw['value'], expected)
                self.assertIs(raw['stateUnsupported']['unknown'], True)
                self.assertNotIn('state', raw)
                self.assertEqual(native_dimension.value_reads, [property_name, property_name])
        self.assertIsNone(table['tableSha256'])
        self.assert_read_only(table)

    def test_state_less_cell_interface_does_not_enable_a_generic_unsafe_value_fallback(self):
        fixture = aggregate_state_fixture(None)

        class StateLessCell:
            def __getattr__(self, name):
                if name == 'getPropertyState':
                    raise AttributeError('This native interface does not support PropertyState')
                return getattr(fixture.cell, name)

        fixture.owner.shapes[0].values['Model'].cells[0][0] = StateLessCell()
        try:
            snapshot = worker.snapshot(fixture.document, SOURCE_SHA)
        except Exception as error:
            self.fail('Only row Height and column Width may opt in to state-less getters: ' + str(error))
        self.assertEqual(fixture.owner.Count, 1)
        self.assertEqual(fixture.cell.unsafe_value_reads, 0)
        table = snapshot['slides'][0]['presentationTables'][0]
        raw = table['cells'][0]['rawStyle']['NumberingStartValue']
        self.assertIs(raw['present'], True)
        self.assertIs(raw['value']['unknown'], True)
        self.assertIsNone(table['tableSha256'])
        self.assert_read_only(table)


    def test_partial_merged_anchor_uses_only_observed_coordinates_under_the_read_budget(self):
        class BudgetExceeded(AssertionError):
            pass

        def bounded_range(*arguments):
            for ordinal, item in enumerate(builtins.range(*arguments)):
                if ordinal == 100:
                    raise BudgetExceeded('A partial table expanded an unobserved span coordinate range')
                yield item

        class Dimensions:
            def __init__(self, count, name):
                self.Count = count
                self.prefix = [Properties({name: 1000}) for _ in range(100)]

            def getByIndex(self, index):
                if not 0 <= index < 100:
                    raise BudgetExceeded('An unobserved dimension was read')
                return self.prefix[index]

        class LargeMergedModel:
            def __init__(self):
                self.rows, self.columns = Dimensions(200000, 'Height'), Dimensions(300000, 'Width')
                self.cells = [Cell(row_span=200000, column_span=300000)]
                self.cells.extend(Cell(covered=True) for _ in range(99))

            def getRows(self):
                return self.rows

            def getColumns(self):
                return self.columns

            def getCellByPosition(self, column, row):
                if row != 0 or not 0 <= column < 100:
                    raise BudgetExceeded('An unobserved coordinate was read')
                return self.cells[column]

        document = Document([TableShape(LargeMergedModel())])
        catalog_module = importlib.import_module('office_presentation_tables')
        with patch.object(catalog_module, 'range', bounded_range, create=True):
            try:
                snapshot = worker.snapshot(document, SOURCE_SHA)
            except BudgetExceeded as error:
                self.fail(str(error))
        slide = snapshot['slides'][0]
        self.assertIsInstance(slide['presentationTables'], list)
        table = slide['presentationTables'][0]
        self.assertEqual(table['totalCellCount'], 200000 * 300000)
        self.assertEqual(len(table['cells']), 100)
        self.assertIs(table['truncated'], True)
        self.assertIsNone(table['tableSha256'])
        anchor = table['cells'][0]
        self.assertEqual((anchor['rowSpan'], anchor['columnSpan']), (200000, 300000))
        self.assertIs(anchor['covered'], False)
        self.assertIsNone(anchor['anchorCellId'])
        self.assertEqual(len({cell['id'] for cell in table['cells']}), 100)
        for column, cell in enumerate(table['cells'][1:], 1):
            self.assertEqual((cell['row'], cell['column']), (0, column))
            self.assertIs(cell['covered'], True)
            self.assertEqual(cell['anchorCellId'], anchor['id'])
        self.assert_read_only(table)

    def test_equal_looking_empty_owner_replacement_is_rejected_for_source_and_registered_owners(self):
        for owner_kind in ('source', 'registered'):
            for guard in ('snapshot', 'assert_fresh'):
                with self.subTest(owner=owner_kind, guard=guard):
                    fixture = deck()
                    presentation = fixture.presentation
                    owner_id = 'slide-0'
                    if owner_kind == 'registered':
                        owner_id = 'created-empty-slide'
                        created = Page()
                        fixture.document.DrawPages.items.append(created)
                        presentation.slides[owner_id] = created
                        presentation.physical.append(owner_id)
                        presentation.logical.append(owner_id)
                        presentation.table_catalog.register_empty_owner(owner_id, created)
                        presentation.used.add(owner_id)
                    initial = worker.snapshot(fixture.document, SOURCE_SHA, presentation=presentation)
                    observed = next(slide for slide in initial['slides'] if slide['id'] == owner_id)
                    self.assertEqual(observed['presentationTables'], [])
                    previous = presentation.slides[owner_id]
                    replacement = Page()
                    self.assertIsNot(replacement, previous)
                    self.assertEqual((replacement.Count, replacement.Width, replacement.Height),
                        (previous.Count, previous.Width, previous.Height))
                    native_index = fixture.document.DrawPages.items.index(previous)
                    fixture.document.DrawPages.items[native_index] = replacement
                    presentation.slides[owner_id] = replacement
                    with self.assertRaises(ValueError):
                        if guard == 'snapshot':
                            worker.snapshot(fixture.document, SOURCE_SHA, presentation=presentation)
                        else:
                            presentation.table_catalog.assert_fresh()


    def test_failed_owner_capture_still_consumes_the_document_table_observation_budget(self):
        attempts = []

        class ObservedShape(TableShape):
            def getPropertyValue(self, name):
                if name == 'Model':
                    attempts.append(self)
                    if len(attempts) > 20:
                        raise AssertionError('A failed owner reused the document table observation budget')
                return super().getPropertyValue(name)

        first = [ObservedShape(TableModel(1, 1)) for _ in range(19)] + [ObservedShape()]
        second = [ObservedShape(TableModel(1, 1)) for _ in range(20)]
        document = Document(first)
        document.DrawPages.items.append(Page(second))
        snapshot = worker.snapshot(document, SOURCE_SHA)
        failed, partial = snapshot['slides']
        self.assertIsNone(failed['presentationTables'])
        self.assertEqual(failed['presentationTableCount'], 20)
        self.assertEqual(partial['presentationTables'], [])
        self.assertEqual(partial['presentationTableCount'], 20)
        self.assertIs(partial['presentationTablesTruncated'], True)
        self.assertIs(partial['canAddTable'], False)
        self.assertEqual(len(attempts), 20)

    def test_first_publication_rechecks_captured_model_cell_and_raw_state(self):
        for change in ('model', 'cell', 'raw_value', 'raw_state'):
            with self.subTest(change=change):
                shape = TableShape(TableModel(1, 1))
                fixture = deck(shape)
                model = shape.values['Model']
                if change == 'model':
                    shape.values['Model'] = TableModel(1, 1)
                elif change == 'cell':
                    model.cells[0][0] = Cell()
                elif change == 'raw_value':
                    model.cells[0][0].values['TextLeftDistance'] += 1
                else:
                    model.cells[0][0].states['CharFontName'] = 'DIRECT_VALUE'
                with self.assertRaises(ValueError):
                    worker.snapshot(fixture.document, SOURCE_SHA, presentation=fixture.presentation)


    def test_cell_rich_reads_and_document_raw_observations_close_at_the_source_budgets(self):
        for kind in ('paragraphs', 'portions', 'utf16', 'property_reads', 'raw_bytes', 'nodes'):
            with self.subTest(budget=kind):
                fixture = rich_budget_fixture(kind)
                snapshot = worker.snapshot(fixture.document, SOURCE_SHA)
                slide = snapshot['slides'][0]
                self.assertIsInstance(slide['presentationTables'], list)
                table = slide['presentationTables'][0]
                self.assertIs(table['truncated'], True, kind)
                self.assertIsNone(table['tableSha256'])
                self.assertEqual((table['rowCount'], table['columnCount'], table['totalCellCount']), (1, 1, 1))
                self.assertEqual(len(table['cells']), 1)
                self.assertEqual(slide['presentationTablesUnknownReason'], 'read_budget_exhausted')
                self.assert_read_only(table)
                cell = table['cells'][0]
                if cell['textDetails'] is not None:
                    self.assertIs(cell['textDetails']['truncated'], True)
                if cell['text'] is not None:
                    self.assertLessEqual(len(cell['text'].encode('utf-16-le')) // 2, 32768)
                if kind == 'utf16':
                    self.assertIsNone(cell['text'])
                    self.assertIsNone(cell['textDetails'])
                    self.assertTrue(all(0 <= count <= 32767 for count in fixture.text.cursor_moves))
                self.assertEqual(fixture.stats.overflows, 0)
                self.assertEqual(fixture.stats.whole_string_reads, 0)
                self.assertLessEqual(fixture.stats.value_reads, 32768)
                self.assertLessEqual(fixture.stats.descriptor_reads, 32768)
                self.assertLessEqual(fixture.stats.node_reads, 131072)
                raw = [table['rawStyle'], *[item['rawStyle'] for item in table['cells']]]
                encoded = json.dumps(raw, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
                self.assertLessEqual(len(encoded), 8 * 1024 * 1024)
                stack, nodes = [raw], 0
                while stack:
                    item = stack.pop()
                    nodes += 1
                    self.assertLessEqual(nodes, 131072)
                    if isinstance(item, dict):
                        stack.extend(item.values())
                    elif isinstance(item, list):
                        stack.extend(item)


    def test_eight_cells_keep_complete_authored_rich_raw_within_the_original_document_limits(self):
        models, expected = [TableModel(2, 2), TableModel(2, 2)], []
        shared_style = 'shared nonempty authored value'
        index = 0
        for model in models:
            for row in model.cells:
                for cell in row:
                    portions = [Portion('CELL' + str(index) + ' A😀', CharWeight=150.0),
                        Portion('é ', CharWeight=100.0),
                        Portion('한글', CharWeight=150.0), Portion(' END', CharWeight=100.0)]
                    for portion in portions:
                        for number in range(76):
                            name = 'AuthoredStyle' + str(number)
                            portion.values[name], portion.types[name] = shared_style, 'string'
                            portion.states[name] = 'DEFAULT_VALUE'
                    cell.paragraphs[:] = [Paragraph(portions)]
                    expected.append(''.join(portion.String for portion in portions))
                    index += 1
        snapshot = worker.snapshot(Document([TableShape(model) for model in models]), SOURCE_SHA)
        tables = snapshot['slides'][0]['presentationTables']
        self.assertIsInstance(tables, list)
        self.assertEqual(len(tables), 2)
        cells = [cell for table in tables for cell in table['cells']]
        self.assertEqual(len(cells), 8)
        self.assertEqual([cell['text'] for cell in cells], expected)
        for table in tables:
            self.assertIs(table['truncated'], False)
            self.assertIsNotNone(table['tableSha256'])
            self.assert_read_only(table)
        for cell in cells:
            self.assertIs(cell['textDetails']['truncated'], False)
            self.assertEqual([run['bold'] for run in cell['textDetails']['runs']],
                [True, False, True, False])
            raw_portions = cell['rawStyle']['_paragraphs'][0]['portions']
            self.assertEqual(len(raw_portions), 4)
            for portion in raw_portions:
                authored = portion['rawStyle']['AuthoredStyle75']
                self.assertEqual(authored['value'], shared_style)
                self.assertEqual(authored['state'],
                    {'enumType': STATE_TYPE, 'value': 'DEFAULT_VALUE'})
        raw = [item['rawStyle'] for item in tables + cells]
        self.assertLessEqual(len(json.dumps(raw, ensure_ascii=False,
            separators=(',', ':')).encode('utf-8')), 8 * 1024 * 1024)

    def test_cell_text_counts_equal_strings_at_distinct_output_positions_without_identity_discount(self):
        catalog_module = importlib.import_module('office_presentation_tables')
        shared = 'R' * 16384

        def observe(separate_objects):
            cell = Cell()
            portions = [Portion('x'), Portion('x')]
            for portion in portions:
                value = shared.encode('utf-8').decode('utf-8') if separate_objects else shared
                portion.values['RepeatedAuthored'], portion.types['RepeatedAuthored'] = value, 'string'
            if separate_objects:
                self.assertIsNot(portions[0].values['RepeatedAuthored'],
                    portions[1].values['RepeatedAuthored'])
            else:
                self.assertIs(portions[0].values['RepeatedAuthored'],
                    portions[1].values['RepeatedAuthored'])
            cell.paragraphs[:] = [Paragraph(portions)]
            budget = catalog_module.DocBudget()
            text, details, raw, truncated = catalog_module.cell_text(cell, budget)
            self.assertEqual(text, 'xx')
            self.assertIs(truncated, False)
            self.assertIs(details['truncated'], False)
            self.assertEqual([item['rawStyle']['RepeatedAuthored']['value']
                for item in raw[0]['portions']], [shared, shared])
            self.assertGreaterEqual(budget.raw_bytes,
                2 * len(json.dumps(shared, ensure_ascii=False).encode('utf-8')))
            return raw, details, budget.nodes, budget.raw_bytes

        self.assertEqual(observe(False), observe(True))

    def test_cell_text_still_stops_oversized_native_conversion_before_unbounded_allocation(self):
        catalog_module = importlib.import_module('office_presentation_tables')
        observed = SimpleNamespace(nodes=0, overflow=False)

        class NativeTree(tuple):
            def __iter__(self):
                for item in super().__iter__():
                    observed.nodes += 1
                    if observed.nodes > 131072:
                        observed.overflow = True
                        raise AssertionError('The native conversion escaped the document node limit')
                    yield item

        tree = 'x'
        for _ in range(6):
            tree = NativeTree((tree,) * 8)
        portion = Portion('x')
        portion.values['LargeNativeTree'], portion.types['LargeNativeTree'] = tree, 'any'
        cell = Cell()
        cell.paragraphs[:] = [Paragraph([portion])]
        budget = catalog_module.DocBudget()
        text, details, raw, truncated = catalog_module.cell_text(cell, budget)
        self.assertEqual(text, 'x')
        self.assertIs(truncated, True)
        self.assertIs(details['truncated'], True)
        self.assertIs(budget.exhausted, True)
        self.assertIs(observed.overflow, False)
        self.assertLessEqual(observed.nodes, 131072)
        self.assertLessEqual(budget.nodes, 131072)
        self.assertLessEqual(len(json.dumps(raw, ensure_ascii=False,
            separators=(',', ':')).encode('utf-8')), 8 * 1024 * 1024)


    def test_table_snapshot_does_not_read_generic_whole_text_cursor_or_rich_inventory(self):
        fixture = generic_table_read_fixture()
        snapshot = worker.snapshot(fixture.document, SOURCE_SHA)
        self.assertEqual(snapshot['sourceSha256'], SOURCE_SHA)
        slide = snapshot['slides'][0]
        self.assertEqual(snapshot['tables'], [])
        self.assertEqual(slide['presentationTableCount'], 1)
        table = slide['presentationTables'][0]
        self.assertEqual(table['id'], 'slide-0/shape-0')
        self.assertEqual(table['ownerId'], 'slide-0')
        self.assertEqual(table['nativeBoundsHmm'], {'x': 1000, 'y': 1500, 'width': 21999, 'height': 7000})
        self.assertEqual((table['rowCount'], table['columnCount'], table['totalCellCount']), (1, 1, 1))
        self.assertEqual(table['cells'][0]['id'], 'slide-0/shape-0/cell-0')
        self.assertEqual(table['cells'][0]['text'], 'same A😀é 한글')
        self.assertEqual(table['cells'][0]['rawStyle']['CharFontName']['value'], '맑은 고딕')
        self.assertIs(table['cells'][0]['textDetails']['truncated'], False)
        self.assert_read_only(table)
        shape = slide['shapes'][0]
        self.assertEqual(shape['id'], table['id'])
        self.assertEqual(shape['type'], 'com.sun.star.drawing.TableShape')
        self.assertEqual((shape['x'], shape['y'], shape['width'], shape['height']), (10, 15, 219.99, 70))
        for name in ('editableText', 'canEditGeometry', 'canDelete', 'canEditTextStyle', 'canEditFill', 'canEditLine'):
            self.assertIs(shape[name], False, name)
        self.assertEqual(fixture.table.reads, {'string': 0, 'cursor': 0, 'rich': 0},
            'Table text must be observed only through the bounded typed cell catalog')
        self.assertEqual(shape['text'], '')
        self.assertIsNone(shape['textDetails'])

    def test_table_snapshot_does_not_read_ambiguous_generic_fill_or_line_values(self):
        fixture = generic_table_read_fixture()
        snapshot = worker.snapshot(fixture.document, SOURCE_SHA)
        slide = snapshot['slides'][0]
        table = slide['presentationTables'][0]
        for name in ('FillStyle', 'FillColor', 'LineStyle', 'LineColor', 'LineWidth'):
            raw = table['rawStyle'][name]
            self.assertIs(raw['present'], True)
            self.assertEqual(raw['state'], {'enumType': STATE_TYPE, 'value': 'AMBIGUOUS_VALUE'})
            self.assertEqual(raw['value'], {'unknown': True, 'error': 'property_value_state_unavailable'})
        self.assertEqual(table['cells'][0]['text'], 'same A😀é 한글')
        self.assertIsNone(table['tableSha256'])
        self.assertEqual(slide['presentationTablesUnknownReason'], 'raw_state_unavailable')
        self.assert_read_only(table)
        self.assertEqual(fixture.table.aggregate_reads,
            {'FillStyle': 0, 'FillColor': 0, 'LineStyle': 0, 'LineColor': 0, 'LineWidth': 0},
            'The generic renderer must not bypass ambiguous table PropertyState')
        shape = slide['shapes'][0]
        for name in ('fillStyle', 'fillColor', 'lineStyle', 'lineColor', 'lineWidth'):
            self.assertIsNone(shape[name], name)
        self.assertIs(shape['canEditFill'], False)
        self.assertIs(shape['canEditLine'], False)

    def test_ordinary_text_shape_keeps_generic_text_rich_style_and_appearance_rendering(self):
        fixture = generic_table_read_fixture()
        snapshot = worker.snapshot(fixture.document, SOURCE_SHA)
        slide = snapshot['slides'][0]
        self.assertEqual(len(slide['presentationTables']), 1)
        shape = slide['shapes'][1]
        self.assertEqual(shape['id'], 'slide-0/shape-1')
        self.assertEqual(shape['shapeKind'], 'text')
        self.assertEqual(shape['text'], 'Ordinary A😀é 한글')
        self.assertIs(shape['editableText'], True)
        self.assertEqual((shape['fontSize'], shape['bold'], shape['color']), (18.0, True, 0x112233))
        self.assertEqual((shape['fillStyle'], shape['fillColor']), ('solid', 0x778899))
        self.assertEqual((shape['lineStyle'], shape['lineColor'], shape['lineWidth']), ('solid', 0x334455, 0.25))
        self.assertIs(shape['canEditFill'], True)
        self.assertIs(shape['canEditLine'], True)
        self.assertIs(shape['textDetails']['canReplace'], True)
        self.assertIs(shape['textDetails']['canStyle'], True)
        self.assertEqual(shape['textDetails']['protectedRanges'], [])
        self.assertEqual(len(shape['textDetails']['runs']), 1)
        self.assertEqual(shape['textDetails']['runs'][0]['fontFamily'], '맑은 고딕')
        self.assertIs(shape['textDetails']['runs'][0]['bold'], True)
        for name in ('string', 'cursor', 'rich'):
            self.assertGreater(fixture.ordinary.reads[name], 0, name)


if __name__ == '__main__':
    unittest.main()
