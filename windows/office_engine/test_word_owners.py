"""Registry invariants only; actual native ownership is tested separately."""
import hashlib
import json
from types import SimpleNamespace
import unittest

from office_word_layout import LAYOUT_PROPERTIES, WordDocument, page_metadata


class Enumeration:
    def __init__(self, values):
        self.values, self.index = values, 0

    def hasMoreElements(self):
        return self.index < len(self.values)

    def nextElement(self):
        result = self.values[self.index]
        self.index += 1
        return result


class Text:
    String = 'SAME TEXT'

    def __init__(self, values=()):
        self.values = list(values)

    def createEnumeration(self):
        return Enumeration(self.values)


class Element:
    def __init__(self, kind, name=None):
        self.kind, self.Name = kind, name

    def supportsService(self, name):
        return name == 'com.sun.star.text.' + self.kind


class Style:
    def __init__(self, properties):
        self.properties = properties

    def getPropertyValue(self, name):
        return self.properties.get(name)

    def isInUse(self):
        return False


class Family:
    def __init__(self, styles):
        self.styles, self.ElementNames = styles, tuple(styles)

    def getByName(self, name):
        return self.styles[name]


def document(body, headers=(), tables=None):
    properties = {}
    for suffix, text in headers:
        properties['HeaderText' + suffix] = text
    native = SimpleNamespace(Text=body, StyleFamilies=Family({'PageStyles': Family({'Standard': Style(properties)})}),
        DrawPage=SimpleNamespace(Count=0), GraphicObjects=Family({}), TextFrames=Family({}), EmbeddedObjects=Family({}))
    paragraphs = {'paragraph-' + str(index): value for index, value in enumerate(body.values) if value.kind == 'Paragraph'}
    return WordDocument(native, paragraphs, tables or {}, None, None)


class WordOwnerRegistryTest(unittest.TestCase):
    def test_style_observations_use_getter_even_when_property_state_is_ambiguous(self):
        class AmbiguousStyle(Style):
            def getPropertyState(self, name):
                return SimpleNamespace(value='AMBIGUOUS_VALUE')

        header = Text([Element('Paragraph')])
        style = AmbiguousStyle({'DisplayName': 'Visible style name', 'Width': 21000,
            'LeftMargin': 0, 'HeaderIsOn': False, 'HeaderText': header, 'HeaderTextRight': header,
            'PageStyleLayout': SimpleNamespace(value='ALL')})
        family = Family({'Standard': style})
        native = SimpleNamespace(Text=Text([Element('Paragraph')]), StyleFamilies=Family({'PageStyles': family}))
        word = WordDocument(native, {'paragraph-0': native.Text.values[0]}, {}, None, None)
        row = word.page_styles[0]
        self.assertEqual(row['displayName'], 'Visible style name')
        self.assertEqual(row['width'], 210)
        self.assertEqual(row['leftMargin'], 0)
        self.assertIs(row['headerIsOn'], False)
        self.assertEqual(row['pageLayout'], 'ALL')
        self.assertEqual(len(word.owners), 1)
        self.assertEqual(row['regions']['header']['default'], row['regions']['header']['right'])

    def test_aliases_use_proxy_identity_and_equal_text_keeps_distinct_scopes(self):
        left, right = Text([Element('Paragraph')]), Text([Element('Paragraph')])
        word = document(Text([Element('Paragraph')]), [('', right), ('Right', right), ('Left', left)])
        self.assertEqual(len(word.owners), 2)
        regions = word.page_styles[0]['regions']['header']
        self.assertEqual(regions['default'], regions['right'])
        self.assertNotEqual(regions['default'], regions['left'])
        self.assertEqual(len(word.owners[0]['references']), 2)
        self.assertIsNone(regions['first'])

    def test_generated_ids_avoid_existing_body_tables_and_each_other(self):
        tables = {name: Element('TextTable', name) for name in [
            'word-owner-0', 'word-page-style-0', 'word-paragraph-0', 'word-opaque-0']}
        word = document(Text([Element('Paragraph'), Element('Unknown')]), [('', Text([Element('Paragraph')]))], tables)
        ids = list(tables) + ['body'] + [row['id'] for row in word.page_styles] + [row['id'] for row in word.owners]
        for scope in word.scopes.values():
            ids.extend(row['id'] for row in scope.order if row['kind'] != 'table')
        self.assertEqual(len(ids), len(set(ids)))
        for scope in word.scopes.values():
            self.assertIs(scope.used_ids, word.used_ids)
        header = word.scopes[word.owners[0]['id']]
        for existing in ids:
            with self.assertRaises(ValueError):
                header.new_identity(existing)
        word.body.used_ids.add('deleted-in-body')
        with self.assertRaises(ValueError):
            header.new_identity('deleted-in-body')

    def test_table_association_uses_proxies_not_same_name_or_text(self):
        body_table, header_table, unknown = Element('TextTable', 'same'), Element('TextTable', 'same'), Element('TextTable', 'unknown')
        word = document(Text([body_table, Element('Paragraph')]), [('', Text([header_table, Element('Paragraph')]))],
            {'body-table': body_table, 'header-table': header_table, 'frame-table': unknown})
        self.assertEqual(word.table_owners, {'body-table': 'body', 'header-table': word.owners[0]['id'], 'frame-table': None})

    def test_scope_resolution_uses_membership_and_rejects_cross_owner_join(self):
        word = document(Text([Element('Paragraph')]), [('', Text([Element('Paragraph')]))])
        header = word.scopes[word.owners[0]['id']]
        header.paragraphs['body-looking-id'] = Element('Paragraph')
        self.assertIs(word.paragraph_scope('body-looking-id'), header)
        with self.assertRaisesRegex(ValueError, 'same native text owner'):
            word.apply({'op': 'paragraphJoin', 'id': 'paragraph-0', 'nextId': 'body-looking-id'})
        with self.assertRaises(ValueError):
            word.paragraph_scope('missing')
        for value in (True, False):
            with self.assertRaisesRegex(ValueError, 'page breaks'):
                header.format(None, {'pageBreakBefore': value})

    def test_layout_hash_retains_false_zero_unknown_and_original_enum(self):
        raw = {name: None for name in LAYOUT_PROPERTIES.values()}
        raw.update(Width=21000, Height=29700, LeftMargin=0, HeaderIsOn=False,
            IsLandscape=False, PageStyleLayout='ALL')
        metadata = page_metadata(Style(raw), 'style', 'Standard')
        self.assertEqual(metadata['width'], 210)
        self.assertEqual(metadata['leftMargin'], 0)
        self.assertIs(metadata['headerIsOn'], False)
        self.assertIsNone(metadata['footerIsOn'])
        self.assertEqual(metadata['pageLayout'], 'ALL')
        self.assertEqual(metadata['layoutSha256'], hashlib.sha256(json.dumps(raw,
            sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode('utf-8')).hexdigest())


if __name__ == '__main__':
    unittest.main()
