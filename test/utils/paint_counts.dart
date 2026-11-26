import 'package:flutter/rendering.dart' show Layer, RenderRepaintBoundary;
import 'package:flutter_test/flutter_test.dart';

/// What says whether [page] was painted (flutter_test's `paints` is the
/// canvas matcher, so this has its own name): its two paint counts and its
/// own layers. A boundary painted on its own counts as asymmetric, and so does
/// one put back as it was when a boundary above it paints
/// (`debugRegisterRepaintBoundaryPaint`, flushPaint's
/// `repaintCompositedChild`), so the asymmetric count cannot tell the two
/// apart. Painting the page again makes new layers under it; being put
/// back keeps them.
({int together, int alone, List<Layer> layers}) paintCounts(
  RenderRepaintBoundary page,
) => (
  together: page.debugSymmetricPaintCount,
  alone: page.debugAsymmetricPaintCount,
  layers: [
    for (Layer? l = page.debugLayer!.firstChild; l != null; l = l.nextSibling)
      l,
  ],
);

/// [page] was not painted since [before]: not with its parent, and not
/// alone (its layers are the same ones). The asymmetric count may rise
/// while its layer is put back.
void expectNotPainted(
  RenderRepaintBoundary page,
  ({int together, int alone, List<Layer> layers}) before,
) {
  final now = paintCounts(page);
  expect(now.together, before.together);
  expect(now.layers, hasLength(before.layers.length));
  for (var i = 0; i < now.layers.length; i++) {
    expect(now.layers[i], same(before.layers[i]), reason: 'layer $i');
  }
}
