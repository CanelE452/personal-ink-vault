"""Actual candidate files with faults at parser, verifier, and source-image exit boundaries."""
from contextlib import contextmanager
from pathlib import Path
import unittest
from unittest.mock import patch

import office_presentation_source as source_reader
import office_presentation_structure as structure
import test_presentation_structure as fixtures


def identity(path):
    information = path.stat()
    return information.st_dev, information.st_ino


class PresentationStructureOwnershipTest(unittest.TestCase):
    @contextmanager
    def fixture(self):
        fixture = fixtures.PresentationStructurePackageTest(methodName='runTest')
        with fixture.fixture() as case:
            sentinel = case.source.parent / 'unrelated.txt'
            sentinel.write_bytes(b'UNRELATED FILE MUST SURVIVE')
            try:
                yield case
            finally:
                self.assertEqual(sentinel.read_bytes(), b'UNRELATED FILE MUST SURVIVE')

    def invoke(self, case):
        return structure.add_tables_pptx(case.source, case.destination,
            [fixtures.operation(case.parts[fixtures.PART])], case.sha)

    def test_candidate_parser_failure_after_actual_write_removes_only_owned_output(self):
        with self.fixture() as case:
            read = source_reader.read_pptx_tables
            observed = []

            def reject_candidate(path):
                self.assertEqual(Path(path), case.destination)
                result = read(path)
                self.assertEqual(len(result['tables']), 2)
                self.assertGreater(case.destination.stat().st_size, 0)
                observed.append(identity(case.destination))
                raise ValueError('injected candidate parser failure after actual reading')

            with patch.object(source_reader, 'read_pptx_tables', reject_candidate):
                with self.assertRaisesRegex(ValueError, 'injected candidate parser failure'):
                    self.invoke(case)
            self.assertEqual(len(observed), 1)
            self.assertFalse(case.destination.exists())
            self.assertEqual(case.source.read_bytes(), case.original)

    def test_request_ledger_verifier_failure_removes_only_owned_output(self):
        with self.fixture() as case:
            verify = structure._verify
            observed = []

            def reject_after_verification(*args):
                verify(*args)
                candidate = source_reader.read_pptx_tables(case.destination)
                self.assertEqual(len(candidate['tables']), 2)
                observed.append(identity(case.destination))
                raise ValueError('injected structure ledger verifier failure')

            with patch.object(structure, '_verify', reject_after_verification):
                with self.assertRaisesRegex(ValueError, 'injected structure ledger verifier failure'):
                    self.invoke(case)
            self.assertEqual(len(observed), 1)
            self.assertFalse(case.destination.exists())
            self.assertEqual(case.source.read_bytes(), case.original)

    def test_source_image_exit_fault_preserves_same_bytes_foreign_inode_and_cleanup_note(self):
        with self.fixture() as case:
            open_image = source_reader.open_pptx_tables
            retained = case.source.parent / 'retained-owned-candidate.pptx'
            fault = ValueError('injected source-image exit failure')
            observed = []

            @contextmanager
            def replace_at_source_exit(path, **kwargs):
                with open_image(path, **kwargs) as image:
                    yield image
                    if Path(path) == case.source:
                        payload = case.destination.read_bytes()
                        owned_identity = identity(case.destination)
                        case.destination.rename(retained)
                        with case.destination.open('xb') as stream:
                            stream.write(payload)
                        foreign_identity = identity(case.destination)
                        self.assertNotEqual(owned_identity, foreign_identity)
                        self.assertEqual(identity(retained), owned_identity)
                        observed.append((payload, owned_identity, foreign_identity))
                        raise fault

            with patch.object(source_reader, 'open_pptx_tables', replace_at_source_exit):
                with self.assertRaisesRegex(ValueError, 'injected source-image exit failure') as caught:
                    self.invoke(case)
            self.assertIs(caught.exception, fault)
            self.assertEqual(len(observed), 1)
            payload, owned_identity, foreign_identity = observed[0]
            self.assertEqual(case.destination.read_bytes(), payload)
            self.assertEqual(identity(case.destination), foreign_identity)
            self.assertEqual(retained.read_bytes(), payload)
            self.assertEqual(identity(retained), owned_identity)
            self.assertEqual(case.source.read_bytes(), case.original)
            self.assertTrue(any('Removing owned failed PPTX structure candidate: '
                'Preserve the foreign replacement of the structure candidate' in note
                for note in getattr(caught.exception, '__notes__', ())),
                'A cleanup refusal must remain attached to the original failure')

    def test_real_source_image_exit_detects_stale_original_and_removes_owned_candidate(self):
        with self.fixture() as case:
            open_image = source_reader.open_pptx_tables
            changed_source = case.original + b' changed only at real source-image exit'
            observed = []

            @contextmanager
            def change_original_at_exit(path, **kwargs):
                with open_image(path, **kwargs) as image:
                    yield image
                    if Path(path) == case.source:
                        candidate = source_reader.read_pptx_tables(case.destination)
                        self.assertEqual(len(candidate['tables']), 2)
                        observed.append(identity(case.destination))
                        case.source.write_bytes(changed_source)

            try:
                with patch.object(source_reader, 'open_pptx_tables', change_original_at_exit):
                    with self.assertRaisesRegex(ValueError, 'immutable PPTX source changed during reading'):
                        self.invoke(case)
                self.assertEqual(len(observed), 1)
                self.assertFalse(case.destination.exists())
                self.assertEqual(case.source.read_bytes(), changed_source,
                    'The writer must not overwrite the externally changed original during cleanup')
            finally:
                case.source.write_bytes(case.original)

    def test_same_inode_output_change_after_real_verification_cannot_return_stale_digest(self):
        with self.fixture() as case:
            verify = structure._verify
            observed = []

            def change_after_verification(*args):
                verify(*args)
                before = identity(case.destination)
                payload = case.destination.read_bytes()
                with case.destination.open('r+b', buffering=0) as stream:
                    self.assertEqual(stream.write(b'!'), 1)
                self.assertEqual(identity(case.destination), before)
                self.assertNotEqual(case.destination.read_bytes(), payload)
                observed.append(before)

            with patch.object(structure, '_verify', change_after_verification):
                with self.assertRaisesRegex(ValueError, 'verified structure candidate changed'):
                    self.invoke(case)
            self.assertEqual(len(observed), 1)
            self.assertFalse(case.destination.exists())
            self.assertEqual(case.source.read_bytes(), case.original)


if __name__ == '__main__':
    unittest.main()
