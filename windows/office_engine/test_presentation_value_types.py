"""Nominal UNO interface closure; these doubles never load native Office."""
from types import SimpleNamespace
import unittest

import office_presentation_tables as tables
from test_presentation_tables import CAPABILITIES, NativeValue, TableModel, TableShape


class NominalInterface:
    def __init__(self, pretend_enum=False):
        self.pretend_enum = pretend_enum
        self.lookups = {'typeName': 0, 'value': 0, 'str': 0, 'repr': 0}

    @property
    def typeName(self):
        self.lookups['typeName'] += 1
        if not self.pretend_enum:
            raise AttributeError('An opaque interface has no enum typeName')
        return 'com.sun.star.drawing.FillStyle'

    @property
    def value(self):
        self.lookups['value'] += 1
        if not self.pretend_enum:
            raise AttributeError('An opaque interface has no enum value')
        return 'SOLID'

    def __str__(self):
        self.lookups['str'] += 1
        raise AssertionError('An unsupported interface must not be stringified')

    def __repr__(self):
        self.lookups['repr'] += 1
        raise AssertionError('An unsupported interface must not be represented')


NominalInterface.__name__, NominalInterface.__module__ = 'pyuno', 'builtins'


class PresentationValueTypesTest(unittest.TestCase):
    def test_bound_opaque_and_enum_shaped_interfaces_close_before_reflection_after_node_accounting(self):
        for pretend_enum in (False, True):
            with self.subTest(pretend_enum=pretend_enum):
                budget = tables.DocBudget()
                budget.interface_type = NominalInterface
                value = NominalInterface(pretend_enum)
                before = budget.nodes, budget.raw_bytes
                with self.assertRaises(ValueError):
                    tables.native_value(value, budget=budget)
                self.assertEqual((budget.nodes, budget.raw_bytes), (before[0] + 1, before[1] + 2))
                self.assertEqual(value.lookups, {'typeName': 0, 'value': 0, 'str': 0, 'repr': 0})
        exhausted = tables.DocBudget()
        exhausted.interface_type = NominalInterface
        exhausted.nodes = exhausted.NODE_LIMIT - exhausted.NODE_RESERVE
        value = NominalInterface(True)
        with self.assertRaises(tables.ReadBudgetExceeded):
            tables.native_value(value, budget=exhausted)
        self.assertEqual(value.lookups, {'typeName': 0, 'value': 0, 'str': 0, 'repr': 0})

    def test_scalars_plain_enums_and_border_wrapper_internal_spelling_keep_their_exact_values(self):
        budget = tables.DocBudget()
        budget.interface_type = NominalInterface
        scalars = [None, False, 17, -4, 1.25, '한글 😀']
        self.assertEqual(tables.native_value(scalars, budget=budget),
            [None, False, 17, -4, 1.25, '한글 😀'])
        self.assertEqual(budget.nodes, 7)
        self.assertEqual(tables.native_value(NativeValue('com.sun.star.beans.PropertyState', 'DEFAULT_VALUE'), budget=budget),
            {'enumType': 'com.sun.star.beans.PropertyState', 'value': 'DEFAULT_VALUE'})
        spelling_only = type('pyuno', (NativeValue,), {'__module__': 'builtins'})
        self.assertIsNot(spelling_only, NominalInterface)
        self.assertEqual(tables.native_value(spelling_only('com.sun.star.drawing.FillStyle', 'SOLID'), budget=budget),
            {'enumType': 'com.sun.star.drawing.FillStyle', 'value': 'SOLID'})
        struct_type = type('struct', (SimpleNamespace,), {'__module__': 'pyuno'})
        internal = struct_type(typeName='struct', Color=-1, InnerLineWidth=0,
            OuterLineWidth=17, LineDistance=0, LineStyle=0, LineWidth=17)
        expected_internal = {'structType': 'struct', 'fields': {'Color': -1,
            'InnerLineWidth': 0, 'OuterLineWidth': 17, 'LineDistance': 0, 'LineStyle': 0, 'LineWidth': 17}}
        self.assertEqual(tables.native_value(internal, hint='com.sun.star.table.BorderLine2', budget=budget),
            expected_internal)
        wrapped = spelling_only('com.sun.star.table.BorderLine2', internal)
        self.assertEqual(tables.native_value(wrapped, hint='com.sun.star.table.BorderLine', budget=budget),
            {'enumType': 'com.sun.star.table.BorderLine2', 'value': expected_internal})
        self.assertIs(budget.interface_type, NominalInterface)
        self.assertFalse(budget.exhausted)

    def test_actual_table_capture_binds_the_shape_type_and_marks_its_interface_raw_value_unknown(self):
        class ActualShape(TableShape):
            def __init__(self):
                super().__init__(TableModel(1, 1))
                self.lookups = {'typeName': 0, 'value': 0}
                self.values['UnrelatedInterface'] = self
                self.types['UnrelatedInterface'] = 'com.sun.star.uno.XInterface'

            @property
            def typeName(self):
                self.lookups['typeName'] += 1
                return 'com.sun.star.drawing.FillStyle'

            @property
            def value(self):
                self.lookups['value'] += 1
                return 'SOLID'

        shape, budget = ActualShape(), tables.DocBudget()
        self.assertIsNone(getattr(budget, 'interface_type', None))
        captured, binding = tables.capture_table('slide-0/shape-0', 'slide-0', shape, budget)
        self.assertEqual(captured['cells'][0]['text'], 'same A😀é 한글')
        self.assertEqual(captured['nativeBoundsHmm'], {'x': 1000, 'y': 1500, 'width': 21999, 'height': 7000})
        self.assertIs(binding['shape'], shape)
        self.assertIs(binding['model'], shape.values['Model'])
        self.assertIs(binding['cells'][0], shape.values['Model'].cells[0][0])
        raw = captured['rawStyle']['UnrelatedInterface']
        self.assertIs(raw['present'], True)
        self.assertEqual(raw['nativeType'], 'com.sun.star.uno.XInterface')
        self.assertIs(raw['value'].get('unknown'), True,
            'An interface with enum-like attributes must remain an unknown raw value')
        self.assertIsNone(captured['tableSha256'])
        self.assertEqual(set(captured['capabilities']), set(CAPABILITIES))
        self.assertTrue(all(value is False for value in captured['capabilities'].values()))
        self.assertIs(budget.interface_type, type(shape))
        self.assertEqual(shape.lookups, {'typeName': 0, 'value': 0})

    def test_a_different_actual_shape_type_cannot_rebind_an_observation_budget(self):
        class DifferentActualShape(TableShape):
            def __init__(self):
                super().__init__(TableModel(1, 1))
                self.model_reads = 0

            def getPropertyValue(self, name):
                if name == 'Model':
                    self.model_reads += 1
                return super().getPropertyValue(name)

        budget = tables.DocBudget()
        first, same_type = TableShape(TableModel(1, 1)), TableShape(TableModel(1, 1))
        for index, shape in enumerate((first, same_type)):
            captured, _ = tables.capture_table('slide-0/shape-' + str(index), 'slide-0', shape, budget)
            self.assertEqual(captured['cells'][0]['text'], 'same A😀é 한글')
            self.assertIsNotNone(captured['tableSha256'])
        different = DifferentActualShape()
        with self.assertRaises(ValueError):
            tables.capture_table('slide-0/shape-2', 'slide-0', different, budget)
        self.assertIs(budget.interface_type, type(first))
        self.assertEqual(different.model_reads, 0)


if __name__ == '__main__':
    unittest.main()
