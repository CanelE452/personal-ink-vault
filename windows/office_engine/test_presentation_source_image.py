import hashlib
import io
import inspect
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

import office_presentation_source as source_reader
from test_presentation_source import package_members, write_package


def failing_close_factory(error):
    factory = source_reader.tempfile.TemporaryFile

    class View:
        def __init__(self, *args, **kwargs):
            self.stream = factory(*args, **kwargs)

        def __getattr__(self, name):
            return getattr(self.stream, name)

        def __enter__(self):
            return self

        def __exit__(self, *args):
            self.stream.close()
            raise error

    return View


class SourceImageTests(unittest.TestCase):
    def opener(self):
        opener = getattr(source_reader, 'open_pptx_tables', None)
        self.assertTrue(callable(opener), 'The source image context API is required')
        return opener

    def test_image_catalog_and_unrelated_members_share_one_owned_archive(self):
        opener = self.opener()
        with TemporaryDirectory() as directory:
            path = Path(directory) / 'source.pptx'
            members = package_members()
            write_package(path, members)
            original = path.read_bytes()
            expected = source_reader.read_pptx_tables(path)
            with opener(path) as image:
                self.assertEqual(image.catalog, expected)
                self.assertEqual(image.catalog['sourceSha256'], hashlib.sha256(original).hexdigest())
                self.assertEqual([(item.filename, image.archive.read(item))
                    for item in image.archive.infolist()], members)
                self.assertEqual(image.archive.mode, 'r')
                archive = image.archive
            self.assertIsNone(archive.fp)
            self.assertEqual(path.read_bytes(), original)

    def test_source_changes_during_catalog_are_rejected_before_context_entry(self):
        opener = self.opener()
        with TemporaryDirectory() as directory:
            path = Path(directory) / 'source.pptx'
            write_package(path, package_members())
            original = path.read_bytes()
            catalog = source_reader._catalog
            entered = []

            def changed(*args):
                result = catalog(*args)
                path.write_bytes(original + b'changed')
                return result

            with patch.object(source_reader, '_catalog', changed):
                with self.assertRaises(ValueError):
                    with opener(path):
                        entered.append(True)
            self.assertEqual(entered, [])

    def test_mutation_inside_context_never_changes_captured_member_bytes(self):
        opener = self.opener()
        with TemporaryDirectory() as directory:
            path = Path(directory) / 'source.pptx'
            members = package_members()
            write_package(path, members)
            original = path.read_bytes()
            with self.assertRaises(ValueError):
                with opener(path) as image:
                    archive = image.archive
                    path.write_bytes(original + b'changed')
                    self.assertEqual([(item.filename, archive.read(item))
                        for item in archive.infolist()], members)
            self.assertIsNone(archive.fp)

    def test_body_oserror_is_preserved_instead_of_reclassified_as_source_failure(self):
        opener = self.opener()
        with TemporaryDirectory() as directory:
            path = Path(directory) / 'source.pptx'
            write_package(path, package_members())
            error = OSError('private consumer failure')
            with self.assertRaises(OSError) as caught:
                with opener(path) as image:
                    archive = image.archive
                    raise error
            self.assertIs(caught.exception, error)
            self.assertIsNone(archive.fp)

    def test_source_drift_does_not_mask_the_body_error(self):
        opener = self.opener()
        with TemporaryDirectory() as directory:
            path = Path(directory) / 'source.pptx'
            write_package(path, package_members())
            original = path.read_bytes()
            error = RuntimeError('private binding failure')
            with self.assertRaises(RuntimeError) as caught:
                with opener(path) as image:
                    archive = image.archive
                    path.write_bytes(original + b'changed')
                    raise error
            self.assertIs(caught.exception, error)
            self.assertTrue(any('source' in note.lower() for note in error.__notes__))
            self.assertIsNone(archive.fp)

    def test_consumer_cannot_write_to_the_catalogs_verified_archive_image(self):
        opener = self.opener()
        with TemporaryDirectory() as directory:
            path = Path(directory) / 'source.pptx'
            write_package(path, package_members())
            original = path.read_bytes()
            with opener(path) as image:
                image.archive.fp.seek(0)
                try:
                    image.archive.fp.write(b'!')
                except (AttributeError, io.UnsupportedOperation):
                    pass
                else:
                    self.fail('A consumer could mutate the verified private archive image')
                self.assertFalse(image.archive.fp.writable())
            self.assertEqual(path.read_bytes(), original)

    def test_owned_view_close_failure_preserves_primary_consumer_error(self):
        opener = self.opener()
        with TemporaryDirectory() as directory:
            path = Path(directory) / 'source.pptx'
            write_package(path, package_members())
            primary = RuntimeError('private consumer failed')
            cleanup = OSError('owned view close failed')
            caught = None
            with patch.object(source_reader.tempfile, 'TemporaryFile', failing_close_factory(cleanup)):
                try:
                    with opener(path):
                        raise primary
                except BaseException as error:
                    caught = error
            self.assertIs(caught, primary)
            self.assertTrue(any('close' in note.lower() for note in primary.__notes__))

    def test_successful_consumer_cannot_hide_owned_view_close_failure(self):
        opener = self.opener()
        with TemporaryDirectory() as directory:
            path = Path(directory) / 'source.pptx'
            write_package(path, package_members())
            cleanup = OSError('owned view close failed')
            with patch.object(source_reader.tempfile, 'TemporaryFile', failing_close_factory(cleanup)):
                with self.assertRaises(OSError) as caught:
                    with opener(path):
                        pass
            self.assertIs(caught.exception, cleanup)

    def test_optional_package_byte_limit_is_checked_before_hashing_or_copying(self):
        opener = self.opener()
        self.assertIn('max_package_bytes', inspect.signature(opener).parameters,
            'BOOTSTRAP: the bounded image capture option is required')
        with TemporaryDirectory() as directory:
            path = Path(directory) / 'source.pptx'
            write_package(path, package_members())
            original = path.read_bytes()
            with patch.object(source_reader, '_digest', side_effect=AssertionError('No oversized hash')), \
                    patch.object(source_reader.tempfile, 'TemporaryFile', side_effect=AssertionError('No oversized image')):
                with self.assertRaises(ValueError):
                    with opener(path, max_package_bytes=len(original) - 1):
                        self.fail('The oversized source cannot be consumed')
            self.assertEqual(path.read_bytes(), original)


if __name__ == '__main__':
    unittest.main()
