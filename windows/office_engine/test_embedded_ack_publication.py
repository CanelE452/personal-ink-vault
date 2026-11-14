"""Real Windows ACK publication with the existing fake Office process boundary."""
import os
from pathlib import Path
import threading
import unittest
from unittest.mock import patch

import test_embedded_stages as fixtures


class EmbeddedAckPublicationTest(unittest.TestCase):
    def test_ack_is_not_visible_while_its_writer_is_still_open(self):
        fixture = fixtures.EmbeddedStagesTest(methodName='runTest')
        with fixture.fixture(inspect_preview=True) as state:
            write_json = state.stages._write_json
            fsync = os.fsync
            parent_thread = threading.get_ident()
            active_ack = None
            observed = []

            def write(path, value, **kwargs):
                nonlocal active_ack
                path = Path(path)
                if not path.name.startswith('pdf-ack'):
                    return write_json(path, value, **kwargs)
                active_ack = path.parent / 'pdf-ack.json'
                try:
                    return write_json(path, value, **kwargs)
                finally:
                    active_ack = None

            def synced(descriptor):
                fsync(descriptor)
                if threading.get_ident() == parent_thread and active_ack is not None:
                    observed.append(active_ack)
                    self.assertFalse(active_ack.exists(),
                        'The child can observe ACK before the parent closes its writable handle')

            with patch.object(state.stages, '_write_json', side_effect=write), \
                    patch.object(state.module.os, 'fsync', side_effect=synced):
                fixture.drive(state)
            self.assertEqual(len(observed), 1)
            self.assertIsNone(state.caught, repr(state.caught))
            self.assertIsNotNone(state.result)
            self.assertEqual(len(state.harness.ack_checks), 1)
            self.assertTrue(observed[0].is_file())
            self.assertEqual(list(observed[0].parent.glob('pdf-ack*')), [observed[0]])

    def test_publication_preserves_an_existing_foreign_ack(self):
        fixture = fixtures.EmbeddedStagesTest(methodName='runTest')
        with fixture.fixture(inspect_preview=True) as state:
            write_json = state.stages._write_json
            foreign = b'FOREIGN ACK MUST SURVIVE'
            injected = []

            def write(path, value, **kwargs):
                path = Path(path)
                if path.name.startswith('pdf-ack') and not injected:
                    ack = path.parent / 'pdf-ack.json'
                    with ack.open('xb') as stream:
                        stream.write(foreign)
                    information = ack.stat()
                    injected.append((ack, (information.st_dev, information.st_ino)))
                return write_json(path, value, **kwargs)

            with patch.object(state.stages, '_write_json', side_effect=write):
                fixture.drive(state)
            self.assertEqual(len(injected), 1)
            self.assertIsNotNone(state.caught)
            self.assertIsNone(state.result)
            ack, identity = injected[0]
            self.assertEqual(ack.read_bytes(), foreign)
            information = ack.stat()
            self.assertEqual((information.st_dev, information.st_ino), identity)

    def test_rename_does_not_replace_an_ack_created_after_the_existence_check(self):
        fixture = fixtures.EmbeddedStagesTest(methodName='runTest')
        with fixture.fixture(inspect_preview=True) as state:
            rename = Path.rename
            foreign = b'FOREIGN ACK CREATED AT RENAME'
            injected = []

            def publishing(path, target):
                if path.name == 'pdf-ack.pending.json':
                    ack = Path(target)
                    self.assertFalse(ack.exists())
                    with ack.open('xb') as stream:
                        stream.write(foreign)
                    information = ack.stat()
                    injected.append((ack, (information.st_dev, information.st_ino)))
                return rename(path, target)

            with patch.object(Path, 'rename', publishing):
                fixture.drive(state)
            self.assertEqual(len(injected), 1)
            self.assertIsNotNone(state.caught)
            self.assertIsNone(state.result)
            ack, identity = injected[0]
            self.assertEqual(ack.read_bytes(), foreign)
            information = ack.stat()
            self.assertEqual((information.st_dev, information.st_ino), identity)

    def test_same_bytes_cannot_adopt_a_replaced_pending_file_identity(self):
        fixture = fixtures.EmbeddedStagesTest(methodName='runTest')
        with fixture.fixture(inspect_preview=True) as state:
            write_json = state.stages._write_json
            injected = []

            def write(path, value, **kwargs):
                result = write_json(path, value, **kwargs)
                path = Path(path)
                if path.name == 'pdf-ack.pending.json':
                    original = path.read_bytes()
                    information = path.stat()
                    identity = (information.st_dev, information.st_ino)
                    path.rename(path.with_name('retained-original-ack.json'))
                    with path.open('xb') as stream:
                        stream.write(original)
                    replacement = path.stat()
                    replacement_identity = (replacement.st_dev, replacement.st_ino)
                    self.assertNotEqual(identity, replacement_identity)
                    injected.append((path, original, replacement_identity))
                return result

            with patch.object(state.stages, '_write_json', side_effect=write):
                fixture.drive(state)
            self.assertEqual(len(injected), 1)
            self.assertIsNotNone(state.caught)
            self.assertIsNone(state.result)
            pending, original, identity = injected[0]
            self.assertFalse((pending.parent / 'pdf-ack.json').exists())
            self.assertEqual(pending.read_bytes(), original)
            information = pending.stat()
            self.assertEqual((information.st_dev, information.st_ino), identity)


if __name__ == '__main__':
    unittest.main()
