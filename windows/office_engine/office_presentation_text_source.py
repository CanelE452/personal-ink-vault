"""Map original PPTX cell text to exact UTF-8 source intervals.

This pure reader grants no package provenance, native identity, or write rights.
All offsets refer to the supplied immutable complete slide-part bytes.
"""
from xml.parsers import expat

from office_presentation_source import A, PART_BYTES, _slide, _walk, _xml


MAX_UTF16 = 131072
MAX_SEGMENTS = 4096
MAX_PROTECTED_RANGES = 4096


def _same_record(actual, supplied):
    if type(actual) is not type(supplied):
        return False
    if type(actual) is dict:
        return (actual.keys() == supplied.keys() and
            all(_same_record(value, supplied[key]) for key, value in actual.items()))
    if type(actual) in (list, tuple):
        return len(actual) == len(supplied) and all(
            _same_record(one, two) for one, two in zip(actual, supplied))
    return actual == supplied


class _CellTextMap:
    def __init__(self, data, cell):
        self.data = data
        self.cell = cell
        self.segments = []
        self.protected = []
        self.text = []
        self.offset = 0

    def _inner_end(self, node):
        if node.empty:
            return node.tag_end
        end = self.data.rfind(b'</', node.tag_end, node.end)
        if end < node.tag_end:
            raise ValueError('A source text container has no exact closing tag')
        return end

    def _structure(self, node, allowed):
        if any(child.name not in allowed for child in node.children):
            raise ValueError('Unsupported PPTX cell text structure')
        position = node.tag_end
        for child in node.children:
            self._structural_gap(position, child.start)
            position = child.end
        self._structural_gap(position, self._inner_end(node))

    def _structural_gap(self, start, end):
        position = start
        while position < end:
            if self.data[position:position + 4] == b'<!--':
                stop = self.data.find(b'-->', position + 4, end)
                if stop < 0:
                    raise ValueError('A source XML comment boundary is incomplete')
                position = stop + 3
            elif self.data[position:position + 2] == b'<?':
                stop = self.data.find(b'?>', position + 2, end)
                if stop < 0:
                    raise ValueError('A source XML instruction boundary is incomplete')
                position = stop + 2
            elif self.data[position] in (9, 10, 13, 32):
                position += 1
            else:
                raise ValueError('Unsupported character data outside PPTX text elements')

    def _reject_inherited_hyperlinks(self, properties):
        for node in properties:
            if any(child.name in (A + 'hlinkClick', A + 'hlinkMouseOver')
                    for child in _walk(node)):
                raise ValueError('Inherited PPTX cell hyperlinks are unsupported')

    def _count(self, node, name, maximum=1):
        values = [child for child in node.children if child.name == A + name]
        if len(values) > maximum:
            raise ValueError('A PPTX cell text property or text root is duplicated')
        return values

    def _advance(self, text):
        length = len(text.encode('utf-16-le')) // 2
        if self.offset + length > MAX_UTF16:
            raise ValueError('PPTX source cell UTF-16 mapping limit exceeded')
        self.offset += length
        self.text.append(text)

    def _append(self, segment):
        if len(self.segments) >= MAX_SEGMENTS:
            raise ValueError('PPTX source cell segment mapping limit exceeded')
        self.segments.append(segment)

    def _protect(self, node_or_span, reason, start, end):
        if len(self.protected) >= MAX_PROTECTED_RANGES:
            raise ValueError('PPTX source cell protected-range mapping limit exceeded')
        span = ((node_or_span.start, node_or_span.end)
            if hasattr(node_or_span, 'start') else node_or_span)
        self.protected.append({'sourceSpan': span, 'reason': reason,
            'startUtf16': start, 'endUtf16': end})

    def _context(self, paragraph, run, text, paragraph_index, run_index):
        return {'paragraphIndex': paragraph_index, 'runIndex': run_index,
            'paragraphSpan': (paragraph.start, paragraph.end),
            'runSpan': (run.start, run.end) if run is not None else None,
            'textSpan': (text.start, text.end) if text is not None else None}

    def _content(self, start, end, lexical, context, reason):
        position = start
        text = []
        start_utf16 = self.offset
        boundaries = [[self.offset, position]]
        named = {b'amp': '&', b'lt': '<', b'gt': '>',
            b'quot': '"', b'apos': "'"}
        while position < end:
            byte = self.data[position]
            if lexical == 'text' and byte == 38:
                stop = self.data.find(b';', position + 1, end)
                if stop < 0:
                    raise ValueError('A source XML entity has no exact boundary')
                entity = self.data[position + 1:stop]
                if entity in named:
                    character = named[entity]
                elif entity.startswith(b'#x'):
                    character = chr(int(entity[2:], 16))
                elif entity.startswith(b'#'):
                    character = chr(int(entity[1:], 10))
                else:
                    raise ValueError('Unsupported source XML entity')
                position = stop + 1
            elif byte == 13:
                character = '\n'
                position += 2 if self.data[position:position + 2] == b'\r\n' else 1
            else:
                width = 1 if byte < 128 else 2 if byte < 224 else 3 if byte < 240 else 4
                character = self.data[position:position + width].decode('utf-8')
                position += width
            self._advance(character)
            text.append(character)
            boundaries.append([self.offset, position])
        self._append({**context, 'kind': 'text', 'lexicalKind': lexical,
            'text': ''.join(text), 'startUtf16': start_utf16, 'endUtf16': self.offset,
            'sourceSpan': (start, end), 'boundaries': boundaries,
            'editable': reason is None, 'protectedReason': reason})

    def _text_element(self, node, context, reason):
        if node.children:
            raise ValueError('Nested PPTX source text markup is unsupported')
        if node.empty:
            self._append({**context, 'kind': 'text', 'lexicalKind': 'text',
                'text': '', 'startUtf16': self.offset, 'endUtf16': self.offset,
                'sourceSpan': None, 'boundaries': [],
                'editable': False, 'protectedReason': reason or 'selfClosingText'})
            return
        position, end = node.tag_end, self._inner_end(node)
        if position == end:
            self._content(position, end, 'text', context, reason)
            return
        while position < end:
            if self.data[position:position + 9] == b'<![CDATA[':
                stop = self.data.find(b']]>', position + 9, end)
                if stop < 0:
                    raise ValueError('A source CDATA boundary is incomplete')
                self._content(position + 9, stop, 'cdata', context, reason)
                position = stop + 3
            elif self.data[position:position + 4] == b'<!--':
                stop = self.data.find(b'-->', position + 4, end)
                if stop < 0:
                    raise ValueError('A source text comment boundary is incomplete')
                self._protect((position, stop + 3), 'comment', self.offset, self.offset)
                position = stop + 3
            elif self.data[position:position + 2] == b'<?':
                stop = self.data.find(b'?>', position + 2, end)
                if stop < 0:
                    raise ValueError('A source text instruction boundary is incomplete')
                self._protect((position, stop + 2), 'processingInstruction',
                    self.offset, self.offset)
                position = stop + 2
            elif self.data[position] == 60:
                raise ValueError('Unsupported source text markup')
            else:
                stop = self.data.find(b'<', position, end)
                stop = end if stop < 0 else stop
                self._content(position, stop, 'text', context, reason)
                position = stop

    def _run(self, node, paragraph, paragraph_index, run_index):
        field = node.name == A + 'fld'
        allowed = {A + 'rPr', A + 't'} | ({A + 'pPr'} if field else set())
        self._structure(node, allowed)
        self._count(node, 'rPr')
        self._count(node, 'pPr')
        texts = self._count(node, 't')
        names = [child.name for child in node.children]
        order = [A + 'rPr', A + 'pPr', A + 't'] if field else [A + 'rPr', A + 't']
        if names != sorted(names, key=order.index):
            raise ValueError('A PPTX cell run has unsupported child order')
        hyperlink = any(child.name in (A + 'hlinkClick', A + 'hlinkMouseOver')
            for properties in node.children if properties.name == A + 'rPr'
            for child in _walk(properties))
        reason = 'field' if field else 'hyperlink' if hyperlink else None
        start = self.offset
        for text in texts:
            context = self._context(paragraph, node, text, paragraph_index, run_index)
            self._text_element(text, context, reason)
        if reason is not None:
            self._protect(node, reason, start, self.offset)

    def _line_break(self, node, paragraph, paragraph_index, run_index):
        self._structure(node, {A + 'rPr'})
        self._count(node, 'rPr')
        start = self.offset
        self._advance('\n')
        self._append({**self._context(paragraph, node, None, paragraph_index, run_index),
            'kind': 'lineBreak', 'lexicalKind': None, 'text': '\n',
            'startUtf16': start, 'endUtf16': self.offset,
            'sourceSpan': (node.start, node.end), 'boundaries': [],
            'editable': False, 'protectedReason': 'lineBreak'})

    def _paragraph(self, paragraph, index):
        self._structure(paragraph, {A + name for name in
            ('pPr', 'r', 'br', 'fld', 'endParaRPr')})
        properties = self._count(paragraph, 'pPr')
        end_properties = self._count(paragraph, 'endParaRPr')
        self._reject_inherited_hyperlinks(properties + end_properties)
        if (properties and paragraph.children[0] is not properties[0] or
                end_properties and paragraph.children[-1] is not end_properties[0]):
            raise ValueError('A PPTX paragraph has unsupported property order')
        run_index = 0
        for child in paragraph.children:
            if child.name in (A + 'r', A + 'fld'):
                self._run(child, paragraph, index, run_index)
                run_index += 1
            elif child.name == A + 'br':
                self._line_break(child, paragraph, index, run_index)
                run_index += 1

    def result(self):
        bodies = [child for child in self.cell.children if child.name == A + 'txBody']
        if len(bodies) != 1:
            raise ValueError('A PPTX cell requires one exact text body')
        body = bodies[0]
        self._structure(body, {A + 'bodyPr', A + 'lstStyle', A + 'p'})
        properties = self._count(body, 'bodyPr')
        listing = self._count(body, 'lstStyle')
        self._reject_inherited_hyperlinks(properties + listing)
        if len(properties) != 1 or body.children[0] is not properties[0]:
            raise ValueError('A PPTX cell text body requires initial body properties')
        if listing and body.children[1] is not listing[0]:
            raise ValueError('A PPTX cell list style has unsupported order')
        paragraphs = [child for child in body.children if child.name == A + 'p']
        if not paragraphs:
            raise ValueError('A PPTX cell text body requires a paragraph')
        for index, paragraph in enumerate(paragraphs):
            if index:
                start = self.offset
                self._advance('\n')
                self._append({**self._context(paragraphs[index - 1], None, None,
                    index - 1, None), 'kind': 'paragraphBreak', 'lexicalKind': None,
                    'text': '\n', 'startUtf16': start, 'endUtf16': self.offset,
                    'sourceSpan': None, 'boundaries': [], 'editable': False,
                    'protectedReason': 'paragraphBoundary'})
            self._paragraph(paragraph, index)
        self.protected.sort(key=lambda value: value['sourceSpan'])
        return {'text': ''.join(self.text), 'utf16Length': self.offset,
            'cellSpan': (self.cell.start, self.cell.end), 'segments': self.segments,
            'protectedRanges': self.protected}


def cell_text_map(part_bytes, cell_record):
    """Return a bounded exact map for a complete record from the source reader."""
    if (type(part_bytes) is not bytes or not part_bytes or
            len(part_bytes) > PART_BYTES or type(cell_record) is not dict):
        raise ValueError('An immutable bounded slide part and complete cell record are required')
    try:
        root = _xml(part_bytes, {'nodes': 0})
        tables = _slide(root, '')
        records = [cell for table in tables for cell in table['cells']
            if _same_record(cell, cell_record)]
        if len(records) != 1:
            raise ValueError('The complete source cell record does not match this slide part')
        span = records[0]['cellSpan']
        nodes = [node for node in _walk(root)
            if node.name == A + 'tc' and (node.start, node.end) == span]
        if len(nodes) != 1:
            raise ValueError('A source cell has no unique original element')
        return _CellTextMap(part_bytes, nodes[0]).result()
    except (expat.ExpatError, UnicodeError, OverflowError) as error:
        raise ValueError('Unsupported or invalid PPTX source text') from error
