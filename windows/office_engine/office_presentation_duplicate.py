"""Clone an authored PPTX slide without running the native save serializer."""
from collections import Counter
from contextlib import contextmanager
import os
from pathlib import Path
import posixpath
import re
import struct
import tempfile
from typing import NamedTuple
from urllib.parse import urlsplit
from uuid import uuid4
from xml.parsers import expat
from xml.sax.saxutils import escape
import zipfile
import zlib

import office_presentation_package_patch as writer
import office_presentation_source as reader


P, R, PKG, CT = reader.P, reader.R, reader.PKG, reader.CT
P14 = 'http://schemas.microsoft.com/office/powerpoint/2010/main|'
A16 = 'http://schemas.microsoft.com/office/drawing/2014/main|'
MS_MEDIA = 'http://schemas.microsoft.com/office/2007/relationships/media'
PRESENTATION = 'ppt/presentation.xml'
TYPES = '[Content_Types].xml'
MIME_PREFIX = 'application/vnd.openxmlformats-officedocument.presentationml.'
GUID = re.compile(r'\{[\da-f]{8}-[\da-f]{4}-[\da-f]{4}-[\da-f]{4}-[\da-f]{12}\}', re.I)
ATTRIBUTE = re.compile(rb"""([^\s<>/=]+)\s*=\s*(?:"([^"]*)"|'([^']*)')""")
XML_ERRORS = (zipfile.BadZipFile, zipfile.LargeZipFile, expat.ExpatError,
    zlib.error, UnicodeError, struct.error)
_require = writer._require


class _Relation(NamedTuple):
    node: object
    kind: str
    target: str
    external: bool


def _rels_path(part):
    parent, name = posixpath.split(part)
    return posixpath.join(parent, '_rels', name + '.rels')


def _xml_attribute(value):
    return escape(value, {'"': '&quot;', "'": '&apos;'}).encode('utf-8')


def _attribute_edit(data, node, name, value):
    key = name.encode('ascii')
    for attribute in ATTRIBUTE.finditer(data, node.start, node.tag_end):
        if attribute[1] == key:
            start, end = attribute.span(2 if attribute[2] is not None else 3)
            return start, end, _xml_attribute(value)
    raise ValueError('An exact PPTX XML attribute cannot be located')


def _edit(data, edits):
    if not edits:
        return data
    pieces, position = [], 0
    for start, end, value in sorted(edits):
        _require(position <= start <= end <= len(data), 'PPTX XML edit intervals overlap or are invalid')
        pieces.extend((data[position:start], value))
        position = end
    pieces.append(data[position:])
    _require(sum(map(len, pieces)) <= reader.PART_BYTES, 'PPTX candidate XML exceeds its byte limit')
    return b''.join(pieces)


def _append_element(data, root, element):
    end = data.rfind(b'</', root.tag_end, root.end)
    _require(end >= root.tag_end and reader._tag_end(data, end) == root.end,
        'A PPTX metadata root has no exact closing tag')
    return _edit(data, [(end, end, element)])


def _first_free(used, start, additionally_used=()):
    while start in used or start in additionally_used:
        start += 1
    return start


def _creation_nodes(root):
    return (node for node in reader._walk(root)
        if node.name in (P14 + 'creationId', A16 + 'creationId'))


def _creation_edits(data, root, known, assigned):
    page_ids, shape_ids = known
    fresh_pages, fresh_shapes = assigned
    creation = list(_creation_nodes(root))
    creation_nodes = set(creation)
    pages = [node for node in creation if node.name == P14 + 'creationId']
    _require(len(pages) <= 1, 'Ambiguous PPTX slide creation identifiers')
    edits, shape_remap = [], {}
    page_id = None
    if pages:
        node = pages[0]
        page_id = reader._identity(node.attributes.get('val'))
        replacement = _first_free(page_ids, 1, fresh_pages)
        fresh_pages.add(replacement)
        edits.append(_attribute_edit(data, node, 'val', str(replacement)))
    for node in creation:
        if node.name != A16 + 'creationId' or 'id' not in node.attributes:
            continue
        old = node.attributes['id'].upper()
        _require(GUID.fullmatch(old) is not None and old not in shape_remap,
            'Ambiguous PPTX shape creation identifier')
        fresh = '{' + str(uuid4()).upper() + '}'
        while fresh in shape_ids or fresh in fresh_shapes:
            fresh = '{' + str(uuid4()).upper() + '}'
        fresh_shapes.add(fresh)
        shape_remap[old] = fresh
        edits.append(_attribute_edit(data, node, 'id', fresh))
    for node in reader._walk(root):
        for name, value in node.attributes.items():
            if node in creation_nodes and (node.name, name) in (
                    (P14 + 'creationId', 'val'), (A16 + 'creationId', 'id')):
                continue
            if node.name == A16 + 'cxnDERefs' and name in ('st', 'end') or (
                    node.name == A16 + 'predDERef' and name == 'pred'):
                _require(value.upper() in shape_remap,
                    'A PPTX drawing reference points outside the copied part')
                edits.append(_attribute_edit(data, node, name, shape_remap[value.upper()]))
            elif (shape_remap and shape_remap.keys() & {match.upper() for match in GUID.findall(value)}) or (
                    page_id is not None and name.rsplit('|', 1)[-1] in ('cId', 'creationId', 'slideCreationId')
                    and value.isascii() and value.isdecimal() and int(value) == page_id):
                raise ValueError('An unsupported PPTX creation identity reference cannot be copied')
    return edits


class _Package:
    def __init__(self, image):
        self.archive = image.archive
        self.members = {item.filename: item for item in self.archive.infolist()}
        self.names = {name.casefold() for name in self.members}
        self.slide_parts = list(image.catalog['parts'])
        self.cache, self.available_names = {}, {}
        self.xml_bytes = 0
        self.budget = {'nodes': 0}
        self.expanded_bytes = sum(item.file_size for item in self.members.values())
        _require(self.expanded_bytes <= writer.MAX_PACKAGE_BYTES,
            'PPTX aggregate expanded byte limit exceeded')
        _require(not writer._signed_package(self.archive), 'Signed PPTX package edits are unsupported')
        writer._layout(self.archive)
        self.defaults, self.overrides = reader._content_types(self.xml(TYPES)[1], self.members)
        self.listing = reader._one(self.xml(PRESENTATION)[1], P + 'sldIdLst')
        slide_ids = {reader._identity(slide.attributes['id']) for slide in self.listing.children}
        _require(all(256 <= identity < 0x80000000 for identity in slide_ids),
            'A PPTX slide ID is outside its supported range')
        self.new_slide_id = _first_free(slide_ids, 256)
        main_rels = self.relationships(PRESENTATION)
        self.new_relation_id = 'rId' + str(_first_free({int(key[3:]) for key in main_rels
            if re.fullmatch(r'rId[1-9][0-9]{0,8}', key)}, 1))
        self.slide_rels = {part: self.relationships(part) for part in self.slide_parts}
        self.notes_owners = Counter(rel.target for rels in self.slide_rels.values()
            for rel in rels.values() if rel.kind == R + '/notesSlide' and not rel.external)
        catalog_parts = {TYPES, PRESENTATION, _rels_path(PRESENTATION), '_rels/.rels', *self.slide_parts}
        self.catalog_bytes = sum(self.members[part].file_size for part in catalog_parts)
        page_ids, shape_ids = set(), set()
        self.creation_ids = page_ids, shape_ids
        for part in [*self.slide_parts, *self.notes_owners]:
            for node in _creation_nodes(self.xml(part)[1]):
                if node.name == P14 + 'creationId':
                    try:
                        page_ids.add(reader._identity(node.attributes.get('val')))
                    except ValueError:
                        pass  # An invalid creation ID disables its own slide.
                elif GUID.fullmatch(node.attributes.get('id', '')):
                    shape_ids.add(node.attributes['id'].upper())

    def xml(self, part):
        if part not in self.cache:
            item = self.members.get(part)
            _require(item is not None and not item.is_dir() and item.file_size <= reader.PART_BYTES,
                'A required PPTX XML part is missing or exceeds its byte limit')
            self.xml_bytes += item.file_size
            _require(self.xml_bytes <= reader.TOTAL_XML_BYTES, 'PPTX duplicate XML budget exceeded')
            data = self.archive.read(item)
            _require(len(data) == item.file_size, 'The PPTX XML part differs from its declared size')
            self.cache[part] = data, reader._xml(data, self.budget)
        return self.cache[part]

    def content_type(self, part):
        return self.overrides.get(part, self.defaults.get(part.rsplit('.', 1)[-1].lower(), ''))

    def relationships(self, part):
        path = _rels_path(part)
        if path not in self.members:
            return {}
        root = self.xml(path)[1]
        _require(root.name == PKG + 'Relationships' and not root.attributes,
            'Unsupported PPTX relationship root')
        result = {}
        for node in root.children:
            attributes = node.attributes
            _require(node.name == PKG + 'Relationship' and not node.children and
                not set(attributes) - {'Id', 'Type', 'Target', 'TargetMode'},
                'Unsupported PPTX relationship element')
            identity, kind, target = (attributes.get(name) for name in ('Id', 'Type', 'Target'))
            mode = attributes.get('TargetMode')
            _require(identity and identity.strip() == identity and identity not in result and
                kind and target and mode in (None, 'Internal', 'External') and
                not any(ord(character) < 32 for character in target),
                'A PPTX relationship identity, target or mode is ambiguous')
            external = mode == 'External'
            if not external:
                parsed = urlsplit(target)
                _require(not (parsed.scheme or parsed.netloc or parsed.query or parsed.fragment or
                    target.startswith('/') or any(character in target for character in '\\:%?#')),
                    'A PPTX relationship target is not canonical')
                target = posixpath.normpath(posixpath.join(posixpath.dirname(part), target))
                reader._member_name(target)
                _require(target in self.members and not self.members[target].is_dir(),
                    'A PPTX relationship target is absent')
            result[identity] = _Relation(node, kind, target, external)
        return result

    def validate_dependencies(self, root, rels, expected_slide=None):
        relationship_counts = Counter()
        for rel in rels.values():
            if rel.external:
                parsed = urlsplit(rel.target)
                _require(rel.kind == R + '/hyperlink' and rel.target.strip() == rel.target and
                    (parsed.scheme in ('http', 'https') and parsed.hostname and parsed.username is None or
                    parsed.scheme == 'mailto' and parsed.path and not parsed.netloc),
                    'Unsupported external PPTX dependency')
                continue
            _require(rel.kind.startswith(R + '/') or rel.kind == MS_MEDIA,
                'Unsupported PPTX relationship type namespace')
            kind = rel.kind.removeprefix(R + '/')
            content_type = self.content_type(rel.target)
            if kind == 'slide':
                _require(rel.target == expected_slide if expected_slide is not None else rel.target in self.slide_parts,
                    'A PPTX slide link or notes backreference is ambiguous')
            elif kind in ('image', 'audio', 'video'):
                _require(content_type.startswith(kind + '/'), 'Unsupported PPTX media content type')
            elif rel.kind in (R + '/media', MS_MEDIA):
                _require(content_type.startswith(('audio/', 'video/')), 'Unsupported PPTX media content type')
            elif expected_slide is None and kind in ('notesSlide', 'slideLayout'):
                _require(content_type == MIME_PREFIX + kind + '+xml', 'Unsupported PPTX dependency content type')
            elif expected_slide is not None and kind == 'notesMaster':
                _require(content_type == MIME_PREFIX + kind + '+xml', 'Unsupported PPTX notes master content type')
            else:
                raise ValueError('Unsupported mutable or unknown PPTX dependency')
            relationship_counts[kind] += 1
        _require(all(relationship_counts[kind] <= 1 for kind in ('notesSlide', 'slideLayout', 'notesMaster')) and
            (expected_slide is None or relationship_counts['slide'] == 1),
            'A PPTX notes or layout dependency is ambiguous')
        for node in reader._walk(root):
            _require(all(value in rels for name, value in node.attributes.items() if name.startswith(R + '|')),
                'A copied PPTX XML relationship reference is missing')

    def new_part(self, part, stem):
        parent = posixpath.dirname(part)
        if (parent, stem) in self.available_names:
            return self.available_names[(parent, stem)]
        for index in range(1, reader.MEMBER_LIMIT + 1):
            candidate = posixpath.join(parent, stem + str(index) + '.xml')
            if candidate.casefold() not in self.names and _rels_path(candidate).casefold() not in self.names:
                self.available_names[(parent, stem)] = candidate
                return candidate
        raise ValueError('The PPTX package has no available private part name')

    def plan(self, slide_index, *, capability_only=False):
        slide = self.slide_parts[slide_index]
        data, root = self.xml(slide)
        relations = self.slide_rels[slide]
        self.validate_dependencies(root, relations)
        assigned = set(), set()
        new_slide = self.new_part(slide, 'slide')
        added = {new_slide: _edit(data, _creation_edits(data, root, self.creation_ids, assigned))}
        if relations:
            old_rels = self.xml(_rels_path(slide))[0]
            added[_rels_path(new_slide)] = old_rels
        notes = next((rel for rel in relations.values() if rel.kind == R + '/notesSlide'), None)
        overrides = {new_slide: self.content_type(slide)}
        if notes is not None:
            _require(self.notes_owners[notes.target] == 1, 'A PPTX notes part has multiple owners')
            note_data, note_root = self.xml(notes.target)
            _require(note_root.name == P + 'notes', 'Invalid PPTX notes root')
            note_relations = self.relationships(notes.target)
            self.validate_dependencies(note_root, note_relations, expected_slide=slide)
            new_notes = self.new_part(notes.target, 'notesSlide')
            _require(new_notes not in added and _rels_path(new_notes) not in added,
                'A duplicate PPTX part name is ambiguous')
            added[new_notes] = _edit(note_data, _creation_edits(note_data, note_root, self.creation_ids, assigned))
            back = next(rel for rel in note_relations.values() if rel.kind == R + '/slide')
            note_rels = self.xml(_rels_path(notes.target))[0]
            added[_rels_path(new_slide)] = _edit(old_rels, [_attribute_edit(
                old_rels, notes.node, 'Target', posixpath.relpath(new_notes, posixpath.dirname(new_slide)))])
            added[_rels_path(new_notes)] = _edit(note_rels, [_attribute_edit(
                note_rels, back.node, 'Target', posixpath.relpath(new_slide, posixpath.dirname(new_notes)))])
            overrides[new_notes] = self.content_type(notes.target)
        _require(len(self.members) + len(added) <= reader.MEMBER_LIMIT, 'PPTX duplicate member limit exceeded')
        relation, identity = self.new_relation_id, self.new_slide_id
        insertion = self.listing.children[slide_index].end
        new_id = (f'<p:sldId xmlns:p="{P[:-1]}" xmlns:r="{R}" id="{identity}" r:id="{relation}"/>').encode()
        main_rels = self.xml(_rels_path(PRESENTATION))
        main_target = _xml_attribute(posixpath.relpath(new_slide, 'ppt'))
        new_rel = (f'<Relationship xmlns="{PKG[:-1]}" Id="{relation}" Type="{R}/slide" Target="').encode() + main_target + b'"/>'
        types = self.xml(TYPES)
        new_types = b''.join((f'<Override xmlns="{CT[:-1]}" PartName="/').encode() +
            _xml_attribute(part) + b'" ContentType="' + _xml_attribute(content_type) + b'"/>'
            for part, content_type in overrides.items())
        _require(len(self.xml(PRESENTATION)[0]) + len(new_id) <= reader.PART_BYTES and
            len(main_rels[0]) + len(new_rel) <= reader.PART_BYTES and
            len(types[0]) + len(new_types) <= reader.PART_BYTES,
            'PPTX duplicate XML part byte limit exceeded')
        new_metadata_bytes = len(new_id) + len(new_rel) + len(new_types)
        _require(self.catalog_bytes + new_metadata_bytes + len(added[new_slide]) <= reader.TOTAL_XML_BYTES,
            'PPTX duplicate source catalog exceeds its XML byte limit')
        _require(self.expanded_bytes + new_metadata_bytes +
            sum(map(len, added.values())) <= writer.MAX_PACKAGE_BYTES,
            'PPTX duplicate aggregate expanded byte limit exceeded')
        if capability_only:
            return
        changed = {
            PRESENTATION: _edit(self.xml(PRESENTATION)[0], [(insertion, insertion, new_id)]),
            _rels_path(PRESENTATION): _append_element(*main_rels, new_rel),
            TYPES: _append_element(*types, new_types),
        }
        order = self.slide_parts.copy()
        order.insert(slide_index + 1, new_slide)
        return changed, added, order


@contextmanager
def _open_package(source, expected_source_sha256):
    _require(writer._hash_value(expected_source_sha256), 'An exact source PPTX SHA-256 is required')
    try:
        with reader.open_pptx_tables(source, max_package_bytes=writer.MAX_PACKAGE_BYTES) as image:
            _require(image.catalog['sourceSha256'] == expected_source_sha256,
                'The expected PPTX source SHA-256 is stale')
            yield _Package(image)
    except XML_ERRORS as error:
        raise ValueError('Unsupported or invalid PPTX slide duplication package') from error


def duplicable_slides(source: Path, expected_source_sha256: str) -> set[int]:
    """Return zero-based logical slide indices with a verified package-copy plan."""
    with _open_package(source, expected_source_sha256) as package:
        supported = set()
        for index in range(len(package.slide_parts)):
            try:
                package.plan(index, capability_only=True)
            except (ValueError, *XML_ERRORS):
                continue
            supported.add(index)
        return supported


def duplicate_pptx(source: Path, destination: Path, slide_index: int, expected_source_sha256: str) -> None:
    """Write and verify a private candidate, preserving every original slide part."""
    destination = Path(destination)
    owned = None
    try:
        with _open_package(source, expected_source_sha256) as package:
            _require(type(slide_index) is int and 0 <= slide_index < len(package.slide_parts),
                'An existing logical PPTX slide index is required')
            changed, added, order = package.plan(slide_index)
            writer._validate_payloads(package.archive, changed)
            with destination.open('x+b', buffering=0) as output:
                owned = reader._stamp(os.fstat(output.fileno()))[:2]
                with tempfile.TemporaryFile() as parts:
                    with zipfile.ZipFile(parts, 'w', compression=zipfile.ZIP_DEFLATED, allowZip64=False) as archive:
                        for name, data in added.items():
                            archive.writestr(name, data)
                    with zipfile.ZipFile(parts) as archive:
                        writer._rewrite(package.archive, output, changed, added_archive=archive)
                output.flush()
                os.fsync(output.fileno())
                output_size = os.fstat(output.fileno()).st_size
                _require(output_size <= writer.MAX_PACKAGE_BYTES and
                    reader._stamp(destination.stat())[:2] == owned,
                    'The private PPTX duplicate candidate changed or exceeds its byte limit')
                candidate_digest = reader._digest(output, output_size)
                output.seek(0)
                count = reader._zip_envelope(output)
                with zipfile.ZipFile(output) as candidate:
                    writer._layout(candidate)
                    _require(list(reader._catalog(candidate, count)['parts']) == order and
                        set(candidate.namelist()) == set(package.members) | set(added) and
                        candidate.testzip() is None, 'The PPTX duplicate candidate inventory or CRC differs')
                    _require(all(candidate.read(name) == data for name, data in (changed | added).items()),
                        'The PPTX duplicate candidate differs from its exact copy plan')
                    _require(all((candidate.getinfo(name).CRC, candidate.getinfo(name).file_size) ==
                        (info.CRC, info.file_size) for name, info in package.members.items() if name not in changed),
                        'An untouched PPTX part changed during duplication')
                _require(reader._digest(output, output_size) == candidate_digest and
                    reader._stamp(destination.stat())[:2] == owned,
                    'The verified PPTX duplicate candidate changed')
    except BaseException as error:
        if owned is not None:
            try:
                if destination.exists():
                    _require(reader._stamp(destination.stat())[:2] == owned,
                        'Preserve a foreign replacement of the duplicate candidate path')
                    destination.unlink()
            except Exception as cleanup_error:
                error.add_note('Removing owned PPTX duplicate candidate: ' + str(cleanup_error))
        raise
