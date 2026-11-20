import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';

void main() {
  const src = 'test-src';
  const label = 'Test Book';

  test('standard block still works, incl. answer given as option text',
      () {
    const text = 'Q1. What is the capital of Pakistan?\n'
        'A) Lahore\nB) Karachi\nC) Islamabad\nD) Quetta\n'
        'Correct: Islamabad\n';
    final r = parseMcqs(text, sourceId: src, sourceLabel: label);
    expect(r.parsed, 1);
    expect(r.questions.first.correctIndex, 2);
    expect(r.formatCounts['block'], 1);
  });

  test('one-liner with (a)-(d) and answer on the next line', () {
    const text =
        '1. What is the capital of Pakistan? (a) Lahore (b) Karachi (c) Islamabad (d) Quetta\n'
        'Ans: (c)\n'
        '2. Which is the largest continent? (a) Africa (b) Asia (c) Europe (d) Australia\n'
        'Answer: B\n';
    final r = parseMcqs(text, sourceId: src, sourceLabel: label);
    expect(r.parsed, 2);
    expect(r.formatCounts['one-liner'], 2);
    expect(r.questions[0].text, 'What is the capital of Pakistan?');
    expect(r.questions[0].options, [
      'Lahore',
      'Karachi',
      'Islamabad',
      'Quetta',
    ]);
    expect(r.questions[0].correctIndex, 2);
    expect(r.questions[1].correctIndex, 1);
  });

  test('one-liner with same-line answer and comma separators', () {
    const text =
        'Q1. What is 2+2? (a) 3, (b) 4, (c) 5, (d) 6 Ans: (b)\n';
    final r = parseMcqs(text, sourceId: src, sourceLabel: label);
    expect(r.parsed, 1);
    expect(r.questions.first.options, ['3', '4', '5', '6']);
    expect(r.questions.first.correctIndex, 1);
  });

  test('one-liner with numbered and roman-numeral options', () {
    const text =
        '1. Capital of France? 1) London 2) Paris 3) Rome 4) Berlin Answer: 2\n'
        '2. Capital of Italy? (i) Madrid (ii) Rome (iii) Paris (iv) Athens Correct: Rome\n';
    final r = parseMcqs(text, sourceId: src, sourceLabel: label);
    expect(r.parsed, 2);
    expect(r.questions[0].correctIndex, 1);
    expect(r.questions[1].correctIndex, 1);
    expect(r.questions[1].options, ['Madrid', 'Rome', 'Paris', 'Athens']);
  });

  test('one-liner without an answer is skipped, not guessed', () {
    const text =
        '1. What is the capital? (a) Lahore (b) Karachi (c) Islamabad (d) Quetta\n';
    final r = parseMcqs(text, sourceId: src, sourceLabel: label);
    expect(r.parsed, 0);
    expect(r.skipped, 1);
  });

  test('Q-only questions get options from the book answer pool', () {
    const text = 'Q. What is the capital of Pakistan? Ans: Islamabad\n'
        'Q. What is the capital of France? Ans: Paris\n'
        'Q. What is the capital of Italy? Ans: Rome\n'
        'Q. What is the capital of Japan? Ans: Tokyo\n';
    final r = parseMcqs(text, sourceId: src, sourceLabel: label);
    expect(r.parsed, 4);
    expect(r.formatCounts['q-only'], 4);
    expect(r.generatedOptions, 4);
    expect(r.excluded, isEmpty);
    for (final q in r.questions) {
      expect(q.options.length, 4);
      expect(q.options.toSet().length, 4,
          reason: 'options must never duplicate the answer');
      expect(['Islamabad', 'Paris', 'Rome', 'Tokyo'],
          contains(q.options[q.correctIndex]),
          reason: 'the correct option must be the question\'s own answer');
      // Every distractor is another question's answer from this book.
      for (final o in q.options) {
        expect(['Islamabad', 'Paris', 'Rome', 'Tokyo'], contains(o));
      }
    }
  });

  test('Q-only with too few distinct answers is excluded honestly', () {
    const text = 'Q. What is the capital of Pakistan? Ans: Islamabad\n'
        'Q. What is 2+2? Ans: 4\n';
    final r = parseMcqs(text, sourceId: src, sourceLabel: label);
    expect(r.parsed, 0);
    expect(r.excluded.length, 2);
    expect(r.excluded.first, contains('only 1 other'));
  });

  test('mixed book: blocks + one-liners + Q-only, counts add up', () {
    const text = 'Q1. What is the capital of Pakistan?\n'
        'A) Lahore\nB) Karachi\nC) Islamabad\nD) Quetta\nAnswer: C\n'
        '2. Largest continent? (a) Africa (b) Asia (c) Europe (d) Australia\nAns: (b)\n'
        'Q. Capital of France? Ans: Paris\n'
        'Q. Capital of Italy? Ans: Rome\n'
        'Q. Capital of Japan? Ans: Tokyo\n';
    final r = parseMcqs(text, sourceId: src, sourceLabel: label);
    expect(r.parsed, 5);
    expect(r.formatCounts['block'], 1);
    expect(r.formatCounts['one-liner'], 1);
    expect(r.formatCounts['q-only'], 3);
    expect(r.generatedOptions, 3);
    // Q-only distractors come from the whole book's answers, including
    // the standard block's correct answer (Islamabad) — but with 4
    // pool answers and 3 distractor slots the shuffle need not pick
    // Islamabad every run, so assert pool membership, not a pick.
    final qOnly = r.questions.where((q) => q.text.contains('France'));
    expect(qOnly.first.options, contains('Paris'));
    for (final o in qOnly.first.options) {
      expect(['Islamabad', 'Asia', 'Paris', 'Rome', 'Tokyo'], contains(o));
    }
  });

  test('exactly 4 options is still enforced for every format', () {
    const text =
        '1. Bad question? (a) One (b) Two (c) Three\nAns: (a)\n'
        'Q2. Good question?\nA) One\nB) Two\nC) Three\nD) Four\nAnswer: A\n';
    final r = parseMcqs(text, sourceId: src, sourceLabel: label);
    expect(r.parsed, 1);
    expect(r.questions.first.options.length, 4);
    expect(r.skipped, 1);
  });
}
