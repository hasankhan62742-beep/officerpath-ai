import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/models/exam.dart';
import 'package:officerpath_ai/models/question.dart';
import 'package:officerpath_ai/screens/book_selection_screen.dart';
import 'package:officerpath_ai/services/book_selection.dart';
import 'package:officerpath_ai/services/book_structure.dart';

/// v1.2 selection UI: parts checklist + page-range picker filter the
/// test pool, and the MPT title maps to the CSS MPT pattern.
void main() {
  List<Question> bank() => [
    Question(
      text: 'GK Q1',
      options: const ['A', 'B', 'C', 'D'],
      correctIndex: 0,
      subject: Subject.gk,
      sourceId: 'b1',
      sourceLabel: 'Book',
      page: 1,
      part: 'General Knowledge',
    ),
    Question(
      text: 'GK Q2',
      options: const ['A', 'B', 'C', 'D'],
      correctIndex: 0,
      subject: Subject.gk,
      sourceId: 'b1',
      sourceLabel: 'Book',
      page: 2,
      part: 'General Knowledge',
    ),
    Question(
      text: 'English Q1',
      options: const ['A', 'B', 'C', 'D'],
      correctIndex: 0,
      subject: Subject.english,
      sourceId: 'b1',
      sourceLabel: 'Book',
      page: 5,
      part: 'English',
    ),
    Question(
      text: 'Maths Q1',
      options: const ['A', 'B', 'C', 'D'],
      correctIndex: 0,
      subject: Subject.gk,
      sourceId: 'b1',
      sourceLabel: 'Book',
      page: 9,
      part: 'Mathematics',
    ),
  ];

  group('BookSelection.apply', () {
    test('whole book passes everything', () {
      expect(const BookSelection().apply(bank()).length, 4);
      expect(const BookSelection().isWholeBook, isTrue);
    });

    test('part filter keeps only that part', () {
      final sel = const BookSelection(partTitles: {'English'});
      final out = sel.apply(bank());
      expect(out.length, 1);
      expect(out.first.text, 'English Q1');
    });

    test('page range keeps only pages in range', () {
      final sel = const BookSelection(fromPage: 1, toPage: 2).normalised(10);
      final out = sel.apply(bank());
      expect(out.map((q) => q.text), ['GK Q1', 'GK Q2']);
    });

    test('part + range combine (AND)', () {
      final sel = const BookSelection(
        partTitles: {'General Knowledge'},
        fromPage: 2,
        toPage: 9,
      );
      final out = sel.apply(bank());
      expect(out.map((q) => q.text), ['GK Q2']);
    });

    test('normalised() swaps an inverted range and clamps', () {
      final sel = const BookSelection(fromPage: 9, toPage: 2).normalised(5);
      expect(sel.fromPage, 2);
      expect(sel.toPage, 5);
    });

    test('describe() is human-readable', () {
      expect(const BookSelection().describe(), 'Poori book');
      expect(
        const BookSelection(partTitles: {'English'}).describe(),
        'English',
      );
      expect(
        const BookSelection(fromPage: 3, toPage: 7).describe(),
        'pages 3–7',
      );
    });
  });

  group('BookSelectionScreen widget', () {
    final parts = [
      const BookPart(
        title: 'General Knowledge',
        startPage: 1,
        endPage: 2,
        questionCount: 2,
      ),
      const BookPart(
        title: 'English',
        startPage: 5,
        endPage: 5,
        questionCount: 1,
      ),
    ];

    testWidgets('shows parts with counts + range picker + Poori book',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: BookSelectionScreen(parts: parts, totalPages: 10),
        ),
      );
      expect(find.text('General Knowledge'), findsOneWidget);
      expect(find.text('Pages 1–2 • 2 MCQs'), findsOneWidget);
      expect(find.text('English'), findsOneWidget);
      expect(find.text('Poori book — 3 MCQs'), findsOneWidget);
      expect(find.text('Poori book'), findsWidgets);
      expect(find.text('Ya page range chunein'), findsOneWidget);
      expect(find.text('Save selection'), findsOneWidget);
    });

    testWidgets('ticking a part updates the selected count', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: BookSelectionScreen(parts: parts, totalPages: 10),
        ),
      );
      await tester.tap(find.text('English'));
      await tester.pump();
      expect(find.text('Selected: 1 MCQs'), findsOneWidget);
    });

    testWidgets('no parts → honest note + range picker only', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: BookSelectionScreen(parts: [], totalPages: 10),
        ),
      );
      expect(
        find.text('Is book mein headings nahi mileen'),
        findsOneWidget,
      );
      expect(find.text('Ya page range chunein'), findsOneWidget);
    });
  });

  group('MPT fit', () {
    test('MPT titles map to CSS MPT (200/200)', () {
      expect(ExamPattern.suggestForTitle('MPT 2027 Solved')?.id, 'css_mpt');
      expect(
        ExamPattern.suggestForTitle('MPT 2027 Solved')?.defaultQuestions,
        200,
      );
      expect(
        ExamPattern.suggestForTitle('MPT 2027 Solved')?.defaultMinutes,
        200,
      );
    });

    test('ordinary titles suggest nothing (user keeps their exam)', () {
      expect(ExamPattern.suggestForTitle('PPSC Past Papers'), isNull);
      expect(ExamPattern.suggestForTitle('My GK Book'), isNull);
    });
  });
}
