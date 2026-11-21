/// Page-tilt estimation + correction for ML Kit OCR geometry
/// (21 Nov 2026, tilted table photo — IBES photo: median tilt
/// 1.45 deg, max 2.6 deg, ~37 px drift vs ~45 px row pitch).
///
/// Pure Dart: no Flutter, no ML Kit imports. The element record is
/// the same shape ML Kit word boxes are converted to in
/// pdf_import_service.dart ([OcrElement]), so the deskewed list
/// feeds [reconstructTableText] unchanged.
///
/// Model: a tilted page shears y linearly with x
/// (y = yTrue + x * tan(θ)). The estimator is the least-squares
/// slope of y on x across all elements — a full text grid makes the
/// per-row offsets average out, so the slope is the tilt. A straight
/// page estimates 0 and is left untouched; too few words, or a
/// single column (no horizontal spread to measure a slope from),
/// also return 0 — never guessed.
library;

import 'dart:math' as math;

/// One OCR word/line box: its text and its bounding box. The same
/// record shape ML Kit elements are converted to in
/// pdf_import_service.dart, and the shape the deskew tests use.
typedef OcrElement = ({
  String text,
  double x,
  double y,
  double width,
  double height,
});

/// Minimum elements for a tilt estimate: fewer words cannot pin a
/// slope down (a 5-word fragment is one row, not a page).
const _minElementsForSkew = 6;

/// Tilts below this are indistinguishable from straight (|θ| is
/// snapped to exactly 0, so a straight page is never "corrected").
const _straightEpsilonDegrees = 0.05;

/// Estimates the page tilt in degrees from the elements' geometry.
/// Positive when y grows with x (the page's right side sits lower
/// than its left). Returns exactly 0 when there is nothing to
/// estimate from: fewer than [_minElementsForSkew] elements,
/// (near-)zero horizontal spread, or a tilt within
/// [_straightEpsilonDegrees] of straight.
double estimateSkewDegrees(List<OcrElement> elements) {
  if (elements.length < _minElementsForSkew) return 0;
  var n = 0;
  var sx = 0.0;
  var sy = 0.0;
  for (final e in elements) {
    n++;
    sx += e.x;
    sy += e.y;
  }
  final mx = sx / n;
  final my = sy / n;
  var sxx = 0.0;
  var sxy = 0.0;
  for (final e in elements) {
    final dx = e.x - mx;
    final dy = e.y - my;
    sxx += dx * dx;
    sxy += dx * dy;
  }
  // No horizontal spread (a single column): no slope to measure.
  if (sxx <= 0) return 0;
  final degrees = math.atan(sxy / sxx) * 180 / math.pi;
  if (degrees.abs() < _straightEpsilonDegrees) return 0;
  return degrees;
}

/// Returns the elements with the estimated tilt removed: each
/// element's y is shifted by -(x - pivot) * tan(θ), where pivot is
/// the leftmost element's x (the left edge stays put; the
/// correction only flattens the rows). x, width, height and text
/// are untouched. A 0° tilt returns the elements unchanged (a copy
/// of the list, same values).
List<OcrElement> deskewElements(
  List<OcrElement> elements,
  double degrees,
) {
  if (elements.isEmpty || degrees == 0) return List.of(elements);
  final t = math.tan(degrees * math.pi / 180);
  final pivot = elements.map((e) => e.x).reduce(math.min);
  return [
    for (final e in elements)
      (
        text: e.text,
        x: e.x,
        y: e.y - (e.x - pivot) * t,
        width: e.width,
        height: e.height,
      ),
  ];
}
