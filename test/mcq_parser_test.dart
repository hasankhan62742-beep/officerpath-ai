import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/models/exam.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';

const _sample = '''
Q1. What is the capital of Pakistan?
A) Lahore
B) Karachi
C) Islamabad
D) Quetta
Answer: C
Explanation: Islamabad became the capital in 1967.
Subject: Pakistan Studies

2. What is 7 x 8?
A. 54
B. 56
C. 48
D. 64
Correct: B
''';

void main() {
  test('parses questions, answers, explanations and subjects', () {
    final result = parseMcqs(
      _sample,
      sourceId: 's1',
      sourceLabel: 'Sample',
    );
    expect(result.parsed, 2);
    expect(result.skipped, 0);
    expect(result.questions[0].text, contains('capital of Pakistan'));
    expect(result.questions[0].correctIndex, 2);
    expect(result.questions[0].correctLetter, 'C');
    expect(result.questions[0].subject, Subject.pakStudies);
    expect(result.questions[0].explanation, contains('1967'));
    // "2." numbering + "A." options + "Correct: B" variant.
    expect(result.questions[1].correctIndex, 1);
    expect(result.questions[1].options[1], '56');
  });

  test('skips blocks without 4 options or an answer line', () {
    const bad = '''
Q1. Incomplete question?
A) Only one option
Answer: A

Q2. No answer here?
A) One
B) Two
C) Three
D) Four
''';
    final result = parseMcqs(
      bad,
      sourceId: 's1',
      sourceLabel: 'Sample',
    );
    expect(result.parsed, 0);
    expect(result.skipped, 2);
    expect(result.errors.length, 2);
  });

  test('answer given as a number (1-4) works', () {
    const numbered = '''
Q1. What is 2 + 2?
A) 3
B) 4
C) 5
D) 6
Answer: 2
''';
    final result = parseMcqs(
      numbered,
      sourceId: 's1',
      sourceLabel: 'Sample',
    );
    expect(result.parsed, 1);
    expect(result.questions.first.correctIndex, 1);
  });
}
