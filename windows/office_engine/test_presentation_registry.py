"""Pure registry safety examples; fake objects do not establish native behavior."""
import hashlib
import copy
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import office_presentation
import office_text


class Properties:
    def __init__(self, values):
        self.values = values

    def hasPropertyByName(self, name):
        return name in self.values

    def getPropertyByName(self, name):
        return SimpleNamespace(Attributes=0,
            Type=SimpleNamespace(typeName='boolean' if type(self.values[name]) is bool else 'short'))


class Shape:
    def __init__(self, text='', kind='OutlinerShape', presentation=True, empty=True, unknown_text=False, **extra):
        self.text, self.unknown_text = text, unknown_text
        self.ShapeType = 'com.sun.star.presentation.' + kind
        self.values = {'IsPresentationObject': presentation, 'IsEmptyPresentationObject': empty,
            'MoveProtect': False, 'SizeProtect': False, 'CharHeight': 12.0,
            'CharWeight': 100.0, 'CharColor': 0, **extra}

    @property
    def String(self):
        if self.unknown_text:
            raise RuntimeError('Text content is unavailable')
        return self.text

    def getShapeType(self):
        return self.ShapeType

    def getPropertySetInfo(self):
        return Properties(self.values)

    def getPropertyValue(self, name):
        return self.values[name]


class Page:
    def __init__(self, shapes=(), master=None, mutate=None):
        self.shapes, self.master, self.mutate = list(shapes), master, mutate
        self.values = {'Layout': 1, 'Visible': True, 'IsBackgroundObjectsVisible': True}

    @property
    def Count(self):
        return len(self.shapes)

    def getByIndex(self, index):
        return self.shapes[index]

    def getMasterPage(self):
        return self.master

    def getPropertySetInfo(self):
        return Properties(self.values)

    def getPropertyValue(self, name):
        return self.values[name]

    def setPropertyValue(self, name, value):
        self.values[name] = value
        if name == 'Layout' and self.mutate is not None:
            self.mutate(self)


def details(value, **changes):
    text = value.String
    return {'utf16Length': len(text.encode('utf-16-le')) // 2,
        'textSha256': hashlib.sha256(text.encode('utf-8')).hexdigest(),
        'runs': [], 'protectedRanges': [], 'truncated': False,
        'canReplace': True, 'canStyle': True, **changes}


def registry(shape, mutation):
    master = Page()
    page = Page([shape], master, mutation)
    document = SimpleNamespace(MasterPages=Page([master]))
    return office_presentation.Presentation(document, {'slide-0': page}, {'slide-0/shape-0': shape})


def change(deck):
    deck.design({'op': 'slideDesign', 'id': 'slide-0', 'changeId': 'design-1',
        'expectedDesignSha256': office_presentation.design_hash('master-0', 1), 'layoutCode': 20})


def verification_case():
    deck = registry(Shape(text='unchanged', empty=False), lambda page: None)
    with patch.object(office_text, 'text_details', side_effect=details):
        change(deck)
    live = {'kind': 'presentation', 'masters': [{
        'id': 'master-0', 'name': 'Source master', 'width': 280.0, 'height': 157.5,
        'backgroundStyle': 'solid', 'backgroundColor': 0xEEDDEE, 'shapes': [{
            'id': 'master-0/shape-0', 'type': 'com.sun.star.drawing.CustomShape',
            'shapeKind': 'rectangle', 'presentationObject': False, 'text': '',
            'x': 10.0, 'y': 10.0, 'width': 50.0, 'height': 10.0,
            'fillStyle': 'none', 'lineStyle': 'none', 'image': None}]}],
        'slides': [{'id': 'slide-0', 'masterId': 'master-0', 'layoutCode': 20,
            'visible': True, 'showMasterObjects': True}]}
    reopened = copy.deepcopy(live)
    reopened['masters'][0]['id'] = 'canonical-master-9'
    reopened['masters'][0]['name'] = 'Renamed by filter'
    reopened['slides'][0]['masterId'] = 'canonical-master-9'
    return deck, live, reopened


class PresentationRegistryTest(unittest.TestCase):
    def test_empty_flag_cannot_authorize_unknown_or_actual_payload_loss(self):
        cases = [
            ('nonempty', Shape(text='actual content'), {}),
            ('unreadable-text', Shape(unknown_text=True), {}),
            ('field-anchor', Shape(), {'protectedRanges': [{'startUtf16': 0, 'endUtf16': 0, 'type': 'TextField'}]}),
            ('unknown-portion', Shape(), {'truncated': True}),
            ('graphic-on-text', Shape(Graphic=object()), {}),
            ('opaque-ole', Shape(kind='OLE2Shape'), {}),
            ('opaque-group', Shape(kind='GroupShape'), {}),
            ('opaque-custom', Shape(kind='CustomShape'), {}),
            ('ordinary', Shape(presentation=False), {}),
        ]
        for label, shape, modifications in cases:
            with self.subTest(label=label):
                deck = registry(shape, lambda page: page.shapes.clear())
                with patch.object(office_text, 'text_details', side_effect=lambda value, *args, **kw: details(value, **modifications)):
                    with self.assertRaises(ValueError):
                        change(deck)
        deck = registry(Shape(), lambda page: page.shapes.clear())
        with patch.object(office_text, 'text_details', side_effect=RuntimeError('Unknown portions')):
            with self.assertRaises(ValueError):
                change(deck)

    def test_known_empty_text_placeholder_may_retire_even_when_imported_empty_flag_is_false(self):
        for kind in ('TitleTextShape', 'OutlinerShape', 'SubtitleShape'):
            with self.subTest(kind=kind):
                shape = Shape(kind=kind, empty=False)
                deck = registry(shape, lambda page: page.shapes.clear())
                self.assertIs(deck.shape_metadata('slide-0/shape-0')['emptyPresentationObject'], False)
                with patch.object(office_text, 'text_details', side_effect=details):
                    change(deck)
                self.assertNotIn('slide-0/shape-0', deck.shapes)
                self.assertIn('slide-0/shape-0', deck.used)
                self.assertEqual(deck.slide_metadata('slide-0')['layoutCode'], 20)

    def test_surviving_known_text_identity_cannot_silently_change_content(self):
        shape = Shape(text='original text', empty=False)
        deck = registry(shape, lambda page: setattr(shape, 'text', 'replaced text'))
        with patch.object(office_text, 'text_details', side_effect=details):
            with self.assertRaises(ValueError):
                change(deck)

    def test_reopened_design_and_display_are_verified_by_final_slide_order_and_master_content(self):
        shape = Shape(text='unchanged', empty=False)
        deck = registry(shape, lambda page: None)
        master = deck.masters['master-0']
        deck.slides['slide-1'] = Page(master=master)
        deck.physical.append('slide-1')
        deck.logical.append('slide-1')
        with patch.object(office_text, 'text_details', side_effect=details):
            change(deck)
        deck.display({'op': 'slideDisplay', 'id': 'slide-0', 'visible': False, 'showMasterObjects': False})
        deck.logical.reverse()
        master_data = {'id': 'master-0', 'name': 'Original name', 'width': 280.0, 'height': 157.5,
            'backgroundStyle': 'solid', 'backgroundColor': 0xEEDDEE, 'shapes': [{
                'id': 'master-0/shape-0', 'type': 'com.sun.star.drawing.TextShape',
                'presentationObject': False, 'text': 'COMMON', 'x': 10.0, 'y': 10.0,
                'width': 50.0, 'height': 10.0, 'fontSize': 14.0, 'bold': False, 'color': 0,
                'fillStyle': 'none', 'fillColor': None, 'lineStyle': 'none', 'lineColor': None,
                'lineWidth': 0, 'image': None}]}
        live = {'kind': 'presentation', 'masters': [master_data], 'slides': [
            {'id': 'slide-1', 'masterId': 'master-0', 'layoutCode': 1, 'visible': True, 'showMasterObjects': True},
            {'id': 'slide-0', 'masterId': 'master-0', 'layoutCode': 20, 'visible': False, 'showMasterObjects': False}]}
        reopened = copy.deepcopy(live)
        reopened['masters'][0]['id'] = 'canonical-master-9'
        reopened['masters'][0]['name'] = 'Filter-generated name'
        reopened['slides'][0]['id'], reopened['slides'][1]['id'] = 'slide-0', 'slide-1'
        for slide in reopened['slides']:
            slide['masterId'] = 'canonical-master-9'
        deck.verify_reopened(live, reopened)
        for field, value in [('layoutCode', 1), ('visible', True), ('showMasterObjects', True)]:
            with self.subTest(field=field):
                changed = copy.deepcopy(reopened)
                changed['slides'][1][field] = value
                with self.assertRaises(ValueError):
                    deck.verify_reopened(live, changed)
        for field in ('layoutCode', 'visible', 'showMasterObjects'):
            with self.subTest(missing=field):
                changed = copy.deepcopy(reopened)
                changed['slides'][1].pop(field)
                with self.assertRaises(ValueError):
                    deck.verify_reopened(live, changed)
        changed = copy.deepcopy(reopened)
        changed['masters'][0]['shapes'][0]['text'] = 'LOST COMMON'
        with self.assertRaises(ValueError):
            deck.verify_reopened(live, changed)
        changed = copy.deepcopy(reopened)
        changed['masters'][0]['backgroundColor'] = 0
        with self.assertRaises(ValueError):
            deck.verify_reopened(live, changed)
        legacy = registry(Shape(), lambda page: None)
        legacy.verify_reopened({}, {})

    def test_identical_custom_shape_type_cannot_hide_rectangle_to_ellipse_change(self):
        deck, live, reopened = verification_case()
        deck.verify_reopened(live, reopened)
        reopened['masters'][0]['shapes'][0]['shapeKind'] = 'ellipse'
        with self.assertRaises(ValueError):
            deck.verify_reopened(live, reopened)

    def test_geometry_allowance_tracks_one_or_two_explicit_serialization_passes(self):
        for count, delta, rejected in [(1, .01, False), (1, .02, True),
                (2, .02, False), (2, .03, True)]:
            with self.subTest(serialization_count=count, delta=delta):
                deck, live, reopened = verification_case()
                reopened['masters'][0]['shapes'][0]['width'] -= delta
                if rejected:
                    with self.assertRaises(ValueError):
                        deck.verify_reopened(live, reopened, serialization_count=count)
                else:
                    deck.verify_reopened(live, reopened, serialization_count=count)


if __name__ == '__main__':
    unittest.main()
