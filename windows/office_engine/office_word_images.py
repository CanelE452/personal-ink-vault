"""Source-bound Writer object identities and verified bitmap replacement."""
import copy
import office_images
import office_presentation
import office_text
import office_word_image_mutations as mutations
from office_word_fidelity import property_value, semantic_value
from office_word_inline import native_margins


def same(left, right):
    return left == right


def writable(image):
    try:
        info = image.getPropertySetInfo()
        return info.hasPropertyByName('Graphic') and not info.getPropertyByName('Graphic').Attributes & 16
    except Exception:
        return False


class WordImages:
    def __init__(self, word):
        self.word = word
        self.image_changed = False
        self.source_bindings = None
        self.expected_bindings = None
        self.pending_bindings = None
        self.retired_images = set()
        self.frame_order = []
        self.mutations_changed = False
        self.raw_verified = False
        self.raw_active = False
        self.source_raw_bindings = None
        self._pending_graphic = None
        self.images = {word.allocate_id('word-image'): row['object'] for row in self.current()}
        if self.verified() is not None:
            self.source_bindings = [{key: binding[key] for key in ('image', 'text', 'format', 'graphic')}
                for binding in word.export_bindings]
            self.expected_bindings = [{**row, 'format': copy.deepcopy(row['format']),
                'graphic': copy.deepcopy(row['graphic'])} for row in self.source_bindings]
            try:
                rows = mutations.require_supported(self)
                self.source_raw_bindings = [(image, copy.deepcopy(state)) for _, image, state in rows]
                self.raw_verified = True
            except Exception:
                pass

    def verify_source(self, bindings):
        expected = self.pending_bindings if self.pending_bindings is not None else self.expected_bindings
        if expected is None:
            return
        if len(bindings) != len(expected):
            raise ValueError('Word source image inventory changed during editing')
        for source in expected:
            current = [row for row in bindings if same(row['image'], source['image'])]
            if len(current) != 1:
                raise ValueError('Word source image lost its native Frame binding')
            binding = current[0]
            payload = source['graphic']
            if self._pending_graphic is not None and same(source['image'], self._pending_graphic[0]):
                payload = self._pending_graphic[1]
            if (not same(binding['text'], source['text']) or binding['format'] != source['format'] or
                    binding['graphic'] != payload):
                raise ValueError('Word source image owner, formatting or payload changed during editing')
            if 'raw' in source and mutations.raw_image_state(binding['image']) != source['raw']:
                raise ValueError('Word source image native values, states or metadata changed during editing')

    def current(self):
        word, result, texts = self.word, [], []

        def add(value, **location):
            if value is not None and not any(same(value, row['object']) for row in result):
                result.append({'object': value, **location})

        def walk(text, owner, paragraphs, table_id=None, cell=None):
            if any(same(text, previous) for previous in texts):
                return
            texts.append(text)
            blocks = text.createEnumeration()
            while blocks.hasMoreElements():
                block = blocks.nextElement()
                if block.supportsService('com.sun.star.text.TextTable'):
                    identifier = next((key for key, value in word.tables.items() if same(value, block)), None)
                    for name in block.CellNames:
                        walk(block.getCellByName(name).Text, owner, {}, identifier, name)
                elif block.supportsService('com.sun.star.text.Paragraph'):
                    paragraph = next((key for key, value in paragraphs.items() if same(value, block)), None)
                    portions = block.createEnumeration()
                    while portions.hasMoreElements():
                        portion = portions.nextElement()
                        if property_value(portion, 'TextPortionType') != 'Frame':
                            continue
                        content = portion.createContentEnumeration('com.sun.star.text.TextContent')
                        while content.hasMoreElements():
                            add(content.nextElement(), ownerId=owner, paragraphId=paragraph,
                                tableId=table_id, cell=cell)

        for owner, scope in word.scopes.items():
            walk(scope.text, owner, scope.paragraphs)
        document = word.document
        page = document.DrawPage
        for index in range(page.Count):
            add(page.getByIndex(index))
        for name in ('GraphicObjects', 'TextFrames', 'EmbeddedObjects'):
            collection = getattr(document, name)
            for key in collection.ElementNames:
                add(collection.getByName(key))
        return result

    def verified(self):
        if self.word.context is None or self.word.geometry_format != 'docx':
            return None
        try:
            state = self.word.verification_state()
            self.verify_source(self.word.export_bindings)
            for binding in self.word.export_bindings:
                if getattr(property_value(binding['image'], 'AnchorType'), 'value', None) == 'AS_CHARACTER':
                    native_margins(binding['format'])
            return state
        except Exception:
            return None

    def snapshot(self, budget=None):
        if budget is None:
            budget = [office_images.THUMBNAIL_BUDGET]
        current = self.current()
        supported = self.source_bindings is not None and self.verified() is not None
        mutable = self.can_mutate() if supported else False
        result = []
        for identifier, image in self.images.items():
            row = next((row for row in current if same(row['object'], image)), None)
            if row is None:
                continue
            metadata = {'mimeType': None, 'pixelWidth': None, 'pixelHeight': None,
                'canReplace': False, 'thumbnailTruncated': True}
            fingerprint, anchor, width, height = None, None, None, None
            try:
                if image.supportsService('com.sun.star.text.TextGraphicObject'):
                    metadata = office_images.image_details(self.word.context, image,
                        self.word.prop, self.word.uno, budget)
                    graphic = property_value(image, 'Graphic')
                    if self.word.context is not None:
                        fingerprint = office_presentation.graphic_digest(
                            self.word.context, graphic, self.word.uno, self.word.prop)
                    anchor = getattr(property_value(image, 'AnchorType'), 'value', None)
                    raw_width, raw_height = property_value(image, 'Width'), property_value(image, 'Height')
                    width = raw_width / 100 if type(raw_width) is int and raw_width > 0 else None
                    height = raw_height / 100 if type(raw_height) is int and raw_height > 0 else None
            except Exception:
                fingerprint = None
            bound = row.get('ownerId') is not None and (row.get('paragraphId') is not None or
                row.get('tableId') is not None and row.get('cell') is not None)
            metadata['canReplace'] = bool(supported and bound and fingerprint and writable(image))
            result.append({'id': identifier, **{key: row.get(key) for key in
                ('ownerId', 'paragraphId', 'tableId', 'cell')}, 'anchorType': anchor,
                'width': width, 'height': height, 'nativeGraphicSha256': fingerprint,
                'canMove': mutable, 'canDelete': mutable,
                'offsetUtf16': self._offset_utf16(image, row) if supported and anchor == 'AS_CHARACTER' else None,
                'image': metadata})
        return result

    def snapshot_targets(self):
        if self.source_bindings is None or self.source_raw_bindings is None or self.verified() is None:
            return None
        body = self.word.body
        mutable = self.can_mutate()
        result = []
        for identifier, paragraph in body.paragraphs.items():
            supported = mutable and body.ordinary(paragraph)
            result.append({'ownerId': 'body', 'paragraphId': identifier,
                'canAdd': supported, 'canMoveHere': supported})
        return result

    def can_mutate(self):
        if not self.raw_verified:
            return False
        try:
            rows = mutations.require_supported(self)
            mutations.verify_authored_source(self, rows)
            return True
        except Exception:
            return False

    def add(self, operation, asset):
        return mutations.add(self, operation, asset)

    def move(self, operation):
        return mutations.move(self, operation)

    def delete(self, operation):
        return mutations.delete(self, operation)

    def _offset_utf16(self, image, location):
        try:
            scope = self.word.scopes[location['ownerId']]
            paragraph = scope.paragraphs[location['paragraphId']]
            bindings = [row for row in self.word.export_bindings if same(row['image'], image)]
            if len(bindings) != 1 or not same(bindings[0]['text'], scope.text):
                return None
            prefix, frames, matches = '', [], []
            portions = paragraph.createEnumeration()
            while portions.hasMoreElements():
                portion = portions.nextElement()
                if property_value(portion, 'TextPortionType') == 'Frame':
                    offset = office_text.utf16_length(prefix)
                    frames.append(offset)
                    contents = portion.createContentEnumeration('com.sun.star.text.TextContent')
                    if not contents.hasMoreElements():
                        return None
                    actual = contents.nextElement()
                    if contents.hasMoreElements():
                        return None
                    if same(actual, image):
                        matches.append((prefix, offset, portion))
                prefix += portion.String
            if prefix != paragraph.String or len(matches) != 1:
                return None
            expected_prefix, offset, portion = matches[0]
            if frames.count(offset) != 1 or scope.text.compareRegionStarts(
                    portion.Start, bindings[0]['portion'].Start) != 0:
                return None
            selected = scope.text.createTextCursorByRange(paragraph.Start)
            selected.gotoRange(portion.Start, True)
            return offset if selected.String == expected_prefix else None
        except Exception:
            return None

    def replace(self, identifier, asset):
        image = self.images.get(identifier)
        if image is None:
            raise ValueError('Unknown Word image identity')
        expected = self.verified()
        if self.source_bindings is None or expected is None or not writable(image):
            raise ValueError('This Word image has no verified writable preservation path')
        bindings = [row for row in self.word.export_bindings if same(row['image'], image)]
        if len(bindings) != 1:
            raise ValueError('The source Word image no longer has its native Frame binding')
        binding = bindings[0]
        text, anchor = binding['text'], image.getAnchor()
        start = text.createTextCursorByRange(anchor.Start)
        end = text.createTextCursorByRange(anchor.End)
        graphic = office_images.load_graphic(self.word.context, asset, self.word.prop, self.word.uno)
        payload = {'mimeType': semantic_value('MimeType', graphic.MimeType),
            'sizePixel': semantic_value('Size', graphic.SizePixel),
            'sha256': office_presentation.graphic_digest(self.word.context, graphic, self.word.uno, self.word.prop)}
        binding['token']['graphic'] = payload
        self._pending_graphic = (image, payload)
        try:
            image.setPropertyValue('Graphic', graphic)
            actual = self.word.verification_state()
            self.verify_source(self.word.export_bindings)
            after = [row for row in self.word.export_bindings if same(row['image'], image)]
            if actual != expected or len(after) != 1:
                raise ValueError('Word image replacement changed another object, authored content or formatting')
            anchor = image.getAnchor()
            if (anchor.getText() != text or text.compareRegionStarts(anchor.Start, start.Start) != 0 or
                    text.compareRegionStarts(anchor.End, end.Start) != 0):
                raise ValueError('Word image replacement moved its native anchor')
            source = next(row for row in self.expected_bindings if same(row['image'], image))
            source['graphic'] = payload
            self.image_changed = True
        finally:
            self._pending_graphic = None
