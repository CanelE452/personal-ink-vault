"""Actual engine context must follow the existing Word production boundaries."""
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import office_worker as worker


def word_model():
    return SimpleNamespace(body=SimpleNamespace(paragraphs={}, order=[], owner_id='body'),
        tables={}, page_styles=[], table_owners={}, refresh_page_metadata=lambda: None,
        owner_snapshot=lambda render: [], image_catalog=lambda: None)


class WordEngineContextContractTest(unittest.TestCase):
    def test_inspection_word_receives_the_actual_engine_context(self):
        context, word = object(), word_model()
        with patch.object(worker, 'objects', return_value=('word', {}, {})), \
                patch.object(worker, 'uno', object(), create=True), \
                patch.object(worker.office_word_layout, 'WordDocument', return_value=word) as constructor, \
                patch.object(worker.office_word, 'paragraph_styles', return_value=[]):
            snapshot = worker.snapshot(object(), 'controlled-source-hash', context=context)
        self.assertEqual(snapshot['kind'], 'word')
        self.assertIs(constructor.call_args.kwargs.get('context'), context)

    def test_edit_journal_word_receives_the_actual_engine_context(self):
        context, word, state = object(), word_model(), {}
        with patch.object(worker, 'objects', return_value=('word', {}, {})), \
                patch.object(worker, 'uno', object(), create=True), \
                patch.object(worker.office_word_layout, 'WordDocument', return_value=word) as constructor:
            result = worker.apply_operations(object(), [], context=context, presentation_state=state)
        self.assertEqual(result, ('word', [], []))
        self.assertIs(state['word'], word)
        self.assertIs(constructor.call_args.kwargs.get('context'), context)


if __name__ == '__main__':
    unittest.main()
