"""Pure exact lexical PPTX cell text edits; no package or native authority."""
import hashlib
import re
from xml.parsers import expat

from office_presentation_source import PART_BYTES, _slide, _xml
from office_presentation_text_source import MAX_UTF16, cell_text_map


def _digest(data):
    return hashlib.sha256(data).hexdigest()


def _xml_scalar(character):
    value = ord(character)
    return (value in (9, 10, 13) or 0x20 <= value <= 0xD7FF or
        0xE000 <= value <= 0xFFFD or 0x10000 <= value <= 0x10FFFF)


def _intersects(start, end, protected_start, protected_end):
    if start == end:
        return protected_start <= start <= protected_end
    if protected_start == protected_end:
        return start < protected_start < end
    return start < protected_end and protected_start < end


def _encode_replacement(text, lexical_kind):
    if lexical_kind == 'cdata':
        if ']]>' in text or '\r' in text:
            raise ValueError('CDATA terminators and semantic CR replacement are unsupported')
        return text.encode('utf-8')
    return (text.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
        .replace('\r', '&#13;').encode('utf-8'))


def _selection(mapping, start, end):
    for segment in mapping['segments']:
        if not segment['editable'] and _intersects(start, end,
                segment['startUtf16'], segment['endUtf16']):
            raise ValueError('The selection touches protected or structural cell content')
    for protected in mapping['protectedRanges']:
        if (protected['reason'] not in ('comment', 'processingInstruction') and
                _intersects(start, end, protected['startUtf16'], protected['endUtf16'])):
            raise ValueError('The selection crosses a protected source boundary')
    selected = []
    for segment in mapping['segments']:
        if not segment['editable'] or segment['sourceSpan'] is None:
            continue
        boundaries = dict(segment['boundaries'])
        if start == end:
            if start in boundaries:
                return [(segment, boundaries[start], boundaries[start])]
            continue
        left, right = max(start, segment['startUtf16']), min(end, segment['endUtf16'])
        if left >= right:
            continue
        if left not in boundaries or right not in boundaries:
            raise ValueError('The selection splits a UTF-16 scalar boundary')
        selected.append((segment, boundaries[left], boundaries[right]))
    if not selected:
        raise ValueError('The selection has no supported exact text content interval')
    return selected


def patch_cell_text(part_bytes, cell_record, start_utf16, end_utf16,
        replacement, expected_text_sha256):
    """Return request-derived original-byte patches and a strictly verified part."""
    if (type(start_utf16) is not int or type(end_utf16) is not int or
            start_utf16 < 0 or end_utf16 < start_utf16 or
            type(replacement) is not str or len(replacement) > MAX_UTF16 or
            type(expected_text_sha256) is not str or
            re.fullmatch(r'[0-9a-f]{64}', expected_text_sha256) is None):
        raise ValueError('Exact offsets, bounded replacement and expected text SHA-256 are required')
    if any(not _xml_scalar(character) for character in replacement):
        raise ValueError('The replacement contains a forbidden XML1.0 scalar')
    replacement_utf16 = replacement.encode('utf-16-le')
    replacement_length = len(replacement_utf16) // 2
    mapping = cell_text_map(part_bytes, cell_record)
    original_text = mapping['text']
    original_hash = _digest(original_text.encode('utf-8'))
    if original_hash != expected_text_sha256:
        raise ValueError('The expected source cell text SHA-256 is stale')
    if cell_record['covered']:
        raise ValueError('A covered source cell cannot be edited independently')
    if (end_utf16 > mapping['utf16Length'] or
            mapping['utf16Length'] - (end_utf16 - start_utf16) +
                replacement_length > MAX_UTF16):
        raise ValueError('The source or result UTF-16 selection is outside the mapping budget')
    selected = _selection(mapping, start_utf16, end_utf16)
    encoded_replacement = _encode_replacement(replacement, selected[0][0]['lexicalKind'])
    original_utf16 = original_text.encode('utf-16-le')
    try:
        selected_text = original_utf16[start_utf16 * 2:end_utf16 * 2].decode('utf-16-le')
        expected_text = (original_utf16[:start_utf16 * 2] + replacement_utf16 +
            original_utf16[end_utf16 * 2:]).decode('utf-16-le')
    except UnicodeError as error:
        raise ValueError('The selection splits a UTF-16 scalar boundary') from error
    source_hash = _digest(part_bytes)
    if selected_text == replacement:
        return {'partBytes': part_bytes, 'text': original_text, 'textSha256': original_hash,
            'sourcePartSha256': source_hash, 'resultPartSha256': source_hash, 'patches': []}
    patches = []
    for index, (segment, start, end) in enumerate(selected):
        data = encoded_replacement if index == 0 else b''
        if segment['lexicalKind'] == 'cdata':
            left, right = segment['sourceSpan']
            if b']]>' in part_bytes[left:start] + data + part_bytes[end:right]:
                raise ValueError('The requested patch forms an unsupported CDATA terminator')
        patches.append({'startByte': start, 'endByte': end, 'replacementBytes': data})
    result_size = len(part_bytes) + sum(
        len(patch['replacementBytes']) - (patch['endByte'] - patch['startByte'])
        for patch in patches)
    if result_size > PART_BYTES:
        raise ValueError('The candidate PPTX source part exceeds the byte budget')
    chunks, cursor = [], 0
    for patch in patches:
        start, end = patch['startByte'], patch['endByte']
        if not cursor <= start <= end <= len(part_bytes):
            raise ValueError('The original source patch intervals overlap or are outside the part')
        chunks.extend((part_bytes[cursor:start], patch['replacementBytes']))
        cursor = end
    candidate = b''.join(chunks) + part_bytes[cursor:]
    try:
        root = _xml(candidate, {'nodes': 0})
        cells = [cell for table in _slide(root, '') for cell in table['cells']
            if cell['cellSpan'][0] == cell_record['cellSpan'][0]]
        if len(cells) != 1:
            raise ValueError('The candidate has no unique original source cell')
        updated = cells[0]
        if any(updated[name] != cell_record[name] for name in
                ('row', 'column', 'rowSpan', 'columnSpan', 'covered', 'anchor')):
            raise ValueError('The candidate source cell topology differs')
        if cell_text_map(candidate, updated)['text'] != expected_text:
            raise ValueError('The candidate cell text differs from the request-derived text')
    except (expat.ExpatError, UnicodeError, OverflowError) as error:
        raise ValueError('The requested lexical source patch is unsupported or invalid XML') from error
    return {'partBytes': candidate, 'text': expected_text,
        'textSha256': _digest(expected_text.encode('utf-8')),
        'sourcePartSha256': source_hash, 'resultPartSha256': _digest(candidate),
        'patches': patches}
