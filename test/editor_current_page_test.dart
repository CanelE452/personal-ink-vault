import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/pages/editor/editor.dart';

void main() {
  group('getPageIndexFromScrollPosition', () {
    final pages = <EditorPage>[
      EditorPage(size: const Size(100, 100)),
      EditorPage(size: const Size(100, 200)),
      EditorPage(size: const Size(100, 300)),
    ];

    test('returns 0 when scroll position is 0', () {
      expect(
        EditorState.getPageIndexFromScrollPosition(
          scrollY: 0,
          screenWidth: 100,
          pages: pages,
        ),
        0,
      );
    });

    test('returns 0 when scroll position is negative', () {
      expect(
        EditorState.getPageIndexFromScrollPosition(
          scrollY: -100000,
          screenWidth: 100,
          pages: pages,
        ),
        0,
      );
    });

    test('returns 0 when scroll position is within first page', () {
      expect(
        EditorState.getPageIndexFromScrollPosition(
          scrollY: 82, // center of the first page after the canvas inset
          screenWidth: 100,
          pages: pages,
        ),
        0,
      );
    });

    test('returns 1 when scroll position is within second page', () {
      expect(
        EditorState.getPageIndexFromScrollPosition(
          scrollY: 248, // center of the second page
          screenWidth: 100,
          pages: pages,
        ),
        1,
      );
    });

    test('returns 2 when scroll position is within third page', () {
      expect(
        EditorState.getPageIndexFromScrollPosition(
          scrollY: 514, // center of the third page
          screenWidth: 100,
          pages: pages,
        ),
        2,
      );
    });

    test('keeps the previous page in the gap and advances at the next top', () {
      expect(
        EditorState.getPageIndexFromScrollPosition(
          scrollY: 363,
          screenWidth: 100,
          pages: pages,
        ),
        1,
      );
      expect(
        EditorState.getPageIndexFromScrollPosition(
          scrollY: 364,
          screenWidth: 100,
          pages: pages,
        ),
        2,
      );
    });

    test('fits page heights to the canvas width before locating a page', () {
      expect(
        EditorState.getPageIndexFromScrollPosition(
          scrollY: 214,
          screenWidth: 50,
          pages: pages,
        ),
        2,
      );
    });

    test(
      'returns last page index when scroll position is beyond last page',
      () {
        expect(
          EditorState.getPageIndexFromScrollPosition(
            scrollY: 100000,
            screenWidth: 100,
            pages: pages,
          ),
          2,
        );
      },
    );
  });
}
