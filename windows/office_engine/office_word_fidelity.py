"""Observed Writer character and paragraph semantics for geometry preservation.

Capture and live checks cover the 14 character and 16 paragraph properties below.
Saved checks cover 14 character and 15 paragraph properties: paragraph style name
identity across saving remains unverified. A supplied native object registry
verifies image Frame tokens; other object preservation remains unverified.
"""
import math


CHARACTER_PROPERTIES = (
    'CharFontName', 'CharHeight', 'CharWeight', 'CharPosture', 'CharUnderline',
    'CharColor', 'CharBackColor', 'CharHidden', 'CharEscapement', 'CharStrikeout',
    'CharKerning', 'CharAutoKerning', 'CharStyleName', 'CharLocale',
)
PARAGRAPH_PROPERTIES = (
    'ParaStyleName', 'ParaAdjust', 'ParaLastLineAdjust', 'ParaTopMargin',
    'ParaBottomMargin', 'ParaLeftMargin', 'ParaRightMargin', 'ParaFirstLineIndent',
    'ParaLineSpacing', 'ParaKeepTogether', 'ParaSplit', 'ParaWidows', 'ParaOrphans',
    'BreakType', 'NumberingStyleName', 'NumberingLevel',
)
STRUCT_FIELDS = {
    'CharLocale': ('Language', 'Country', 'Variant'),
    'ParaLineSpacing': ('Mode', 'Height'),
    'Size': ('Width', 'Height'),
    'GraphicCrop': ('Top', 'Bottom', 'Left', 'Right'),
    **{name: ('Color', 'InnerLineWidth', 'OuterLineWidth', 'LineDistance')
        for name in ('LeftBorder', 'RightBorder', 'TopBorder', 'BottomBorder')},
}


def scalar(value):
    if value is None:
        return ('void',)
    if type(value) is bool:
        return ('boolean', value)
    if type(value) is int:
        return ('integer', value)
    if type(value) is float and math.isfinite(value):
        return ('number', value)
    if type(value) is str:
        return ('string', value)
    raise ValueError('Word formatting contains an unverified native value')


def semantic_value(name, value):
    if value is None or type(value) in (bool, int, float, str):
        return scalar(value)
    if name in STRUCT_FIELDS:
        try:
            return ('struct', tuple((field, scalar(getattr(value, field)))
                for field in STRUCT_FIELDS[name]))
        except AttributeError as error:
            raise ValueError('Word formatting contains an unreadable native structure') from error
    try:
        member = value.value
    except AttributeError as error:
        raise ValueError('Word formatting contains an unverified native value') from error
    if type(member) is not str:
        raise ValueError('Word formatting contains an unverified native enumeration')
    return ('enum', getattr(value, 'typeName', None), member)


def property_value(target, name):
    try:
        return target.getPropertyValue(name)
    except Exception as error:
        raise ValueError('Word preservation could not read ' + name) from error


def properties(target, names):
    information = None
    if hasattr(target, 'getPropertySetInfo'):
        try:
            information = target.getPropertySetInfo()
        except Exception as error:
            raise ValueError('Word preservation could not inspect native properties') from error
    result = {}
    for name in names:
        if information is not None and not information.hasPropertyByName(name):
            result[name] = ('absent',)
        else:
            result[name] = semantic_value(name, property_value(target, name))
    return result


def paragraph_content(paragraph, objects=None, owner_text=None, image_delta=None):
    tokens = []
    def append_text(value, formatting):
        if tokens and tokens[-1][0] == 'text' and tokens[-1][2] == formatting:
            tokens[-1][1] += value
        else:
            tokens.append(['text', value, formatting])
    enumeration = paragraph.createEnumeration()
    while enumeration.hasMoreElements():
        portion = enumeration.nextElement()
        kind = property_value(portion, 'TextPortionType')
        if kind == 'SoftPageBreak':
            continue
        if kind == 'Text':
            formatting = properties(portion, CHARACTER_PROPERTIES)
            target = None if image_delta is None else image_delta['target']
            if (target is not None and paragraph == target['paragraph'] and
                    owner_text.compareRegionStarts(portion.Start, target['portion'].Start) == 0 and
                    owner_text.compareRegionStarts(portion.End, target['portion'].End) == 0):
                split = target['splitIndex']
                append_text(portion.String[:split], formatting)
                tokens.append(['object', image_delta['token']])
                append_text(portion.String[split:], formatting)
                image_delta['insertions'] += 1
            else:
                append_text(portion.String, formatting)
        elif kind == 'TextField':
            field = property_value(portion, 'TextField')
            if field is None:
                raise ValueError('A Word field cannot be verified')
            # Displayed results are layout caches. Commands and formatting are
            # authored content and must survive both layout and serialization.
            tokens.append(['field', field.getPresentation(True),
                tuple(sorted(field.getSupportedServiceNames())),
                properties(portion, CHARACTER_PROPERTIES)])
        elif kind == 'Bookmark':
            bookmark = property_value(portion, 'Bookmark')
            if bookmark is None:
                raise ValueError('A Word bookmark cannot be verified')
            tokens.append(['bookmark', bookmark.Name,
                semantic_value('IsStart', property_value(portion, 'IsStart'))])
        elif kind == 'Frame' and objects is not None:
            token = objects.frame_content(portion, owner_text)
            if image_delta is not None and objects.export_bindings[-1]['image'] == image_delta['remove']:
                image_delta['removals'] += 1
            else:
                tokens.append(['object', token])
        else:
            raise ValueError('This Word paragraph contains an unverified content object')
    result = {'format': properties(paragraph, PARAGRAPH_PROPERTIES), 'portions': tokens}
    if all(token[0] == 'bookmark' or token[0] == 'text' and token[1] == '' for token in tokens):
        result['emptyCharacterFormat'] = properties(paragraph, CHARACTER_PROPERTIES)
    return result


def content_blocks(text, objects=None, image_delta=None):
    result = []
    enumeration = text.createEnumeration()
    while enumeration.hasMoreElements():
        block = enumeration.nextElement()
        if block.supportsService('com.sun.star.text.Paragraph'):
            result.append(['paragraph', paragraph_content(block, objects, text, image_delta)])
        elif block.supportsService('com.sun.star.text.TextTable'):
            cells = []
            for name in block.CellNames:
                cells.append([name, content_blocks(block.getCellByName(name).Text, objects, image_delta)])
            result.append(['table', cells])
        else:
            raise ValueError('This Word block cannot be verified after a geometry change')
    return result


def saved_blocks(blocks):
    result = []
    for kind, payload in blocks:
        if kind == 'paragraph':
            result.append([kind, {**payload, 'format': {
                name: value for name, value in payload['format'].items() if name != 'ParaStyleName'}}])
        elif kind == 'table':
            result.append([kind, [[name, saved_blocks(cell)] for name, cell in payload]])
        else:
            raise ValueError('Saved Word preservation contains an unverified block')
    return result


def saved_reopen_state(state):
    """Compare saved semantics without claiming paragraph style name identity."""
    return {**state, 'body': saved_blocks(state['body']), 'ownersByReferences': {
        owner: saved_blocks(blocks) for owner, blocks in state['ownersByReferences'].items()}}
