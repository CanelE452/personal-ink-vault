from contextlib import contextmanager
import hashlib
import importlib
import importlib.util
import io
from pathlib import Path
import struct
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import zipfile

import office_presentation_source as source_reader
from office_presentation_text_source import cell_text_map
from test_presentation_source import package_members, frame_xml, slide_xml

MODULE = (importlib.import_module('office_presentation_package_patch')
    if importlib.util.find_spec('office_presentation_package_patch') else SimpleNamespace(patch_pptx=None))
PART = 'ppt/slides/slide1.xml'
MEDIA = 'ppt/media/unrelated.bin'


class NonSeekable(io.BytesIO):
    def seek(self, *args):
        raise io.UnsupportedOperation('streamed fixture')


def archive_bytes(members, streamed=False, compression=zipfile.ZIP_DEFLATED):
    stream = NonSeekable() if streamed else io.BytesIO()
    with zipfile.ZipFile(stream, 'w', allowZip64=False) as archive:
        archive.comment = b'Preserve the entire archive comment'
        for name, data in members:
            information = zipfile.ZipInfo(name, (2020, 3, 4, 5, 6, 8))
            information.compress_type = compression
            information.extra = b'\xfe\xca\x04\x00META'
            information.comment = b'Preserve member metadata'
            information.create_system = 3
            information.external_attr = 0o100600 << 16
            archive.writestr(information, data, compresslevel=1)
    return stream.getvalue()


def physical_records(data):
    end = data.rfind(b'PK\x05\x06')
    central = struct.unpack_from('<I', data, end + 16)[0]
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        information = sorted(archive.infolist(), key=lambda item: item.header_offset)
    return {item.filename: data[item.header_offset:(information[index + 1].header_offset
        if index + 1 < len(information) else central)] for index, item in enumerate(information)}


def central_records(data):
    end = data.rfind(b'PK\x05\x06')
    position = struct.unpack_from('<I', data, end + 16)[0]
    result = []
    while position < end:
        if data[position:position + 4] != b'PK\x01\x02':
            raise AssertionError('The controlled fixture central record is invalid')
        names, extra, comment = struct.unpack_from('<3H', data, position + 28)
        length = 46 + names + extra + comment
        result.append((data[position + 46:position + 46 + names].decode('utf-8'),
            data[position:position + length]))
        position += length
    return result


class PresentationPackagePatchTest(unittest.TestCase):
    def api(self):
        function = getattr(MODULE, 'patch_pptx', None)
        self.assertTrue(callable(function), 'BOOTSTRAP: patch_pptx is absent; not package/native save evidence')
        return function

    @contextmanager
    def fixture(self, *, streamed=False, members=None, compression=zipfile.ZIP_DEFLATED):
        with TemporaryDirectory() as directory:
            source = Path(directory) / 'original.pptx'
            destination = Path(directory) / 'candidate.pptx'
            contents = [(name, b'opaque media\x00\xff' * 100 if name == MEDIA else payload)
                for name, payload in package_members({PART: slide_xml([frame_xml('9'), frame_xml('10')])})]
            if members is not None:
                contents = members(contents)
            original = archive_bytes(contents, streamed, compression)
            source.write_bytes(original)
            catalog = source_reader.read_pptx_tables(source)
            case = SimpleNamespace(source=source, destination=destination, original=original,
                sha=hashlib.sha256(original).hexdigest(), catalog=catalog, members=dict(contents))
            yield case
            self.assertEqual(source.read_bytes(), case.original, 'The writer must preserve the declared immutable input')

    def operation(self, case, *, shape_id='10', row=1, column=1, text='수정😀 &<>'):
        table = next(table for table in case.catalog['tables'] if table['shapeId'] == shape_id)
        cell = next(cell for cell in table['cells'] if (cell['row'], cell['column']) == (row, column))
        mapped = cell_text_map(case.catalog['parts'][PART], cell)
        return {'sourcePart': PART, 'shapeId': shape_id, 'row': row, 'column': column,
            'expectedSourceFrameSha256': hashlib.sha256(case.catalog['parts'][PART][slice(*table['frameSpan'])]).hexdigest(),
            'expectedTextSha256': hashlib.sha256(mapped['text'].encode('utf-8')).hexdigest(),
            'startUtf16': 0, 'endUtf16': 4, 'text': text}

    def invoke(self, case, operations):
        return self.api()(case.source, case.destination, operations, case.sha)

    def test_api_is_explicit(self):
        self.api()

    def test_empty_operation_batch_is_an_exact_package_noop(self):
        with self.fixture(streamed=True) as case:
            result = self.invoke(case, [])
            self.assertEqual(case.destination.read_bytes(), case.original)
            self.assertEqual(result['sourceSha256'], case.sha)
            self.assertEqual(result['resultSha256'], case.sha)
            self.assertEqual(result['changedParts'], [])

    def test_semantic_noop_keeps_original_entity_spelling_and_every_zip_byte(self):
        with self.fixture() as case:
            result = self.invoke(case, [self.operation(case, text='SAME')])
            self.assertEqual(case.destination.read_bytes(), case.original)
            self.assertEqual(result['changedParts'], [])

    def test_only_exact_target_cell_content_changes_and_other_compressed_records_are_exact(self):
        with self.fixture() as case:
            operation = self.operation(case)
            result = self.invoke(case, [operation])
            table = case.catalog['tables'][1]
            cell = table['cells'][3]
            original_part = case.members[PART]
            start = original_part.index(b'SAME', cell['cellSpan'][0], cell['cellSpan'][1])
            expected = original_part[:start] + '수정😀 &amp;&lt;&gt;'.encode() + original_part[start + 4:]
            with zipfile.ZipFile(case.destination) as archive:
                self.assertIsNone(archive.testzip())
                self.assertEqual(archive.read(PART), expected)
                for name, payload in case.members.items():
                    if name != PART:
                        self.assertEqual(archive.read(name), payload)
                self.assertEqual(archive.comment, b'Preserve the entire archive comment')
            source_records, output_records = physical_records(case.original), physical_records(case.destination.read_bytes())
            self.assertEqual(list(source_records), list(output_records))
            for name, record in source_records.items():
                if name != PART:
                    self.assertEqual(output_records[name], record, 'Untouched compressed/local records must be raw-copied')
            self.assertEqual(result['changedParts'], [PART])

    def test_central_metadata_changes_only_offsets_and_changed_member_crc_sizes(self):
        with self.fixture() as case:
            self.invoke(case, [self.operation(case)])
            before, after = central_records(case.original), central_records(case.destination.read_bytes())
            self.assertEqual([name for name, _ in before], [name for name, _ in after])
            for (name, original), (_, current) in zip(before, after):
                if name == PART:
                    self.assertEqual(original[:16] + original[28:42] + original[46:],
                        current[:16] + current[28:42] + current[46:])
                else:
                    self.assertEqual(original[:42] + original[46:], current[:42] + current[46:])

    def test_streamed_data_descriptors_survive_with_valid_changed_crc_and_sizes(self):
        with self.fixture(streamed=True) as case:
            before = physical_records(case.original)
            self.assertTrue(all(struct.unpack_from('<H', record, 6)[0] & 8 for record in before.values()))
            self.invoke(case, [self.operation(case)])
            with zipfile.ZipFile(case.destination) as archive:
                self.assertIsNone(archive.testzip())
                self.assertTrue(all(item.flag_bits & 8 for item in archive.infolist()))
            after = physical_records(case.destination.read_bytes())
            for name in before:
                if name != PART:
                    self.assertEqual(before[name], after[name])
            self.assertIn(b'PK\x07\x08', after[PART])

    def test_stored_members_remain_stored_and_unmodified_local_records_are_exact(self):
        with self.fixture(compression=zipfile.ZIP_STORED) as case:
            self.invoke(case, [self.operation(case)])
            with zipfile.ZipFile(case.destination) as archive:
                self.assertIsNone(archive.testzip())
                self.assertTrue(all(item.compress_type == zipfile.ZIP_STORED for item in archive.infolist()))
            before, after = physical_records(case.original), physical_records(case.destination.read_bytes())
            self.assertEqual(before[MEDIA], after[MEDIA])

    def test_unsigned_streamed_data_descriptors_are_preserved(self):
        with self.fixture(streamed=True) as case:
            before = physical_records(case.original)
            with zipfile.ZipFile(io.BytesIO(case.original)) as archive:
                information = {item.filename: item for item in archive.infolist()}
            chunks, offsets, offset = [], {}, 0
            for name, record in before.items():
                item = information[name]
                names, extras = struct.unpack_from('<2H', record, 26)
                descriptor = 30 + names + extras + item.compress_size
                self.assertEqual(record[descriptor:descriptor + 4], b'PK\x07\x08')
                offsets[item.header_offset] = offset
                chunk = record[:descriptor] + record[descriptor + 4:]
                chunks.append(chunk)
                offset += len(chunk)
            central = []
            for _, record in central_records(case.original):
                changed = bytearray(record)
                struct.pack_into('<I', changed, 42, offsets[struct.unpack_from('<I', record, 42)[0]])
                central.append(bytes(changed))
            end = bytearray(case.original[case.original.rfind(b'PK\x05\x06'):])
            struct.pack_into('<I', end, 16, offset)
            case.original = b''.join(chunks + central) + bytes(end)
            case.source.write_bytes(case.original)
            case.sha = hashlib.sha256(case.original).hexdigest()
            case.catalog = source_reader.read_pptx_tables(case.source)
            with zipfile.ZipFile(case.source) as archive:
                self.assertIsNone(archive.testzip())
            self.invoke(case, [self.operation(case)])
            with zipfile.ZipFile(case.destination) as archive:
                self.assertIsNone(archive.testzip())
                item = archive.getinfo(PART)
            record = physical_records(case.destination.read_bytes())[PART]
            names, extras = struct.unpack_from('<2H', record, 26)
            self.assertEqual(len(record) - (30 + names + extras + item.compress_size), 12)

    def test_central_order_can_differ_from_physical_member_order(self):
        with self.fixture() as case:
            end = case.original.rfind(b'PK\x05\x06')
            central = struct.unpack_from('<I', case.original, end + 16)[0]
            case.original = case.original[:central] + b''.join(record for _, record in reversed(central_records(case.original))) + case.original[end:]
            case.source.write_bytes(case.original)
            case.sha = hashlib.sha256(case.original).hexdigest()
            case.catalog = source_reader.read_pptx_tables(case.source)
            self.invoke(case, [self.operation(case)])
            self.assertEqual([name for name, _ in central_records(case.original)],
                [name for name, _ in central_records(case.destination.read_bytes())])
            self.assertEqual(list(physical_records(case.original)), list(physical_records(case.destination.read_bytes())))

    def test_sequential_operations_keep_origin_frame_guard_and_current_text_hash(self):
        with self.fixture() as case:
            first = self.operation(case, text='새😀')
            source_cell = case.catalog['tables'][1]['cells'][3]
            original_text = cell_text_map(case.members[PART], source_cell)['text']
            second = {**first, 'expectedTextSha256': hashlib.sha256(('새😀' + original_text[4:]).encode()).hexdigest(),
                'startUtf16': 0, 'endUtf16': 1, 'text': '최종'}
            self.invoke(case, [first, second])
            final = source_reader.read_pptx_tables(case.destination)
            final_cell = final['tables'][1]['cells'][3]
            self.assertEqual(cell_text_map(final['parts'][PART], final_cell)['text'], '최종😀' + original_text[4:])

    def test_stale_frame_text_and_package_hash_reject_before_output(self):
        for kind in ('source', 'frame', 'text'):
            with self.subTest(kind=kind), self.fixture() as case:
                operation = self.operation(case)
                if kind != 'source':
                    operation['expectedSourceFrameSha256' if kind == 'frame' else 'expectedTextSha256'] = '0' * 64
                with self.assertRaises(ValueError):
                    self.api()(case.source, case.destination, [operation], '0' * 64 if kind == 'source' else case.sha)
                self.assertFalse(case.destination.exists())

    def test_unknown_fields_foreign_targets_and_boolean_coordinates_reject(self):
        for values in ({'extra': 1}, {'sourcePart': 'ppt/slides/missing.xml'}, {'shapeId': '999'}, {'row': True}, {'column': -1}):
            with self.subTest(values=values), self.fixture() as case:
                with self.assertRaises(ValueError):
                    self.invoke(case, [{**self.operation(case), **values}])
                self.assertFalse(case.destination.exists())

    def test_existing_destination_or_source_is_never_overwritten(self):
        with self.fixture() as case:
            case.destination.write_bytes(b'foreign file')
            with self.assertRaises((ValueError, FileExistsError)):
                self.invoke(case, [self.operation(case)])
            self.assertEqual(case.destination.read_bytes(), b'foreign file')
            with self.assertRaises((ValueError, FileExistsError)):
                self.api()(case.source, case.source, [self.operation(case)], case.sha)

    def test_signed_opc_package_is_not_patched_without_signature_preservation(self):
        with self.fixture(members=lambda members: members + [('_xmlsignatures/sig1.xml', b'<Signature/>')]) as case:
            with self.assertRaises(ValueError):
                self.invoke(case, [self.operation(case)])
            self.assertFalse(case.destination.exists())

    def test_source_size_limit_rejects_before_capturing_the_owned_archive_image(self):
        with self.fixture() as case:
            with patch.object(MODULE, 'MAX_PACKAGE_BYTES', len(case.original) - 1), \
                    patch.object(source_reader, 'open_pptx_tables', wraps=source_reader.open_pptx_tables) as capture:
                with self.assertRaises(ValueError):
                    self.invoke(case, [self.operation(case)])
                self.assertEqual(capture.call_count, 0, 'Reject a static oversized input before hashing/copying it')
            self.assertFalse(case.destination.exists())

    def test_same_inode_candidate_change_after_catalog_verification_cannot_publish_stale_hash(self):
        with self.fixture() as case:
            verify = MODULE._verify_catalog
            changed = []

            def alter_candidate_after_verification(*args):
                verify(*args)
                with case.destination.open('r+b', buffering=0) as candidate:
                    candidate.write(b'!')
                changed.append(True)

            with patch.object(MODULE, '_verify_catalog', alter_candidate_after_verification):
                with self.assertRaises(ValueError):
                    self.invoke(case, [self.operation(case)])
            self.assertEqual(changed, [True])
            self.assertFalse(case.destination.exists())

    def test_unrelated_corrupt_media_is_rejected_without_publishing_candidate(self):
        with self.fixture() as case:
            data = bytearray(case.original)
            with zipfile.ZipFile(io.BytesIO(data)) as archive:
                information = archive.getinfo(MEDIA)
                names, extra = struct.unpack_from('<2H', data, information.header_offset + 26)
                position = information.header_offset + 30 + names + extra
            data[position] ^= 0xFF
            case.original = bytes(data)
            case.source.write_bytes(case.original)
            case.sha = hashlib.sha256(case.original).hexdigest()
            with self.assertRaises(ValueError):
                self.invoke(case, [self.operation(case)])
            self.assertFalse(case.destination.exists())

    def test_original_change_during_candidate_verification_removes_only_owned_candidate(self):
        with self.fixture() as case:
            original_catalog = source_reader._catalog
            calls = []
            sentinel = case.source.parent / 'foreign.txt'
            sentinel.write_bytes(b'preserve')

            def mutate_source_during_result_catalog(*args):
                result = original_catalog(*args)
                calls.append(True)
                if len(calls) == 2:
                    case.source.write_bytes(case.original + b'changed during verification')
                return result

            try:
                with patch.object(source_reader, '_catalog', mutate_source_during_result_catalog):
                    with self.assertRaises(ValueError):
                        self.invoke(case, [self.operation(case)])
                self.assertEqual(len(calls), 2)
                self.assertFalse(case.destination.exists())
                self.assertEqual(sentinel.read_bytes(), b'preserve')
            finally:
                case.source.write_bytes(case.original)


if __name__ == '__main__':
    unittest.main()
