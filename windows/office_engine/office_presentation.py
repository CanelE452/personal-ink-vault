import hashlib
import json
import math

import office_text
import office_presentation_tables


LAYOUT_OPTIONS = ({'code': 0, 'label': '제목'}, {'code': 1, 'label': '제목과 내용'},
    {'code': 19, 'label': '제목만'}, {'code': 20, 'label': '빈 슬라이드'})
TEXT_PLACEHOLDERS = {'com.sun.star.presentation.' + name
    for name in ('TitleTextShape', 'OutlinerShape', 'SubtitleShape')}


def optional(value, name):
    try:
        if value.getPropertySetInfo().hasPropertyByName(name):
            return value.getPropertyValue(name)
    except Exception:
        pass
    return None


def writable(value, *names):
    try:
        information = value.getPropertySetInfo()
        return all(information.hasPropertyByName(name) and
            not information.getPropertyByName(name).Attributes & 16 for name in names)
    except Exception:
        return False


def design_hash(master_id, layout):
    if not isinstance(master_id, str) or type(layout) is not int:
        return None
    encoded = json.dumps({'layoutCode': layout, 'masterId': master_id}, sort_keys=True,
        separators=(',', ':'), ensure_ascii=False).encode('utf-8')
    return hashlib.sha256(encoded).hexdigest()


def content_inventory(shape):
    try:
        content = shape.String
        known_text = isinstance(content, str)
    except Exception:
        content, known_text = None, False
    result = {'textKnown': known_text, 'text': content if known_text else None, 'canRetire': False}
    try:
        native_type = shape.getShapeType()
        if native_type not in TEXT_PLACEHOLDERS or optional(shape, 'IsPresentationObject') is not True or content != '':
            return result
        information = shape.getPropertySetInfo()
        for name in ('Graphic', 'GraphicBitmap', 'GraphicURL', 'GraphicStreamURL', 'EmbeddedObject', 'OLEModel', 'Model'):
            if information.hasPropertyByName(name):
                payload = shape.getPropertyValue(name)
                if payload is not None and payload != '':
                    return result
        details = office_text.text_details(shape)
        result['canRetire'] = (known_text and details.get('utf16Length') == 0 and
            details.get('textSha256') == hashlib.sha256(b'').hexdigest() and
            details.get('truncated') is False and details.get('protectedRanges') == [] and
            details.get('canReplace') is True and details.get('canStyle') is True and
            isinstance(details.get('runs'), list) and all(
                run.get('startUtf16') == run.get('endUtf16') == 0 for run in details['runs']))
    except Exception:
        result['canRetire'] = False
    return result


def graphic_digest(context, graphic, uno, prop):
    if context is None or graphic is None or uno is None or prop is None:
        raise ValueError('Master image content could not be verified')
    if graphic.MimeType not in ('image/png', 'image/jpeg'):
        raise ValueError('This master image format cannot be verified for a design change')
    width, height = graphic.SizePixel.Width, graphic.SizePixel.Height
    if width < 1 or height < 1 or width * height > 40000000:
        raise ValueError('Master image content exceeds the verification limit')
    stream = None
    try:
        stream = context.ServiceManager.createInstanceWithContext('com.sun.star.io.TempFile', context)
        stream.RemoveFile = True
        provider = context.ServiceManager.createInstanceWithContext('com.sun.star.graphic.GraphicProvider', context)
        provider.storeGraphic(graphic, (prop('OutputStream', stream), prop('MimeType', graphic.MimeType)))
        size = stream.getLength()
        if not 0 < size <= 20 * 1024 * 1024:
            raise ValueError('Master image content exceeds the verification byte limit')
        stream.seek(0)
        digest, remaining = hashlib.sha256(), size
        while remaining:
            requested = min(1024 * 1024, remaining)
            count, sequence = stream.getInputStream().readBytes(None, requested)
            payload = bytes(sequence)
            if count != requested or len(payload) != requested:
                raise ValueError('Master image verification returned incomplete content')
            digest.update(payload)
            remaining -= requested
        return digest.hexdigest()
    finally:
        if stream is not None:
            for getter, close in (('getInputStream', 'closeInput'), ('getOutputStream', 'closeOutput')):
                try:
                    getattr(getattr(stream, getter)(), close)()
                except Exception:
                    pass


def master_fingerprint(master, image_hashes=None):
    if not isinstance(master, dict) or master.get('backgroundStyle') not in ('none', 'solid'):
        raise ValueError('Master background cannot be verified after saving')
    for name in ('width', 'height'):
        value = master.get(name)
        if type(value) not in (int, float) or not math.isfinite(value) or value <= 0:
            raise ValueError('Master dimensions cannot be verified after saving')
    if master['backgroundStyle'] == 'solid' and (type(master.get('backgroundColor')) is not int or
            not 0 <= master['backgroundColor'] <= 0xffffff):
        raise ValueError('Master background color is unknown')
    result = {'width': master.get('width'), 'height': master.get('height'),
        'backgroundStyle': master['backgroundStyle'],
        'backgroundColor': master.get('backgroundColor') if master['backgroundStyle'] == 'solid' else None,
        'decorations': []}
    for shape in master.get('shapes', []):
        if shape.get('presentationObject') is True:
            continue
        if shape.get('presentationObject') is not False:
            raise ValueError('Master contains objects with unknown ownership roles')
        native = shape.get('type', '').rsplit('.', 1)[-1]
        if native not in ('TextShape', 'CustomShape', 'RectangleShape', 'EllipseShape', 'LineShape', 'GraphicObjectShape'):
            raise ValueError('Master contains a decoration that cannot be verified after saving')
        if native == 'CustomShape' and shape.get('shapeKind') not in ('text', 'rectangle', 'ellipse', 'line'):
            raise ValueError('Master contains unsupported custom shape geometry')
        normalized_kind = ({'TextShape': 'rectangle', 'RectangleShape': 'rectangle',
            'EllipseShape': 'ellipse', 'LineShape': 'line', 'GraphicObjectShape': 'image'}.get(native)
            if native != 'CustomShape' else {'text': 'rectangle', 'rectangle': 'rectangle',
                'ellipse': 'ellipse', 'line': 'line'}[shape['shapeKind']])
        fill, line = shape.get('fillStyle'), shape.get('lineStyle')
        if fill not in ('none', 'solid') or line not in ('none', 'solid'):
            raise ValueError('Master decoration appearance cannot be verified after saving')
        entry = {name: shape.get(name) for name in ('x', 'y', 'width', 'height')}
        if any(type(value) not in (int, float) or not math.isfinite(value) for value in entry.values()):
            raise ValueError('Master decoration geometry is unknown')
        entry.update({'shapeKind': normalized_kind, 'text': shape.get('text'), 'fillStyle': fill,
            'fillColor': shape.get('fillColor') if fill == 'solid' else None,
            'lineStyle': line, 'lineColor': shape.get('lineColor') if line == 'solid' else None,
            'lineWidth': shape.get('lineWidth') if line == 'solid' else None})
        if shape.get('text'):
            entry.update({name: shape.get(name) for name in ('fontSize', 'bold', 'color')})
            details = shape.get('textDetails')
            if details is not None:
                if details.get('truncated') is not False or details.get('protectedRanges') != []:
                    raise ValueError('Master decoration text contains unverifiable protected content')
                entry['runs'] = details.get('runs')
        if native == 'GraphicObjectShape' or shape.get('image') is not None:
            if image_hashes is None or shape.get('id') not in image_hashes:
                raise ValueError('Master image content has no verified full-content digest')
            entry['imageSha256'] = image_hashes[shape['id']]
        result['decorations'].append(entry)
    return result


def same_fingerprint(expected, actual, key=None, *, geometry_tolerance=1):
    if type(geometry_tolerance) is not int or geometry_tolerance not in (1, 2):
        raise ValueError('Expected one or two controlled geometry normalization units')
    if key in ('x', 'y', 'width', 'height', 'lineWidth') and expected is not None and actual is not None:
        if (type(expected) not in (int, float) or type(actual) not in (int, float) or
                not math.isfinite(expected) or not math.isfinite(actual)):
            return False
        return abs(round(expected * 100) - round(actual * 100)) <= geometry_tolerance
    if isinstance(expected, dict) and isinstance(actual, dict):
        return expected.keys() == actual.keys() and all(same_fingerprint(value, actual[name], name,
            geometry_tolerance=geometry_tolerance)
            for name, value in expected.items())
    if isinstance(expected, list) and isinstance(actual, list):
        return len(expected) == len(actual) and all(same_fingerprint(left, right,
            geometry_tolerance=geometry_tolerance) for left, right in zip(expected, actual))
    return type(expected) is type(actual) and expected == actual


class Presentation:
    def __init__(self, document, slides, shapes, source_path=None):
        self.document, self.slides, self.shapes = document, slides, shapes
        self.physical, self.logical = list(slides), list(slides)
        self.masters = {'master-' + str(index): document.MasterPages.getByIndex(index)
            for index in range(document.MasterPages.Count)}
        self.owners = {identifier: identifier.rsplit('/shape-', 1)[0] for identifier in shapes}
        for master_id, master in self.masters.items():
            for index in range(master.Count):
                identifier = master_id + '/shape-' + str(index)
                self.shapes[identifier], self.owners[identifier] = master.getByIndex(index), master_id
        self.used = set(slides) | set(self.masters) | set(shapes)
        self.change_ids = set()
        self.design_touched, self.display_touched = set(), {}
        self.prepared_images = {}
        self.table_catalog = office_presentation_tables.PresentationTables(self, document, source_path)

    def owner(self, identifier):
        if not isinstance(identifier, str):
            raise ValueError('Expected a presentation owner identity')
        if identifier in self.slides:
            return self.slides[identifier]
        if identifier in self.masters:
            return self.masters[identifier]
        raise ValueError('Unknown presentation owner identity')

    def owner_kind(self, identifier):
        if identifier in self.slides:
            return 'slide'
        if identifier in self.masters:
            return 'master'
        raise ValueError('Unknown presentation owner identity')

    def assert_fresh(self, identifier):
        if (not isinstance(identifier, str) or not identifier or identifier in self.used or
                any(identifier.startswith(change + '/') or change.startswith(identifier + '/')
                    for change in self.change_ids)):
            raise ValueError('Presentation identity or reserved namespace was already used')

    def register_shape(self, identifier, shape, owner):
        self.owner(owner)
        self.shapes[identifier], self.owners[identifier] = shape, owner
        self.used.add(identifier)

    def shape_items(self, owner_id):
        owner = self.owner(owner_id)
        ordered = [(identifier, shape) for identifier, shape in self.shapes.items()
            if self.owners[identifier] == owner_id]
        if len(ordered) != owner.Count or any(shape != owner.getByIndex(index)
                for index, (_, shape) in enumerate(ordered)):
            raise ValueError('Presentation shape ownership or order could not be verified')
        return ordered

    def master_id(self, slide):
        try:
            native = slide.getMasterPage()
            matches = [identifier for identifier, master in self.masters.items() if master == native]
            return matches[0] if len(matches) == 1 else None
        except Exception:
            return None

    def slide_metadata(self, identifier):
        slide = self.slides[identifier]
        master_id = self.master_id(slide)
        layout = optional(slide, 'Layout')
        layout = layout if type(layout) is int else None
        visible, objects = optional(slide, 'Visible'), optional(slide, 'IsBackgroundObjectsVisible')
        return {'masterId': master_id, 'layoutCode': layout, 'designSha256': design_hash(master_id, layout),
            'visible': visible if type(visible) is bool else None,
            'showMasterObjects': objects if type(objects) is bool else None}

    def shape_metadata(self, identifier):
        shape, owner = self.shapes[identifier], self.owners[identifier]
        kind = self.owner_kind(owner)
        presentation, empty = optional(shape, 'IsPresentationObject'), optional(shape, 'IsEmptyPresentationObject')
        presentation = presentation if type(presentation) is bool else None
        empty = empty if type(empty) is bool else None
        mutable = (getattr(shape, 'ShapeType', None) != office_presentation_tables.TABLE_TYPE and
            presentation is not None and (kind != 'master' or presentation is False))
        geometry = mutable and optional(shape, 'MoveProtect') is False and optional(shape, 'SizeProtect') is False
        return {'ownerKind': kind, 'ownerId': owner, 'presentationObject': presentation,
            'emptyPresentationObject': empty, 'canEditGeometry': geometry, 'canDelete': mutable,
            'canEditTextStyle': mutable and writable(shape, 'CharHeight', 'CharWeight', 'CharColor')}

    def require_edit(self, identifier, operation):
        if identifier not in self.shapes:
            raise ValueError('Unknown presentation shape identity')
        if getattr(self.shapes[identifier], 'ShapeType', None) == office_presentation_tables.TABLE_TYPE:
            raise ValueError('Presentation tables require their verified table operation path')
        metadata = self.shape_metadata(identifier)
        if metadata['presentationObject'] is None or (
                metadata['ownerKind'] == 'master' and metadata['presentationObject'] is not False):
            raise ValueError('Master template placeholders or unknown objects cannot be edited as content')
        flag = {'geometry': 'canEditGeometry', 'delete': 'canDelete', 'textStyle': 'canEditTextStyle'}.get(operation)
        if flag is not None and not metadata[flag]:
            raise ValueError('This presentation shape does not support the requested edit')

    def refresh(self, change_id, before):
        native_masters = [self.document.MasterPages.getByIndex(index) for index in range(self.document.MasterPages.Count)]
        for identifier, master in self.masters.items():
            if sum(master == native for native in native_masters) != 1:
                raise ValueError('A design change removed or replaced a shared master')
        next_master = 0
        for master in native_masters:
            if any(master == previous for previous in self.masters.values()):
                continue
            identifier = change_id + '/master-' + str(next_master)
            next_master += 1
            if identifier in self.used:
                raise ValueError('Generated presentation master identity was already used')
            self.masters[identifier] = master
            self.used.add(identifier)
        replacement, owners, next_shape = {}, {}, 0
        for owner_id in [*self.physical, *self.masters]:
            owner = self.owner(owner_id)
            old = {identifier: shape for identifier, shape in self.shapes.items() if self.owners[identifier] == owner_id}
            for index in range(owner.Count):
                native = owner.getByIndex(index)
                matches = [identifier for identifier, shape in old.items() if shape == native]
                if len(matches) > 1:
                    raise ValueError('Presentation shape identity is ambiguous')
                if matches:
                    identifier = matches[0]
                    old.pop(identifier)
                    previous = before[identifier]
                    current = content_inventory(native)
                    if previous['textKnown'] and (not current['textKnown'] or current['text'] != previous['text']):
                        raise ValueError('Design change altered the content of a surviving shape')
                else:
                    identifier = change_id + '/shape-' + str(next_shape)
                    next_shape += 1
                    if identifier in self.used:
                        raise ValueError('Generated presentation shape identity was already used')
                    self.used.add(identifier)
                replacement[identifier], owners[identifier] = native, owner_id
            for identifier in old:
                if before[identifier]['canRetire'] is not True:
                    raise ValueError('Design change would remove content, an ordinary shape, or an unknown object')
        self.shapes.clear()
        self.shapes.update(replacement)
        self.owners.clear()
        self.owners.update(owners)

    def design(self, operation):
        allowed = {'op', 'id', 'changeId', 'expectedDesignSha256', 'masterId', 'layoutCode'}
        if set(operation) - allowed:
            raise ValueError('Invalid presentation design fields')
        identifier = operation.get('id')
        if not isinstance(identifier, str) or identifier not in self.slides:
            raise ValueError('A design change requires an actual slide')
        current = self.slide_metadata(identifier)
        if current['designSha256'] is None or operation.get('expectedDesignSha256') != current['designSha256']:
            raise ValueError('Slide design changed since inspection')
        change_id = operation.get('changeId')
        if (not isinstance(change_id, str) or not 1 <= len(change_id) <= 128 or
                any(change_id == used or change_id.startswith(used + '/') or used.startswith(change_id + '/') for used in self.used)):
            raise ValueError('Invalid or previously reserved presentation design identity')
        change_id.encode('utf-8')
        if not any(operation.get(name) is not None for name in ('masterId', 'layoutCode')):
            raise ValueError('Expected a master or a standard layout selection')
        master_id, layout = operation.get('masterId'), operation.get('layoutCode')
        if master_id is not None and (not isinstance(master_id, str) or master_id not in self.masters):
            raise ValueError('Unknown presentation master identity')
        if layout is not None and (type(layout) is not int or layout not in {item['code'] for item in LAYOUT_OPTIONS}):
            raise ValueError('Unsupported presentation layout selection')
        before = {key: content_inventory(shape) for key, shape in self.shapes.items()}
        previous_display = {key: self.slide_metadata(key) for key in self.slides}
        self.used.add(change_id)
        self.change_ids.add(change_id)
        page = self.slides[identifier]
        if master_id is not None and master_id != current['masterId']:
            target = self.masters[master_id]
            dimensions = (optional(page, 'Width'), optional(page, 'Height'), optional(target, 'Width'), optional(target, 'Height'))
            if any(type(value) is not int or value <= 0 for value in dimensions) or dimensions[:2] != dimensions[2:]:
                raise ValueError('Changing to a master with different page dimensions is unsupported')
            page.setMasterPage(self.masters[master_id])
        if layout is not None and optional(page, 'Layout') != layout:
            if not writable(page, 'Layout'):
                raise ValueError('This slide does not support a standard layout selection')
            page.setPropertyValue('Layout', layout)
        self.refresh(change_id, before)
        actual = self.slide_metadata(identifier)
        if (master_id is not None and actual['masterId'] != master_id or
                layout is not None and actual['layoutCode'] != layout):
            raise ValueError('Native slide design did not retain the requested selection')
        for key, previous in previous_display.items():
            current_display = self.slide_metadata(key)
            for name in ('visible', 'showMasterObjects'):
                if type(previous[name]) is bool and current_display[name] is not previous[name]:
                    raise ValueError('Design change altered an existing slide display setting')
        self.design_touched.add(identifier)

    def display(self, operation):
        if set(operation) - {'op', 'id', 'visible', 'showMasterObjects'}:
            raise ValueError('Invalid presentation display fields')
        identifier = operation.get('id')
        if not isinstance(identifier, str) or identifier not in self.slides:
            raise ValueError('Slide display requires an actual slide')
        selected = [name for name in ('visible', 'showMasterObjects') if name in operation]
        if not selected or any(type(operation[name]) is not bool for name in selected):
            raise ValueError('Expected at least one explicit boolean slide display property')
        page = self.slides[identifier]
        for name in selected:
            native = {'visible': 'Visible', 'showMasterObjects': 'IsBackgroundObjectsVisible'}[name]
            if optional(page, native) is None or not writable(page, native):
                raise ValueError('Slide display property is unsupported')
            description = page.getPropertySetInfo().getPropertyByName(native)
            if description.Type.typeName != 'boolean':
                raise ValueError('Slide display property is not a native boolean')
            page.setPropertyValue(native, operation[name])
            if optional(page, native) is not operation[name]:
                raise ValueError('Slide display did not retain the requested boolean')
        self.display_touched.setdefault(identifier, set()).update(selected)

    def requires_reopen_verification(self):
        return any(identifier in self.slides for identifier in self.design_touched | set(self.display_touched))

    def image_hashes(self, native_master, snapshot_master, context, uno, prop):
        native_shapes = [native_master.getByIndex(index) for index in range(native_master.Count)]
        snapshots = snapshot_master.get('shapes', [])
        if len(native_shapes) != len(snapshots):
            raise ValueError('Master shape content could not be matched for verification')
        result = {}
        for shape, item in zip(native_shapes, snapshots):
            if item.get('presentationObject') is False and shape.getShapeType().endswith('.GraphicObjectShape'):
                crop = shape.GraphicCrop
                result[item['id']] = {'sha256': graphic_digest(context, shape.Graphic, uno, prop),
                    'rotation': shape.RotateAngle, 'crop': [crop.Left, crop.Top, crop.Right, crop.Bottom]}
        return result

    def prepare_reopen(self, live, context, uno, prop):
        selected = {slide['masterId'] for slide in live['slides'] if slide['id'] in self.design_touched}
        masters = {master['id']: master for master in live['masters']}
        for identifier in selected:
            if identifier not in masters or identifier not in self.masters:
                raise ValueError('Selected live master could not be verified')
            hashes = self.image_hashes(self.masters[identifier], masters[identifier], context, uno, prop)
            master_fingerprint(masters[identifier], hashes)
            self.prepared_images[identifier] = hashes

    def verify_reopened(self, live, reopened, document=None, context=None, uno=None, prop=None, *, serialization_count=1):
        if not self.requires_reopen_verification():
            return
        if type(serialization_count) is not int or serialization_count not in (1, 2):
            raise ValueError('Expected one or two controlled presentation serialization passes')
        before, after = live.get('slides'), reopened.get('slides')
        if (not isinstance(before, list) or not isinstance(after, list) or len(before) != len(self.logical) or
                len(after) != len(before) or [slide.get('id') for slide in before] != self.logical):
            raise ValueError('Saved presentation slide order could not be verified')
        source_masters = {master['id']: master for master in live.get('masters', [])}
        saved_masters = {master['id']: master for master in reopened.get('masters', [])}
        for index, (expected, actual) in enumerate(zip(before, after)):
            identifier = expected['id']
            design_changed = identifier in self.design_touched
            fields = set(self.display_touched.get(identifier, set()))
            if design_changed:
                if type(expected.get('layoutCode')) is not int or type(actual.get('layoutCode')) is not int or actual['layoutCode'] != expected['layoutCode']:
                    raise ValueError('Saved slide layout did not retain the requested selection')
                fields.update(name for name in ('visible', 'showMasterObjects') if type(expected.get(name)) is bool)
                source_id, saved_id = expected.get('masterId'), actual.get('masterId')
                if source_id not in source_masters or saved_id not in saved_masters:
                    raise ValueError('Saved slide master connection could not be verified')
                hashes = None
                if document is not None:
                    native_master = document.DrawPages.getByIndex(index).getMasterPage()
                    hashes = self.image_hashes(native_master, saved_masters[saved_id], context, uno, prop)
                source = master_fingerprint(source_masters[source_id], self.prepared_images.get(source_id))
                target = master_fingerprint(saved_masters[saved_id], hashes)
                if not same_fingerprint(source, target, geometry_tolerance=serialization_count):
                    raise ValueError('Saved slide master decoration or background changed')
            for field in fields:
                if type(expected.get(field)) is not bool or type(actual.get(field)) is not bool or actual[field] is not expected[field]:
                    raise ValueError('Saved slide display did not retain the requested boolean')
