// Running headers/footers must never become part titles
// (PPSC66_BASELINE_2026-11-20.md §5.5). On the baseline parser the
// pending rows carried part labels taken from running headers:
// "522", "524", "524 Advanced FPJC MCQs Model Papers (Volume 2)".
// The OCR text of the real PDF opens pages with:
//   p1: "Papers of 2021 521"   p4: "524 Advanced FPJC MCQs Model
//   Papers (Volume 2)"        p7: "Papers of 2021 527"
// None of those lines is a section. The old code only recognised
// "Papers of 2026" / "Year 2026" — the year was hardcoded.
import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/book_structure.dart';

void main() {
  test('running headers never become part titles', () {
    final pages = [
      const PageText(
        1,
        'Papers of 2021 521\n'
        'MODEL PAPER 66\n'
        'English Grammar\n'
        '1. The Plague ______ in London.\n'
        '(A) Broke out\n'
        '(B) Broke up\n'
        '(C) Broke down\n'
        '(D) Broke off\n'
        '2. Are they blaming us for nothing?\n'
        '(A) Are we being blamed\n'
        '(B) Are we blamed\n'
        '(C) Are we blame\n'
        '(D) Are we being blame',
      ),
      const PageText(
        2,
        '522\n'
        '18. Choose the correct article.\n'
        '(A) a\n'
        '(B) an\n'
        '(C) the\n'
        '(D) none',
      ),
      const PageText(
        4,
        '524 Advanced FPJC MCQs Model Papers (Volume 2)\n'
        '58. Choose the correct sentence.\n'
        '(A) He is good\n'
        '(B) He are good\n'
        '(C) He am good\n'
        '(D) He be good',
      ),
      const PageText(
        7,
        'Papers of 2021 527\n'
        'MODEL PAPER 67\n'
        'General Knowledge\n'
        '1. What is the capital?\n'
        '(A) Lahore\n'
        '(B) Karachi\n'
        '(C) Islamabad\n'
        '(D) Peshawar',
      ),
    ];
    final structure = detectBookStructure(pages);
    final titles = structure.parts.map((p) => p.title).toList();
    for (final bad in [
      'Papers of 2021 521',
      'Papers of 2021 527',
      '522',
      '524 Advanced FPJC MCQs Model Papers (Volume 2)',
    ]) {
      expect(
        titles.any((t) => t == bad || t.contains(bad)),
        isFalse,
        reason: 'running header became a part title: "$bad" in $titles',
      );
    }
    // The real sections survive: English Grammar (p1) and General
    // Knowledge (p7) are still detected as parts.
    expect(
      titles.any((t) => t.contains('English Grammar')),
      isTrue,
      reason: 'real section lost: $titles',
    );
    expect(
      titles.any((t) => t.contains('General Knowledge')),
      isTrue,
      reason: 'real section lost: $titles',
    );
  });

  test('a heading starting with a year is still a heading', () {
    // The page-number-prefix exclusion must not eat a real heading
    // that starts with a year ("2021 Current Affairs").
    final pages = [
      const PageText(
        1,
        '2021 Current Affairs\n'
        '1. Who is the president?\n'
        '(A) A\n'
        '(B) B\n'
        '(C) C\n'
        '(D) D',
      ),
    ];
    final structure = detectBookStructure(pages);
    final titles = structure.parts.map((p) => p.title).toList();
    expect(titles.any((t) => t.contains('2021')), isTrue,
        reason: 'year heading lost: $titles');
  });
}
