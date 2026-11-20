import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundled sample paper parses to 10 MCQs, all with 4 options', () async {
    final text = await rootBundle.loadString(
      'assets/sample_books/ppsc-sample-paper.txt',
    );
    final result = parseMcqs(
      text,
      sourceId: 'sample',
      sourceLabel: 'Sample Paper',
    );
    expect(result.parsed, 10);
    expect(result.skipped, 0);
    for (final q in result.questions) {
      expect(q.options.length, 4);
      expect(q.correctIndex, inInclusiveRange(0, 3));
    }
  });
}
