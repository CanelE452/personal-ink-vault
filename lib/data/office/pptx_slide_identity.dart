import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:saber/data/native/ink_vault_native.dart';

final class PptxSlideIdentityMatch {
  new({required List<int?> previousToCurrent, required this.currentSlideCount})
    : previousToCurrent = List.unmodifiable(previousToCurrent);

  final List<int?> previousToCurrent;
  final int currentSlideCount;
  int get previousSlideCount => previousToCurrent.length;
}

class PptxSlideIdentityEngine {
  const new({this._libraryPath});

  final String? _libraryPath;
  static const _maxSlides = 256;
  static final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');
  static const _invalidReply = InkVaultNativeException(
    'invalid_response',
    'PPTX 원본 판본과 슬라이드 연결을 확인하지 못했습니다.',
  );

  Future<PptxSlideIdentityMatch> match({
    required String previousPath,
    required String previousSha256,
    required String currentPath,
    required String currentSha256,
  }) async {
    _requireSource(previousPath, previousSha256);
    _requireSource(currentPath, currentSha256);
    final library = _libraryPath;
    final result = await Isolate.run(
      () => InkVaultNative.open(libraryPath: library).invoke({
        'op': 'pptx_slide_identity_match',
        'previousPath': previousPath,
        'previousSha256': previousSha256,
        'currentPath': currentPath,
        'currentSha256': currentSha256,
      }),
    );
    final indices = result['previousToCurrent'];
    final currentCount = result['currentSlideCount'];
    if (result.length != 4 ||
        result['previousSha256'] != previousSha256 ||
        result['currentSha256'] != currentSha256 ||
        currentCount is! int ||
        currentCount < 1 ||
        currentCount > _maxSlides ||
        indices is! List ||
        indices.isEmpty ||
        indices.length > _maxSlides) {
      throw _invalidReply;
    }
    final mapped = <int?>[];
    final seen = <int>{};
    for (final index in indices) {
      if (index != null &&
          (index is! int ||
              index < 0 ||
              index >= currentCount ||
              !seen.add(index))) {
        throw _invalidReply;
      }
      mapped.add(index as int?);
    }
    return PptxSlideIdentityMatch(
      previousToCurrent: mapped,
      currentSlideCount: currentCount,
    );
  }

  static void _requireSource(String path, String sha256) {
    if (!p.isAbsolute(path) ||
        p.normalize(path) != path ||
        p.extension(path).toLowerCase() != '.pptx' ||
        !_sha256Pattern.hasMatch(sha256)) {
      throw ArgumentError(
        'Expected a normalized absolute PPTX path and SHA-256',
      );
    }
  }
}
