import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/answer_key.dart';
import 'package:officerpath_ai/services/extraction/format_registry.dart';
import 'package:officerpath_ai/services/extraction/layout_patterns.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';

/// Phase A modularisation: the format registry + layout-pattern
/// library. The registry is the catalogue new formats plug into;
/// the table format is the one extracted proof (its handler must
/// agree exactly with the parser's own table entry point).
void main() {
  group('format registry', () {
    test('every known format is registered, with a proof', () {
      expect(FormatRegistry.all.length, 5);
      for (final f in FormatRegistry.all) {
        expect(f.id, isNotEmpty);
        expect(f.label, isNotEmpty);
        expect(f.recognition, isNotEmpty);
        expect(f.codeLocation, isNotEmpty);
        expect(f.provingTest, isNotEmpty);
      }
      expect(
        FormatRegistry.all.map((f) => f.id),
        ['table', 'block', 'one-liner', 'q-only', 'flashcard'],
      );
    });

    test('byId finds formats, unknown id returns null (never guessed)',
        () {
      expect(FormatRegistry.byId('table'), isNotNull);
      expect(FormatRegistry.byId('flashcard')!.label, contains('Flashcard'));
      expect(FormatRegistry.byId('omr'), isNull);
    });

    test('only the table format is extracted so far (honest scope)', () {
      expect(FormatRegistry.byId('table')!.isExtracted, isTrue);
      for (final id in ['block', 'one-liner', 'q-only', 'flashcard']) {
        final f = FormatRegistry.byId(id)!;
        expect(f.isExtracted, isFalse, reason: id);
        expect(f.embeddedIn, '_parseImpl');
      }
    });

    test('table handler agrees with parseTableFormat (32-row fixture)',
        () {
      const rows = '''
Adjective and its Types
Which word is a noun in this sentence here?
Which word is a verb in this sentence here?
Which word is an adjective in this sentence here?
Apple
Banana
Cherry
Run
Jump
Swim
Happy
Sad
Bright
Quickly
Slowly
Softly
B
A
C
Noun
Verb
Adjective
''';
      final lines = rows
          .split('\n')
          .where((l) => l.trim().isNotEmpty)
          .toList();
      // The handler takes SegmentedLines — build them the way the
      // parser does (segmentText on the raw lines).
      final segmented = segmentText(lines);
      final viaHandler = FormatRegistry.table.parse(
        segmented.questionLines,
        sourceId: 'registry',
        sourceLabel: 'registry',
      );
      final direct = parseTableFormat(
        segmented.questionLines,
        sourceId: 'registry',
        sourceLabel: 'registry',
      );
      expect(viaHandler.questions.length, 3);
      expect(viaHandler.questions.length, direct.questions.length);
      for (var i = 0; i < 3; i++) {
        expect(viaHandler.questions[i].text, direct.questions[i].text);
        expect(
          viaHandler.questions[i].correctIndex,
          direct.questions[i].correctIndex,
        );
      }
    });
  });

  group('layout-pattern library', () {
    test('every pattern has an id, rule, example and status', () {
      expect(layoutPatterns.length, greaterThanOrEqualTo(15));
      final ids = <String>{};
      for (final p in layoutPatterns) {
        expect(ids.add(p.id), isTrue, reason: 'duplicate id ${p.id}');
        expect(p.name, isNotEmpty);
        expect(p.recognition, isNotEmpty);
        expect(p.example, isNotEmpty);
        expect(
          ['supported', 'partial', 'unsupported', 'unmeasured'],
          contains(p.status),
        );
        expect(p.provedBy, isNotEmpty);
      }
    });

    test('unsupported patterns are listed, not hidden', () {
      final unsupported =
          layoutPatterns.where((p) => p.status == 'unsupported');
      expect(
        unsupported.map((p) => p.id),
        containsAll(['omr', 'italic-signal', 'multi-question-row']),
      );
    });
  });
}
