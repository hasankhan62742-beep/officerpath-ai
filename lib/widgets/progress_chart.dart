import 'package:flutter/material.dart';

/// Simple bar chart (no chart dependency) — last attempts' percentages.
///
/// v1.2: bars animate in (grow from zero, ~700 ms, ease-out) unless the
/// system asks for reduced motion ([MediaQuery.disableAnimations]),
/// in which case the final chart is drawn immediately.
class ProgressChart extends StatefulWidget {
  const ProgressChart({
    super.key,
    required this.percents,
    this.passPercent = 40,
  });

  /// Percentages in chronological order (oldest first).
  final List<double> percents;

  /// Pass line for the chart (AUDIT F15: was hardcoded at 40%, but CSS
  /// MPT passes at 33% — History passes its most recent exam's value).
  final double passPercent;

  @override
  State<ProgressChart> createState() => _ProgressChartState();
}

class _ProgressChartState extends State<ProgressChart>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _progress;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _progress = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reduced motion: no animation, final chart at once. Otherwise
    // animate in — but only from the first build, never on rebuilds
    // (a rebuild mid-animation would restart the bars).
    if (MediaQuery.of(context).disableAnimations) {
      _controller.value = 1;
    } else if (_controller.status == AnimationStatus.dismissed) {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.percents.isEmpty) {
      return const SizedBox(
        height: 120,
        child: Center(child: Text('No attempts yet — take your first test!')),
      );
    }
    return SizedBox(
      height: 140,
      child: AnimatedBuilder(
        animation: _progress,
        builder: (context, _) => CustomPaint(
          painter: _BarChartPainter(
            widget.percents,
            widget.passPercent,
            Theme.of(context).colorScheme.onSurface,
            _progress.value,
          ),
          child: Container(),
        ),
      ),
    );
  }
}

class _BarChartPainter extends CustomPainter {
  _BarChartPainter(
    this.percents,
    this.passPercent,
    this.textColor, [
    this.progress = 1,
  ]);

  final List<double> percents;
  final double passPercent;
  final Color textColor;

  /// 0 → 1: bars grow from the baseline as the chart animates in.
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    const barGap = 6.0;
    final barWidth =
        (size.width - barGap * (percents.length + 1)) / percents.length;
    // v1.2: brand gold for pass bars (readable on light AND dark cards;
    // the old dark green was muddy on the dark card), brighter red for fail.
    final passPaint = Paint()..color = const Color(0xFFC9A227);
    final failPaint = Paint()..color = const Color(0xFFD64541);
    final textPainter = TextPainter(textDirection: TextDirection.ltr);

    for (var i = 0; i < percents.length; i++) {
      final pct = percents[i].clamp(0, 100);
      final barHeight = (size.height - 24) * (pct / 100) * progress;
      final x = barGap + i * (barWidth + barGap);
      final y = size.height - 24 - barHeight;
      final rect = Rect.fromLTWH(x, y, barWidth, barHeight);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(4)),
        pct >= passPercent ? passPaint : failPaint,
      );
      // AUDIT F15: a 100% bar tops out at y = 0 and its label (y − 14)
      // was painted outside the canvas — a perfect score showed no
      // label. Paint the label INSIDE the bar when there is no room.
      final labelInside = y < 16;
      textPainter.text = TextSpan(
        text: pct.toStringAsFixed(0),
        style: TextStyle(
          fontSize: 10,
          // v1.2: white on the gold pass bar is unreadable — navy
          // text on gold, white on red.
          color: labelInside
              ? (pct >= passPercent
                    ? const Color(0xFF0B1F3A)
                    : Colors.white)
              : textColor,
        ),
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(
          x + barWidth / 2 - textPainter.width / 2,
          labelInside ? y + 4 : y - 14,
        ),
      );
    }
    // Pass line (per-exam value, not a hardcoded 40%).
    final passY =
        size.height - 24 - (size.height - 24) * (passPercent / 100);
    final linePaint = Paint()
      ..color = textColor.withValues(alpha: 0.45)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    canvas.drawLine(
      Offset(0, passY),
      Offset(size.width, passY),
      linePaint,
    );
    textPainter.text = TextSpan(
      text: '${passPercent.toStringAsFixed(0)}% pass',
      style: TextStyle(fontSize: 10, color: textColor),
    );
    textPainter.layout();
    textPainter.paint(canvas, Offset(4, passY - 14));
  }

  @override
  bool shouldRepaint(covariant _BarChartPainter oldDelegate) =>
      oldDelegate.percents != percents ||
      oldDelegate.passPercent != passPercent ||
      oldDelegate.textColor != textColor;
}
