"""Writer image preservation contracts at the current WordDocument boundary.

Native Frame/reference/range APIs mirror properties2 observations. Only the
external GraphicProvider/stream is doubled; production hashing is not patched.
Run with windows/office_engine on PYTHONPATH. Root alone executes these tests.
"""
import copy
from types import SimpleNamespace
import unittest

from office_word_layout import WordDocument
from test_word_fidelity import FormattedParagraph, FormattedPortion, field
from test_word_owners import Enumeration, Text
from test_word_page_geometry import model, operation


PAYLOAD = b'\x89PNG\r\n\x1a\n' + b'A' * (1024 * 1024 + 19)


def enum(type_name, value):
    return SimpleNamespace(typeName=type_name, value=value)


def native(value):
    return value.target if isinstance(value, Proxy) else value


class Proxy:
    """Separate Python wrappers refer to one native object by equality."""
    def __init__(self, target):
        self.target = target

    def __getattr__(self, name):
        return getattr(self.target, name)

    def __eq__(self, other):
        return self.target is native(other)


class Range:
    String = ''

    def __init__(self, owner, offset, accepted=True):
        self.owner, self.offset, self.accepted = owner, offset, accepted
        self.Start = self.End = self

    def getText(self):
        return self.owner


class NativeText(Text):
    def createTextCursorByRange(self, value):
        if value.getText() is not self or not value.accepted:
            raise ValueError('Controlled range is not accepted by this native owner')
        return Range(self, value.Start.offset)

    def compareRegionStarts(self, left, right):
        self.createTextCursorByRange(left)
        self.createTextCursorByRange(right)
        return (left.offset < right.offset) - (left.offset > right.offset)


class NativeCollection:
    def __init__(self, values=()):
        self.entries = list(values)
        self.unreadable = False

    @property
    def ElementNames(self):
        if self.unreadable:
            raise RuntimeError('Controlled native collection enumeration failure')
        return tuple(name for name, _ in self.entries)

    def getByName(self, name):
        for key, value in self.entries:
            if key == name:
                return Proxy(value)
        raise KeyError(name)


class DrawPage:
    def __init__(self, values=()):
        self.values = list(values)
        self.unreadable = False

    @property
    def Count(self):
        if self.unreadable:
            raise RuntimeError('Controlled native drawing enumeration failure')
        return len(self.values)

    def getByIndex(self, index):
        return Proxy(self.values[index])


class Stream:
    def __init__(self):
        self.payload, self.position = bytearray(), 0
        self.input_closed = self.output_closed = False
        self.RemoveFile = False

    def getOutputStream(self):
        return self

    def getInputStream(self):
        return self

    def writeBytes(self, payload):
        self.payload.extend(bytes(payload))

    def getLength(self):
        return len(self.payload)

    def seek(self, position):
        self.position = position

    def readBytes(self, unused, requested):
        result = bytes(self.payload[self.position:self.position + requested])
        self.position += len(result)
        return len(result), result

    def closeInput(self):
        self.input_closed = True

    def closeOutput(self):
        self.output_closed = True


class GraphicProvider:
    def storeGraphic(self, graphic, arguments):
        values = {item.Name: item.Value for item in arguments}
        if values['MimeType'] != graphic.MimeType:
            raise ValueError('Controlled export requested a different encoding')
        values['OutputStream'].writeBytes(graphic.payload)


class ServiceManager:
    def __init__(self):
        self.streams = []

    def createInstanceWithContext(self, name, context):
        if name == 'com.sun.star.io.TempFile':
            stream = Stream()
            self.streams.append(stream)
            return stream
        if name == 'com.sun.star.graphic.GraphicProvider':
            return GraphicProvider()
        raise ValueError('Unexpected controlled native service: ' + name)


class Image:
    def __init__(self, owner, offset, index):
        self.anchor = Range(owner, offset)
        self.name = 'SAME AUTHORED IMAGE NAME'
        self.Graphic = SimpleNamespace(MimeType='image/png',
            SizePixel=SimpleNamespace(Width=37, Height=29),
            Size100thMM=SimpleNamespace(Width=0, Height=0), payload=PAYLOAD)
        self.properties = {
            'AnchorType': enum('com.sun.star.text.TextContentAnchorType',
                'AS_CHARACTER' if index == 0 else 'AT_CHARACTER'),
            'Graphic': self.Graphic, 'Width': 2701, 'Height': 1900,
            'Size': SimpleNamespace(Width=2701, Height=1900),
            'RelativeWidth': 0, 'RelativeHeight': 0,
            'HoriOrient': 0, 'HoriOrientPosition': 1270, 'HoriOrientRelation': 0,
            'VertOrient': 0, 'VertOrientPosition': 2, 'VertOrientRelation': 0,
            'Surround': enum('com.sun.star.text.WrapTextMode', 'DYNAMIC'),
            'Opaque': True, 'IsFollowingTextFlow': False,
            'LeftMargin': 0, 'RightMargin': 0, 'TopMargin': 0, 'BottomMargin': 0,
            'FrameStyleName': 'Graphics',
            'FillStyle': enum('com.sun.star.drawing.FillStyle', 'NONE'),
            'FillColor': 7512015, 'LineStyle': None, 'LineWidth': None,
            'ZOrder': index,
            'GraphicCrop': SimpleNamespace(Top=0, Bottom=0, Left=0, Right=0),
            'GraphicFilter': '', 'BackColor': -1, 'BackTransparent': True,
            'SurroundAnchorOnly': False, 'IsAutomaticContour': False, 'AllowOverlap': True,
            'SurroundContour': False, 'Transparency': 0, 'Visible': True,
            'GraphicRotation': 0, 'AdjustRed': 0, 'Gamma': 1.0, 'VertMirrored': False,
        }

    def getName(self):
        return self.name

    def getPropertySetInfo(self):
        return SimpleNamespace(hasPropertyByName=lambda name: name in self.properties)

    def getPropertyValue(self, name):
        return self.properties[name]

    def getAnchor(self):
        return self.anchor

    def getSupportedServiceNames(self):
        return ('com.sun.star.text.BaseFrame', 'com.sun.star.text.TextContent',
            'com.sun.star.document.LinkTarget', 'com.sun.star.text.TextGraphicObject')

    def supportsService(self, name):
        return name in self.getSupportedServiceNames()

    def getShapeType(self):
        return 'FrameShape'


class Frame(FormattedPortion):
    def __init__(self, owner, offset, image):
        super().__init__('', 'Frame')
        self.Start = self.End = Range(owner, offset)
        self.references = [image]
        self.unreadable = False

    def getText(self):
        return self.Start.getText()

    def createContentEnumeration(self, service):
        if service != 'com.sun.star.text.TextContent':
            raise ValueError('Unexpected content enumeration service')
        if self.unreadable:
            raise RuntimeError('Controlled Frame content enumeration failure')
        return Enumeration([Proxy(image) for image in self.references])


def prop(name, value):
    return SimpleNamespace(Name=name, Value=value)


def image_model(cache='6', count=2, include_frames=True):
    original, styles, events = model(names=('A',))
    document = original.document
    text = NativeText()
    images, frames = [], []
    portions = [FormattedPortion('PRE='), FormattedPortion(cache, 'TextField', field('NUMPAGES'))]
    offset = 4 + len(cache.encode('utf-16-le')) // 2
    for index in range(count):
        image = Image(text, offset, index)
        frame = Frame(text, offset, image)
        images.append(image)
        frames.append(frame)
        if include_frames:
            portions.append(frame)
        portions.append(FormattedPortion('AFTER'))
        offset += 5
    paragraph = FormattedParagraph('A', portions)
    paragraph.Start, paragraph.End = Range(text, 0), Range(text, offset)
    text.values = [paragraph]
    document.Text = text
    document.DrawPage = DrawPage(images)
    document.getDrawPage = lambda: document.DrawPage
    document.GraphicObjects = NativeCollection([('Alias ' + str(index), image)
        for index, image in enumerate(images)])
    document.TextFrames = NativeCollection()
    document.EmbeddedObjects = NativeCollection()
    context = SimpleNamespace(ServiceManager=ServiceManager())
    word = WordDocument(document, {'paragraph-0': paragraph}, {}, SimpleNamespace(), prop)
    # This attaches the real constructor dependency without relying on a new
    # signature before the parent authorizes the worker/context route.
    word.context = context
    return SimpleNamespace(word=word, document=document, text=text, paragraph=paragraph,
        images=images, frames=frames, styles=styles, events=events, context=context)


class WordImagesContractTest(unittest.TestCase):
    def test_export_bindings_are_native_ephemeral_and_do_not_change_ids_or_semantics(self):
        fixture = image_model()
        before_ids = set(fixture.word.used_ids)
        expected = fixture.word.verification_state()
        bindings = fixture.word.export_bindings
        tokens = [item[1] for item in expected['body'][0][1]['portions'] if item[0] == 'object']
        self.assertEqual(len(bindings), 2)
        for binding, image, frame in zip(bindings, fixture.images, fixture.frames):
            self.assertEqual(binding['image'], image)
            self.assertIs(binding['text'], fixture.text)
            self.assertIs(binding['portion'], frame)
            self.assertIs(binding['token'], tokens[fixture.images.index(image)])
        self.assertEqual(fixture.word.verification_state(), expected)
        self.assertEqual(set(fixture.word.used_ids), before_ids)
        self.assertNotIn('export_bindings', expected)

    def test_geometry_accepts_verified_frame_images_with_complete_native_payload(self):
        fixture = image_model()
        fixture.word.geometry(operation(fixture.word, leftMargin=0))
        self.assertTrue(fixture.word.has_geometry)
        self.assertEqual(fixture.paragraph.String, 'PRE=6AFTERAFTER')

    def test_reopen_accepts_new_native_wrappers_and_reordered_collection_aliases(self):
        before = image_model()
        expected = before.word.verification_state()
        reopened = image_model()
        reopened.document.DrawPage.values.reverse()
        reopened.document.GraphicObjects.entries = [('Renamed alias B', reopened.images[1]),
            ('Renamed alias A', reopened.images[0])]
        reopened.word.verify_reopened(expected)

    def test_reopen_accepts_field_cache_length_change_before_image_anchor(self):
        before = image_model(cache='6')
        expected = before.word.verification_state()
        reopened = image_model(cache='123456')
        self.assertNotEqual(before.frames[0].Start.offset, reopened.frames[0].Start.offset)
        reopened.word.verify_reopened(expected)

    def test_distinct_images_with_equal_names_and_bytes_cannot_collapse_to_one_frame(self):
        before = image_model()
        self.assertEqual(before.images[0].getName(), before.images[1].getName())
        self.assertEqual(before.images[0].Graphic.payload, before.images[1].Graphic.payload)
        self.assertIsNot(before.images[0], before.images[1])
        expected = before.word.verification_state()
        reopened = image_model(count=1)
        # Retain the same strings so only the missing native object differs.
        reopened.paragraph.portions.append(FormattedPortion('AFTER'))
        with self.assertRaises(ValueError):
            reopened.word.verify_reopened(expected)

    def test_reopen_rejects_changed_payload_byte_beyond_first_megabyte(self):
        before = image_model()
        expected = before.word.verification_state()
        reopened = image_model()
        reopened.images[0].Graphic.payload = PAYLOAD[:-1] + b'B'
        with self.assertRaises(ValueError):
            reopened.word.verify_reopened(expected)

    def test_reopen_rejects_changed_crop_size_wrap_or_manual_position(self):
        changes = [('GraphicCrop', SimpleNamespace(Top=0, Bottom=0, Left=20, Right=0)),
            ('Width', 2800), ('Height', 2000),
            ('Surround', enum('com.sun.star.text.WrapTextMode', 'NONE')),
            ('HoriOrientPosition', 2540), ('VertOrientPosition', 1270),
            ('AnchorType', enum('com.sun.star.text.TextContentAnchorType', 'AT_PARAGRAPH'))]
        for name, changed in changes:
            with self.subTest(property=name):
                before = image_model()
                expected = before.word.verification_state()
                reopened = image_model()
                reopened.images[0].properties[name] = copy.deepcopy(changed)
                with self.assertRaises(ValueError):
                    reopened.word.verify_reopened(expected)

    def test_geometry_rejects_wrong_native_anchor_owner_before_any_setter(self):
        fixture = image_model()
        fixture.images[0].anchor.owner = NativeText()
        with self.assertRaises(ValueError):
            fixture.word.geometry(operation(fixture.word, leftMargin=0))
        self.assertFalse(any(event[0] == 'set' for event in fixture.events))

    def test_geometry_rejects_unaccepted_native_anchor_or_portion_range(self):
        for target in ('anchor', 'portion'):
            with self.subTest(range=target):
                fixture = image_model()
                value = fixture.images[0].anchor if target == 'anchor' else fixture.frames[0].Start
                value.accepted = False
                with self.assertRaises(ValueError):
                    fixture.word.geometry(operation(fixture.word, leftMargin=0))
                self.assertFalse(any(event[0] == 'set' for event in fixture.events))

    def test_geometry_rejects_anchor_position_different_from_structural_frame_range(self):
        fixture = image_model()
        fixture.images[0].anchor.offset += 1
        with self.assertRaises(ValueError):
            fixture.word.geometry(operation(fixture.word, leftMargin=0))
        self.assertFalse(any(event[0] == 'set' for event in fixture.events))

    def test_geometry_rejects_missing_multiple_or_unreadable_frame_references(self):
        for state in ('missing', 'multiple', 'unreadable'):
            with self.subTest(state=state):
                fixture = image_model()
                frame = fixture.frames[0]
                if state == 'missing':
                    frame.references = []
                elif state == 'multiple':
                    frame.references = fixture.images
                else:
                    frame.unreadable = True
                with self.assertRaises(ValueError):
                    fixture.word.geometry(operation(fixture.word, leftMargin=0))
                self.assertFalse(any(event[0] == 'set' for event in fixture.events))

    def test_geometry_rejects_same_native_object_referenced_from_two_frame_tokens(self):
        fixture = image_model()
        duplicate = Frame(fixture.text, fixture.frames[0].Start.offset, fixture.images[0])
        fixture.paragraph.portions.insert(3, duplicate)
        with self.assertRaises(ValueError):
            fixture.word.geometry(operation(fixture.word, leftMargin=0))
        self.assertFalse(any(event[0] == 'set' for event in fixture.events))

    def test_geometry_rejects_native_object_inventory_orphan_without_any_frame_tokens(self):
        for collection in ('DrawPage', 'GraphicObjects', 'TextFrames', 'EmbeddedObjects'):
            with self.subTest(collection=collection):
                fixture = image_model(count=1, include_frames=False)
                fixture.document.DrawPage.values.clear()
                fixture.document.GraphicObjects.entries.clear()
                if collection == 'DrawPage':
                    fixture.document.DrawPage.values.append(fixture.images[0])
                else:
                    getattr(fixture.document, collection).entries.append(('Orphan', fixture.images[0]))
                with self.assertRaises(ValueError):
                    fixture.word.geometry(operation(fixture.word, leftMargin=0))
                self.assertFalse(any(event[0] == 'set' for event in fixture.events))

    def test_geometry_rejects_extra_native_object_with_same_name_and_payload(self):
        fixture = image_model()
        extra = Image(fixture.text, fixture.images[0].anchor.offset, 0)
        fixture.document.DrawPage.values.append(extra)
        fixture.document.GraphicObjects.entries.append(('Extra alias', extra))
        with self.assertRaises(ValueError):
            fixture.word.geometry(operation(fixture.word, leftMargin=0))
        self.assertFalse(any(event[0] == 'set' for event in fixture.events))

    def test_geometry_rejects_reference_missing_from_all_native_inventories(self):
        fixture = image_model()
        fixture.document.DrawPage.values.remove(fixture.images[0])
        fixture.document.GraphicObjects.entries = [('Remaining', fixture.images[1])]
        with self.assertRaises(ValueError):
            fixture.word.geometry(operation(fixture.word, leftMargin=0))
        self.assertFalse(any(event[0] == 'set' for event in fixture.events))

    def test_geometry_rejects_unreadable_native_object_inventory(self):
        for collection in ('DrawPage', 'GraphicObjects', 'TextFrames', 'EmbeddedObjects'):
            with self.subTest(collection=collection):
                fixture = image_model(count=0)
                getattr(fixture.document, collection).unreadable = True
                with self.assertRaises(ValueError):
                    fixture.word.geometry(operation(fixture.word, leftMargin=0))
                self.assertFalse(any(event[0] == 'set' for event in fixture.events))

    def test_native_aliases_deduplicate_without_duplicate_object_occurrence(self):
        fixture = image_model()
        fixture.document.GraphicObjects.entries.append(('Another native alias', fixture.images[0]))
        self.assertIsNot(fixture.document.DrawPage.getByIndex(0),
            fixture.document.GraphicObjects.getByName('Another native alias'))
        fixture.word.geometry(operation(fixture.word, leftMargin=0))
        self.assertTrue(fixture.word.has_geometry)

    def test_geometry_rejects_object_text_owner_cycle(self):
        fixture = image_model()
        fixture.images[0].Text = fixture.text
        with self.assertRaises(ValueError):
            fixture.word.geometry(operation(fixture.word, leftMargin=0))
        self.assertFalse(any(event[0] == 'set' for event in fixture.events))

    def test_reopen_accepts_center_position_reflow_with_mode_and_relation_preserved(self):
        before = image_model()
        before.images[1].properties.update(HoriOrient=2, HoriOrientPosition=7151)
        expected = before.word.verification_state()
        reopened = image_model()
        reopened.images[1].properties.update(HoriOrient=2, HoriOrientPosition=11331)
        reopened.word.verify_reopened(expected)

    def test_reopen_rejects_center_mode_or_relation_change(self):
        for name, changed in [('HoriOrient', 0), ('HoriOrientRelation', 1)]:
            with self.subTest(property=name):
                before = image_model()
                before.images[1].properties.update(HoriOrient=2, HoriOrientPosition=7151)
                expected = before.word.verification_state()
                reopened = image_model()
                reopened.images[1].properties.update(HoriOrient=2, HoriOrientPosition=11331)
                reopened.images[1].properties[name] = changed
                with self.assertRaises(ValueError):
                    reopened.word.verify_reopened(expected)

    def test_computed_position_getter_failure_rejects_before_geometry_setter(self):
        fixture = image_model()
        image = fixture.images[1]
        image.properties['HoriOrient'] = 2
        original = image.getPropertyValue

        def unreadable(name):
            if name == 'HoriOrientPosition':
                raise RuntimeError('Controlled computed-position getter failure')
            return original(name)

        image.getPropertyValue = unreadable
        with self.assertRaises(ValueError):
            fixture.word.geometry(operation(fixture.word, leftMargin=0))
        self.assertFalse(any(event[0] == 'set' for event in fixture.events))

    def test_reopen_rejects_image_appearance_loss_with_unchanged_native_payload(self):
        for name, changed in [('Transparency', 50), ('Visible', False), ('GraphicRotation', 900),
                ('AdjustRed', 10), ('Gamma', 1.2), ('VertMirrored', True)]:
            with self.subTest(property=name):
                before = image_model()
                expected = before.word.verification_state()
                reopened = image_model()
                reopened.images[0].properties[name] = changed
                with self.assertRaises(ValueError):
                    reopened.word.verify_reopened(expected)

    def test_reopen_distinguishes_void_false_and_zero_image_values(self):
        for original, changed in [(None, False), (False, 0), (0, None)]:
            with self.subTest(original=original, changed=changed):
                before = image_model()
                before.images[0].properties['Visible'] = original
                expected = before.word.verification_state()
                reopened = image_model()
                reopened.images[0].properties['Visible'] = changed
                with self.assertRaises(ValueError):
                    reopened.word.verify_reopened(expected)

    def test_inline_anchor_end_need_not_equal_frame_end(self):
        fixture = image_model()
        fixture.images[0].anchor.End = Range(fixture.text, fixture.frames[0].End.offset + 1)
        self.assertNotEqual(fixture.text.compareRegionStarts(
            fixture.images[0].anchor.End, fixture.frames[0].End), 0)
        fixture.word.geometry(operation(fixture.word, leftMargin=0))
        self.assertTrue(fixture.word.has_geometry)

    def test_repeated_verification_does_not_allocate_document_ids_or_change_scopes(self):
        fixture = image_model()
        counters = copy.deepcopy(fixture.word._counters)
        identifiers = set(fixture.word.used_ids)
        scopes = dict(fixture.word.scopes)
        expected = fixture.word.verification_state()
        self.assertEqual(fixture.word.verification_state(), expected)
        self.assertEqual(fixture.word._counters, counters)
        self.assertEqual(fixture.word.used_ids, identifiers)
        self.assertEqual(fixture.word.scopes, scopes)

    def test_native_payload_streams_close_after_successful_hashing(self):
        fixture = image_model()
        fixture.word.geometry(operation(fixture.word, leftMargin=0))
        streams = fixture.context.ServiceManager.streams
        self.assertTrue(streams)
        self.assertTrue(all(stream.input_closed and stream.output_closed for stream in streams))

    def test_native_payload_streams_close_when_graphic_provider_raises(self):
        class FailingProvider(GraphicProvider):
            def storeGraphic(self, graphic, arguments):
                super().storeGraphic(graphic, arguments)
                raise RuntimeError('Controlled native image export failure')

        fixture = image_model()
        manager = fixture.context.ServiceManager
        original = manager.createInstanceWithContext

        def create(name, context):
            return FailingProvider() if name == 'com.sun.star.graphic.GraphicProvider' else original(name, context)

        manager.createInstanceWithContext = create
        with self.assertRaises(ValueError):
            fixture.word.geometry(operation(fixture.word, leftMargin=0))
        self.assertFalse(any(event[0] == 'set' for event in fixture.events))
        self.assertTrue(manager.streams)
        self.assertTrue(all(stream.input_closed and stream.output_closed for stream in manager.streams))

    def test_missing_native_inventory_is_not_treated_as_empty(self):
        for collection in ('DrawPage', 'GraphicObjects', 'TextFrames', 'EmbeddedObjects'):
            with self.subTest(collection=collection):
                fixture = image_model(count=0)
                delattr(fixture.document, collection)
                with self.assertRaises(ValueError):
                    fixture.word.geometry(operation(fixture.word, leftMargin=0))
                self.assertFalse(any(event[0] == 'set' for event in fixture.events))

    def test_missing_context_rejects_native_image_before_geometry_setter(self):
        fixture = image_model()
        fixture.word.context = None
        with self.assertRaises(ValueError):
            fixture.word.geometry(operation(fixture.word, leftMargin=0))
        self.assertFalse(any(event[0] == 'set' for event in fixture.events))


if __name__ == '__main__':
    unittest.main()
