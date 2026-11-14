"""Native bookmark-preparation contracts; root alone executes this file.

The native graphic export stream is doubled; production payload hashing runs.
Empty visible String and a nonzero native symbol span are deliberately distinct.
"""
import hashlib
from types import SimpleNamespace
import unittest

from office_word_inline import prepare_inline_spacing
from office_word_objects import image_properties
from test_word_images import DrawPage, Frame, Image, NativeCollection, NativeText, PAYLOAD, Proxy, Range, ServiceManager, enum, prop


class Cursor:
    String = ''

    def __init__(self, owner, start, end=None):
        self.owner = owner
        self.Start = Range(owner, start)
        self.End = Range(owner, start if end is None else end)

    def getText(self):
        return self.owner

    def gotoRange(self, value, select):
        self.owner.createTextCursorByRange(value)
        if select:
            self.End = Range(self.owner, value.Start.offset)
        else:
            self.Start = self.End = Range(self.owner, value.Start.offset)


class Bookmark:
    def __init__(self):
        self.Name, self.anchor = '', None

    def getAnchor(self):
        return self.anchor

    def dispose(self):
        raise AssertionError('Private preparation must not dispose live bookmark content')


class Bookmarks:
    def __init__(self):
        self.values, self.collide = {}, False

    def hasByName(self, name):
        return self.collide or name in self.values


class Owner(NativeText):
    def __init__(self, document):
        super().__init__()
        self.document = document

    def createTextCursorByRange(self, value):
        for boundary in (value.Start, value.End):
            if boundary.getText() is not self or not boundary.accepted:
                raise ValueError('Controlled native range belongs elsewhere or is rejected')
        return Cursor(self, value.Start.offset, value.End.offset)

    def insertTextContent(self, cursor, bookmark, absorb):
        if absorb is not True:
            raise AssertionError('An inline bookmark must absorb its actual symbol range')
        bookmark.anchor = Cursor(self, cursor.Start.offset, cursor.End.offset)
        self.document.Bookmarks.values[bookmark.Name] = bookmark
        self.document.insertions.append((self, bookmark))
        if self.document.on_insert is not None:
            self.document.on_insert(self, bookmark)


def fixture(count=1, separate_owners=False):
    document = SimpleNamespace(Bookmarks=Bookmarks(), insertions=[], on_insert=None, created=[])

    def create(name):
        if name != 'com.sun.star.text.Bookmark':
            raise ValueError('Unexpected controlled native instance')
        result = Bookmark()
        document.created.append(result)
        return result

    document.createInstance = create
    first = Owner(document)
    images, frames, bindings, owners = [], [], [], []
    for index in range(count):
        owner = Owner(document) if separate_owners else first
        image = Image(owner, 10 + index * 4, index)
        image.properties['AnchorType'] = enum('com.sun.star.text.TextContentAnchorType', 'AS_CHARACTER')
        image.properties.update(LeftMargin=319, RightMargin=319)
        frame = Frame(owner, image.anchor.offset, image)
        frame.End = Range(owner, image.anchor.offset + 1)
        images.append(image)
        frames.append(frame)
        owners.append(owner)
        bindings.append({'text': owner, 'portion': frame, 'image': Proxy(image),
            'format': image_properties(image), 'graphic': {'sha256': hashlib.sha256(PAYLOAD).hexdigest()}})
    document.Text, document.DrawPage = first, DrawPage(images)
    document.GraphicObjects = NativeCollection([('same name ' + str(index), image) for index, image in enumerate(images)])
    context = SimpleNamespace(ServiceManager=ServiceManager())
    return SimpleNamespace(document=document, owners=owners, images=images, frames=frames, bindings=bindings, context=context)


def prepare(value):
    return prepare_inline_spacing(value.document, value.bindings, value.context, SimpleNamespace(), prop)


class WordInlineMarkersTest(unittest.TestCase):
    def test_empty_string_nonzero_native_span_gets_exact_private_mapping(self):
        value = fixture()
        self.assertEqual(value.frames[0].String, '')
        self.assertNotEqual(value.frames[0].Start.offset, value.frames[0].End.offset)
        result = prepare(value)
        self.assertEqual(len(result), 1)
        name, margins = next(iter(result.items()))
        self.assertRegex(name, r'\APIV_[0-9a-f]{32}\Z')
        self.assertEqual(margins, {'LeftMargin': 319, 'RightMargin': 319, 'TopMargin': 0, 'BottomMargin': 0})
        marker = value.document.Bookmarks.values[name]
        self.assertEqual((marker.anchor.Start.offset, marker.anchor.End.offset), (10, 11))
        self.assertTrue(all(stream.input_closed and stream.output_closed for stream in value.context.ServiceManager.streams))

    def test_equal_names_payloads_and_owner_strings_do_not_merge_native_images(self):
        value = fixture(2, separate_owners=True)
        self.assertEqual(value.images[0].name, value.images[1].name)
        self.assertEqual(value.owners[0].String, value.owners[1].String)
        result = prepare(value)
        self.assertEqual(len(result), 2)
        self.assertIs(value.document.insertions[0][0], value.owners[0])
        self.assertIs(value.document.insertions[1][0], value.owners[1])

    def test_at_character_is_skipped_and_no_bindings_is_a_no_op(self):
        value = fixture()
        value.images[0].properties['AnchorType'] = enum('com.sun.star.text.TextContentAnchorType', 'AT_CHARACTER')
        value.bindings[0]['format'] = image_properties(value.images[0])
        self.assertEqual(prepare(value), {})
        self.assertEqual(value.document.insertions, [])
        value.bindings = []
        self.assertEqual(prepare(value), {})

    def test_each_zero_or_319_side_is_retained_without_normalization(self):
        for left, right in ((0, 0), (319, 0), (0, 319), (319, 319)):
            with self.subTest(left=left, right=right):
                value = fixture()
                value.images[0].properties.update(LeftMargin=left, RightMargin=right)
                value.bindings[0]['format'] = image_properties(value.images[0])
                margins = next(iter(prepare(value).values()))
                self.assertEqual((margins['LeftMargin'], margins['RightMargin']), (left, right))

    def test_all_candidate_spacing_is_validated_before_any_marker_is_inserted(self):
        for property_name, invalid in (('LeftMargin', 1), ('RightMargin', -1), ('TopMargin', 319),
                ('BottomMargin', 1), ('LeftMargin', True), ('RightMargin', 319.0)):
            with self.subTest(property=property_name, invalid=invalid):
                value = fixture(2)
                value.bindings[1]['format'][property_name] = ('integer', invalid)
                with self.assertRaises(ValueError):
                    prepare(value)
                self.assertEqual(value.document.insertions, [])

    def test_wrong_owner_rejected_range_collapsed_span_or_wrong_start_is_rejected_before_markers(self):
        for corruption in ('owner', 'rejected-start', 'rejected-end', 'collapsed', 'wrong-start', 'wrong-frame-reference', 'duplicate'):
            with self.subTest(corruption=corruption):
                value = fixture(2)
                frame, image = value.frames[1], value.images[1]
                if corruption == 'owner':
                    value.bindings[1]['text'] = Owner(value.document)
                elif corruption == 'rejected-start':
                    frame.Start.accepted = False
                elif corruption == 'rejected-end':
                    frame.End.accepted = False
                elif corruption == 'collapsed':
                    frame.End = frame.Start
                elif corruption == 'wrong-start':
                    image.anchor.offset += 1
                elif corruption == 'wrong-frame-reference':
                    frame.references = [value.images[0]]
                else:
                    value.bindings[1] = value.bindings[0]
                with self.assertRaises(ValueError):
                    prepare(value)
                self.assertEqual(value.document.insertions, [])

    def test_stale_native_format_or_full_payload_fails_before_insertion(self):
        for corruption in ('format', 'payload'):
            with self.subTest(corruption=corruption):
                value = fixture(2)
                if corruption == 'format':
                    value.images[1].properties['Width'] += 1
                else:
                    value.bindings[1]['graphic']['sha256'] = '0' * 64
                with self.assertRaises(ValueError):
                    prepare(value)
                self.assertEqual(value.document.insertions, [])

    def test_uuid_collision_does_not_overwrite_authored_bookmark_or_insert(self):
        value = fixture()
        value.document.Bookmarks.collide = True
        with self.assertRaises(ValueError):
            prepare(value)
        self.assertEqual(value.document.insertions, [])

    def test_native_insertion_that_moves_deletes_or_changes_content_is_rejected(self):
        for corruption in ('format', 'payload-tail', 'owner-text', 'image-anchor', 'marker-span', 'membership', 'same-payload-replacement'):
            with self.subTest(corruption=corruption):
                value = fixture()

                def corrupt(owner, bookmark):
                    if corruption == 'format':
                        value.images[0].properties['Width'] += 1
                    elif corruption == 'payload-tail':
                        value.images[0].Graphic.payload = PAYLOAD[:-1] + b'Z'
                    elif corruption == 'owner-text':
                        owner.String = 'CHANGED AUTHOR TEXT'
                    elif corruption == 'image-anchor':
                        value.images[0].anchor.offset += 1
                    elif corruption == 'marker-span':
                        bookmark.anchor.End = bookmark.anchor.Start
                    elif corruption == 'membership':
                        value.document.GraphicObjects.entries.clear()
                    else:
                        replacement = Image(owner, value.images[0].anchor.offset, 0)
                        value.document.GraphicObjects.entries = [('same replacement alias', replacement)]

                value.document.on_insert = corrupt
                with self.assertRaises(ValueError):
                    prepare(value)

    def test_later_marker_cannot_change_an_already_prepared_image(self):
        value = fixture(2)

        def corrupt_previous(owner, bookmark):
            if len(value.document.insertions) == 2:
                value.images[0].properties['Width'] += 1

        value.document.on_insert = corrupt_previous
        with self.assertRaises(ValueError):
            prepare(value)


if __name__ == '__main__':
    unittest.main()
