"""Ordered Writer body ownership and sequential paragraph operations."""
import office_text

STRUCTURE_OPERATIONS = {'paragraphSplit', 'paragraphInsert', 'paragraphJoin', 'paragraphDelete', 'paragraphFormat'}


def optional(value, name):
    return office_text.property_value(value, name)


def body_elements(document, text_owner=None):
    result = []
    enumeration = (document.Text if text_owner is None else text_owner).createEnumeration()
    while enumeration.hasMoreElements():
        value = enumeration.nextElement()
        if value.supportsService('com.sun.star.text.TextTable'):
            result.append(('table', value.Name, value))
        elif value.supportsService('com.sun.star.text.Paragraph'):
            result.append(('paragraph', None, value))
        else:
            result.append(('opaque', None, value))
    return result


def physical_alignment(adjust, writing_mode):
    if writing_mode not in (0, 1):
        return 'other'
    if adjust in (0, 1, 2, 3):
        return {0: 'left', 1: 'right', 2: 'justify', 3: 'center'}[adjust]
    if adjust not in (5, 6):
        return 'other'
    return ('left' if adjust == 5 else 'right') if writing_mode == 0 else ('right' if adjust == 5 else 'left')


def writing_mode(value, document):
    mode = optional(value, 'WritingMode')
    if mode != 4 or document is None:
        return mode
    try:
        if optional(value, 'TextSection') is not None:
            return None
        text = value.getText()
        text.createTextCursorByRange(value.Start)
        name = optional(value, 'PageStyleName')
        family = document.StyleFamilies.getByName('PageStyles')
        if not isinstance(name, str) or not name or not family.hasByName(name):
            return None
        style = family.getByName(name)
        if text != document.Text and not any(optional(style, prefix + suffix) == text
                for prefix in ('HeaderText', 'FooterText') for suffix in ('', 'Left', 'Right', 'First')):
            return None
        inherited = optional(style, 'WritingMode')
        return inherited if inherited in (0, 1) else None
    except Exception:
        return None


def paragraph_format(value, document=None):
    alignment = physical_alignment(optional(value, 'ParaAdjust'), writing_mode(value, document))
    level = optional(value, 'NumberingLevel')
    rules = optional(value, 'NumberingRules')
    list_kind = 'none'
    if rules is not None and isinstance(level, int) and level >= 0:
        try:
            rule = {entry.Name: entry.Value for entry in rules.getByIndex(level)}
            list_kind = {4: 'number', 6: 'bullet'}.get(rule.get('NumberingType'), 'other')
        except Exception:
            list_kind = 'other'
    break_type = optional(value, 'BreakType')
    break_name = getattr(break_type, 'value', None)
    return {'styleName': optional(value, 'ParaStyleName'),
        'alignment': alignment,
        'listKind': list_kind, 'listLevel': level if list_kind != 'none' else None,
        'pageBreakBefore': None if break_name not in ('NONE', 'PAGE_BEFORE', 'PAGE_AFTER', 'PAGE_BOTH')
            else break_name in ('PAGE_BEFORE', 'PAGE_BOTH')}


def paragraph_styles(document):
    family = document.StyleFamilies.getByName('ParagraphStyles')
    return [{'name': name, 'displayName': optional(family.getByName(name), 'DisplayName') or name}
        for name in family.ElementNames]


class WordBody:
    def __init__(self, document, paragraphs, tables, uno, prop, text_owner=None, owner_id='body', used_ids=None, allocate_id=None):
        self.document, self.text, self.paragraphs, self.tables = document, document.Text if text_owner is None else text_owner, paragraphs, tables
        self.owner_id = owner_id
        self.uno, self.prop = uno, prop
        paragraph_ids = iter(paragraphs)
        self.order = []
        for kind, name, value in body_elements(document, self.text):
            identifier = (next(paragraph_ids) if kind == 'paragraph' else name if kind == 'table'
                else allocate_id('word-opaque') if allocate_id is not None else 'opaque-' + str(len(self.order)))
            self.order.append({'kind': kind, 'id': identifier})
        self.used_ids = used_ids if used_ids is not None else set()
        self.used_ids.update(set(paragraphs) | set(tables) | {item['id'] for item in self.order})
        self._floating = None

    def refresh(self):
        actual = body_elements(self.document, self.text)
        if len(actual) != len(self.order):
            raise ValueError('Word paragraph operation changed an unexpected body block count')
        rebound = {}
        for expected, (kind, name, value) in zip(self.order, actual):
            if kind != expected['kind'] or kind == 'table' and name != expected['id']:
                raise ValueError('Word paragraph operation crossed a table or opaque body boundary')
            if kind == 'paragraph':
                rebound[expected['id']] = value
        self.paragraphs.clear()
        self.paragraphs.update(rebound)
        self._floating = None

    def paragraph(self, identifier):
        if not isinstance(identifier, str) or identifier not in self.paragraphs:
            raise ValueError('Unknown Word paragraph identity')
        return self.paragraphs[identifier]

    def index(self, identifier):
        return next(index for index, item in enumerate(self.order) if item == {'kind': 'paragraph', 'id': identifier})

    def current(self, identifier, expected_hash):
        value = self.paragraph(identifier)
        if expected_hash != office_text.text_hash(value.String):
            raise ValueError('Word paragraph text changed since the requested operation')
        return value

    def new_identity(self, identifier):
        if not isinstance(identifier, str) or not identifier or identifier in self.used_ids:
            raise ValueError('Invalid or reused Word paragraph identity')
        return identifier

    def floating_anchors(self):
        if self._floating is not None:
            return self._floating
        anchors, safe = [], True
        try:
            page = self.document.DrawPage
            contents = [page.getByIndex(index) for index in range(page.Count)]
            for collection_name in ('TextFrames', 'GraphicObjects', 'EmbeddedObjects'):
                collection = getattr(self.document, collection_name)
                contents.extend(collection.getByName(name) for name in collection.ElementNames)
            for content in contents:
                kind = optional(content, 'AnchorType')
                if kind is None:
                    safe = False
                    continue
                if getattr(kind, 'value', None) == 'AS_CHARACTER':
                    continue
                anchor = content.getAnchor()
                if anchor is None:
                    safe = False
                    continue
                try:
                    self.text.compareRegionStarts(anchor, self.text.Start)
                except Exception as error:
                    owner = anchor.getText()
                    if type(error).__name__.rsplit('.', 1)[-1] != 'IllegalArgumentException' or owner is None:
                        safe = False
                        continue
                    # A different text owner must validate its own range before being excluded.
                    owner.createTextCursorByRange(anchor)
                    if owner == self.text:
                        safe = False
                    continue
                anchors.append(anchor)
        except Exception:
            safe = False
        self._floating = anchors, safe
        return self._floating

    def ordinary(self, value):
        if optional(value, 'TextSection') is not None:
            return False
        anchors, safe = self.floating_anchors()
        if not safe:
            return False
        try:
            self.text.createTextCursorByRange(value.Start)
            for anchor in anchors:
                if self.text.compareRegionStarts(anchor, value.Start) <= 0 and self.text.compareRegionStarts(anchor, value.End) >= 0:
                    return False
            return office_text.text_details(value, True)['canReplace']
        except Exception:
            return False

    def point(self, value, offset):
        return office_text.selection(value, {'startUtf16': offset, 'endUtf16': offset,
            'expectedTextSha256': office_text.text_hash(value.String)}, True, True, replacing=True)[0]

    def point_safe(self, value, offset):
        try:
            self.point(value, offset)
            return True
        except Exception:
            return False

    def can_join(self, identifier):
        index = self.index(identifier)
        if index + 1 >= len(self.order) or self.order[index + 1]['kind'] != 'paragraph':
            return False
        left, right = self.paragraph(identifier), self.paragraph(self.order[index + 1]['id'])
        return self.ordinary(left) and self.ordinary(right) and self.point_safe(left, office_text.utf16_length(left.String)) and self.point_safe(right, 0)

    def structure(self, identifier):
        value = self.paragraph(identifier)
        ordinary = self.ordinary(value)
        details = office_text.text_details(value, True)
        index = self.index(identifier)
        return {'canSplit': ordinary,
            'canDelete': ordinary and not details['protectedRanges'] and len(self.paragraphs) > 1 and index < len(self.order) - 1,
            'canInsertBefore': ordinary and self.point_safe(value, 0),
            'canInsertAfter': ordinary and self.point_safe(value, details['utf16Length']),
            'canJoinNext': self.can_join(identifier)}

    def require_structure(self, identifier, capability):
        if not self.structure(identifier)[capability]:
            raise ValueError('This Word paragraph does not support the requested structural change')

    def apply(self, operation):
        op = operation['op']
        common = {'op', 'id', 'expectedTextSha256'}
        fields = {'paragraphSplit': {'newId', 'offsetUtf16'},
            'paragraphInsert': {'referenceId', 'position', 'text'},
            'paragraphJoin': {'nextId', 'expectedNextTextSha256'},
            'paragraphDelete': set(),
            'paragraphFormat': {'styleName', 'alignment', 'listKind', 'listLevel', 'pageBreakBefore'}}
        if set(operation) - (common | fields[op]):
            raise ValueError('Invalid Word paragraph operation fields')
        if op == 'paragraphInsert':
            return self.insert(operation)
        value = self.current(operation.get('id'), operation.get('expectedTextSha256'))
        if op == 'paragraphFormat':
            return self.format(value, operation)
        if op == 'paragraphSplit':
            return self.split(value, operation)
        if op == 'paragraphJoin':
            return self.join(value, operation)
        self.require_structure(operation['id'], 'canDelete')
        index = self.index(operation['id'])
        self.text.removeTextContent(value)
        self.order.pop(index)
        self.refresh()

    def split(self, value, operation):
        identifier = operation['id']
        self.require_structure(identifier, 'canSplit')
        new_id = self.new_identity(operation.get('newId'))
        original = value.String
        offset = operation.get('offsetUtf16')
        index = office_text.utf16_index(original, offset)
        cursor = self.point(value, offset)
        position = self.index(identifier)
        self.text.insertControlCharacter(cursor, 0, False)
        self.order.insert(position + 1, {'kind': 'paragraph', 'id': new_id})
        self.used_ids.add(new_id)
        self.refresh()
        if self.paragraph(identifier).String != original[:index] or self.paragraph(new_id).String != original[index:]:
            raise ValueError('Word split did not preserve the left and right paragraph text')

    def insert(self, operation):
        identifier = self.new_identity(operation.get('id'))
        reference = self.current(operation.get('referenceId'), operation.get('expectedTextSha256'))
        content, position = operation.get('text'), operation.get('position')
        if not isinstance(content, str) or len(content) > 10000000 or '\n' in content or '\r' in content:
            raise ValueError('New Word paragraphs must contain one paragraph of text')
        content.encode('utf-8')
        if position not in ('before', 'after'):
            raise ValueError('Invalid Word paragraph insertion position')
        self.require_structure(operation['referenceId'], 'canInsertBefore' if position == 'before' else 'canInsertAfter')
        index = self.index(operation['referenceId']) + (1 if position == 'after' else 0)
        original = reference.String
        inherited = optional(reference, 'ParaStyleName')
        page_properties = {}
        information = reference.getPropertySetInfo()
        for name in ('PageDescName', 'PageNumberOffset', 'BreakType'):
            if information.hasPropertyByName(name):
                page_properties[name] = (reference.getPropertyValue(name), reference.getPropertyState(name))
        cursor = self.point(reference, 0 if position == 'before' else office_text.utf16_length(original))
        self.text.insertControlCharacter(cursor, 0, False)
        self.order.insert(index, {'kind': 'paragraph', 'id': identifier})
        self.used_ids.add(identifier)
        self.refresh()
        value = self.paragraph(identifier)
        if value.String != '' or self.paragraph(operation['referenceId']).String != original:
            raise ValueError('Word insertion did not preserve the reference paragraph')
        reset = self.text.createTextCursorByRange(value.Start)
        reset.gotoRange(value.End, True)
        reset.setAllPropertiesToDefault()
        if inherited is not None:
            value.ParaStyleName = inherited
        value.BreakType = self.uno.Enum('com.sun.star.style.BreakType', 'NONE')
        value.String = content
        self.refresh()
        survivor = self.paragraph(operation['referenceId'])
        for name, (assigned, state) in page_properties.items():
            if survivor.getPropertyValue(name) != assigned:
                if getattr(state, 'value', None) == 'DEFAULT_VALUE':
                    survivor.setPropertyToDefault(name)
                elif getattr(state, 'value', None) == 'DIRECT_VALUE':
                    survivor.setPropertyValue(name, assigned)
                else:
                    raise ValueError('The reference paragraph page properties cannot be restored safely')
        if any(survivor.getPropertyValue(name) != assigned for name, (assigned, _) in page_properties.items()):
            raise ValueError('Word insertion changed the reference paragraph page properties')
        if (self.paragraph(identifier).String != content or self.paragraph(operation['referenceId']).String != original
                or optional(self.paragraph(operation['referenceId']), 'ParaStyleName') != inherited):
            raise ValueError('Word insertion did not create the requested paragraph')

    def join(self, left, operation):
        identifier, following = operation['id'], operation.get('nextId')
        right = self.current(following, operation.get('expectedNextTextSha256'))
        self.require_structure(identifier, 'canJoinNext')
        index = self.index(identifier)
        if self.order[index + 1] != {'kind': 'paragraph', 'id': following}:
            raise ValueError('Word paragraphs must be adjacent in the actual body')
        original, left_style = left.String + right.String, optional(left, 'ParaStyleName')
        cursor = self.text.createTextCursorByRange(left.End)
        cursor.gotoRange(right.Start, True)
        if cursor.String not in ('\n', '\r\n'):
            raise ValueError('Word join selection is not exactly a paragraph boundary')
        cursor.String = ''
        self.order.pop(index + 1)
        self.refresh()
        combined = self.paragraph(identifier)
        if combined.String != original or optional(combined, 'ParaStyleName') != left_style:
            raise ValueError('Word join did not preserve the text or left paragraph style')

    def copied_numbering_rules(self, original):
        result = self.document.createInstance('com.sun.star.text.NumberingRules')
        if original is None:
            return result
        if original.getCount() > result.getCount():
            raise ValueError('The Word list has an unsupported number of levels')
        for index in range(original.getCount()):
            entries = {entry.Name: self.prop(entry.Name, entry.Value) for entry in original.getByIndex(index)}
            graphic_url = entries.get('GraphicURL')
            if graphic_url is not None and graphic_url.Value:
                bitmap = entries.get('GraphicBitmap')
                if bitmap is None or bitmap.Value is None:
                    raise ValueError('A Word list image must already be embedded before changing list formatting')
                entries.pop('GraphicURL')
            result.replaceByIndex(index, self.uno.Any('[]com.sun.star.beans.PropertyValue', tuple(entries.values())))
        properties = result.getPropertySetInfo()
        for name in ('IsAbsoluteMargins', 'IsContinuousNumbering'):
            assigned = optional(original, name)
            if assigned is not None and properties.hasPropertyByName(name) and not properties.getPropertyByName(name).Attributes & 16:
                result.setPropertyValue(name, assigned)
        return result

    def format(self, value, operation):
        if self.owner_id != 'body' and 'pageBreakBefore' in operation:
            raise ValueError('Header and footer paragraphs do not support page breaks')
        supported = {'styleName', 'alignment', 'listKind', 'listLevel', 'pageBreakBefore'}
        if not any(name in operation and operation[name] is not None for name in supported):
            raise ValueError('Expected at least one Word paragraph formatting property')
        section, seen = optional(value, 'TextSection'), []
        while section is not None:
            if any(section == item for item in seen) or optional(section, 'IsProtected') is not False:
                raise ValueError('Word paragraph formatting is inside a protected or unknown section')
            seen.append(section)
            section = section.getParentSection()
        original_format = paragraph_format(value, self.document)
        original_rules = optional(value, 'NumberingRules')
        original_visible_label = optional(value, 'NumberingIsNumber')
        style_name = operation.get('styleName')
        if 'styleName' in operation:
            if not isinstance(style_name, str) or not self.document.StyleFamilies.getByName('ParagraphStyles').hasByName(style_name):
                raise ValueError('Unknown Word paragraph style')
        alignment = operation.get('alignment')
        if 'alignment' in operation and alignment not in ('left', 'right', 'center', 'justify'):
            raise ValueError('Unsupported Word paragraph alignment')
        list_kind = operation.get('listKind')
        if 'listKind' in operation and list_kind not in ('none', 'bullet', 'number'):
            raise ValueError('Unsupported Word paragraph list kind')
        level = operation.get('listLevel')
        if 'listLevel' in operation and (type(level) is not int or not 0 <= level <= 8):
            raise ValueError('Invalid Word list level')
        if 'pageBreakBefore' in operation and not isinstance(operation['pageBreakBefore'], bool):
            raise ValueError('Invalid Word paragraph break flag')
        prepared_rules = None
        selected_level = level
        if list_kind not in (None, 'none') or list_kind is None and level is not None:
            if list_kind is None and original_format['listKind'] not in ('bullet', 'number'):
                raise ValueError('A Word list level requires a supported active list')
            if selected_level is None:
                selected_level = original_format['listLevel'] if original_format['listKind'] != 'none' else 0
            if type(selected_level) is not int or not 0 <= selected_level <= 8:
                raise ValueError('An existing Word list level must be preserved or changed explicitly')
            active_original = original_rules if original_format['listKind'] != 'none' else None
            prepared_rules = self.copied_numbering_rules(active_original)
            entries = {entry.Name: entry for entry in prepared_rules.getByIndex(selected_level)}
            if list_kind is None:
                current_entries = {entry.Name: entry for entry in original_rules.getByIndex(original_format['listLevel'])}
                for name in ('NumberingType', 'Prefix', 'Suffix', 'BulletChar', 'BulletFontName', 'BulletFont',
                        'BulletColor', 'BulletRelSize', 'CharStyleName'):
                    if name in current_entries:
                        entries[name] = self.prop(name, current_entries[name].Value)
            else:
                entries['NumberingType'] = self.prop('NumberingType', 6 if list_kind == 'bullet' else 4)
                if active_original is None:
                    entries['Prefix'] = self.prop('Prefix', '')
                    entries['Suffix'] = self.prop('Suffix', '' if list_kind == 'bullet' else '.')
                if list_kind == 'bullet' and ('BulletChar' not in entries or not entries['BulletChar'].Value):
                    entries['BulletChar'] = self.prop('BulletChar', '•')
            prepared_rules.replaceByIndex(selected_level,
                self.uno.Any('[]com.sun.star.beans.PropertyValue', tuple(entries.values())))
        if style_name is not None:
            value.ParaStyleName = style_name
        if alignment is not None:
            value.ParaAdjust = {'left': 0, 'right': 1, 'justify': 2, 'center': 3}[alignment]
        if list_kind == 'none':
            value.NumberingStyleName = ''
        elif prepared_rules is not None:
            value.NumberingRules = prepared_rules
            value.NumberingLevel = selected_level
            value.NumberingIsNumber = original_visible_label if original_format['listKind'] != 'none' and isinstance(original_visible_label, bool) else True
        if 'pageBreakBefore' in operation:
            current = getattr(optional(value, 'BreakType'), 'value', None)
            if current not in ('NONE', 'PAGE_BEFORE', 'PAGE_AFTER', 'PAGE_BOTH'):
                raise ValueError('This paragraph has a break type that cannot be changed independently')
            after = current in ('PAGE_AFTER', 'PAGE_BOTH')
            before = operation['pageBreakBefore']
            assigned = 'PAGE_BOTH' if before and after else 'PAGE_BEFORE' if before else 'PAGE_AFTER' if after else 'NONE'
            value.BreakType = self.uno.Enum('com.sun.star.style.BreakType', assigned)
        self._floating = None
