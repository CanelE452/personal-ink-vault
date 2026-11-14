"""Geometry validation/registry invariants; not a substitute for Native evidence."""
import copy
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import office_worker as worker
from office_word_layout import WordDocument, geometry_values, layout_hash, millimetres, normalized_hmm, raw_layout
from test_word_owners import Element, Family, Style, Text


BASE = {'Width': 21001, 'Height': 29700, 'IsLandscape': False,
    'LeftMargin': 1799, 'RightMargin': 1799, 'TopMargin': 1799, 'BottomMargin': 1799,
    'HeaderIsOn': False, 'FooterIsOn': False, 'HeaderIsShared': True,
    'FooterIsShared': True, 'FirstIsShared': True, 'PageStyleLayout': 'ALL'}


class Portion(Style):
    def __init__(self, text, kind='Text', field=None):
        super().__init__({'TextPortionType': kind, 'TextField': field})
        self.String = text


class Paragraph(Element):
    def __init__(self, style, portions=None):
        super().__init__('Paragraph')
        self.style = style
        self.portions = portions or [Portion('PRESERVED')]

    def getPropertyValue(self, name):
        return self.style if name == 'PageStyleName' else None

    def createEnumeration(self):
        return Text(self.portions).createEnumeration()


class GeometryStyle(Style):
    def __init__(self, events):
        super().__init__(copy.deepcopy(BASE))
        self.events, self.readonly, self.missing, self.used, self.clamp = events, set(), set(), True, False

    def isInUse(self):
        return self.used

    def getPropertySetInfo(self):
        return SimpleNamespace(hasPropertyByName=lambda name: name not in self.missing,
            getPropertyByName=lambda name: SimpleNamespace(Attributes=16 if name in self.readonly else 0))

    def setPropertyValue(self, name, value):
        self.events.append(('set', name, value))
        observed = {0: 0, 63: 64, 190: 191, 21000: 21001, 21001: 21001,
            29700: 29700, 1800: 1799, 2540: 2540, 2000: 2000, 2100: 2101}
        self.properties[name] = value if name == 'IsLandscape' else observed.get(value, value) + int(self.clamp)


class Wrapper:
    """Deliberately creates a different Python wrapper for each family getter."""
    def __init__(self, value):
        self.value = value

    def __getattr__(self, name):
        return getattr(self.value, name)


class GeometryFamily(Family):
    def hasByName(self, name):
        return name in self.styles

    def getByName(self, name):
        return Wrapper(self.styles[name])


def model(names=('A', 'B'), url='file:///controlled.docx'):
    events = []
    values = {name: GeometryStyle(events) for name in names}
    body = Text([Paragraph(name) for name in names])
    family = GeometryFamily(values)

    class Controller:
        @property
        def PageCount(self):
            events.append(('layout-page-count',))
            return 6

    native = SimpleNamespace(Text=body, StyleFamilies=Family({'PageStyles': family}),
        getURL=lambda: url, TextFields=SimpleNamespace(refresh=lambda: events.append(('field-refresh',))),
        CurrentController=Controller(), DrawPage=SimpleNamespace(Count=0),
        GraphicObjects=Family({}), TextFrames=Family({}), EmbeddedObjects=Family({}))
    word = WordDocument(native, {'paragraph-' + str(index): value for index, value in enumerate(body.values)}, {}, None, None)
    return word, values, events


def operation(word, index=0, **values):
    row = word.page_styles[index]
    return {'op': 'pageGeometry', 'id': row['id'], 'expectedLayoutSha256': row['layoutSha256'], **values}


class WordPageGeometryTest(unittest.TestCase):
    def test_half_up_integer_chain_matches_observed_ties_and_dimensions(self):
        for requested, observed in [(63, 64), (190, 191), (21000, 21001), (21002, 21003),
                (29701, 29700), (14800, 14801), (33333, 33332), (22222, 22221), (2540, 2540), (0, 0)]:
            with self.subTest(requested=requested):
                self.assertEqual(normalized_hmm(requested), observed)
        for value in [True, None, float('nan'), float('inf'), -1, 1000.01, 1.001]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                millimetres(value)
        self.assertEqual(millimetres(25.4), 2540)
        self.assertEqual(millimetres(0), 0)

    def test_margin_only_preserves_omitted_raw_values_and_rejects_invalid_final_geometry(self):
        assigned, expected = geometry_values({'op': 'pageGeometry', 'leftMargin': 0}, BASE)
        self.assertEqual(assigned, {'LeftMargin': 0})
        self.assertEqual(expected, {**BASE, 'LeftMargin': 0})
        for values in [{'landscape': True}, {'width': 297}, {'leftMargin': None}, {'leftMargin': True},
                {'width': 210, 'height': 210, 'landscape': False},
                {'width': 210, 'height': 297, 'landscape': True},
                {'width': 0, 'height': 297, 'landscape': False},
                {'leftMargin': 200, 'rightMargin': 200}, {'headerIsOn': False}, {}, {'leftMargin': 1.001}]:
            with self.subTest(values=values), self.assertRaises(ValueError):
                geometry_values({'op': 'pageGeometry', **values}, BASE)

    def test_equal_hash_distinct_styles_keep_target_identity_with_nonidentical_wrappers(self):
        word, styles, events = model()
        self.assertEqual(word.page_styles[0]['layoutSha256'], word.page_styles[1]['layoutSha256'])
        word.geometry(operation(word, 1, leftMargin=0))
        self.assertEqual(styles['A'].properties, BASE)
        self.assertEqual(styles['B'].properties, {**BASE, 'LeftMargin': 0})
        self.assertEqual(events[-3:], [('field-refresh',), ('layout-page-count',), ('field-refresh',)])
        self.assertTrue(word.has_geometry)
        self.assertEqual(word.page_styles[1]['layoutSha256'], layout_hash(styles['B'].properties))

    def test_stale_second_hash_and_unknown_id_reject_before_another_setter(self):
        word, _, events = model()
        first = operation(word, leftMargin=0.63)
        word.geometry(first)
        setters = [event for event in events if event[0] == 'set']
        for invalid in [first, dict(first, id='paragraph-0'), dict(first, id='body')]:
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                word.geometry(invalid)
        self.assertEqual([event for event in events if event[0] == 'set'], setters)

    def test_unexpected_native_clamp_is_not_a_blanket_one_hmm_tolerance(self):
        word, styles, _ = model()
        styles['A'].clamp = True
        with self.assertRaisesRegex(ValueError, 'readback'):
            word.geometry(operation(word, leftMargin=0.63))
        self.assertFalse(word.has_geometry)

    def test_geometry_rejects_semantic_content_loss_during_native_layout_refresh(self):
        preserved, _, _ = model()
        before = preserved.verification_state()
        preserved.geometry(operation(preserved, leftMargin=0))
        after = preserved.verification_state()
        self.assertEqual(after['body'], before['body'])
        self.assertEqual(after['ownersByReferences'], before['ownersByReferences'])
        damaged, _, events = model()

        def actual_refresh_drops_authored_text():
            events.append(('field-refresh',))
            damaged.document.Text.values[0].portions[0].String = 'AUTHORED_CONTENT_LOST'

        damaged.document.TextFields.refresh = actual_refresh_drops_authored_text
        with self.assertRaisesRegex(ValueError, 'content'):
            damaged.geometry(operation(damaged, leftMargin=0))

    def test_capability_requires_known_writable_used_body_binding_and_confirmed_format(self):
        word, styles, _ = model()
        identifier = word.page_styles[0]['id']
        self.assertIs(word.can_edit_geometry(identifier), True)
        styles['A'].readonly.add('Width')
        self.assertIs(word.can_edit_geometry(identifier), False)
        styles['A'].readonly.clear()
        styles['A'].missing.add('TopMargin')
        self.assertIs(word.can_edit_geometry(identifier), False)
        styles['A'].missing.clear()
        styles['A'].properties['Width'] = None
        self.assertIsNone(word.can_edit_geometry(identifier))
        styles['A'].properties['Width'] = BASE['Width']
        styles['A'].used = False
        self.assertIs(word.can_edit_geometry(identifier), False)
        styles['A'].used = True
        word.document.Text.values[0].style = 'UNVERIFIABLE'
        self.assertIsNone(word.can_edit_geometry(identifier))
        other, _, _ = model(url='file:///unverified.odt')
        self.assertIs(other.can_edit_geometry(other.page_styles[0]['id']), False)

    def test_reopen_correspondence_uses_body_usage_groups_across_style_renames(self):
        before, _, _ = model()
        before.geometry(operation(before, leftMargin=0))
        expected = before.verification_state()
        after, styles, _ = model(names=('RENAMED_B', 'RENAMED_A'))
        styles['RENAMED_B'].properties['LeftMargin'] = 0
        after.verify_reopened(expected)
        after.document.Text.values[1].style = 'RENAMED_B'
        with self.assertRaisesRegex(ValueError, 'binding'):
            after.verify_reopened(expected)

    def test_authored_text_and_field_commands_are_protected_while_field_caches_can_change(self):
        def field(command):
            return SimpleNamespace(getPresentation=lambda _command: command,
                getSupportedServiceNames=lambda: ('com.sun.star.text.TextField.PageCount',))

        before, _, _ = model()
        before.document.Text.values[0].portions = [Portion('TOTAL='), Portion('6', 'TextField', field('NUMPAGES'))]
        expected = before.verification_state()
        after, _, _ = model()
        after.document.Text.values[0].portions = [Portion('TOTAL='), Portion('12', 'TextField', field('NUMPAGES'))]
        after.verify_reopened(expected)
        after.document.Text.values[0].portions[1] = Portion('12', 'TextField', field('PAGE'))
        with self.assertRaises(ValueError):
            after.verify_reopened(expected)

    def test_request_requires_source_hash_and_verified_docx_before_starting_office(self):
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'source.docx'
            source.write_bytes(b'Guard-only controlled input')
            request = {'mode': 'apply', 'sourcePath': str(source), 'sessionId': 'guard',
                'operations': [{'op': 'pageGeometry', 'id': 'style', 'leftMargin': 0}]}
            with patch.object(worker, 'OfficeServer', side_effect=AssertionError('Guard started Office')):
                for expected in (None, '0' * 64):
                    with self.subTest(expected=expected), self.assertRaises(ValueError):
                        worker.run_request(root, {**request, 'expectedSourceSha256': expected}, root / 'unused')
                unsupported = root / 'source.odt'
                unsupported.write_bytes(source.read_bytes())
                with self.assertRaises(ValueError):
                    worker.run_request(root, {**request, 'sourcePath': str(unsupported),
                        'expectedSourceSha256': worker.digest(unsupported)}, root / 'unsupported')


if __name__ == '__main__':
    unittest.main()
