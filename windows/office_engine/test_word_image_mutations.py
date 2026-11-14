"""Verified empty catalogs and conservative Writer mutation target discovery.

Root alone executes these tests and the separate native mutation evidence.
"""
import copy
from types import SimpleNamespace
import unittest

import office_text
from office_word_layout import WordDocument
from office_word_objects import image_properties
from test_word_fidelity import FormattedParagraph, FormattedPortion, field
from test_word_image_catalog import ASSET, DecoderManager, NEW_NATIVE_BYTES, OpaqueObject, catalog_model
from test_word_images import Frame, Image, NativeText, Range, enum, image_model, native
from test_word_owners import Element


class ReadCursor:
    def __init__(self, owner, start, end=None):
        self.owner = owner
        self.Start = Range(owner, start)
        self.End = Range(owner, start if end is None else end)

    @property
    def String(self):
        return self.owner.String[self.Start.offset:self.End.offset]

    def getText(self):
        return self.owner

    def goRight(self, count, select):
        end = self.End.offset + count
        if end > len(self.owner.String):
            return False
        self.End = Range(self.owner, end)
        if not select:
            self.Start = self.End
        return True

    def gotoRange(self, value, select):
        self.owner.createTextCursorByRange(value)
        self.End = Range(self.owner, value.Start.offset)
        if not select:
            self.Start = self.End


class ReadOwner(NativeText):
    @property
    def String(self):
        return '\n'.join(value.String for value in self.values
            if value.supportsService('com.sun.star.text.Paragraph'))

    def createTextCursorByRange(self, value):
        for boundary in (value.Start, value.End):
            if boundary.getText() != self or not boundary.accepted:
                raise ValueError('Controlled range belongs to another text owner')
        return ReadCursor(self, value.Start.offset, value.End.offset)


def plain_paragraph(owner, text):
    portion = FormattedPortion(text)
    portion.Start, portion.End = Range(owner, 0), Range(owner, len(text))
    portion.getText = lambda: owner
    paragraph = FormattedParagraph('A', [portion])
    paragraph.Start, paragraph.End = Range(owner, 0), Range(owner, len(text))
    paragraph.getText = lambda: owner
    owner.values.append(paragraph)
    return paragraph


def empty_catalog_model():
    fixture = image_model(count=0)
    fixture.text = ReadOwner()
    fixture.paragraph = plain_paragraph(fixture.text, 'PLAIN BODY')
    fixture.document.Text = fixture.text
    fixture.word = WordDocument(fixture.document,
        {'paragraph-0': fixture.paragraph}, {}, fixture.word.uno,
        fixture.word.prop, context=fixture.context)
    return fixture


class WordImageMutationDiscoveryTest(unittest.TestCase):
    def test_verified_empty_source_has_add_targets_and_keeps_empty_bindings(self):
        fixture = empty_catalog_model()
        before = copy.deepcopy(fixture.word.verification_state())
        catalog = fixture.word.image_catalog()
        self.assertIsNotNone(catalog)
        self.assertEqual(catalog.source_bindings, [])
        self.assertEqual(catalog.snapshot([0]), [])
        self.assertEqual(catalog.snapshot_targets(), [{'ownerId': 'body',
            'paragraphId': 'paragraph-0', 'canAdd': True, 'canMoveHere': True}])
        self.assertEqual(fixture.word.verification_state(), before)
        self.assertFalse(any(event[0] == 'set' for event in fixture.events))

    def test_unknown_catalog_is_not_a_verified_empty_mutation_capability(self):
        for reason in ('context', 'format', 'inventory'):
            with self.subTest(reason=reason):
                fixture = empty_catalog_model()
                if reason == 'context':
                    fixture.word.context = None
                elif reason == 'format':
                    fixture.word.geometry_format = 'odt'
                else:
                    fixture.document.DrawPage.unreadable = True
                catalog = fixture.word.image_catalog()
                if catalog is not None:
                    self.assertIsNone(catalog.source_bindings)
                    self.assertIsNone(catalog.snapshot_targets())
                self.assertFalse(fixture.word.requires_reopen_verification())

    def test_frame_owner_or_inventory_gaps_keep_all_mutation_capabilities_unknown(self):
        for reason in ('unknown-frame', 'duplicate-frame', 'owner', 'orphan', 'missing-frame'):
            with self.subTest(reason=reason):
                fixture = catalog_model()
                if reason == 'unknown-frame':
                    fixture.frames[0].references = [OpaqueObject(fixture.text, 5)]
                elif reason == 'duplicate-frame':
                    fixture.frames[1].references = [fixture.images[0]]
                elif reason == 'owner':
                    fixture.images[0].anchor.owner = NativeText()
                elif reason == 'orphan':
                    fixture.document.DrawPage.values.append(Image(fixture.text, 999, 2))
                else:
                    fixture.paragraph.portions.remove(fixture.frames[0])
                catalog = fixture.word.image_catalog()
                self.assertIsNotNone(catalog)
                self.assertIsNone(catalog.source_bindings)
                self.assertIsNone(catalog.snapshot_targets())
                for row in catalog.snapshot([0]):
                    self.assertIs(row['canMove'], False)
                    self.assertIs(row['canDelete'], False)
                    self.assertIsNone(row['offsetUtf16'])
                self.assertFalse(any(event[0] == 'set' for event in fixture.events))

    def test_targets_are_only_registered_body_paragraphs_not_headers_or_table_cells(self):
        fixture = empty_catalog_model()
        header, cell = ReadOwner(), ReadOwner()
        plain_paragraph(header, 'PLAIN BODY')
        plain_paragraph(cell, 'PLAIN BODY')
        fixture.styles['A'].properties['HeaderText'] = header
        table = Element('TextTable', 'table-0')
        table.CellNames = ('A1',)
        table.getCellByName = lambda name: SimpleNamespace(Text=cell)
        fixture.text.values.append(table)
        fixture.word = WordDocument(fixture.document,
            {'paragraph-0': fixture.paragraph}, {'table-0': table},
            fixture.word.uno, fixture.word.prop, context=fixture.context)
        self.assertTrue(fixture.word.owners)
        catalog = fixture.word.image_catalog()
        self.assertEqual(catalog.source_bindings, [])
        self.assertEqual(catalog.snapshot_targets(), [{'ownerId': 'body',
            'paragraphId': 'paragraph-0', 'canAdd': True, 'canMoveHere': True}])

    def test_protected_body_section_never_advertises_a_mutation_target(self):
        fixture = empty_catalog_model()
        fixture.paragraph.properties['TextSection'] = SimpleNamespace(IsProtected=True)
        catalog = fixture.word.image_catalog()
        self.assertEqual(catalog.source_bindings, [])
        self.assertEqual(catalog.snapshot_targets(), [{'ownerId': 'body',
            'paragraphId': 'paragraph-0', 'canAdd': False, 'canMoveHere': False}])

    def test_source_image_rows_do_not_claim_raw_state_mutation_support(self):
        fixture = catalog_model()
        catalog = fixture.word.image_catalog()
        rows = catalog.snapshot([0])
        self.assertTrue(all(row['image']['canReplace'] for row in rows))
        for row in rows:
            self.assertIs(row['canMove'], False)
            self.assertIs(row['canDelete'], False)
            self.assertIn('offsetUtf16', row)
            self.assertTrue(row['offsetUtf16'] is None or type(row['offsetUtf16']) is int)

    def test_as_character_offset_requires_its_actual_native_paragraph_prefix(self):
        fixture = empty_catalog_model()
        image = Image(fixture.text, len(fixture.paragraph.String), 0)
        fixture.paragraph.portions.append(Frame(fixture.text, image.anchor.offset, image))
        fixture.document.DrawPage.values.append(image)
        fixture.document.GraphicObjects.entries.append(('Actual source image', image))
        catalog = fixture.word.image_catalog()
        self.assertEqual(catalog.snapshot([0])[0]['offsetUtf16'], len('PLAIN BODY'))
        fixture.paragraph.Start.accepted = False
        self.assertIsNone(catalog.snapshot([0])[0]['offsetUtf16'])

    def test_verified_empty_source_rejects_unapproved_inventory_growth_and_keeps_reopen_sticky(self):
        fixture = empty_catalog_model()
        catalog = fixture.word.image_catalog()
        self.assertEqual(catalog.source_bindings, [])
        self.assertTrue(fixture.word.requires_reopen_verification())
        image = Image(fixture.text, len(fixture.paragraph.String), 0)
        fixture.paragraph.portions.append(Frame(fixture.text, image.anchor.offset, image))
        fixture.document.DrawPage.values.append(image)
        fixture.document.GraphicObjects.entries.append(('Unauthorized image', image))
        with self.assertRaises(ValueError):
            fixture.word.verification_state()
        self.assertTrue(fixture.word.requires_reopen_verification())
        self.assertIsNone(catalog.snapshot_targets())


class MutationImage(Image):
    def __init__(self, owner, offset=0, index=0):
        super().__init__(owner, offset, 0)
        self.properties.update(Name='Authored name', Title='Authored title', Description='Authored description',
            HyperLinkURL='https://example.invalid/source', HyperLinkTarget='_blank', HyperLinkName='Source link')
        self.properties.update(BorderDistance=0, BottomBorderDistance=0, LeftBorderDistance=0,
            RightBorderDistance=0, TopBorderDistance=0)
        for name in ('BottomBorder', 'LeftBorder', 'RightBorder', 'TopBorder'):
            self.properties[name] = SimpleNamespace(Color=0, InnerLineWidth=0, OuterLineWidth=0, LineDistance=0)
        self.properties['ZOrder'] = index
        self.defaults = copy.deepcopy(self.properties)
        self.states = {name: 'DEFAULT_VALUE' if value is None else 'DIRECT_VALUE'
            for name, value in self.properties.items()}
        self.attributes = {name: 0 for name in self.properties}
        self.type_names = {name: 'controlled:' + type(value).__name__ for name, value in self.properties.items()}
        self.fail_default = False
        self.default_state_drift = False

    def getPropertySetInfo(self):
        return SimpleNamespace(hasPropertyByName=lambda name: name in self.properties,
            getPropertyByName=lambda name: SimpleNamespace(Attributes=self.attributes[name],
                Type=SimpleNamespace(typeName=self.type_names[name])))

    def getPropertyState(self, name):
        return enum('com.sun.star.beans.PropertyState', self.states[name])

    def setPropertyToDefault(self, name):
        if self.fail_default:
            raise ValueError('Controlled DEFAULT setter failure')
        self.properties[name] = copy.deepcopy(self.defaults[name])
        self.states[name] = 'DIRECT_VALUE' if self.default_state_drift else 'DEFAULT_VALUE'

    def setPropertyValue(self, name, value):
        if self.attributes.get(name, 0) & 16:
            raise ValueError('Controlled readonly native property')
        self.properties[name] = value
        self.states[name] = 'DIRECT_VALUE'
        if name == 'Graphic':
            self.Graphic = value
        elif name in ('Width', 'Height'):
            setattr(self.properties['Size'], name, value)

    def getName(self):
        return self.properties['Name']

    def setName(self, value):
        self.setPropertyValue('Name', value)


class MutationCursor(ReadCursor):
    @property
    def String(self):
        return self.owner.native_string[self.Start.offset:self.End.offset].replace('\ufffc', '')

    def goRight(self, count, select):
        end = self.End.offset + count
        if end > len(self.owner.native_string):
            return False
        self.End = self.owner.track(end)
        if not select:
            self.Start = self.End
        return True

    def gotoRange(self, value, select):
        self.owner.createTextCursorByRange(value)
        self.End = self.owner.track(value.Start.offset)
        if not select:
            self.Start = self.End


class MutationOwner(ReadOwner):
    def __init__(self, fixture):
        super().__init__()
        self.fixture, self.ranges = fixture, []
        self.insertions, self.removals = [], []
        self.on_insert = None
        self.suppress_insert = False

    @property
    def native_string(self):
        return '\n'.join(''.join('\ufffc' if portion.properties['TextPortionType'] == 'Frame'
            else portion.String for portion in paragraph.portions) for paragraph in self.values)

    def track(self, offset):
        value = Range(self, offset)
        self.ranges.append(value)
        return value

    def createTextCursorByRange(self, value):
        for boundary in (value.Start, value.End):
            if boundary.getText() != self or not boundary.accepted:
                raise ValueError('Controlled native range is not in its actual owner')
        result = MutationCursor(self, value.Start.offset, value.End.offset)
        result.Start, result.End = self.track(value.Start.offset), self.track(value.End.offset)
        return result

    def reindex(self):
        offset = 0
        for paragraph in self.values:
            paragraph.Start = Range(self, offset)
            for portion in paragraph.portions:
                portion.Start = Range(self, offset)
                portion.getText = lambda: self
                if portion.properties['TextPortionType'] == 'Frame':
                    image = native(portion.references[0])
                    image.anchor = Range(self, offset)
                    offset += 1
                else:
                    offset += len(portion.String)
                portion.End = Range(self, offset)
            paragraph.End = Range(self, offset)
            offset += 1

    def insertTextContent(self, cursor, descriptor, absorb):
        if absorb is not False:
            raise AssertionError('A photo insertion must not absorb authored text')
        if self.suppress_insert:
            return
        point = cursor.Start.offset
        actual = MutationImage(self, point, len(self.fixture.document.DrawPage.values))
        actual.properties = copy.deepcopy(descriptor.properties)
        actual.states = dict(descriptor.states)
        actual.Graphic = actual.properties['Graphic']
        actual.properties['ZOrder'] = len(self.fixture.document.DrawPage.values)
        for paragraph in self.values:
            for index, portion in enumerate(paragraph.portions):
                if portion.properties['TextPortionType'] == 'Text' and portion.Start.offset <= point <= portion.End.offset:
                    prefix, suffix = portion.String[:point - portion.Start.offset], portion.String[point - portion.Start.offset:]
                    fragments = []
                    for text in (prefix, suffix):
                        fragment = copy.copy(portion)
                        fragment.properties = copy.deepcopy(portion.properties)
                        fragment.String = text
                        fragments.append(fragment)
                    paragraph.portions[index:index + 1] = [fragments[0], Frame(self, point, actual), fragments[1]]
                    for value in self.ranges:
                        if value.offset >= point:
                            value.offset += 1
                    self.fixture.document.DrawPage.values.append(actual)
                    self.fixture.document.GraphicObjects.entries.append(('alias-' + str(len(self.insertions)), actual))
                    self.insertions.append((descriptor, actual))
                    self.reindex()
                    if self.on_insert is not None:
                        self.on_insert(descriptor, actual)
                    return
        raise ValueError('Controlled target is not a plain text run')

    def removeTextContent(self, image):
        image = native(image)
        for paragraph in self.values:
            for portion in list(paragraph.portions):
                if portion.properties['TextPortionType'] == 'Frame' and native(portion.references[0]) is image:
                    point = portion.Start.offset
                    paragraph.portions.remove(portion)
                    self.fixture.document.DrawPage.values.remove(image)
                    self.fixture.document.GraphicObjects.entries[:] = [row for row in
                        self.fixture.document.GraphicObjects.entries if native(row[1]) is not image]
                    for survivor in self.fixture.document.DrawPage.values:
                        if survivor.properties['ZOrder'] > image.properties['ZOrder']:
                            survivor.properties['ZOrder'] -= 1
                    for value in self.ranges:
                        if value.offset > point:
                            value.offset -= 1
                    self.removals.append(image)
                    self.reindex()
                    return
        raise ValueError('Controlled removal is not an actual bound image')


def mutation_model(count=0):
    fixture = image_model(count=0)
    owner = MutationOwner(fixture)
    paragraph = plain_paragraph(owner, 'abcdefghij')
    paragraph.portions += [FormattedPortion('6', 'TextField', field('NUMPAGES')),
        FormattedPortion('TAIL', CharColor=0x112233)]
    fixture.text, fixture.paragraph = owner, paragraph
    fixture.document.Text = owner
    owner.reindex()
    fixture.context.ServiceManager = DecoderManager()
    fixture.word.uno = SimpleNamespace(ByteSequence=lambda payload: bytes(payload), Enum=enum)
    fixture.created = []

    def create(name):
        if name != 'com.sun.star.text.TextGraphicObject':
            raise ValueError('Unexpected controlled native service ' + name)
        descriptor = MutationImage(owner)
        fixture.created.append(descriptor)
        return descriptor

    fixture.document.createInstance = create
    for offset in (2, 7)[:count]:
        owner.insertTextContent(MutationCursor(owner, offset), create('com.sun.star.text.TextGraphicObject'), False)
    owner.insertions.clear()
    fixture.created.clear()
    fixture.word = WordDocument(fixture.document, {'paragraph-0': paragraph}, {},
        fixture.word.uno, fixture.word.prop, context=fixture.context)
    return fixture


def mutation_operation(fixture, op, identifier='fresh-photo', offset=1):
    result = {'op': op, 'id': identifier}
    if op != 'wordImageDelete':
        result.update(ownerId='body', paragraphId='paragraph-0', offsetUtf16=offset,
            expectedTextSha256=office_text.text_hash(fixture.paragraph.String))
    if op == 'wordImageAdd':
        result.update(assetId=ASSET['id'], width=25.4, height=19.05)
    return result


def authored_without_images(state):
    value = copy.deepcopy(state)
    def blocks(items):
        for kind, payload in items:
            if kind == 'table':
                for _, cell in payload:
                    blocks(cell)
            else:
                result = []
                for token in payload['portions']:
                    if token[0] == 'object':
                        continue
                    if token[0] == 'text' and result and result[-1][0] == 'text' and result[-1][2] == token[2]:
                        result[-1][1] += token[1]
                    else:
                        result.append(token)
                payload['portions'] = result
    blocks(value['body'])
    for items in value['ownersByReferences'].values():
        blocks(items)
    return value


def native_unique_clone_name(fixture, source, events, fail_after_retire=False):
    def inserted(descriptor, actual):
        temporary = 'Unique native attached clone'
        has_name_property = 'Name' in source.properties
        if has_name_property:
            actual.properties['Name'] = temporary
            actual.defaults['Name'] = temporary
            actual.states['Name'] = 'DEFAULT_VALUE'
        else:
            actual.properties.pop('Name', None)
            actual.native_name = temporary
            actual.getName = lambda: actual.native_name
        original_set = actual.setPropertyValue
        def set_name(value):
            old_present = source in fixture.document.DrawPage.values
            events.append({'value': value, 'oldPresent': old_present})
            if any(other is not actual and other.getName() == value
                    for other in fixture.document.DrawPage.values):
                raise ValueError('SwXFrame::setName(): Illegal object name. Duplicate name?')
            if fail_after_retire and not old_present:
                raise ValueError('Identified post-retire native Name setter failure')
            if has_name_property:
                state = actual.states['Name']
                original_set('Name', value)
                actual.states['Name'] = state
            else:
                actual.native_name = value
        def set_property(name, value):
            if name == 'Name':
                if not has_name_property:
                    raise ValueError('An absent Name property cannot be invented')
                set_name(value)
                actual.states['Name'] = 'DIRECT_VALUE'
            else:
                original_set(name, value)
        actual.setName = set_name
        actual.setPropertyValue = set_property
    fixture.text.on_insert = inserted


def authored_default_metadata(fixture, source, calls, failure=None):
    for name in ('Title', 'Description'):
        source.states[name] = 'DEFAULT_VALUE'
        source.defaults[name] = ''
    def inserted(descriptor, actual):
        for name in ('Title', 'Description'):
            actual.properties[name] = ''
            actual.defaults[name] = ''
            actual.states[name] = 'DEFAULT_VALUE'
        original_set, original_default = actual.setPropertyValue, actual.setPropertyToDefault
        def set_default(name):
            if name in ('Title', 'Description'):
                calls.append(('default', name))
            return original_default(name)
        def set_value(name, value):
            if name in ('Title', 'Description'):
                calls.append(('value', name, value, source in fixture.document.DrawPage.values))
                if failure == 'api':
                    raise ValueError('Identified authored DEFAULT metadata value setter failure')
            original_set(name, value)
            if name in ('Title', 'Description') and failure != 'state':
                actual.states[name] = 'DEFAULT_VALUE'
        actual.setPropertyToDefault = set_default
        actual.setPropertyValue = set_value
    fixture.text.on_insert = inserted


class WordImageMutationContractTest(unittest.TestCase):
    def test_pre_activation_authored_metadata_drift_is_rejected_before_add_move_or_delete(self):
        for op in ('wordImageAdd', 'wordImageMove', 'wordImageDelete'):
            for field in ('Title', 'Description', 'HyperLinkURL', 'XNamed', 'presence', 'type', 'attributes', 'state'):
                with self.subTest(op=op, field=field):
                    fixture = mutation_model(count=1)
                    source = fixture.document.DrawPage.values[0]
                    catalog = fixture.word.image_catalog()
                    self.assertIsNotNone(catalog.source_raw_bindings)
                    evidence = copy.deepcopy(catalog.source_raw_bindings[0][1])
                    semantic = fixture.word.verification_state()
                    if field == 'XNamed':
                        source.getName = lambda: 'Unapproved native name'
                    elif field == 'presence':
                        del source.properties['Description']
                    elif field == 'type':
                        source.type_names['Title'] = 'changed-native-type'
                    elif field == 'attributes':
                        source.attributes['Title'] = 16
                    elif field == 'state':
                        source.states['Title'] = 'DEFAULT_VALUE'
                    else:
                        source.properties[field] = 'Unapproved authored metadata'
                    self.assertEqual(fixture.word.verification_state(), semantic,
                        'Ordinary semantic validation alone does not cover this metadata counterexample')
                    identifier = 'new-after-drift' if op == 'wordImageAdd' else next(iter(catalog.images))
                    operation = mutation_operation(fixture, op, identifier, offset=8)
                    with self.assertRaises(ValueError):
                        if op == 'wordImageAdd':
                            catalog.add(operation, dict(ASSET))
                        else:
                            getattr(catalog, {'wordImageMove': 'move', 'wordImageDelete': 'delete'}[op])(operation)
                    self.assertEqual(fixture.created, [])
                    self.assertEqual(fixture.text.insertions, [])
                    self.assertEqual(fixture.text.removals, [])
                    self.assertFalse(catalog.image_changed)
                    self.assertEqual(catalog.source_raw_bindings[0][1], evidence)

    def test_pre_activation_guard_keeps_legacy_replace_text_shift_and_computed_positions_supported(self):
        from office_word_image_mutations import raw_image_state
        fixture = mutation_model(count=1)
        source = fixture.document.DrawPage.values[0]
        source.properties.update(HoriOrient=2, VertOrient=1)
        catalog = fixture.word.image_catalog()
        identifier = next(iter(catalog.images))
        evidence = copy.deepcopy(catalog.source_raw_bindings[0][1])
        catalog.replace(identifier, dict(ASSET))
        fixture.paragraph.portions[0].String = 'PREFIX ' + fixture.paragraph.portions[0].String
        fixture.text.reindex()
        source.properties['HoriOrientPosition'] += 99
        source.properties['VertOrientPosition'] += 100
        fixture.word.verification_state()
        self.assertFalse(catalog.raw_active)
        self.assertTrue(catalog.can_mutate())
        expected = raw_image_state(source)
        catalog.move(mutation_operation(fixture, 'wordImageMove', identifier, offset=8))
        actual = native(catalog.images[identifier])
        self.assertEqual(raw_image_state(actual), expected)
        self.assertEqual(actual.Graphic.payload, NEW_NATIVE_BYTES)
        self.assertEqual(catalog.source_raw_bindings[0][1], evidence)
        self.assertNotEqual(expected['HoriOrientPosition'], evidence['HoriOrientPosition'])
        self.assertNotEqual(expected['VertOrientPosition'], evidence['VertOrientPosition'])

    def test_unknown_initial_raw_evidence_cannot_be_retrusted_by_a_later_mutation(self):
        fixture = mutation_model(count=1)
        source = fixture.document.DrawPage.values[0]
        original_get_name = source.getName
        def unavailable_name():
            raise ValueError('Initial native authored name evidence is unavailable')
        source.getName = unavailable_name
        catalog = fixture.word.image_catalog()
        self.assertIsNone(catalog.source_raw_bindings)
        self.assertFalse(catalog.raw_verified)
        source.getName = original_get_name
        fixture.word.verification_state()
        self.assertFalse(catalog.can_mutate())
        self.assertIsNone(catalog.snapshot_targets())
        with self.assertRaises(ValueError):
            catalog.add(mutation_operation(fixture, 'wordImageAdd', 'new-after-unknown', offset=8), dict(ASSET))
        self.assertEqual(fixture.created, [])
        self.assertEqual(fixture.text.insertions, [])
        self.assertEqual(fixture.text.removals, [])

    def test_authored_default_metadata_restores_captured_native_value_without_normalizing_its_state(self):
        from office_word_image_mutations import raw_image_state
        fixture = mutation_model(count=1)
        source = fixture.document.DrawPage.values[0]
        calls = []
        authored_default_metadata(fixture, source, calls)
        expected = raw_image_state(source)
        catalog = fixture.word.image_catalog()
        identifier = next(iter(catalog.images))
        catalog.move(mutation_operation(fixture, 'wordImageMove', identifier, offset=8))
        actual = native(catalog.images[identifier])
        self.assertEqual(raw_image_state(actual), expected)
        for name in ('Title', 'Description'):
            self.assertEqual(source.getPropertyValue(name), expected[name]['value'][1])
            self.assertEqual(actual.getPropertyState(name).value, 'DEFAULT_VALUE')
            default_call = calls.index(('default', name))
            value_call = next(index for index, call in enumerate(calls)
                if call[:3] == ('value', name, expected[name]['value'][1]))
            self.assertLess(default_call, value_call)
            self.assertTrue(calls[value_call][3])

    def test_authored_default_metadata_wrong_state_or_api_failure_never_retires_the_source(self):
        for failure in ('state', 'api'):
            with self.subTest(failure=failure):
                fixture = mutation_model(count=1)
                source = fixture.document.DrawPage.values[0]
                title = source.getPropertyValue('Title')
                calls = []
                authored_default_metadata(fixture, source, calls, failure)
                catalog = fixture.word.image_catalog()
                identifier = next(iter(catalog.images))
                with self.assertRaises(ValueError):
                    catalog.move(mutation_operation(fixture, 'wordImageMove', identifier, offset=8))
                self.assertTrue(any(call[:3] == ('value', 'Title', title) for call in calls))
                self.assertIn(source, fixture.document.DrawPage.values)
                self.assertNotIn(source, fixture.text.removals)
                self.assertIs(native(catalog.images[identifier]), source)
                self.assertEqual(source.getPropertyValue('Title'), title)
                self.assertFalse(catalog.image_changed)

    def test_move_preserves_absent_name_property_and_restores_nonempty_xnamed_only_after_retirement(self):
        from office_word_image_mutations import raw_image_state
        fixture = mutation_model(count=1)
        source = fixture.document.DrawPage.values[0]
        source.native_name = source.properties.pop('Name')
        source.getName = lambda: source.native_name
        expected = raw_image_state(source)
        self.assertEqual(expected['Name'], {'present': False})
        catalog = fixture.word.image_catalog()
        identifier = next(iter(catalog.images))
        events = []
        native_unique_clone_name(fixture, source, events)
        catalog.move(mutation_operation(fixture, 'wordImageMove', identifier, offset=8))
        actual = native(catalog.images[identifier])
        self.assertNotIn('Name', actual.properties)
        self.assertEqual(raw_image_state(actual), expected)
        self.assertTrue(events and all(not event['oldPresent'] for event in events if event['value'] == source.getName()))

    def test_move_defers_only_native_unique_name_until_old_retirement_and_restores_default_state(self):
        from office_word_image_mutations import raw_image_state
        fixture = mutation_model(count=1)
        source = fixture.document.DrawPage.values[0]
        source.states['Name'] = 'DEFAULT_VALUE'
        expected = raw_image_state(source)
        original_name = source.getName()
        catalog = fixture.word.image_catalog()
        identifier = next(iter(catalog.images))
        events = []
        native_unique_clone_name(fixture, source, events)
        catalog.move(mutation_operation(fixture, 'wordImageMove', identifier, offset=8))
        actual = native(catalog.images[identifier])
        self.assertIsNot(actual, source)
        self.assertEqual(source.getName(), original_name)
        self.assertEqual(raw_image_state(actual), expected)
        self.assertEqual(catalog.snapshot([0])[0]['offsetUtf16'], 8)
        self.assertTrue(any(event['value'] == original_name for event in events))
        self.assertTrue(all(not event['oldPresent'] for event in events if event['value'] == original_name))

    def test_post_retire_name_api_failure_never_commits_the_rebound_alias(self):
        fixture = mutation_model(count=1)
        source = fixture.document.DrawPage.values[0]
        source.states['Name'] = 'DEFAULT_VALUE'
        original_name = source.getName()
        catalog = fixture.word.image_catalog()
        identifier = next(iter(catalog.images))
        events = []
        native_unique_clone_name(fixture, source, events, fail_after_retire=True)
        with self.assertRaisesRegex(ValueError, 'Identified post-retire native Name setter failure'):
            catalog.move(mutation_operation(fixture, 'wordImageMove', identifier, offset=8))
        self.assertEqual(source.getName(), original_name)
        self.assertNotIn(source, fixture.document.DrawPage.values)
        self.assertIs(native(catalog.images[identifier]), source)
        self.assertFalse(catalog.image_changed)
        self.assertTrue(events and all(not event['oldPresent'] for event in events if event['value'] == original_name))

    def test_move_binds_actual_inserted_object_before_reading_attachment_only_frame_style(self):
        from office_word_image_mutations import raw_image_state
        fixture = mutation_model(count=1)
        catalog = fixture.word.image_catalog()
        identifier = next(iter(catalog.images))
        original = native(catalog.images[identifier])
        expected = raw_image_state(original)
        create_original = fixture.document.createInstance
        descriptor_style_reads = []
        class UnknownPropertyException(Exception):
            pass
        def create(name):
            descriptor = create_original(name)
            read_original = descriptor.getPropertyValue
            def read(field):
                if field == 'FrameStyleName':
                    descriptor_style_reads.append(field)
                    raise UnknownPropertyException('FrameStyleName is unavailable before native attachment')
                return read_original(field)
            descriptor.getPropertyValue = read
            return descriptor
        fixture.document.createInstance = create
        catalog.move(mutation_operation(fixture, 'wordImageMove', identifier, offset=8))
        actual = native(catalog.images[identifier])
        self.assertIsNot(actual, fixture.created[0])
        self.assertEqual(descriptor_style_reads, [])
        self.assertEqual(raw_image_state(actual), expected)
        self.assertNotIn(original, fixture.document.DrawPage.values)

    def test_target_rejects_surrogate_interior_fields_bookmarks_and_foreign_owner_before_native_creation(self):
        for reason in ('surrogate', 'field', 'bookmark', 'section', 'owner', 'paragraph', 'hash'):
            with self.subTest(reason=reason):
                fixture = mutation_model()
                offset = 1
                if reason == 'surrogate':
                    fixture.paragraph.portions[0].String = 'A😀BCDEFGHIJ'
                    offset = 2
                elif reason == 'field':
                    offset = 10
                elif reason == 'bookmark':
                    original = fixture.paragraph.portions.pop(0)
                    left, right = copy.copy(original), copy.copy(original)
                    left.String, right.String = original.String[:3], original.String[3:]
                    marker = SimpleNamespace(Name='Preserved bookmark')
                    fixture.paragraph.portions[:0] = [left,
                        FormattedPortion('', 'Bookmark', Bookmark=marker, IsStart=True),
                        FormattedPortion('', 'Bookmark', Bookmark=marker, IsStart=False), right]
                    offset = 3
                elif reason == 'section':
                    fixture.paragraph.properties['TextSection'] = SimpleNamespace(IsProtected=True)
                fixture.text.reindex()
                catalog = fixture.word.image_catalog()
                operation = mutation_operation(fixture, 'wordImageAdd', offset=offset)
                if reason == 'owner':
                    operation['ownerId'] = 'header-owner'
                elif reason == 'paragraph':
                    operation['paragraphId'] = 'another-paragraph-with-the-same-text'
                elif reason == 'hash':
                    operation['expectedTextSha256'] = '0' * 64
                with self.assertRaises(ValueError):
                    catalog.add(operation, dict(ASSET))
                self.assertEqual(fixture.created, [])
                self.assertEqual(fixture.text.insertions, [])
                self.assertEqual(fixture.text.removals, [])

    def test_closed_fields_dimensions_and_asset_binding_are_checked_before_native_creation(self):
        for invalid in (0, -1, True, float('nan'), float('inf'), 1000.01, 1.001, '25.4'):
            with self.subTest(width=invalid):
                fixture = mutation_model()
                catalog = fixture.word.image_catalog()
                operation = mutation_operation(fixture, 'wordImageAdd')
                operation['width'] = invalid
                with self.assertRaises(ValueError):
                    catalog.add(operation, dict(ASSET))
                self.assertEqual(fixture.created, [])
        for op in ('wordImageAdd', 'wordImageMove', 'wordImageDelete'):
            with self.subTest(op=op):
                fixture = mutation_model(count=1)
                catalog = fixture.word.image_catalog()
                operation = mutation_operation(fixture, op, next(iter(catalog.images)))
                operation['arbitraryPath'] = '/unsealed/foreign.png'
                with self.assertRaises(ValueError):
                    if op == 'wordImageAdd':
                        catalog.add(operation, dict(ASSET))
                    else:
                        getattr(catalog, {'wordImageMove': 'move', 'wordImageDelete': 'delete'}[op])(operation)
                self.assertEqual(fixture.created, [])
                self.assertEqual(fixture.text.removals, [])
        fixture = mutation_model()
        catalog = fixture.word.image_catalog()
        with self.assertRaises(ValueError):
            catalog.add(mutation_operation(fixture, 'wordImageAdd'), dict(ASSET, id='foreign-sealed-asset'))
        self.assertEqual(fixture.created, [])

    def test_same_paragraph_forward_and_backward_move_check_final_offset_after_old_removal(self):
        from office_word_image_mutations import raw_image_state
        fixture = mutation_model(count=1)
        catalog = fixture.word.image_catalog()
        identifier = next(iter(catalog.images))
        expected_text = authored_without_images(fixture.word.verification_state())
        expected_raw = raw_image_state(native(catalog.images[identifier]))
        for target in (8, 1):
            previous = native(catalog.images[identifier])
            catalog.move(mutation_operation(fixture, 'wordImageMove', identifier, offset=target))
            current = native(catalog.images[identifier])
            self.assertIsNot(current, previous)
            self.assertNotIn(previous, fixture.document.DrawPage.values)
            row = next(row for row in catalog.snapshot([0]) if row['id'] == identifier)
            self.assertEqual(row['offsetUtf16'], target)
            self.assertEqual(raw_image_state(current), expected_raw)
            self.assertEqual(authored_without_images(fixture.word.verification_state()), expected_text)

    def test_clone_side_effect_on_untargeted_run_or_source_metadata_is_not_committed(self):
        for reason in ('run', 'metadata'):
            with self.subTest(reason=reason):
                fixture = mutation_model(count=1)
                catalog = fixture.word.image_catalog()
                identifier = next(iter(catalog.images))
                original = native(catalog.images[identifier])
                if reason == 'run':
                    fixture.text.on_insert = lambda descriptor, actual: fixture.paragraph.portions[-1].properties.update(CharColor=0)
                else:
                    fixture.text.on_insert = lambda descriptor, actual: original.properties.update(Title='Unapproved source metadata')
                with self.assertRaises(ValueError):
                    catalog.move(mutation_operation(fixture, 'wordImageMove', identifier, offset=8))
                self.assertIs(native(catalog.images[identifier]), original)
                self.assertNotIn(original, fixture.text.removals)
                self.assertFalse(catalog.image_changed)

    def test_add_move_replace_delete_retires_the_alias_and_preserves_authored_runs_and_fields(self):
        fixture = mutation_model()
        catalog = fixture.word.image_catalog()
        expected = authored_without_images(fixture.word.verification_state())
        catalog.add(mutation_operation(fixture, 'wordImageAdd'), dict(ASSET))
        first = native(catalog.images['fresh-photo'])
        self.assertIsNot(first, fixture.created[0])
        self.assertIs(first, fixture.text.insertions[0][1])
        self.assertEqual(catalog.source_bindings, [])
        from office_word_image_mutations import raw_image_state
        raw_before_move = raw_image_state(first)
        catalog.move(mutation_operation(fixture, 'wordImageMove', offset=8))
        moved = native(catalog.images['fresh-photo'])
        self.assertIsNot(moved, first)
        self.assertEqual(raw_image_state(moved), raw_before_move)
        self.assertNotIn(first, fixture.document.DrawPage.values)
        self.assertEqual(catalog.snapshot([0])[0]['offsetUtf16'], 8)
        catalog.replace('fresh-photo', dict(ASSET))
        self.assertEqual(moved.Graphic.payload, NEW_NATIVE_BYTES)
        self.assertEqual(authored_without_images(fixture.word.verification_state()), expected)
        catalog.delete(mutation_operation(fixture, 'wordImageDelete'))
        self.assertEqual(catalog.snapshot([0]), [])
        self.assertEqual(fixture.word.export_bindings, [])
        self.assertEqual(authored_without_images(fixture.word.verification_state()), expected)
        self.assertTrue(fixture.word.requires_reopen_verification())
        count = len(fixture.text.insertions)
        with self.assertRaises(ValueError):
            catalog.add(mutation_operation(fixture, 'wordImageAdd'), dict(ASSET))
        self.assertEqual(len(fixture.text.insertions), count)
        with self.assertRaises(ValueError):
            catalog.move(mutation_operation(fixture, 'wordImageMove'))

    def test_same_payload_sources_move_and_delete_only_the_requested_native_identity(self):
        fixture = mutation_model(count=2)
        catalog = fixture.word.image_catalog()
        identifiers = list(catalog.images)
        original = [native(catalog.images[key]) for key in identifiers]
        self.assertEqual(original[0].Graphic.payload, original[1].Graphic.payload)
        metadata = {key: original[0].properties[key] for key in
            ('Name', 'Title', 'Description', 'HyperLinkURL', 'HyperLinkTarget', 'HyperLinkName')}
        catalog.move(mutation_operation(fixture, 'wordImageMove', identifiers[0], offset=9))
        self.assertIs(native(catalog.images[identifiers[1]]), original[1])
        moved = native(catalog.images[identifiers[0]])
        self.assertEqual({key: moved.properties[key] for key in metadata}, metadata)
        self.assertNotIn(original[0], fixture.document.DrawPage.values)
        catalog.delete(mutation_operation(fixture, 'wordImageDelete', identifiers[1]))
        self.assertEqual(list(catalog.images), [identifiers[0]])
        self.assertIs(native(catalog.images[identifiers[0]]), moved)
        fixture.word.verification_state()

    def test_failed_or_ambiguous_actual_insertion_never_retires_the_original(self):
        for reason in ('zero-delta', 'two-delta', 'wrong-frame'):
            with self.subTest(reason=reason):
                fixture = mutation_model(count=1)
                catalog = fixture.word.image_catalog()
                identifier, original = next(iter(catalog.images.items()))
                if reason == 'zero-delta':
                    fixture.text.suppress_insert = True
                elif reason == 'two-delta':
                    fixture.text.on_insert = lambda descriptor, actual: fixture.document.DrawPage.values.append(
                        MutationImage(fixture.text, 999))
                else:
                    fixture.text.on_insert = lambda descriptor, actual: setattr(actual.anchor, 'owner', NativeText())
                with self.assertRaises(ValueError):
                    catalog.move(mutation_operation(fixture, 'wordImageMove', identifier, offset=8))
                self.assertIn(native(original), fixture.document.DrawPage.values)
                self.assertNotIn(native(original), fixture.text.removals)

    def test_raw_state_keeps_computed_positions_property_state_metadata_and_property_information(self):
        from office_word_image_mutations import raw_image_state
        image = MutationImage(NativeText())
        image.properties['HoriOrient'] = 2
        for reason in ('position', 'state', 'title', 'name', 'hyperlink', 'presence', 'attributes', 'type'):
            with self.subTest(reason=reason):
                changed = copy.deepcopy(image)
                before = raw_image_state(image)
                if reason == 'position':
                    changed.properties['HoriOrientPosition'] += 100
                    self.assertEqual(image_properties(image), image_properties(changed))
                elif reason == 'state':
                    changed.states['Width'] = 'DEFAULT_VALUE'
                elif reason in ('title', 'name', 'hyperlink'):
                    changed.properties[{'title': 'Title', 'name': 'Name', 'hyperlink': 'HyperLinkURL'}[reason]] = 'changed'
                elif reason == 'presence':
                    del changed.properties['LineStyle']
                elif reason == 'attributes':
                    changed.attributes['Width'] = 16
                else:
                    changed.type_names['Width'] = 'different-native-type'
                self.assertNotEqual(raw_image_state(changed), before)
                self.assertEqual(raw_image_state(image), before)

    def test_default_state_api_failure_and_final_raw_drift_never_remove_the_original(self):
        for reason in ('default-api', 'raw-drift'):
            with self.subTest(reason=reason):
                fixture = mutation_model(count=1)
                image = fixture.document.DrawPage.values[0]
                image.states['LeftMargin'] = 'DEFAULT_VALUE'
                catalog = fixture.word.image_catalog()
                identifier = next(iter(catalog.images))
                if reason == 'default-api':
                    fixture.text.on_insert = lambda descriptor, actual: setattr(actual, 'fail_default', True)
                else:
                    def drift(descriptor, actual):
                        actual.states['LeftMargin'] = 'DIRECT_VALUE'
                        actual.default_state_drift = True
                    fixture.text.on_insert = drift
                with self.assertRaises(ValueError):
                    catalog.move(mutation_operation(fixture, 'wordImageMove', identifier, offset=8))
                self.assertIn(image, fixture.document.DrawPage.values)
                self.assertNotIn(image, fixture.text.removals)

    def test_replacement_preserves_immutable_source_evidence_and_rejects_later_inventory_changes(self):
        fixture = catalog_model()
        catalog = fixture.word.image_catalog()
        source = copy.deepcopy([row['graphic'] for row in catalog.source_bindings])
        identifier = next(iter(catalog.images))
        catalog.replace(identifier, dict(ASSET))
        self.assertEqual([row['graphic'] for row in catalog.source_bindings], source)
        fixture.word.verification_state()
        fixture.document.DrawPage.values.append(Image(fixture.text, 999, 2))
        with self.assertRaises(ValueError):
            fixture.word.verification_state()

    def test_reopened_word_uses_expected_raw_sidecar_even_before_its_catalog_is_created(self):
        for reason in ('metadata', 'property-state'):
            with self.subTest(reason=reason):
                fixture = mutation_model(count=1)
                catalog = fixture.word.image_catalog()
                identifier = next(iter(catalog.images))
                catalog.move(mutation_operation(fixture, 'wordImageMove', identifier, offset=8))
                expected = fixture.word.reopen_verification_state()
                reopened = WordDocument(fixture.document, {'paragraph-0': fixture.paragraph}, {},
                    fixture.word.uno, fixture.word.prop, context=fixture.context)
                self.assertIsNone(reopened._images)
                reopened.verify_reopened(expected)
                image = native(catalog.images[identifier])
                if reason == 'metadata':
                    image.properties['Title'] = 'Drifted only after serialization'
                else:
                    image.states['LeftMargin'] = ('DEFAULT_VALUE' if image.states['LeftMargin'] == 'DIRECT_VALUE'
                        else 'DIRECT_VALUE')
                with self.assertRaises(ValueError):
                    reopened.verify_reopened(expected)

    def test_last_image_delete_still_requires_independent_empty_reopen_verification(self):
        fixture = mutation_model(count=1)
        catalog = fixture.word.image_catalog()
        catalog.delete(mutation_operation(fixture, 'wordImageDelete', next(iter(catalog.images))))
        expected = fixture.word.reopen_verification_state()
        self.assertEqual(fixture.word.export_bindings, [])
        self.assertTrue(fixture.word.requires_reopen_verification())
        reopened = WordDocument(fixture.document, {'paragraph-0': fixture.paragraph}, {},
            fixture.word.uno, fixture.word.prop, context=fixture.context)
        reopened.verify_reopened(expected)
        fixture.text.insertTextContent(MutationCursor(fixture.text, 1), MutationImage(fixture.text), False)
        with self.assertRaises(ValueError):
            reopened.verify_reopened(expected)


if __name__ == '__main__':
    unittest.main()
