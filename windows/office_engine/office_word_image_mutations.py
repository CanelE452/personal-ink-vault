"""Request-derived Writer image inventory and exact native property preservation."""
import copy
from decimal import Decimal
from functools import cmp_to_key

import office_images
import office_presentation
import office_text
from office_word_fidelity import property_value, semantic_value
from office_word_objects import IMAGE_PROPERTIES, image_properties


METADATA_PROPERTIES = ('Title', 'Description', 'Name', 'HyperLinkURL', 'HyperLinkTarget',
    'HyperLinkName', 'ServerMap', 'ImageMap', 'HyperLinkEvents')
RAW_PROPERTIES = tuple(dict.fromkeys((*IMAGE_PROPERTIES, *METADATA_PROPERTIES)))
NEW_DEFAULT_FIELDS = ('BackColor', 'BackTransparent', 'BorderDistance', 'BottomBorder',
    'BottomBorderDistance', 'FillColor', 'FillStyle', 'LeftBorder', 'LeftBorderDistance',
    'LineStyle', 'LineWidth', 'RightBorder', 'RightBorderDistance', 'TopBorder', 'TopBorderDistance')


def raw_value(name, value):
    if isinstance(value, (tuple, list)) and not value:
        return ('empty-sequence',)
    if hasattr(value, 'getCount'):
        if type(value.getCount()) is int and value.getCount() == 0:
            return ('empty-native-container',)
        raise ValueError('A nonempty Word image container has no verified preservation path')
    return semantic_value(name, value)


def raw_property(image, information, name):
    if not information.hasPropertyByName(name):
        return {'present': False}
    descriptor = information.getPropertyByName(name)
    state = image.getPropertyState(name)
    if getattr(state, 'value', None) not in ('DEFAULT_VALUE', 'DIRECT_VALUE'):
        raise ValueError('An image native property state cannot be preserved')
    return {'present': True, 'type': descriptor.Type.typeName,
        'attributes': descriptor.Attributes, 'state': semantic_value('PropertyState', state),
        'value': raw_value(name, image.getPropertyValue(name))}


def raw_image_state(image):
    information = image.getPropertySetInfo()
    result = {name: raw_property(image, information, name) for name in RAW_PROPERTIES}
    result['XNamed'] = semantic_value('Name', image.getName())
    return result


def binding(image, text, catalog):
    graphic = property_value(image, 'Graphic')
    return {'image': image, 'text': text, 'format': image_properties(image),
        'graphic': {'mimeType': semantic_value('MimeType', graphic.MimeType),
            'sizePixel': semantic_value('Size', graphic.SizePixel),
            'sha256': office_presentation.graphic_digest(catalog.word.context, graphic,
                catalog.word.uno, catalog.word.prop)}, 'raw': raw_image_state(image)}


def same(left, right):
    return left == right


def inventory(catalog):
    return [row['object'] for row in catalog.current()]


def actual_added(catalog, before):
    after = inventory(catalog)
    added = [image for image in after if not any(same(image, old) for old in before)]
    if (len(after) != len(before) + 1 or len(added) != 1 or
            any(sum(same(old, image) for image in after) != 1 for old in before)):
        raise ValueError('Insertion did not preserve every source and exactly one actual new image')
    return added[0]


def require_supported(catalog):
    if catalog.source_bindings is None or catalog.verified() is None:
        raise ValueError('This Word source has no verified mutation inventory')
    current = catalog.current()
    rows = []
    for identifier, image in catalog.images.items():
        location = next((row for row in current if same(row['object'], image)), None)
        if (location is None or location.get('ownerId') != 'body' or location.get('paragraphId') is None or
                getattr(property_value(image, 'AnchorType'), 'value', None) != 'AS_CHARACTER' or
                catalog._offset_utf16(image, location) is None):
            raise ValueError('Word mutations require actual body paragraph AS_CHARACTER Frames')
        state = raw_image_state(image)
        for name in ('ContentProtected', 'PositionProtected', 'SizeProtected'):
            if state[name].get('present') and state[name]['value'] != ('boolean', False):
                raise ValueError('A protected image cannot be mutated')
        rows.append((identifier, image, state))
    orders = [state['ZOrder']['value'] for _, _, state in rows]
    if set(orders) != {('integer', index) for index in range(len(rows))}:
        raise ValueError('The source has no verified exact native ZOrder permutation')
    return rows


def dimensions(value):
    if type(value) not in (int, float):
        raise ValueError('A Word image dimension must be numeric')
    number = Decimal(str(value))
    if not number.is_finite() or not 0 < number <= 1000 or number * 100 != (number * 100).to_integral_value():
        raise ValueError('A Word image dimension must be positive millimetres with at most two decimals')
    return int(number * 100)


def request(catalog, operation, op, asset=None):
    fields = {'op', 'id'}
    if op != 'wordImageDelete':
        fields |= {'ownerId', 'paragraphId', 'offsetUtf16', 'expectedTextSha256'}
    if op == 'wordImageAdd':
        fields |= {'assetId', 'width', 'height'}
    if not isinstance(operation, dict) or set(operation) != fields or operation.get('op') != op:
        raise ValueError('Invalid closed Word image mutation fields')
    identifier = operation['id']
    if not isinstance(identifier, str) or not identifier:
        raise ValueError('Invalid logical image identity')
    if op == 'wordImageAdd':
        if identifier in catalog.word.used_ids or identifier in catalog.images or identifier in catalog.retired_images:
            raise ValueError('A Word image alias cannot be reused')
        if not isinstance(asset, dict) or operation['assetId'] != asset.get('id'):
            raise ValueError('Word image asset is not bound to this request')
        size = dimensions(operation['width']), dimensions(operation['height'])
    else:
        if identifier not in catalog.images or identifier in catalog.retired_images:
            raise ValueError('Unknown or retired Word image identity')
        size = None
    rows = require_supported(catalog)
    target = None
    if op != 'wordImageDelete':
        if operation['ownerId'] != 'body' or operation['paragraphId'] not in catalog.word.body.paragraphs:
            raise ValueError('Word image target must be its registered body paragraph')
        paragraph = catalog.word.body.paragraphs[operation['paragraphId']]
        if not catalog.word.body.ordinary(paragraph):
            raise ValueError('Word image target is protected or cannot be verified')
        offset = operation['offsetUtf16']
        cursor, _, _, _ = office_text.selection(paragraph, {'startUtf16': offset, 'endUtf16': offset,
            'expectedTextSha256': operation['expectedTextSha256']}, True, True, replacing=True)
        _, segments, mapped = office_text._segments(paragraph, True)
        if not mapped:
            raise ValueError('Word image target is not mapped')
        candidates = [row for row in segments if row['type'] == 'Text' and row['startUtf16'] <= offset < row['endUtf16']]
        if not candidates:
            candidates = [row for row in reversed(segments) if row['type'] == 'Text' and row['startUtf16'] <= offset <= row['endUtf16']]
        if not candidates:
            raise ValueError('Word image target does not belong to a plain run')
        segment = candidates[0]
        target = {'cursor': cursor, 'paragraph': paragraph, 'portion': segment['portion'],
            'splitIndex': office_text.utf16_index(segment['text'], offset - segment['startUtf16']),
            'offset': offset}
    return identifier, rows, target, size


def requested_order(catalog, rows, target=None, remove=None, added=None):
    text = catalog.word.body.text
    identifiers = [identifier for identifier, _, _ in rows]
    images = {identifier: image for identifier, image, _ in rows}
    identifiers.sort(key=cmp_to_key(lambda left, right: -text.compareRegionStarts(
        images[left].getAnchor().Start, images[right].getAnchor().Start)))
    result = []
    inserted = False
    for identifier in identifiers:
        if target is not None:
            relation = text.compareRegionStarts(images[identifier].getAnchor().Start, target['cursor'].Start)
            if relation == 0:
                raise ValueError('The image destination is ambiguous with an existing native Frame')
            if relation < 0 and not inserted:
                result.append(added)
                inserted = True
        if identifier != remove:
            result.append(identifier)
    if target is not None and not inserted:
        result.append(added)
    return result


def verify_authored_source(catalog, rows):
    if catalog.raw_active:
        return
    evidence = catalog.source_raw_bindings
    if evidence is None:
        raise ValueError('Initial Word image authored metadata evidence is unavailable')
    if len(rows) != len(evidence):
        raise ValueError('The initial Word image metadata inventory changed')
    for source, expected in evidence:
        matches = [state for _, image, state in rows if same(image, source)]
        if len(matches) != 1:
            raise ValueError('The initial metadata lost its exact native source identity')
        for name in (*METADATA_PROPERTIES, 'XNamed'):
            if matches[0][name] != expected[name]:
                raise ValueError('Authored Word image metadata changed before the mutation transaction')


def activate(catalog, rows):
    if catalog.raw_active:
        return
    verify_authored_source(catalog, rows)
    for row in catalog.expected_bindings:
        row['raw'] = copy.deepcopy(next(state for _, image, state in rows if same(image, row['image'])))
    catalog.raw_active = True


def verify(catalog, expected, bindings):
    catalog.pending_bindings = bindings
    actual = catalog.word.verification_state()
    if actual != expected:
        raise ValueError('Word image mutation changed an unexpected Frame, authored content or formatting')


def projected_binding(row, z):
    result = {**row, 'format': copy.deepcopy(row['format'])}
    result['format']['ZOrder'] = ('integer', z)
    if 'raw' in row:
        result['raw'] = copy.deepcopy(row['raw'])
        result['raw']['ZOrder']['value'] = ('integer', z)
    return result


def project_tokens(bindings, desired):
    for row in bindings:
        for image, z in desired:
            if same(row['image'], image):
                row['token']['format']['ZOrder'] = ('integer', z)


def copy_native(source, target, defer_name=False):
    expected = raw_image_state(source)
    information = target.getPropertySetInfo()
    for name in ('FrameStyleName', *RAW_PROPERTIES):
        record = expected.get(name)
        if not record or not record['present'] or name == 'ZOrder' or defer_name and name == 'Name':
            continue
        current = raw_property(target, information, name)
        if current == record:
            continue
        if record['attributes'] & 16 or current.get('attributes', 16) & 16:
            raise ValueError('A readonly image property differs on its clone')
        if record['state'][-1] == 'DEFAULT_VALUE':
            native_value = source.getPropertyValue(name)
            if raw_value(name, native_value) != record['value']:
                raise ValueError('The captured native source value changed during cloning')
            target.setPropertyToDefault(name)
            restored = raw_property(target, information, name)
            if restored != record:
                if restored != {**record, 'value': restored.get('value')}:
                    raise ValueError('Native default restoration changed property metadata or state')
                target.setPropertyValue(name, native_value)
                if raw_property(target, information, name) != record:
                    raise ValueError('Native default value restoration did not preserve the exact source state')
        else:
            target.setPropertyValue(name, source.getPropertyValue(name))
    if not defer_name and target.getName() != source.getName():
        target.setName(source.getName())
    return expected


def temporary_name(target, source_raw):
    information = target.getPropertySetInfo()
    expected = source_raw['Name']
    current = raw_property(target, information, 'Name')
    if expected['present']:
        if not current.get('present'):
            raise ValueError('The clone lost the source Name property')
        if current['state'] != expected['state']:
            if current['attributes'] & 16:
                raise ValueError('The clone Name state cannot be restored')
            if expected['state'][-1] == 'DEFAULT_VALUE':
                target.setPropertyToDefault('Name')
            else:
                target.setPropertyValue('Name', target.getPropertyValue('Name'))
        current = raw_property(target, information, 'Name')
        permitted = {**expected, 'value': current['value']}
        if current != permitted:
            raise ValueError('Temporary native Name changed source property metadata or state')
    elif current != expected:
        raise ValueError('A clone cannot invent an absent Name property')
    native_name = semantic_value('Name', target.getName())
    if len(native_name) != 2 or native_name[0] != 'string':
        raise ValueError('The clone has no verified temporary native name')
    return current, native_name


def restore_name(target, expected, native_value):
    original_name = expected['XNamed']
    if len(original_name) != 2 or original_name[0] != 'string':
        raise ValueError('The original native name is not a verified string')
    if target.getName() != original_name[1]:
        target.setName(original_name[1])
    information = target.getPropertySetInfo()
    source = expected['Name']
    current = raw_property(target, information, 'Name')
    if source['present']:
        if not current.get('present') or current['attributes'] & 16 and current != source:
            raise ValueError('The retired source Name property cannot be restored')
        if current['value'] != source['value']:
            target.setPropertyValue('Name', native_value)
        current = raw_property(target, information, 'Name')
        if current['state'] != source['state']:
            if source['state'][-1] == 'DEFAULT_VALUE':
                target.setPropertyToDefault('Name')
            else:
                target.setPropertyValue('Name', native_value)
    if (raw_property(target, information, 'Name') != source or
            semantic_value('Name', target.getName()) != original_name):
        raise ValueError('The clone did not regain the exact source Name and native state after retirement')


def materialize_new(catalog, image, before):
    expected = raw_image_state(image)
    information = image.getPropertySetInfo()
    for name in NEW_DEFAULT_FIELDS:
        record = expected[name]
        if not record.get('present') or record['attributes'] & 16:
            raise ValueError('The verified new-image property batch is unavailable')
        value = image.getPropertyValue(name)
        image.setPropertyValue(name, value)
        if raw_property(image, information, name)['value'] != record['value'] or not same(actual_added(catalog, before), image):
            raise ValueError('New-image property materialization changed a value or native identity')
    actual = raw_image_state(image)
    for name, record in expected.items():
        if name in NEW_DEFAULT_FIELDS:
            if actual[name]['value'] != record['value'] or actual[name]['state'][-1] != 'DIRECT_VALUE':
                raise ValueError('New-image finite property batch did not reach its verified final state')
        elif actual[name] != record:
            raise ValueError('New-image property materialization changed an unrelated field')


def delta(target=None, token=None, removed=None):
    return {'target': target, 'token': token, 'remove': removed, 'insertions': 0, 'removals': 0}


def planned(catalog, change):
    state = catalog.word.verification_state(image_delta=change)
    if change['insertions'] != int(change['target'] is not None) or change['removals'] != int(change['remove'] is not None):
        raise ValueError('The planned image change is not bound to exactly its native paragraph and Frame')
    return state, list(catalog.word.export_bindings)


def commit(catalog, identifier, image, bindings, order, retired=False):
    catalog.expected_bindings = bindings
    catalog.pending_bindings = None
    catalog.frame_order = order
    catalog.mutations_changed = True
    catalog.image_changed = True
    if retired:
        catalog.images.pop(identifier)
        catalog.retired_images.add(identifier)
    else:
        catalog.images[identifier] = image
        catalog.word.used_ids.add(identifier)


def add(catalog, operation, asset):
    identifier, rows, target, size = request(catalog, operation, 'wordImageAdd', asset)
    order = requested_order(catalog, rows, target, added=identifier)
    activate(catalog, rows)
    token = {}
    expected, _ = planned(catalog, delta(target, token))
    before = inventory(catalog)
    descriptor = catalog.word.document.createInstance('com.sun.star.text.TextGraphicObject')
    graphic = office_images.load_graphic(catalog.word.context, asset, catalog.word.prop, catalog.word.uno)
    for name, value in (('Graphic', graphic), ('AnchorType', catalog.word.uno.Enum(
            'com.sun.star.text.TextContentAnchorType', 'AS_CHARACTER')), ('Width', size[0]), ('Height', size[1]),
            ('LeftMargin', 0), ('RightMargin', 0), ('TopMargin', 0), ('BottomMargin', 0)):
        descriptor.setPropertyValue(name, value)
    try:
        catalog.word.body.text.insertTextContent(target['cursor'], descriptor, False)
        actual = actual_added(catalog, before)
        materialize_new(catalog, actual, before)
        added = binding(actual, catalog.word.body.text, catalog)
        if (added['format']['AnchorType'][-1] != 'AS_CHARACTER' or
                added['format']['Width'] != ('integer', size[0]) or added['format']['Height'] != ('integer', size[1]) or
                added['graphic']['sha256'] != office_presentation.graphic_digest(
                    catalog.word.context, graphic, catalog.word.uno, catalog.word.prop) or
                any(added['format'][name] != ('integer', 0) for name in ('LeftMargin', 'RightMargin', 'TopMargin', 'BottomMargin'))):
            raise ValueError('The actual inserted image differs from its requested asset and geometry')
        added = projected_binding(added, len(before))
        token.update(kind='image', format=added['format'], graphic=added['graphic'])
        bindings = [*catalog.expected_bindings, added]
        verify(catalog, expected, bindings)
        commit(catalog, identifier, actual, bindings, order)
    finally:
        catalog.pending_bindings = None


def delete(catalog, operation):
    identifier, rows, _, _ = request(catalog, operation, 'wordImageDelete')
    image = catalog.images[identifier]
    old = next(row for row in catalog.expected_bindings if same(row['image'], image))
    old_z = old['format']['ZOrder'][1]
    order = requested_order(catalog, rows, remove=identifier)
    activate(catalog, rows)
    expected, source_tokens = planned(catalog, delta(removed=image))
    survivors = [projected_binding(row, row['format']['ZOrder'][1] - int(row['format']['ZOrder'][1] > old_z))
        for row in catalog.expected_bindings if not same(row['image'], image)]
    project_tokens(source_tokens, [(row['image'], row['format']['ZOrder'][1]) for row in survivors])
    try:
        catalog.word.body.text.removeTextContent(image)
        verify(catalog, expected, survivors)
        commit(catalog, identifier, None, survivors, order, retired=True)
    finally:
        catalog.pending_bindings = None


def move(catalog, operation):
    identifier, rows, target, _ = request(catalog, operation, 'wordImageMove')
    image = catalog.images[identifier]
    old = next(row for row in catalog.expected_bindings if same(row['image'], image))
    old_z = old['format']['ZOrder'][1]
    order = requested_order(catalog, rows, target, remove=identifier, added=identifier)
    activate(catalog, rows)
    staged = projected_binding(old, len(rows))
    token = {'kind': 'image', 'format': staged['format'], 'graphic': staged['graphic']}
    coexist, _ = planned(catalog, delta(target, token))
    expected, source_tokens = planned(catalog, delta(target, token, image))
    before = inventory(catalog)
    descriptor = catalog.word.document.createInstance('com.sun.star.text.TextGraphicObject')
    for name in ('Graphic', 'AnchorType', 'Width', 'Height', 'LeftMargin', 'RightMargin', 'TopMargin', 'BottomMargin'):
        descriptor.setPropertyValue(name, property_value(image, name))
    try:
        catalog.word.body.text.insertTextContent(target['cursor'], descriptor, False)
        actual = actual_added(catalog, before)
        copy_native(image, actual, defer_name=True)
        replacement = {**staged, 'image': actual, 'text': catalog.word.body.text}
        native_name_value = image.getPropertyValue('Name') if old['raw']['Name']['present'] else None
        name_property, native_name = temporary_name(actual, old['raw'])
        replacement['raw'] = copy.deepcopy(staged['raw'])
        replacement['raw']['Name'] = name_property
        replacement['raw']['XNamed'] = native_name
        verify(catalog, coexist, [*catalog.expected_bindings, replacement])
        final_z = len(rows) - 1
        replacement = projected_binding({**old, 'image': actual, 'text': catalog.word.body.text}, final_z)
        token['format'] = replacement['format']
        survivors = [projected_binding(row, row['format']['ZOrder'][1] - int(row['format']['ZOrder'][1] > old_z))
            for row in catalog.expected_bindings if not same(row['image'], image)]
        project_tokens(source_tokens, [(row['image'], row['format']['ZOrder'][1]) for row in survivors])
        catalog.word.body.text.removeTextContent(image)
        restore_name(actual, old['raw'], native_name_value)
        bindings = [*survivors, replacement]
        verify(catalog, expected, bindings)
        commit(catalog, identifier, actual, bindings, order)
    finally:
        catalog.pending_bindings = None
