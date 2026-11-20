import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';
import 'package:officerpath_ai/services/pdf_text_extractor.dart';

/// Worker 4 — Requirement B (every character): the parser/extractor
/// must handle Urdu script (RTL, Nastaliq ligatures), Arabic,
/// English, digits, math symbols (× ÷ √ ±), special characters,
/// punctuation, dashes (– —), ticks (✓/✔), bullets (•). Ligatures
/// are normalised (oﬃcially → officially), a question is never
/// dropped because of an unfamiliar character, and Urdu script is
/// preserved exactly — no garbling, no forced transliteration.
///
/// Normalisation choke points (verified in code):
/// * PDF text layer → [_clean] → ligatures normalised
///   (lib/services/pdf_text_extractor.dart).
/// * TXT / paste / OCR / DOCX-import → [parseTextInBackground]
///   normalises ligatures before parsing (same file).
/// * Direct [parseMcqs] calls bypass normalisation — see the gap in
///   docs/universal-formats.md; the ligature tests below therefore
///   go through [parseTextInBackground], the real import path.
void main() {
  ParseResult parse(String text) => parseMcqs(
        text,
        sourceId: 'chars',
        sourceLabel: 'Character handling',
      );

  Map<String, dynamic> parseViaImport(String text) =>
      parseTextInBackground({
        'text': text,
        'sourceId': 'chars',
        'sourceLabel': 'Character handling',
      });

  group('ligatures — normalised, never a parse failure', () {
    test('paste path: oﬃcially / Aﬀairs become officially / Affairs',
        () {
      const text = '''
Q1. Who handles oﬃcially the Aﬀairs of the state?
A) President
B) Prime Minister
C) Chief Justice
D) Speaker
Answer: B
''';
      final maps = parseViaImport(text);
      expect(maps['parsed'], 1);
      final q =
          (maps['questions'] as List).first as Map<String, dynamic>;
      expect(q['text'], contains('officially'));
      expect(q['text'], contains('Affairs'));
      expect(q['text'].contains('ﬃ'), isFalse);
    });

    test('paste path: all FB00–FB06 ligatures normalise', () {
      // ﬀ ﬁ ﬂ ﬃ ﬄ ﬅ ﬆ in one question + one option.
      // (ﬁ = "fi", so "ﬁnal" normalises to "final"; ﬃ = "ffi".)
      const text = 'Q1. The oﬀer was eﬀective, with ﬂags and aﬃnity?\n'
          'A) ﬁnal\nB) baﬄe\nC) ﬁsh\nD) ſtream\nAnswer: A\n';
      final maps = parseViaImport(text);
      expect(maps['parsed'], 1);
      final q =
          (maps['questions'] as List).first as Map<String, dynamic>;
      expect(q['text'], contains('offer'));
      expect(q['text'], contains('effective'));
      expect(q['option_a'], 'final');
      expect(q['option_b'], 'baffle');
      expect(q['option_c'], 'fish');
      for (var i = 0; i <= 6; i++) {
        expect(
          q['text'].contains(String.fromCharCode(0xFB00 + i)),
          isFalse,
        );
      }
    });

    test('PDF text layer: Pace book has no ligatures after extraction',
        () async {
      final bytes = await File(
        '/home/hatch/workspace/user/files/Current_Affairs_Jan-Nov_2026_by_Pace_GK_Academy.pdf',
      ).readAsBytes();
      final text = extractTextFromPdfBytes(bytes);
      expect(text, contains('officially'));
      expect(text, contains('Affairs'));
      for (var i = 0; i <= 6; i++) {
        expect(text.contains(String.fromCharCode(0xFB00 + i)), isFalse);
      }
    });
  });

  group('Urdu + Arabic — preserved exactly, never transliterated', () {
    test('Urdu block: question, options and answer byte-for-byte', () {
      const q = 'پاکستان کا دارالحکومت کون سا ہے؟';
      const text = 'Q1. پاکستان کا دارالحکومت کون سا ہے؟\n'
          'A) لاہور\nB) کراچی\nC) اسلام آباد\nD) کوئٹہ\nAnswer: C\n';
      final r = parse(text);
      expect(r.parsed, 1);
      expect(r.questions.first.text, q);
      expect(r.questions.first.options[2], 'اسلام آباد');
      expect(r.questions.first.correctIndex, 2);
    });

    test('GAP (Req B): Urdu flashcard with Arabic ؟ must parse — '
        'currently 0', () {
      // KNOWN GAP for integration (lib/services/mcq_parser.dart,
      // _scanFlashcards / _trailingAnswerSplit): only ASCII "?" is
      // recognised as the question terminator. The same 5 items with
      // ASCII "?" parse 5/5 (see the numbered test below); with "؟"
      // (U+061F, the question mark Urdu actually uses) they parse 0.
      const text = '1. رسول اللہ ﷺ کے اونٹنی کا نام کیا تھا؟ قصواء\n'
          '2. رسول اللہ ﷺ کے خچر کا نام کیا تھا؟ دُلدُل\n'
          '3. رسول اللہ ﷺ نے آخری حج کب ادا کیا؟ 10 ہجری\n'
          '4. رسول اللہ ﷺ کی وفات کب ہوئی؟ 12 ربیع الاول 11 ہجری\n'
          '5. رسول اللہ ﷺ کے جھنڈے کا نام کیا تھا؟ عُقاب\n';
      final r = parse(text);
      expect(r.parsed, 5);
      expect(r.questions[0].text, contains('ﷺ'));
      expect(r.questions[0].text, contains('؟'));
      expect(r.questions[0].options, contains('قصواء'));
      // No Roman transliteration anywhere in the output.
      expect(r.questions.expand((q) => q.options).join(' '),
          isNot(contains('Qaswa')));
    });

    test('Urdu flashcard with ASCII ? parses, ﷺ preserved', () {
      const text = '1. رسول اللہ ﷺ کے اونٹنی کا نام کیا تھا? قصواء\n'
          '2. رسول اللہ ﷺ کے خچر کا نام کیا تھا? دُلدُل\n'
          '3. رسول اللہ ﷺ نے آخری حج کب ادا کیا? 10 ہجری\n'
          '4. رسول اللہ ﷺ کی وفات کب ہوئی? 12 ربیع الاول 11 ہجری\n'
          '5. رسول اللہ ﷺ کے جھنڈے کا نام کیا تھا? عُقاب\n';
      final r = parse(text);
      expect(r.parsed, 5);
      expect(r.questions[0].text, contains('ﷺ'));
      expect(r.questions[0].options, contains('قصواء'));
    });

    test('Arabic text parses and is preserved', () {
      const text = 'Q1. ما هي عاصمة المملكة العربية السعودية؟\n'
          'A) جدة\nB) الرياض\nC) مكة\nD) المدينة\nAnswer: B\n';
      final r = parse(text);
      expect(r.parsed, 1);
      expect(r.questions.first.text,
          'ما هي عاصمة المملكة العربية السعودية؟');
      expect(r.questions.first.options[1], 'الرياض');
    });

    test('Urdu digits and mixed Urdu/English in one question', () {
      const text = 'Q1. ۱۹۴۷ میں پاکستان کب بنا؟\n'
          'A) ۱۴ اگست ۱۹۴۷\nB) ۲۳ مارچ ۱۹۴۰\nC) ۱۴ اگست ۱۹۴۸\nD) ۲۵ دسمبر ۱۹۴۷\nAnswer: A\n';
      final r = parse(text);
      expect(r.parsed, 1);
      expect(r.questions.first.options[0], '۱۴ اگست ۱۹۴۷');
    });
  });

  group('math, dashes, ticks, bullets — parse, never drop', () {
    test('math symbols × ÷ √ ± preserved in question and options', () {
      const text = 'Q1. What is 12 × 8 ÷ 4?\n'
          'A) 24\nB) 20\nC) 32\nD) 16\nAnswer: A\n'
          'Q2. What is √144 ± 2?\n'
          'A) 10\nB) 12\nC) 14\nD) 16\nAnswer: C\n';
      final r = parse(text);
      expect(r.parsed, 2);
      expect(r.questions[0].text, contains('×'));
      expect(r.questions[0].text, contains('÷'));
      expect(r.questions[1].text, contains('√'));
      expect(r.questions[1].text, contains('±'));
      expect(r.questions[0].correctIndex, 0);
      expect(r.questions[1].correctIndex, 2);
    });

    test('en dash / em dash flashcard separators both work', () {
      // Flashcards need their number prefix ("1. ") — unnumbered
      // dash lines parse 0 (documented gap, see docs).
      const text = '1. Who won the 2026 Nobel Peace Prize? – Navanethem Pillay\n'
          '2. What is the largest ocean? — Pacific\n'
          '3. What is the capital of Canada? – Ottawa\n'
          '4. Which river is longest in Asia? — Yangtze\n'
          '5. Who wrote the national anthem? – Hafeez Jalandhari\n';
      final r = parse(text);
      expect(r.parsed, 5);
      expect(r.questions[0].options, contains('Navanethem Pillay'));
      expect(r.questions[1].options, contains('Pacific'));
    });

    test('tick ✔ (heavy) also marks the answer', () {
      const text = 'Q1. Which is the largest ocean?\n'
          'A) Atlantic\nB) Pacific ✔\nC) Indian\nD) Arctic\n';
      final r = parse(text);
      expect(r.parsed, 1);
      expect(r.questions.first.correctIndex, 1);
      expect(r.questions.first.answerSource, 'tick');
    });

    test('bullet lines before a valid MCQ do not break the parse', () {
      const text = '• Read the instructions carefully.\n'
          '• Each question has four options.\n'
          'Q1. What is the capital of Pakistan?\n'
          'A) Lahore\nB) Karachi\nC) Islamabad\nD) Quetta\nAnswer: C\n';
      final r = parse(text);
      expect(r.parsed, 1);
      expect(r.questions.first.correctIndex, 2);
    });

    test('GAP: trailing bullet line after the Answer must not drop '
        'the MCQ — currently 0', () {
      // KNOWN GAP for integration (lib/services/mcq_parser.dart,
      // block loop): a "• ..." line AFTER the "Answer:" line makes
      // the question land in answerPending instead of parsing.
      const text = 'Q1. What is the capital of Pakistan?\n'
          'A) Lahore\nB) Karachi\nC) Islamabad\nD) Quetta\nAnswer: C\n'
          '• Good luck!\n';
      final r = parse(text);
      expect(r.parsed, 1);
      expect(r.questions.first.correctIndex, 2);
    });

    test('special punctuation (quotes, %, \$, brackets) never crashes',
        () {
      const text = 'Q1. The "GDP growth" was 3.5% in 2025-26 (est.) — true?\n'
          'A) Yes, 3.5%\nB) No, 2.5%\nC) No, 4.5%\nD) None of these\nAnswer: A\n'
          'Q2. Which costs \$100 [approx.]?\n'
          'A) Book\nB) Pen\nC) Bag\nD) Phone\nAnswer: B\n';
      final r = parse(text);
      expect(r.parsed, 2);
      expect(r.questions[0].text, contains('3.5%'));
      expect(r.questions[1].text, contains('\$100'));
    });

    test('one hostile mixed line: Urdu + math + dash + tick, no crash',
        () {
      const text = 'Q1. ۱۲ × ۸ = ۹۶ — کیا یہ درست ہے؟\n'
          'A) جی ہاں ✓\nB) نہیں\nC) شاید\nD) معلوم نہیں\n';
      final r = parse(text);
      expect(r.parsed, 1);
      expect(r.questions.first.text, contains('۱۲ × ۸ = ۹۶'));
      expect(r.questions.first.correctIndex, 0);
      expect(r.questions.first.answerSource, 'tick');
    });
  });
}
