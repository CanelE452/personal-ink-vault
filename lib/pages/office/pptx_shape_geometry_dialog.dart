import 'dart:async';

import 'package:flutter/material.dart';
import 'package:saber/data/office/pptx_shape_geometry.dart';

typedef PptxShapeGeometryDraft = ({
  int slideIndex,
  PptxShapeGeometryShape shape,
  PptxShapeGeometry geometry,
});

Future<PptxShapeGeometryDraft?> choosePptxShapeGeometry(
  BuildContext context,
  PptxShapeGeometryPlan plan,
  Future<List<PptxShapeGeometryShape>> Function(int slideIndex) loadSlide,
) => showDialog<PptxShapeGeometryDraft>(
  context: context,
  barrierDismissible: false,
  builder: (context) => _PptxShapeGeometryDialog(plan, loadSlide),
);

const _emuPerMm = 36000;
const _decimalScale = 1000000;
final _decimal = RegExp(r'^([+-]?)(\d{0,9})(?:[.,](\d{0,6}))?$');
final _trailingZeroes = RegExp(r'0+$');

String _asMillimetres(int value) {
  final magnitude = value.abs();
  final whole = magnitude ~/ _emuPerMm;
  final fraction =
      (magnitude % _emuPerMm * _decimalScale + _emuPerMm ~/ 2) ~/ _emuPerMm;
  final sign = value < 0 ? '-' : '';
  if (fraction == 0) return '$sign$whole';
  final digits = fraction.toString().padLeft(6, '0');
  return '$sign$whole.${digits.replaceFirst(_trailingZeroes, '')}';
}

int? _fromMillimetres(String text) {
  final match = _decimal.firstMatch(text.trim());
  if (match == null) return null;
  final whole = match[2]!;
  final fraction = match[3] ?? '';
  if (whole.isEmpty && fraction.isEmpty) return null;
  final magnitude =
      (int.tryParse(whole) ?? 0) * _emuPerMm +
      (int.parse(fraction.padRight(6, '0')) * _emuPerMm + _decimalScale ~/ 2) ~/
          _decimalScale;
  return match[1] == '-' ? -magnitude : magnitude;
}

enum _Field {
  x('가로 위치 (X)'),
  y('세로 위치 (Y)'),
  width('너비'),
  height('높이');

  new(this.label);

  final String label;
  bool get isExtent => this == width || this == height;

  int read(PptxShapeGeometry geometry) => switch (this) {
    x => geometry.xEmu,
    y => geometry.yEmu,
    width => geometry.widthEmu,
    height => geometry.heightEmu,
  };
}

class _PptxShapeGeometryDialog extends StatefulWidget {
  const new(this.plan, this.loadSlide);

  final PptxShapeGeometryPlan plan;
  final Future<List<PptxShapeGeometryShape>> Function(int slideIndex) loadSlide;

  @override
  State<_PptxShapeGeometryDialog> createState() =>
      _PptxShapeGeometryDialogState();
}

class _PptxShapeGeometryDialogState extends State<_PptxShapeGeometryDialog> {
  final _inputs = {
    for (final field in _Field.values) field: TextEditingController(),
  };
  int? _slideIndex;
  List<PptxShapeGeometryShape>? _shapes;
  PptxShapeGeometryShape? _shape;
  _Field? _resizeDriver;
  var _loadGeneration = 0;
  var _loadFailed = false;
  var _confirming = false;

  @override
  void dispose() {
    for (final controller in _inputs.values) {
      controller.dispose();
    }
    super.dispose();
  }

  bool _editable(_Field field, PptxShapeGeometryShape shape) =>
      field.isExtent ? shape.canResize : shape.canMove;

  int? _value(_Field field, PptxShapeGeometryShape shape) {
    final original = field.read(shape.geometry);
    final input = _inputs[field]!.text;
    if (!_editable(field, shape) || input == _asMillimetres(original)) {
      return original;
    }
    final emu = _fromMillimetres(input);
    final minimum = field.isExtent ? 1 : PptxShapeGeometry.minCoordinate;
    return emu != null &&
            emu >= minimum &&
            emu <= PptxShapeGeometry.maxCoordinate
        ? emu
        : null;
  }

  int? _dependentExtent(_Field driver, PptxShapeGeometryShape shape) {
    final value = _value(driver, shape);
    if (value == null) return null;
    final other = driver == _Field.width ? _Field.height : _Field.width;
    return PptxShapeGeometry.proportionalExtent(
      value,
      driver.read(shape.geometry),
      other.read(shape.geometry),
    );
  }

  PptxShapeGeometry? get _geometry {
    final shape = _shape;
    if (shape == null) return null;
    final x = _value(_Field.x, shape);
    final y = _value(_Field.y, shape);
    var width = _value(_Field.width, shape);
    var height = _value(_Field.height, shape);
    if (_resizeDriver case final driver? when shape.aspectRatioLocked) {
      final other = _dependentExtent(driver, shape);
      if (driver == _Field.width) {
        height = other;
      } else {
        width = other;
      }
    }
    if (x == null || y == null || width == null || height == null) return null;
    return PptxShapeGeometry(
      xEmu: x,
      yEmu: y,
      widthEmu: width,
      heightEmu: height,
    );
  }

  bool get _dirty {
    final shape = _shape;
    if (shape == null) return false;
    return _geometry != shape.geometry;
  }

  Future<bool> _discardChanges() async {
    if (!_dirty) return true;
    if (_confirming) return false;
    _confirming = true;
    try {
      return await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('이 개체의 변경 사항을 버릴까요?'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('계속 편집'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('변경 버리기'),
                ),
              ],
            ),
          ) ==
          true;
    } finally {
      _confirming = false;
    }
  }

  Future<void> _cancel() async {
    if (await _discardChanges() &&
        mounted &&
        ModalRoute.of(context)?.isCurrent == true) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _selectSlide(int index) async {
    if (!await _discardChanges() || !mounted) return;
    final generation = ++_loadGeneration;
    setState(() {
      _slideIndex = index;
      _shapes = null;
      _shape = null;
      _resizeDriver = null;
      _loadFailed = false;
    });
    try {
      final shapes = await widget.loadSlide(index);
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _shapes = shapes);
    } on Object {
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _loadFailed = true);
    }
  }

  Future<void> _selectShape(PptxShapeGeometryShape shape) async {
    if (identical(_shape, shape) || !await _discardChanges() || !mounted) {
      return;
    }
    for (final field in _Field.values) {
      _inputs[field]!.text = _asMillimetres(field.read(shape.geometry));
    }
    setState(() {
      _shape = shape;
      _resizeDriver = null;
    });
  }

  void _onEdited(_Field field, PptxShapeGeometryShape shape) {
    setState(() {
      if (!shape.aspectRatioLocked || !field.isExtent) return;
      _resizeDriver = field;
      final other = _dependentExtent(field, shape);
      if (other != null) {
        final dependent = field == _Field.width ? _Field.height : _Field.width;
        _inputs[dependent]!.text = _asMillimetres(other);
      }
    });
  }

  void _submit() {
    if (ModalRoute.of(context)?.isCurrent != true) return;
    final slide = _slideIndex;
    final shape = _shape;
    final geometry = _geometry;
    if (slide == null ||
        shape == null ||
        geometry == null ||
        geometry == shape.geometry) {
      return;
    }
    Navigator.of(context)
        .pop((slideIndex: slide, shape: shape, geometry: geometry));
  }

  @override
  Widget build(BuildContext context) {
    final slide = _slideIndex;
    final shape = _shape;
    final geometry = _geometry;
    return PopScope<PptxShapeGeometryDraft>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_cancel());
      },
      child: AlertDialog(
        key: const ValueKey('pptx-shape-geometry-dialog'),
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        scrollable: true,
        title: const Text('PPTX 개체 위치 및 크기'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _slidePicker(),
              if (slide != null) ...[
                const SizedBox(height: 12),
                _shapePicker(slide),
              ],
              if (shape != null) ...[
                const SizedBox(height: 12),
                const Text('슬라이드의 왼쪽과 위쪽을 기준으로 위치를 입력합니다.'),
                if (!shape.canMove) const Text('위치는 원본에서 잠겨 있습니다.'),
                if (!shape.canResize) const Text('크기는 원본에서 잠겨 있습니다.'),
                if (shape.aspectRatioLocked && shape.canResize)
                  const Text('원본의 가로세로 비율을 유지합니다.'),
                const SizedBox(height: 12),
                _fields(shape),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('pptx-shape-geometry-cancel'),
            onPressed: _cancel,
            child: const Text('취소'),
          ),
          FilledButton(
            key: const ValueKey('pptx-shape-geometry-save'),
            onPressed:
                shape != null && geometry != null && geometry != shape.geometry
                ? _submit
                : null,
            child: const Text('수정하고 저장'),
          ),
        ],
      ),
    );
  }

  Widget _slidePicker() => InputDecorator(
    decoration: const InputDecoration(labelText: '슬라이드'),
    child: DropdownButtonHideUnderline(
      child: DropdownButton<int>(
        key: const ValueKey('pptx-shape-geometry-slide'),
        value: _slideIndex,
        isDense: true,
        isExpanded: true,
        hint: const Text('슬라이드 선택'),
        items: [
          for (final slide in widget.plan.slides)
            DropdownMenuItem(
              value: slide.index,
              child: Text(
                [
                  '슬라이드 ${slide.index + 1}',
                  if (slide.hidden) '숨김',
                  if (slide.title case final title? when title.isNotEmpty)
                    title,
                ].join(' · '),
                key: ValueKey('pptx-shape-geometry-slide-${slide.index}'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: (index) async {
          if (index != null && index != _slideIndex) await _selectSlide(index);
        },
      ),
    ),
  );

  Widget _shapePicker(int slide) {
    if (_loadFailed) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('이 슬라이드의 개체 정보를 읽지 못했습니다.'),
          TextButton(
            onPressed: () => _selectSlide(slide),
            child: const Text('다시 읽기'),
          ),
        ],
      );
    }
    final shapes = _shapes;
    if (shapes == null) {
      return const LinearProgressIndicator(semanticsLabel: '개체 읽는 중');
    }
    if (shapes.isEmpty) return const Text('이 슬라이드에 수정할 수 있는 개체가 없습니다.');
    final names = <String, int>{};
    for (final shape in shapes) {
      final name = shape.name.trim();
      names[name] = (names[name] ?? 0) + 1;
    }
    return InputDecorator(
      decoration: const InputDecoration(labelText: '개체'),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<PptxShapeGeometryShape>(
          key: const ValueKey('pptx-shape-geometry-shape'),
          value: _shape,
          isDense: true,
          isExpanded: true,
          hint: const Text('도형 또는 사진 선택'),
          items: [
            for (final shape in shapes)
              DropdownMenuItem(
                value: shape,
                child: Text(
                  _shapeLabel(shape, names),
                  key: ValueKey('pptx-shape-geometry-shape-${shape.shapeId}'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (shape) async {
            if (shape != null) await _selectShape(shape);
          },
        ),
      ),
    );
  }

  String _shapeLabel(PptxShapeGeometryShape shape, Map<String, int> names) {
    final name = shape.name.trim();
    final kind = shape.kind == 'picture' ? '사진' : '도형';
    if (name.isEmpty) return '$kind ${shape.shapeId}';
    if (names[name] != 1) return '$name · $kind ${shape.shapeId}';
    return name;
  }

  Widget _fields(PptxShapeGeometryShape shape) {
    final fields = [for (final field in _Field.values) _input(field, shape)];
    if (MediaQuery.sizeOf(context).width < 560) {
      return Column(
        children: [
          for (var index = 0; index < fields.length; index++) ...[
            if (index != 0) const SizedBox(height: 10),
            fields[index],
          ],
        ],
      );
    }
    return Column(
      children: [
        for (var index = 0; index < fields.length; index += 2) ...[
          if (index != 0) const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: fields[index]),
              const SizedBox(width: 12),
              Expanded(child: fields[index + 1]),
            ],
          ),
        ],
      ],
    );
  }

  Widget _input(_Field field, PptxShapeGeometryShape shape) {
    final enabled = _editable(field, shape);
    String? error;
    if (enabled && _value(field, shape) == null) {
      error = field.isExtent ? '양수 크기를 입력하세요.' : '유효한 좌표를 입력하세요.';
    } else if (field == _resizeDriver &&
        _dependentExtent(field, shape) == null) {
      error = '비율을 유지할 수 있는 범위를 넘었습니다.';
    }
    return TextFormField(
      key: ValueKey('pptx-shape-geometry-${field.name}'),
      controller: _inputs[field],
      enabled: enabled,
      keyboardType: TextInputType.numberWithOptions(
        signed: !field.isExtent,
        decimal: true,
      ),
      textInputAction: field == _Field.height
          ? TextInputAction.done
          : TextInputAction.next,
      decoration: InputDecoration(
        labelText: field.label,
        suffixText: 'mm',
        border: const OutlineInputBorder(),
        errorText: error,
        errorMaxLines: 2,
      ),
      onChanged: (_) => _onEdited(field, shape),
    );
  }
}
