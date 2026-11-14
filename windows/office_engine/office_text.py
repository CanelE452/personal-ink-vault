"""Verified UTF-16 selections over native text portions, including opaque anchors."""
import hashlib


def utf16_length(value):
    return len(value.encode('utf-16-le')) // 2


def text_hash(value):
    return hashlib.sha256(value.encode('utf-8')).hexdigest()


def utf16_index(value, offset):
    if type(offset) is not int or offset < 0:
        raise ValueError('Invalid Office UTF-16 range')
    total = 0
    for index, character in enumerate(value):
        if total == offset:
            return index
        total += 2 if ord(character) > 0xffff else 1
        if total > offset:
            raise ValueError('Office range splits a Unicode surrogate pair')
    if total == offset:
        return len(value)
    raise ValueError('Office UTF-16 range is outside the current text')


def property_value(value, name):
    try:
        try:
            state = value.getPropertyState(name)
            if getattr(state, 'value', None) == 'AMBIGUOUS_VALUE':
                return None
        except Exception:
            pass
        return value.getPropertyValue(name)
    except Exception:
        return None


def read_style(value):
    size = property_value(value, 'CharHeight')
    weight = property_value(value, 'CharWeight')
    color = property_value(value, 'CharColor')
    posture = property_value(value, 'CharPosture')
    underline = property_value(value, 'CharUnderline')
    family = property_value(value, 'CharFontName')
    return {
        'fontSize': float(size) if isinstance(size, (int, float)) and size > 0 else None,
        'bold': weight >= 150 if isinstance(weight, (int, float)) else None,
        'italic': None if posture is None else posture.value in ('ITALIC', 'OBLIQUE'),
        'underline': None if underline is None else underline != 0,
        'color': color if type(color) is int and color >= 0 else None,
        'fontFamily': family if isinstance(family, str) and family else None,
    }


def _container(value, paragraph):
    return value.getText() if paragraph else value.Text


def _segments(value, paragraph):
    content = value.String
    result, pieces = [], []
    offset = 0

    def add(portion, portion_type, text):
        nonlocal offset
        end = offset + utf16_length(text)
        result.append({'startUtf16': offset, 'endUtf16': end, 'type': portion_type,
                       'text': text, 'portion': portion})
        pieces.append(text)
        offset = end

    try:
        paragraphs = [value] if paragraph else list(_enumerate(_container(value, False)))
        for index, item in enumerate(paragraphs):
            if index:
                add(None, 'ParagraphBoundary', '\n')
            for portion in _enumerate(item):
                portion_type = property_value(portion, 'TextPortionType')
                if not isinstance(portion_type, str):
                    portion_type = 'Unknown'
                add(portion, portion_type, portion.String)
    except Exception:
        return content, result, False
    mapped = ''.join(pieces) == content
    if not result and not content:
        result.append({'startUtf16': 0, 'endUtf16': 0, 'type': 'Text',
                       'text': '', 'portion': value if paragraph else _container(value, False)})
    return content, result, mapped


def _enumerate(value):
    enumeration = value.createEnumeration()
    while enumeration.hasMoreElements():
        yield enumeration.nextElement()


def text_details(value, paragraph=False):
    content, segments, mapped = _segments(value, paragraph)
    runs, protected = [], []
    for segment in segments:
        interval = {name: segment[name] for name in ('startUtf16', 'endUtf16')}
        if segment['type'] == 'Text':
            runs.append({**interval, **read_style(segment['portion'])})
        elif segment['type'] != 'ParagraphBoundary':
            protected.append({**interval, 'type': segment['type']})
    if not mapped:
        protected = [{'startUtf16': 0, 'endUtf16': utf16_length(content), 'type': 'Unmapped'}]
    return {'utf16Length': utf16_length(content), 'textSha256': text_hash(content),
            'runs': runs, 'protectedRanges': protected, 'canReplace': mapped,
            'canStyle': mapped, 'truncated': False}


def _move(cursor, count):
    while count:
        step = min(count, 32767)
        if not cursor.goRight(step, False):
            raise ValueError('Native Office cursor did not reach the requested range')
        count -= step


def _endpoint(value, paragraph, segment, offset, scalar_cursor):
    if segment['portion'] is None:
        raise ValueError('Office selection endpoint is a paragraph boundary')
    content = segment['text']
    index = utf16_index(content, offset - segment['startUtf16'])
    prefix = content[:index]
    container = _container(value, paragraph)
    cursor = container.createTextCursorByRange(segment['portion'].Start)
    _move(cursor, len(prefix) if scalar_cursor else utf16_length(prefix))
    check = container.createTextCursorByRange(segment['portion'].Start)
    check.gotoRange(cursor.Start, True)
    if check.String != prefix:
        raise ValueError('Native Office cursor does not match the requested text prefix')
    return cursor


def selection(value, operation, paragraph=False, scalar_cursor=True, replacing=False):
    content, segments, mapped = _segments(value, paragraph)
    if not mapped or operation.get('expectedTextSha256') != text_hash(content):
        raise ValueError('Office text changed or cannot be mapped safely')
    start, end = operation.get('startUtf16'), operation.get('endUtf16')
    left, right = utf16_index(content, start), utf16_index(content, end)
    if start > end:
        raise ValueError('Invalid Office UTF-16 range order')
    for segment in segments:
        if segment['type'] in ('Text', 'ParagraphBoundary'):
            continue
        a, b = segment['startUtf16'], segment['endUtf16']
        intersects = start < b and end > a if a != b else replacing and start <= a <= end
        if replacing and start == end == a:
            intersects = True
        if intersects:
            raise ValueError('Office selection crosses a protected text object')
    plain = [item for item in segments if item['type'] == 'Text']
    first = next((item for item in plain if item['startUtf16'] <= start < item['endUtf16']), None)
    if first is None:
        first = next((item for item in reversed(plain) if item['startUtf16'] <= start <= item['endUtf16']), None)
    last = next((item for item in reversed(plain) if item['startUtf16'] < end <= item['endUtf16']), None)
    if last is None:
        last = next((item for item in plain if item['startUtf16'] <= end <= item['endUtf16']), None)
    if first is None or last is None:
        raise ValueError('Office selection endpoint is a protected text object')
    begin = _endpoint(value, paragraph, first, start, scalar_cursor)
    finish = _endpoint(value, paragraph, last, end, scalar_cursor)
    begin.gotoRange(finish.Start, True)
    if begin.String != content[left:right]:
        raise ValueError('Native Office selection does not match the requested text')
    return begin, content, left, right


def replace_text(value, operation, paragraph=False, scalar_cursor=True):
    replacement = operation.get('text')
    if not isinstance(replacement, str) or len(replacement) > 10000000:
        raise ValueError('Invalid Office text')
    replacement.encode('utf-8')
    cursor, content, left, right = selection(value, operation, paragraph, scalar_cursor, replacing=True)
    if paragraph and any(character in replacement for character in ('\n', '\r')):
        raise ValueError('Paragraph structure edits require a paragraph operation')
    cursor.String = replacement
    if value.String != content[:left] + replacement + content[right:]:
        raise ValueError('Native Office replacement did not preserve the surrounding text')


def replace_legacy(value, replacement, paragraph=False, scalar_cursor=True):
    original = value.String
    if original == replacement:
        return
    left = 0
    while left < min(len(original), len(replacement)) and original[left] == replacement[left]:
        left += 1
    right = 0
    while right < min(len(original), len(replacement)) - left and original[-1 - right] == replacement[-1 - right]:
        right += 1
    replace_text(value, {'text': replacement[left:len(replacement) - right if right else None],
        'startUtf16': utf16_length(original[:left]),
        'endUtf16': utf16_length(original[:len(original) - right if right else None]),
        'expectedTextSha256': text_hash(original)}, paragraph, scalar_cursor)


def apply_style(cursor, operation):
    import uno
    assignments = []
    for key, names in [('fontSize', ('CharHeight', 'CharHeightAsian', 'CharHeightComplex')),
                       ('bold', ('CharWeight', 'CharWeightAsian', 'CharWeightComplex')),
                       ('italic', ('CharPosture', 'CharPostureAsian', 'CharPostureComplex')),
                       ('fontFamily', ('CharFontName', 'CharFontNameAsian', 'CharFontNameComplex')),
                       ('underline', ('CharUnderline',)), ('color', ('CharColor',))]:
        if key not in operation:
            continue
        value = operation[key]
        if key == 'fontSize':
            if type(value) not in (int, float) or not 1 <= value <= 400:
                raise ValueError('Invalid Office font size')
            value = float(value)
        elif key in ('bold', 'italic', 'underline'):
            if not isinstance(value, bool):
                raise ValueError('Invalid Office boolean text style')
            if key == 'bold':
                value = 150.0 if value else 100.0
            elif key == 'italic':
                value = uno.Enum('com.sun.star.awt.FontSlant', 'ITALIC' if value else 'NONE')
            else:
                value = 1 if value else 0
        elif key == 'color':
            if type(value) is not int or not 0 <= value <= 0xffffff:
                raise ValueError('Invalid Office text color')
        elif not isinstance(value, str) or not value.strip() or len(value) > 256 or '\x00' in value:
            raise ValueError('Invalid Office font family')
        properties = cursor.getPropertySetInfo()
        for name in names:
            if properties.hasPropertyByName(name) and not properties.getPropertyByName(name).Attributes & 16:
                assignments.append((name, value))
    for name, value in assignments:
        cursor.setPropertyValue(name, value)


def style_text(value, operation, paragraph=False, scalar_cursor=True):
    if operation.get('startUtf16') == operation.get('endUtf16'):
        raise ValueError('Select text before applying a range style')
    cursor, _, _, _ = selection(value, operation, paragraph, scalar_cursor)
    apply_style(cursor, operation)
