"""Writer page-style observations and actual native text-owner registry."""
import hashlib
import json
import copy
from decimal import Decimal, InvalidOperation

import office_word
from office_word_fidelity import content_blocks, paragraph_content, saved_reopen_state
from office_word_objects import WordObjectRegistry


LAYOUT_PROPERTIES = {'width': 'Width', 'height': 'Height', 'leftMargin': 'LeftMargin',
    'rightMargin': 'RightMargin', 'topMargin': 'TopMargin', 'bottomMargin': 'BottomMargin',
    'landscape': 'IsLandscape', 'headerIsOn': 'HeaderIsOn', 'footerIsOn': 'FooterIsOn',
    'headerIsShared': 'HeaderIsShared', 'footerIsShared': 'FooterIsShared',
    'firstIsShared': 'FirstIsShared', 'pageLayout': 'PageStyleLayout'}
MEASUREMENTS = {'width', 'height', 'leftMargin', 'rightMargin', 'topMargin', 'bottomMargin'}
REGION_PROPERTIES = {'default': '', 'left': 'Left', 'right': 'Right', 'first': 'First'}
GEOMETRY_PROPERTIES = {key: value for key, value in LAYOUT_PROPERTIES.items()
    if key in MEASUREMENTS or key == 'landscape'}


def layout_hash(raw):
    return hashlib.sha256(json.dumps(raw, ensure_ascii=False,
        sort_keys=True, separators=(',', ':')).encode('utf-8')).hexdigest()


def normalized_hmm(value):
    twips = (value * 144 + 127) // 254
    return (twips * 254 + 72) // 144


def millimetres(value):
    if type(value) not in (int, float):
        raise ValueError('Page geometry requires finite millimetre numbers')
    try:
        decimal = Decimal(str(value))
        scaled = decimal * 100
        if not decimal.is_finite() or decimal < 0 or decimal > 1000 or scaled != scaled.to_integral_value():
            raise ValueError('Page geometry must use nonnegative millimetres with at most two decimal places')
        return int(scaled)
    except InvalidOperation as error:
        raise ValueError('Invalid page geometry number') from error


def geometry_values(operation, raw):
    allowed = {'op', 'id', 'expectedLayoutSha256'} | set(GEOMETRY_PROPERTIES)
    requested = set(operation) & set(GEOMETRY_PROPERTIES)
    if set(operation) - allowed or not requested:
        raise ValueError('Invalid page geometry operation fields')
    size = {'width', 'height', 'landscape'}
    if requested & size and not size <= requested:
        raise ValueError('Page width, height and orientation must be supplied together')
    assigned, expected = {}, dict(raw)
    for key in requested:
        name, value = GEOMETRY_PROPERTIES[key], operation[key]
        if key == 'landscape':
            if type(value) is not bool:
                raise ValueError('Invalid page orientation')
            assigned[name] = expected[name] = value
        else:
            hmm = millimetres(value)
            if key in ('width', 'height') and hmm == 0:
                raise ValueError('Page dimensions must be positive')
            assigned[name], expected[name] = hmm, normalized_hmm(hmm)
    width, height = expected['Width'], expected['Height']
    if (not 0 < width <= 100000 or not 0 < height <= 100000
            or any(expected[name] < 0 for name in ('LeftMargin', 'RightMargin', 'TopMargin', 'BottomMargin'))
            or expected['IsLandscape'] and width <= height or not expected['IsLandscape'] and height <= width
            or expected['LeftMargin'] + expected['RightMargin'] >= width
            or expected['TopMargin'] + expected['BottomMargin'] >= height):
        raise ValueError('Page geometry has inconsistent orientation or no positive body area')
    return assigned, expected


def style_property(style, name):
    try:
        return style.getPropertyValue(name)
    except Exception:
        return None


def raw_layout(style):
    result = {}
    for name in LAYOUT_PROPERTIES.values():
        value = style_property(style, name)
        value = getattr(value, 'value', value)
        result[name] = value if value is None or type(value) in (str, bool, int, float) else None
    return result


def page_metadata(style, identifier, name):
    raw = raw_layout(style)
    result = {'id': identifier, 'name': name,
        'displayName': style_property(style, 'DisplayName') or name,
        'layoutSha256': layout_hash(raw)}
    try:
        result['inUse'] = bool(style.isInUse())
    except Exception:
        result['inUse'] = None
    for key, name in LAYOUT_PROPERTIES.items():
        value = raw[name]
        result[key] = value / 100 if key in MEASUREMENTS and type(value) in (int, float) else value
    return result


class WordDocument:
    def __init__(self, document, paragraphs, tables, uno, prop, context=None):
        self.document, self.tables = document, tables
        self.uno, self.prop = uno, prop
        self.context = context
        self.used_ids = set(paragraphs) | set(tables) | {'body'}
        self._counters = {}
        self.body = office_word.WordBody(document, paragraphs, tables, uno, prop,
            used_ids=self.used_ids, allocate_id=self.allocate_id)
        self.scopes = {'body': self.body}
        self.owners, self.page_styles = [], []
        self.styles, self.style_names = {}, {}
        self.has_geometry = False
        self._images = None
        self._images_initialized = False
        self._preserve_source_images = False
        try:
            url = document.getURL()
            self.geometry_format = url.rsplit('.', 1)[-1].lower() if isinstance(url, str) and url else None
        except Exception:
            self.geometry_format = None
        family = document.StyleFamilies.getByName('PageStyles')
        for name in family.ElementNames:
            style = family.getByName(name)
            row = page_metadata(style, self.allocate_id('word-page-style'), name)
            self.styles[row['id']] = style
            self.style_names[name] = row['id']
            row['regions'] = {}
            for kind, prefix in [('header', 'HeaderText'), ('footer', 'FooterText')]:
                row['regions'][kind] = {}
                for variant, suffix in REGION_PROPERTIES.items():
                    text = style_property(style, prefix + suffix)
                    identifier = self.identify(text, kind) if text is not None else None
                    row['regions'][kind][variant] = identifier
                    if identifier is not None:
                        owner = next(item for item in self.owners if item['id'] == identifier)
                        owner['references'].append({'pageStyleId': row['id'], 'variant': variant})
            self.page_styles.append(row)
        self.table_owners = self.locate_tables()
        self.refresh_page_metadata()

    def image_catalog(self):
        if not self._images_initialized:
            self._images_initialized = True
            try:
                from office_word_images import WordImages
                self._images = WordImages(self)
                self._preserve_source_images = self._images.source_bindings is not None
            except Exception:
                self._images = None
        return self._images

    def requires_reopen_verification(self):
        return (self.has_geometry or self._preserve_source_images or
            self._images is not None and self._images.image_changed)

    def body_style_usage(self):
        try:
            family = self.document.StyleFamilies.getByName('PageStyles')
            elements = office_word.body_elements(self.document)
            if len(elements) != len(self.body.order):
                return None
            result = {}
            for position, ((kind, _, value), block) in enumerate(zip(elements, self.body.order)):
                if kind != block['kind']:
                    return None
                if kind != 'paragraph':
                    continue
                name = style_property(value, 'PageStyleName')
                if not isinstance(name, str) or name not in self.style_names or not family.hasByName(name):
                    return None
                result.setdefault(self.style_names[name], []).append(position)
            return result
        except Exception:
            return None

    def can_edit_geometry(self, identifier, usage=None):
        style = self.styles[identifier]
        try:
            if self.geometry_format is None:
                return None
            if self.geometry_format != 'docx':
                return False
            if not style.isInUse():
                return False
            if usage is None:
                usage = self.body_style_usage()
            if usage is None:
                return None
            if identifier not in usage:
                return False
            info = style.getPropertySetInfo()
            for name in GEOMETRY_PROPERTIES.values():
                if not info.hasPropertyByName(name) or info.getPropertyByName(name).Attributes & 16:
                    return False
            raw = raw_layout(style)
            if (type(raw['IsLandscape']) is not bool or any(type(raw[name]) is not int
                    for name in GEOMETRY_PROPERTIES.values() if name != 'IsLandscape')):
                return None
            return True
        except Exception:
            return None

    def refresh_page_metadata(self):
        usage = self.body_style_usage()
        for row in self.page_styles:
            regions = row['regions']
            row.update(page_metadata(self.styles[row['id']], row['id'], row['name']))
            row['regions'] = regions
            row['canEditGeometry'] = self.can_edit_geometry(row['id'], usage)

    def verify_live_regions(self):
        for row in self.page_styles:
            style = self.styles[row['id']]
            for kind, prefix in [('header', 'HeaderText'), ('footer', 'FooterText')]:
                for variant, suffix in REGION_PROPERTIES.items():
                    actual = style_property(style, prefix + suffix)
                    expected_id = row['regions'][kind][variant]
                    expected = None if expected_id is None else self.scopes[expected_id].text
                    if actual != expected:
                        raise ValueError('Page geometry changed a native header or footer owner')

    def geometry(self, operation):
        identifier = operation.get('id')
        if not isinstance(identifier, str) or identifier not in self.styles:
            raise ValueError('Unknown Word page style identity')
        if self.can_edit_geometry(identifier) is not True:
            raise ValueError('This page style has no verified writable body geometry binding')
        raw = raw_layout(self.styles[identifier])
        if operation.get('expectedLayoutSha256') != layout_hash(raw):
            raise ValueError('Word page layout changed since the requested operation')
        assigned, expected = geometry_values(operation, raw)
        expected_state = self.verification_state()
        usage = self.body_style_usage()
        if usage is None or identifier not in usage:
            raise ValueError('Page geometry cannot verify the target body style usage')
        expected_state['stylesByBodyUsage'][tuple(usage[identifier])] = expected
        before = {key: raw_layout(style) for key, style in self.styles.items()}
        for name in ('Width', 'Height', 'IsLandscape', 'LeftMargin', 'RightMargin', 'TopMargin', 'BottomMargin'):
            if name in assigned:
                self.styles[identifier].setPropertyValue(name, assigned[name])
        self.refresh_layout_fields()
        for key, style in self.styles.items():
            if raw_layout(style) != (expected if key == identifier else before[key]):
                raise ValueError('Page geometry readback differs from the verified unit normalization')
        self.verify_live_regions()
        if self.verification_state() != expected_state:
            raise ValueError('Page geometry changed its body style binding or authored content')
        self.has_geometry = True
        self.refresh_page_metadata()

    def refresh_layout_fields(self):
        self.document.TextFields.refresh()
        if int(self.document.CurrentController.PageCount) < 1:
            raise ValueError('Word layout did not produce a valid page count')
        self.document.TextFields.refresh()

    def verification_state(self, image_delta=None):
        usage = self.body_style_usage()
        if not usage:
            raise ValueError('Page geometry cannot verify the actual body style usage')
        by_style = {key: tuple(positions) for key, positions in usage.items()}
        styles = {positions: raw_layout(self.styles[key]) for key, positions in by_style.items()}
        objects = WordObjectRegistry(self.document, self.context, self.uno, self.prop)
        owners = {}
        for owner in self.owners:
            references = []
            for reference in owner['references']:
                if reference['pageStyleId'] in by_style:
                    references.append((by_style[reference['pageStyleId']], owner['kind'], reference['variant']))
            if not references:
                raise ValueError('A header or footer has no verifiable body style binding')
            key = tuple(sorted(references))
            owners[key] = content_blocks(self.scopes[owner['id']].text, objects, image_delta)
        body = content_blocks(self.body.text, objects, image_delta)
        objects.verify_complete()
        self.export_bindings = objects.export_bindings
        if self._images is not None:
            self._images.verify_source(self.export_bindings)
        return {'stylesByBodyUsage': styles, 'body': body, 'ownersByReferences': owners}

    def reopen_verification_state(self):
        state = self.verification_state()
        catalog = self._images
        if catalog is None or not catalog.raw_active:
            return state
        from office_word_image_mutations import raw_image_state
        raw = [raw_image_state(row['image']) for row in self.export_bindings]
        semantic = copy.deepcopy(state)
        if catalog.mutations_changed:
            tokens = []
            def collect(blocks):
                for kind, payload in blocks:
                    if kind == 'table':
                        for _, cell in payload:
                            collect(cell)
                    else:
                        tokens.extend(token[1] for token in payload['portions'] if token[0] == 'object')
            for blocks in semantic['ownersByReferences'].values():
                collect(blocks)
            collect(semantic['body'])
            if len(tokens) != len(raw):
                raise ValueError('Saved image projection differs from the complete native Frame inventory')
            for row, observed, token in zip(self.export_bindings, raw, tokens):
                identifier = next(key for key, image in catalog.images.items() if image == row['image'])
                z = catalog.frame_order.index(identifier)
                token['format']['ZOrder'] = ('integer', z)
                observed['ZOrder']['value'] = ('integer', z)
        return {'semantic': semantic, 'imageRawStates': raw}

    def verify_reopened(self, expected):
        actual = self.verification_state()
        if isinstance(expected, dict) and set(expected) == {'semantic', 'imageRawStates'}:
            from office_word_image_mutations import raw_image_state
            if [raw_image_state(row['image']) for row in self.export_bindings] != expected['imageRawStates']:
                raise ValueError('Saved Word image native values, states or metadata changed')
            expected = expected['semantic']
        if saved_reopen_state(actual) != saved_reopen_state(expected):
            raise ValueError('Saved Word geometry changed its body style binding, layout or authored content')

    def allocate_id(self, prefix):
        index = self._counters.get(prefix, 0)
        identifier = prefix + '-' + str(index)
        while identifier in self.used_ids:
            index += 1
            identifier = prefix + '-' + str(index)
        self._counters[prefix] = index + 1
        self.used_ids.add(identifier)
        return identifier

    def identify(self, text, kind):
        for identifier, scope in self.scopes.items():
            if scope.text == text:
                if identifier == 'body' or next(item for item in self.owners if item['id'] == identifier)['kind'] != kind:
                    raise ValueError('Writer region shares an incompatible native text owner')
                return identifier
        identifier = self.allocate_id('word-owner')
        paragraphs = {self.allocate_id('word-paragraph'): value
            for block_kind, _, value in office_word.body_elements(self.document, text) if block_kind == 'paragraph'}
        scope = office_word.WordBody(self.document, paragraphs, self.tables, self.uno, self.prop,
            text_owner=text, owner_id=identifier, used_ids=self.used_ids, allocate_id=self.allocate_id)
        self.scopes[identifier] = scope
        self.owners.append({'id': identifier, 'kind': kind, 'references': []})
        return identifier

    def locate_tables(self):
        result = {}
        for identifier, table in self.tables.items():
            containing = []
            for owner_id, scope in self.scopes.items():
                if any(kind == 'table' and value == table
                        for kind, _, value in office_word.body_elements(self.document, scope.text)):
                    containing.append(owner_id)
            result[identifier] = containing[0] if len(containing) == 1 else None
        return result

    def paragraph_scope(self, identifier):
        if isinstance(identifier, str):
            for scope in self.scopes.values():
                if identifier in scope.paragraphs:
                    return scope
        raise ValueError('Unknown Word paragraph identity')

    def paragraph(self, identifier):
        return self.paragraph_scope(identifier).paragraph(identifier)

    def apply(self, operation):
        key = 'referenceId' if operation['op'] == 'paragraphInsert' else 'id'
        scope = self.paragraph_scope(operation.get(key))
        if operation['op'] == 'paragraphJoin' and self.paragraph_scope(operation.get('nextId')) is not scope:
            raise ValueError('Word paragraphs must belong to the same native text owner')
        scope.apply(operation)

    def owner_snapshot(self, render_paragraphs):
        result = []
        for row in self.owners:
            scope = self.scopes[row['id']]
            result.append({**row, 'blocks': scope.order, 'paragraphs': render_paragraphs(scope),
                'tableIds': [item['id'] for item in scope.order if item['kind'] == 'table']})
        return result
