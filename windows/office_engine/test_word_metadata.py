import unittest

from office_word import physical_alignment


class WordDirectionMetadataTest(unittest.TestCase):
    def test_actual_logical_alignment_roundtrips_keep_physical_direction(self):
        for adjust, writing_mode, expected in [
            (6, 0, 'right'),
            (5, 1, 'right'),
            (6, 1, 'left'),
            (5, 0, 'left'),
            (0, 0, 'left'),
            (1, 1, 'right'),
            (2, 0, 'justify'),
            (3, 1, 'center'),
        ]:
            with self.subTest(adjust=adjust, writing_mode=writing_mode):
                self.assertEqual(physical_alignment(adjust, writing_mode), expected)

    def test_unresolved_context_vertical_and_stretched_alignment_stay_other(self):
        for adjust, writing_mode in [(5, 4), (6, None), (5, 2), (6, 3), (0, 2), (4, 0), (99, 1)]:
            with self.subTest(adjust=adjust, writing_mode=writing_mode):
                self.assertEqual(physical_alignment(adjust, writing_mode), 'other')


if __name__ == '__main__':
    unittest.main()
