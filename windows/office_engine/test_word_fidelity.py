"""Formatting preservation contracts; native round-trip evidence is separate.

Run with windows/office_engine on PYTHONPATH. This file deliberately uses the
existing geometry model so the real geometry and reopen guards are exercised.
"""
import copy
from types import SimpleNamespace
import unittest

from test_word_page_geometry import Paragraph, Portion, model, operation
from office_word_layout import WordDocument
from test_word_owners import Element, Text


CHARACTER = {
    'CharColor': 0x1B4F72,
    'CharWeight': 150.0,
    'CharFontName': 'Liberation Serif',
    'CharHeight': 12.0,
}
PARAGRAPH = {
    'ParaAdjust': 3,
    'ParaTopMargin': 240,
    'ParaBottomMargin': 120,
    'ParaLeftMargin': 400,
    'ParaRightMargin': 200,
    'ParaFirstLineIndent': -100,
    'ParaLineSpacing': SimpleNamespace(Mode=0, Height=125),
}
CHARACTER_LOSS = (
    ('CharColor', 0),
    ('CharWeight', 100.0),
    ('CharFontName', 'Liberation Sans'),
    ('CharHeight', 10.0),
)
PARAGRAPH_LOSS = (
    ('ParaAdjust', 0),
    ('ParaTopMargin', 0),
    ('ParaBottomMargin', 0),
    ('ParaLeftMargin', 0),
    ('ParaRightMargin', 0),
    ('ParaFirstLineIndent', 0),
    ('ParaLineSpacing', SimpleNamespace(Mode=0, Height=100)),
)


class FormattedPortion(Portion):
    def __init__(self, text, kind='Text', field=None, **properties):
        super().__init__(text, kind, field)
        self.properties.update(copy.deepcopy(CHARACTER))
        self.properties.update(properties)


class FormattedParagraph(Paragraph):
    def __init__(self, style, portions):
        super().__init__(style, portions)
        self.portions = portions
        self.properties = copy.deepcopy({**CHARACTER, **PARAGRAPH})

    @property
    def String(self):
        return ''.join(portion.String for portion in self.portions)

    def getPropertyValue(self, name):
        if name == 'PageStyleName':
            return self.style
        return self.properties.get(name)


def formatted_model(portions=None):
    word, styles, events = model(names=('A',))
    paragraph = FormattedParagraph('A', [FormattedPortion('PRESERVED')] if portions is None else portions)
    word.document.Text.values[0] = paragraph
    word.body.paragraphs['paragraph-0'] = paragraph
    return word, paragraph, styles, events


def field(command):
    return SimpleNamespace(getPresentation=lambda _command: command,
        getSupportedServiceNames=lambda: ('com.sun.star.text.TextField.PageCount',))


def bookmark_portions(include_empty_text=False):
    bookmark = SimpleNamespace(Name='PRESERVED_BOOKMARK')
    portions = [FormattedPortion('', 'Bookmark', Bookmark=bookmark, IsStart=True)]
    if include_empty_text:
        portions.append(FormattedPortion(''))
    portions.append(FormattedPortion('', 'Bookmark', Bookmark=bookmark, IsStart=False))
    return portions


def formatted_graph_model():
    word, paragraph, styles, events = formatted_model()
    cell_paragraph = FormattedParagraph('A', [FormattedPortion('CELL')])
    header_paragraph = FormattedParagraph('A', [FormattedPortion('HEADER')])
    cell = SimpleNamespace(Text=Text([cell_paragraph]))
    table = Element('TextTable', 'table-0')
    table.CellNames = ('A1',)
    table.getCellByName = lambda name: cell if name == 'A1' else None
    word.document.Text.values.append(table)
    header = Text([header_paragraph])
    styles['A'].properties.update(HeaderText=header, HeaderTextRight=header)
    rebound = WordDocument(word.document, {'paragraph-0': paragraph}, {'table-0': table}, None, None)
    return rebound, cell_paragraph, header_paragraph, events


class WordFidelityContractTest(unittest.TestCase):
    def test_geometry_rejects_character_format_loss_with_unchanged_authored_text(self):
        for name, lost in CHARACTER_LOSS:
            with self.subTest(property=name):
                word, paragraph, _, _ = formatted_model()

                def refresh():
                    paragraph.portions[0].properties[name] = lost

                word.document.TextFields.refresh = refresh
                with self.assertRaises(ValueError):
                    word.geometry(operation(word, leftMargin=0))
                self.assertEqual(paragraph.String, 'PRESERVED')
                self.assertFalse(word.has_geometry)

    def test_geometry_rejects_paragraph_format_loss_with_unchanged_authored_text(self):
        for name, lost in PARAGRAPH_LOSS:
            with self.subTest(property=name):
                word, paragraph, _, _ = formatted_model()

                def refresh():
                    paragraph.properties[name] = copy.deepcopy(lost)

                word.document.TextFields.refresh = refresh
                with self.assertRaises(ValueError):
                    word.geometry(operation(word, leftMargin=0))
                self.assertEqual(paragraph.String, 'PRESERVED')
                self.assertFalse(word.has_geometry)

    def test_reopen_rejects_character_format_loss_with_unchanged_authored_text(self):
        for name, lost in CHARACTER_LOSS:
            with self.subTest(property=name):
                before, _, _, _ = formatted_model()
                before.geometry(operation(before, leftMargin=0))
                expected = before.verification_state()
                reopened, paragraph, styles, _ = formatted_model()
                styles['A'].properties['LeftMargin'] = 0
                paragraph.portions[0].properties[name] = lost
                self.assertEqual(paragraph.String, 'PRESERVED')
                with self.assertRaises(ValueError):
                    reopened.verify_reopened(expected)

    def test_reopen_rejects_paragraph_format_loss_with_unchanged_authored_text(self):
        for name, lost in PARAGRAPH_LOSS:
            with self.subTest(property=name):
                before, _, _, _ = formatted_model()
                before.geometry(operation(before, leftMargin=0))
                expected = before.verification_state()
                reopened, paragraph, styles, _ = formatted_model()
                styles['A'].properties['LeftMargin'] = 0
                paragraph.properties[name] = copy.deepcopy(lost)
                self.assertEqual(paragraph.String, 'PRESERVED')
                with self.assertRaises(ValueError):
                    reopened.verify_reopened(expected)

    def test_reopen_accepts_equivalent_split_and_merged_text_portions(self):
        for before_texts, after_texts in [(['PRESERVED'], ['PRE', 'SERVED']),
                (['PRE', 'SERVED'], ['PRESERVED'])]:
            with self.subTest(before=before_texts):
                before, _, _, _ = formatted_model([FormattedPortion(text) for text in before_texts])
                expected = before.verification_state()
                reopened, _, _, _ = formatted_model([FormattedPortion(text) for text in after_texts])
                reopened.verify_reopened(expected)

    def test_geometry_accepts_equivalent_text_portion_split_during_refresh(self):
        word, paragraph, _, _ = formatted_model()

        def refresh():
            paragraph.portions = [FormattedPortion('PRE'), FormattedPortion('SERVED')]

        word.document.TextFields.refresh = refresh
        word.geometry(operation(word, leftMargin=0))
        self.assertTrue(word.has_geometry)
        self.assertEqual(paragraph.String, 'PRESERVED')

    def test_reopen_rejects_run_boundary_format_shift_even_when_text_and_styles_remain(self):
        before, _, _, _ = formatted_model([
            FormattedPortion('AB', CharWeight=150.0), FormattedPortion('CD', CharWeight=100.0)])
        expected = before.verification_state()
        reopened, paragraph, _, _ = formatted_model([
            FormattedPortion('A', CharWeight=150.0), FormattedPortion('BCD', CharWeight=100.0)])
        self.assertEqual(paragraph.String, 'ABCD')
        with self.assertRaises(ValueError):
            reopened.verify_reopened(expected)

    def test_reopen_rejects_empty_paragraph_character_format_loss(self):
        before, _, _, _ = formatted_model([FormattedPortion('')])
        expected = before.verification_state()
        reopened, paragraph, _, _ = formatted_model([FormattedPortion('', CharFontName='Liberation Sans')])
        self.assertEqual(paragraph.String, '')
        with self.assertRaises(ValueError):
            reopened.verify_reopened(expected)

    def test_reopen_rejects_empty_paragraph_spacing_loss(self):
        before, _, _, _ = formatted_model([FormattedPortion('')])
        expected = before.verification_state()
        reopened, paragraph, _, _ = formatted_model([FormattedPortion('')])
        paragraph.properties['ParaBottomMargin'] = 0
        self.assertEqual(paragraph.String, '')
        with self.assertRaises(ValueError):
            reopened.verify_reopened(expected)

    def test_reopen_allows_field_cache_change_with_same_command_and_formatting(self):
        before, _, _, _ = formatted_model([
            FormattedPortion('TOTAL='), FormattedPortion('6', 'TextField', field('NUMPAGES'))])
        expected = before.verification_state()
        reopened, paragraph, _, _ = formatted_model([
            FormattedPortion('TOTAL='), FormattedPortion('12', 'TextField', field('NUMPAGES'))])
        self.assertEqual(paragraph.String, 'TOTAL=12')
        reopened.verify_reopened(expected)

    def test_reopen_rejects_field_format_loss_even_when_cache_is_allowed_to_change(self):
        before, _, _, _ = formatted_model([
            FormattedPortion('TOTAL='), FormattedPortion('6', 'TextField', field('NUMPAGES'))])
        expected = before.verification_state()
        reopened, _, _, _ = formatted_model([
            FormattedPortion('TOTAL='),
            FormattedPortion('12', 'TextField', field('NUMPAGES'), CharColor=0)])
        with self.assertRaises(ValueError):
            reopened.verify_reopened(expected)

    def test_reopen_rejects_changed_field_command_despite_same_cache_and_formatting(self):
        before, _, _, _ = formatted_model([FormattedPortion('6', 'TextField', field('NUMPAGES'))])
        expected = before.verification_state()
        reopened, _, _, _ = formatted_model([FormattedPortion('6', 'TextField', field('PAGE'))])
        with self.assertRaises(ValueError):
            reopened.verify_reopened(expected)

    def test_reopen_distinguishes_void_false_and_zero_character_values(self):
        for original, changed in [(None, False), (False, 0), (0, None)]:
            with self.subTest(original=original, changed=changed):
                before, paragraph, _, _ = formatted_model()
                paragraph.portions[0].properties['CharHidden'] = original
                expected = before.verification_state()
                reopened, paragraph, _, _ = formatted_model()
                paragraph.portions[0].properties['CharHidden'] = changed
                with self.assertRaises(ValueError):
                    reopened.verify_reopened(expected)

    def test_unreadable_advertised_character_property_rejects_before_geometry_setter(self):
        class UnreadablePortion(FormattedPortion):
            def getPropertySetInfo(self):
                return SimpleNamespace(hasPropertyByName=lambda name: True)

            def getPropertyValue(self, name):
                if name == 'CharWeight':
                    raise RuntimeError('Controlled native getter failure')
                return super().getPropertyValue(name)

        word, _, _, events = formatted_model([UnreadablePortion('PRESERVED')])
        with self.assertRaisesRegex(ValueError, 'CharWeight'):
            word.geometry(operation(word, leftMargin=0))
        self.assertFalse(any(event[0] == 'set' for event in events))
        self.assertFalse(word.has_geometry)

    def test_reopen_distinguishes_absent_property_from_advertised_void(self):
        class DescribedPortion(FormattedPortion):
            def __init__(self, present):
                super().__init__('PRESERVED', CharHidden=None)
                self.present = present

            def getPropertySetInfo(self):
                return SimpleNamespace(hasPropertyByName=lambda name: name != 'CharHidden' or self.present)

        before, _, _, _ = formatted_model([DescribedPortion(False)])
        expected = before.verification_state()
        reopened, _, _, _ = formatted_model([DescribedPortion(True)])
        with self.assertRaises(ValueError):
            reopened.verify_reopened(expected)

    def test_geometry_rejects_format_loss_in_shared_native_header_owner(self):
        word, _, header, _ = formatted_graph_model()

        def refresh():
            header.portions[0].properties['CharColor'] = 0

        word.document.TextFields.refresh = refresh
        with self.assertRaises(ValueError):
            word.geometry(operation(word, leftMargin=0))
        self.assertEqual(header.String, 'HEADER')
        self.assertEqual(len(word.owners), 1)
        self.assertFalse(word.has_geometry)

    def test_reopen_rejects_paragraph_spacing_loss_inside_table_cell(self):
        before, _, _, _ = formatted_graph_model()
        expected = before.verification_state()
        reopened, cell, _, _ = formatted_graph_model()
        cell.properties['ParaBottomMargin'] = 0
        with self.assertRaises(ValueError):
            reopened.verify_reopened(expected)
        self.assertEqual(cell.String, 'CELL')

    def test_reopen_accepts_equal_table_and_header_formats_with_new_native_owners(self):
        before, _, _, _ = formatted_graph_model()
        expected = before.verification_state()
        reopened, _, _, _ = formatted_graph_model()
        reopened.verify_reopened(expected)

    def test_geometry_rejects_default_character_loss_in_bookmark_only_empty_paragraph(self):
        for name, lost in [('CharHeight', 10.0), ('CharFontName', 'Liberation Sans')]:
            with self.subTest(property=name):
                word, paragraph, _, _ = formatted_model(bookmark_portions())

                def refresh():
                    paragraph.properties[name] = lost

                word.document.TextFields.refresh = refresh
                with self.assertRaises(ValueError):
                    word.geometry(operation(word, leftMargin=0))
                self.assertEqual(paragraph.String, '')
                self.assertFalse(word.has_geometry)

    def test_reopen_rejects_default_character_loss_in_bookmark_and_empty_text_paragraph(self):
        for name, lost in [('CharHeight', 10.0), ('CharFontName', 'Liberation Sans')]:
            with self.subTest(property=name):
                before, _, _, _ = formatted_model(bookmark_portions(include_empty_text=True))
                expected = before.verification_state()
                reopened, paragraph, _, _ = formatted_model(bookmark_portions(include_empty_text=True))
                paragraph.properties[name] = lost
                self.assertEqual(paragraph.String, '')
                with self.assertRaises(ValueError):
                    reopened.verify_reopened(expected)

    def test_reopen_allows_empty_field_cache_to_change_without_empty_paragraph_false_positive(self):
        for before_cache, after_cache in [('', '12'), ('12', '')]:
            with self.subTest(before=before_cache, after=after_cache):
                before, _, _, _ = formatted_model([
                    FormattedPortion(before_cache, 'TextField', field('NUMPAGES'))])
                expected = before.verification_state()
                reopened, _, _, _ = formatted_model([
                    FormattedPortion(after_cache, 'TextField', field('NUMPAGES'))])
                reopened.verify_reopened(expected)

    def test_reopen_allows_only_paragraph_style_name_change_without_mutating_raw_states(self):
        before, paragraph, _, _ = formatted_model()
        paragraph.properties['ParaStyleName'] = 'Table Contents'
        expected = before.verification_state()
        expected_copy = copy.deepcopy(expected)
        reopened, paragraph, _, _ = formatted_model()
        paragraph.properties['ParaStyleName'] = '표 내용'
        actual = reopened.verification_state()
        actual_copy = copy.deepcopy(actual)
        self.assertNotEqual(actual, expected)
        reopened.verify_reopened(expected)
        self.assertEqual(expected, expected_copy)
        self.assertEqual(reopened.verification_state(), actual_copy)

    def test_geometry_rejects_live_paragraph_style_name_change(self):
        word, paragraph, _, _ = formatted_model()
        paragraph.properties['ParaStyleName'] = 'Original Custom Style'

        def refresh():
            paragraph.properties['ParaStyleName'] = 'Changed Custom Style'

        word.document.TextFields.refresh = refresh
        with self.assertRaises(ValueError):
            word.geometry(operation(word, leftMargin=0))
        self.assertFalse(word.has_geometry)

    def test_reopen_paragraph_style_name_exception_does_not_hide_color_or_spacing_loss(self):
        for name, lost in [('CharColor', 0), ('ParaTopMargin', 0)]:
            with self.subTest(property=name):
                before, paragraph, _, _ = formatted_model()
                paragraph.properties['ParaStyleName'] = 'Table Contents'
                expected = before.verification_state()
                reopened, paragraph, _, _ = formatted_model()
                paragraph.properties['ParaStyleName'] = '표 내용'
                target = paragraph.portions[0] if name == 'CharColor' else paragraph
                target.properties[name] = lost
                with self.assertRaises(ValueError):
                    reopened.verify_reopened(expected)

    def test_reopen_paragraph_style_name_exception_keeps_character_style_name_strict(self):
        before, paragraph, _, _ = formatted_model()
        paragraph.properties['ParaStyleName'] = 'Table Contents'
        paragraph.portions[0].properties['CharStyleName'] = 'Original Character Style'
        expected = before.verification_state()
        reopened, paragraph, _, _ = formatted_model()
        paragraph.properties['ParaStyleName'] = '표 내용'
        paragraph.portions[0].properties['CharStyleName'] = 'Changed Character Style'
        with self.assertRaises(ValueError):
            reopened.verify_reopened(expected)

    def test_reopen_style_name_exception_recurses_through_body_header_and_table_cell(self):
        before, cell, header, _ = formatted_graph_model()
        for paragraph in [before.document.Text.values[0], cell, header]:
            paragraph.properties['ParaStyleName'] = 'Table Contents'
        expected = before.verification_state()
        reopened, cell, header, _ = formatted_graph_model()
        for paragraph in [reopened.document.Text.values[0], cell, header]:
            paragraph.properties['ParaStyleName'] = '표 내용'
        self.assertNotEqual(reopened.verification_state(), expected)
        reopened.verify_reopened(expected)


if __name__ == '__main__':
    unittest.main()
