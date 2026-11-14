"""Private native range markers for verified Writer inline export spacing.

Called after public draft/expected state capture on a disposable working model.
Failure leaves disposal to that model's owner; no live bookmark undo is used.
"""
import uuid

import office_presentation
from office_word_fidelity import properties, property_value
from office_word_objects import IMAGE_PROPERTIES, image_properties


def native_margins(formatting):
    result = {}
    for name in ('LeftMargin', 'RightMargin', 'TopMargin', 'BottomMargin'):
        value = formatting.get(name)
        allowed = (0, 319) if name in ('LeftMargin', 'RightMargin') else (0,)
        if (not isinstance(value, tuple) or len(value) != 2 or value[0] != 'integer'
                or type(value[1]) is not int or value[1] not in allowed):
            raise ValueError('This native inline spacing has no verified export mapping')
        result[name] = value[1]
    return result


def graphic_objects(document):
    collection = document.GraphicObjects
    return [collection.getByName(name) for name in collection.ElementNames]


def prepare_inline_spacing(document, bindings, context, uno, prop):
    """Return exact generated marker names and raw margins, preserving images."""
    try:
        return prepare_markers(document, bindings, context, uno, prop)
    except Exception as error:
        raise ValueError('Word inline spacing preparation failed: ' + str(error)) from error


def prepare_markers(document, bindings, context, uno, prop):
    if not isinstance(bindings, list):
        raise ValueError('Inline export requires the final native binding list')
    plans = []
    # Complete every candidate check before the first native document mutation.
    for binding in bindings:
        image = binding['image']
        anchor_type = property_value(image, 'AnchorType')
        kind = getattr(anchor_type, 'value', None)
        if kind == 'AT_CHARACTER':
            continue
        if kind != 'AS_CHARACTER':
            raise ValueError('This Word image anchor has no verified inline export path')
        formatting = binding['format']
        margins = native_margins(formatting)
        if image_properties(image) != formatting:
            raise ValueError('Word inline formatting changed after final verification')
        if any(image == previous['image'] for previous in plans):
            raise ValueError('A native inline image has more than one export binding')
        text, portion = binding['text'], binding['portion']
        contents = portion.createContentEnumeration('com.sun.star.text.TextContent')
        if not contents.hasMoreElements() or contents.nextElement() != image or contents.hasMoreElements():
            raise ValueError('Word inline binding differs from its actual Frame content')
        anchor = image.getAnchor()
        if anchor is None or anchor.getText() != text:
            raise ValueError('Word inline anchor belongs to a different native owner')
        text.createTextCursorByRange(anchor)
        start = text.createTextCursorByRange(portion.Start)
        end = text.createTextCursorByRange(portion.End)
        if (text.compareRegionStarts(start.Start, end.Start) == 0
                or text.compareRegionStarts(anchor.Start, start.Start) != 0):
            raise ValueError('Word inline symbol range or anchor binding cannot be verified')
        anchor_start = text.createTextCursorByRange(anchor.Start)
        anchor_end = text.createTextCursorByRange(anchor.End)
        digest = office_presentation.graphic_digest(context, property_value(image, 'Graphic'), uno, prop)
        if digest != binding['graphic']['sha256']:
            raise ValueError('Word inline graphic changed after final verification')
        plans.append({'image': image, 'text': text, 'start': start, 'end': end,
            'anchorStart': anchor_start, 'anchorEnd': anchor_end,
            'ownerString': text.String, 'format': formatting, 'rawFormat': properties(image, IMAGE_PROPERTIES),
            'digest': digest, 'margins': margins})
    if not plans:
        return {}
    inventory = graphic_objects(document)
    for plan in plans:
        if not any(plan['image'] == actual for actual in inventory):
            raise ValueError('Word inline image is absent from the native graphic inventory')
    names = set()
    for plan in plans:
        name = 'PIV_' + uuid.uuid4().hex
        if name in names or document.Bookmarks.hasByName(name):
            raise ValueError('Private inline export bookmark collides with an existing name')
        names.add(name)
        plan['name'] = name
    for plan in plans:
        text = plan['text']
        if document.Bookmarks.hasByName(plan['name']):
            raise ValueError('Private inline export bookmark name became occupied')
        selected = text.createTextCursorByRange(plan['start'].Start)
        selected.gotoRange(plan['end'].Start, True)
        if (text.compareRegionStarts(selected.Start, plan['start'].Start) != 0
                or text.compareRegionStarts(selected.End, plan['end'].Start) != 0
                or text.compareRegionStarts(selected.Start, selected.End) == 0):
            raise ValueError('Native inline export selection does not span the verified symbol')
        bookmark = document.createInstance('com.sun.star.text.Bookmark')
        bookmark.Name = plan['name']
        text.insertTextContent(selected, bookmark, True)
        plan['bookmark'] = bookmark
    after = graphic_objects(document)
    if (len(inventory) != len(after)
            or not all(any(old == current for current in after) for old in inventory)
            or not all(any(current == old for old in inventory) for current in after)):
        raise ValueError('Private inline markers changed the native graphic inventory')
    result = {}
    for plan in plans:
        image, text = plan['image'], plan['text']
        anchor, marker = image.getAnchor(), plan['bookmark'].getAnchor()
        if anchor is None or marker is None or anchor.getText() != text or marker.getText() != text:
            raise ValueError('Private inline marker changed its native owner binding')
        text.createTextCursorByRange(anchor)
        text.createTextCursorByRange(marker)
        if (text.compareRegionStarts(anchor.Start, plan['anchorStart'].Start) != 0
                or text.compareRegionStarts(anchor.End, plan['anchorEnd'].Start) != 0
                or text.compareRegionStarts(marker.Start, plan['start'].Start) != 0
                or text.compareRegionStarts(marker.End, plan['end'].Start) != 0
                or text.compareRegionStarts(marker.Start, marker.End) == 0):
            raise ValueError('Private inline marker moved or collapsed the native image range')
        if (text.String != plan['ownerString'] or image_properties(image) != plan['format']
                or properties(image, IMAGE_PROPERTIES) != plan['rawFormat']):
            raise ValueError('Private inline marker changed authored text or image formatting')
        digest = office_presentation.graphic_digest(context, property_value(image, 'Graphic'), uno, prop)
        if digest != plan['digest']:
            raise ValueError('Private inline marker changed the full native graphic payload')
        result[plan['name']] = dict(plan['margins'])
    return result
