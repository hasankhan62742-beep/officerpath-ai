import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/book_structure.dart';

/// Question stems must never become part titles (MASTER BUG FIX
/// DIRECTIVE, 20 Nov 2026 + the owner's Gemini-ticked phone
/// screenshots, 15:16 PKT): on the phone the parts list showed
/// "difficult I thjnk he speaks English. (A whether",
/// "S1. Choose the best English translation of the" and
/// "to English of word: ei Harmless" — all question stems, because
/// OCR misreads ("S1." for "51.") defeated the question-start check
/// and the bare word "English" alone made the line a "strong
/// heading". The same stems appear in Tesseract's read of the same
/// pages ("\$1. …", "§22 …", "(8) …").
void main() {
  test('phone stems never become part titles', () {
    final pages = [
      const PageText(
        1,
        'Papers of 2021 521\n'
        'MODEL PAPER 66\n'
        'TEHSILDAR / CONSOLIDATION OFFICER (BS-16) - 2021\n'
        'English Morning\n'
        'English Grammar\n'
        '1. The Plague ______ in London that summer.\n'
        '(A) Broke out\n(B) Broke up\n(C) Broke down\n(D) None of these\n'
        '43. Choose the correct form of VERB.\n'
        'difficult I thjnk he speaks English. (A whether\n'
        '44. Choose the correct article.\n'
        '(A) a\n(B) an\n(C) the\n(D) none\n',
      ),
      const PageText(
        5,
        'S1. Choose the best English translation of the\n'
        'following sentence into Urdu.\n'
        '(A) Woh ja raha hai\n(B) Woh gaya tha\n(C) Woh jaye ga\n(D) None of these\n'
        '52. Choose the correct preposition.\n'
        '(A) on\n(B) in\n(C) at\n(D) by\n',
      ),
      const PageText(
        6,
        'to English of word: ei Harmless\n'
        '53. Select the correct sentence.\n'
        '(A) He called me a fool.\n(B) He called me as a fool.\n'
        '(C) He did called me as a fool.\n(D) None of these\n',
      ),
    ];
    final structure = detectBookStructure(pages);
    final titles = structure.parts.map((p) => p.title).toList();
    for (final bad in ['thjnk', 'S1.', 'Harmless', 'difficult']) {
      expect(
        titles.any((t) => t.contains(bad)),
        isFalse,
        reason: 'stem fragment "$bad" became a part title: $titles',
      );
    }
    // The real headings survive.
    expect(titles.any((t) => t.contains('English Grammar')), isTrue);
  });

  test('Tesseract stems never become part titles', () {
    // Tesseract's read of the same pages: "\$1." for "51.",
    // "(8)" for "(B)", "§22" for "522".
    final pages = [
      const PageText(
        1,
        'Papers of 2021 __524\n'
        'MODEL PAPER 66\n'
        'English Grammar (8) Unusual/openly\n'
        '1. The Plague ______ in London.\n'
        '(A) Broke out\n(B) Broke up\n(C) Broke down\n(D) None of these\n',
      ),
      const PageText(
        2,
        '§22 Advanced PPSC MCQs Model Papers (Volume 2)\n'
        '18. Choose the correct article.\n'
        '(A) a\n(B) an\n(C) the\n(D) none\n',
      ),
      const PageText(
        5,
        '\$1. “2 Choose the best English t i ye\n'
        '52. Choose the correct preposition.\n'
        '(A) on\n(B) in\n(C) at\n(D) by\n',
      ),
    ];
    final structure = detectBookStructure(pages);
    final titles = structure.parts.map((p) => p.title).toList();
    for (final bad in ['Unusual', '\$1.', '§22', '(8)']) {
      expect(
        titles.any((t) => t.contains(bad)),
        isFalse,
        reason: 'Tesseract stem "$bad" became a part title: $titles',
      );
    }
    // The real paper heading survives the noise.
    expect(titles.any((t) => t.contains('MODEL PAPER 66')), isTrue);
  });
}
