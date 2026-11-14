import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
from zipfile import ZipFile

import office_worker as worker


CFB = bytes.fromhex('d0cf11e0a1b11ae1')
OOXML_PARTS = {'docx': 'word/document.xml', 'pptx': 'ppt/presentation.xml'}
SERVICES = {'doc': 'com.sun.star.text.TextDocument',
            'ppt': 'com.sun.star.presentation.PresentationDocument'}


class LegacyConversionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.runtime, self.job = self.root / 'runtime', self.root / 'job'

    def original(self, extension, data=CFB + b'legacy source bytes'):
        path = self.root / f'original.{extension}'
        path.write_bytes(data)
        return path, {'mode': 'convertLegacy', 'sourcePath': str(path),
                      'sessionId': 'legacy-fixture', 'expectedSourceSha256': worker.digest(path)}

    @contextmanager
    def fake_engine(self, extension, *, wrong_family=False, wrong_zip=False,
                    source_slides=2, reopened_slides=2, pages=2, mutate_working=False):
        modern = extension + 'x'
        events = []

        class Document:
            def __init__(self, path, converted):
                self.path, self.converted = path, converted
                self.DrawPages = SimpleNamespace(Count=reopened_slides if converted else source_slides)

            def supportsService(self, service):
                return not (self.converted and wrong_family) and service == SERVICES[extension]

            def isReadonly(self):
                return True

            def storeToURL(self, target, options):
                events.append(('store', target, options))
                self_test.assertFalse(self.converted)
                self_test.assertEqual(dict(options), {'FilterName': worker.FILTERS[modern], 'Overwrite': False})
                with ZipFile(self_test.job / f'converted.{modern}', 'x') as archive:
                    archive.writestr('[Content_Types].xml', '<Types/>')
                    archive.writestr('wrong.xml' if wrong_zip else OOXML_PARTS[modern], '<document/>')
                if mutate_working:
                    self.path.write_bytes(CFB + b'mutated private input')

            def close(self, deliver_ownership):
                events.append(('close', self.path.name, deliver_ownership))

        self_test = self

        def load(path, *, read_only=False):
            self.assertEqual(path.parent, self.job)
            self.assertTrue(read_only)
            events.append(('load', path.name, read_only))
            return Document(path, path.suffix == '.' + modern)

        @contextmanager
        def factory(runtime, directory):
            self.assertEqual(runtime, self.runtime)
            self.assertEqual(directory, self.job)
            events.append(('begin',))
            try:
                yield SimpleNamespace(load=load)
            finally:
                events.append(('end',))

        def export(document, pdf, kind, *, max_bytes):
            self.assertTrue(document.converted)
            self.assertEqual(kind, 'word' if extension == 'doc' else 'presentation')
            self.assertEqual(max_bytes, 128 * 1024 * 1024)
            pdf.write_bytes(b'%PDF-1.7\nverified\n%%EOF\n')
            events.append(('pdf', document.path.name))
            return pages

        with patch.object(worker, 'prop', side_effect=lambda name, value: (name, value)), \
             patch.object(worker, 'export_pdf', side_effect=export):
            yield factory, events

    def test_doc_and_ppt_convert_read_only_reopen_and_bind_exact_pair(self):
        for extension in ('doc', 'ppt'):
            with self.subTest(extension=extension):
                self.job = self.root / extension
                source, request = self.original(extension)
                original = source.read_bytes()
                with self.fake_engine(extension) as (factory, events):
                    result = worker.run_request(self.runtime, request, self.job, server_factory=factory)
                modern = extension + 'x'
                converted, pdf = self.job / f'converted.{modern}', self.job / 'preview.pdf'
                self.assertEqual(result, {'sessionId': request['sessionId'],
                    'inputSourceSha256': request['expectedSourceSha256'], 'targetExtension': modern,
                    'sourcePath': str(converted), 'sourceSha256': worker.digest(converted),
                    'pdfPath': str(pdf), 'pdfSha256': worker.digest(pdf), 'pdfPageCount': 2,
                    'engineVersion': 'LibreOffice26.8.2.2'})
                self.assertEqual(source.read_bytes(), original)
                self.assertEqual((self.job / f'working.{extension}').read_bytes(), original)
                self.assertEqual([e[0] for e in events], ['begin', 'load', 'store', 'close', 'load', 'pdf', 'close', 'end'])

    def test_rejects_wrong_fields_source_digest_and_signature_before_engine(self):
        source, request = self.original('doc')
        wrong, wrong_request = self.original('ppt', b'not a compound document')
        _, modern_request = self.original('docx')
        for args in ({**request, 'preview': False}, {**request, 'sessionId': ' '},
                     {**request, 'expectedSourceSha256': '0' * 64}, wrong_request, modern_request,
                     {**request, 'sourcePath': source.name}):
            with self.subTest(args=args):
                with self.fake_engine('doc') as (factory, events), self.assertRaises(ValueError):
                    worker.run_request(self.runtime, args, self.job, server_factory=factory)
                self.assertFalse(events)
                self.assertFalse(self.job.exists())
        self.assertTrue(wrong.is_file())

    def test_invalid_reopened_format_pdf_and_mutated_input_clean_only_job(self):
        source, request = self.original('ppt')
        original = source.read_bytes()
        unrelated = self.root / 'unrelated.txt'
        unrelated.write_bytes(b'keep')
        for failure in ({'wrong_family': True}, {'wrong_zip': True}, {'reopened_slides': 1},
                        {'pages': 1}, {'mutate_working': True}):
            with self.subTest(failure=failure):
                with self.fake_engine('ppt', **failure) as (factory, _), self.assertRaises(ValueError):
                    worker.run_request(self.runtime, request, self.job, server_factory=factory)
                self.assertFalse(self.job.exists())
                self.assertEqual(source.read_bytes(), original)
                self.assertEqual(unrelated.read_bytes(), b'keep')

    def test_rejects_existing_job_without_deleting_its_files(self):
        _, request = self.original('doc')
        self.job.mkdir()
        marker = self.job / 'existing'
        marker.write_text('keep')
        with self.fake_engine('doc') as (factory, events), self.assertRaises(FileExistsError):
            worker.run_request(self.runtime, request, self.job, server_factory=factory)
        self.assertEqual(marker.read_text(), 'keep')
        self.assertFalse(events)


if __name__ == '__main__':
    unittest.main()
