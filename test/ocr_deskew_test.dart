import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/ocr_deskew.dart';

typedef _El = ({String text, double x, double y, double width, double height});

List<_El> _grid(double tiltDeg) {
  final t = math.tan(tiltDeg * math.pi / 180);
  return [
    for (var r = 0; r < 12; r++)
      for (var c = 0; c < 6; c++)
        (
          text: 'w$r$c',
          x: 20.0 + c * 200,
          y: 300.0 + r * 45 + (20.0 + c * 200 + 40) * t,
          width: 80.0,
          height: 22.0,
        ),
  ];
}

void main() {
  test('recovers a 2 degree tilt and puts each row back in one line', () {
    final els = _grid(2.0);
    final est = estimateSkewDegrees(els);
    expect((est - 2.0).abs(), lessThan(0.4));
    final flat = deskewElements(els, est);
    for (var r = 0; r < 12; r++) {
      final ys = [for (var c = 0; c < 6; c++) flat[r * 6 + c].y];
      expect(ys.reduce(math.max) - ys.reduce(math.min), lessThan(22));
    }
  });

  test('a straight page is left alone', () {
    expect(estimateSkewDegrees(_grid(0)), 0);
  });

  test('too few words: no correction', () {
    expect(estimateSkewDegrees(_grid(2.0).take(5).toList()), 0);
  });
}
