/// Layout-pattern library (Phase A, v2.0.0).
///
/// One entry per layout pattern the extraction engine recognises,
/// with the exact recognition rule the code implements — so a new
/// format starts from a WRITTEN pattern, not from guessing at the
/// parser. Status: supported / partial / unsupported / unmeasured,
/// matching docs/extraction-audit.md §1. "Proved by" names the test
/// or real item; a pattern with no proof is never claimed as covered.
///
/// To add a pattern: add an entry here FIRST (recognition rule +
/// example), then the detector/parser, then the test, then the audit
/// row — in that order.
class LayoutPattern {
  const LayoutPattern({
    required this.id,
    required this.name,
    required this.recognition,
    required this.example,
    required this.status,
    required this.provedBy,
  });

  final String id;
  final String name;
  final String recognition;
  final String example;
  final String status;
  final String provedBy;
}

/// Every layout pattern the engine knows (and the ones it does not
/// yet — listed so the gap is visible, not hidden).
const List<LayoutPattern> layoutPatterns = [
  LayoutPattern(
    id: 'block',
    name: 'Standard block',
    recognition:
        'Numbered start ("Q1." / "1.") + 4 option lines (A) / A. / A: '
        '+ answer line ("Answer: C" / "Ans: C" / "Correct: C"), or a '
        'key entry / tick / bold / asterisk signal. Precedence: '
        'answer-line > key > tick > bold > asterisk.',
    example: 'Q1. Capital of Pakistan?\nA) Lahore\nB) Karachi\n'
        'C) Islamabad\nD) Quetta\nAnswer: C',
    status: 'supported',
    provedBy: 'F1 PPSC 40/40; F6 Pace 1442; F12 MPT 142',
  ),
  LayoutPattern(
    id: 'one-liner',
    name: 'One-liner (inline options)',
    recognition:
        'Question + all 4 options on ONE line; ≥ 2 consecutive option '
        'markers (a)/(b)/(c)/(d) or A./B./C./D.; answer on the same '
        'line ("Ans: (c)") or the next line.',
    example: '1. Capital of Pakistan? (a) Lahore (b) Karachi '
        '(c) Islamabad (d) Quetta\nAns: (c)',
    status: 'supported',
    provedBy: 'F14 Sir Rizwan GSA (2); synthetic one-liner tests',
  ),
  LayoutPattern(
    id: 'q-only',
    name: 'Q-only (direct answer, pool-built options)',
    recognition:
        '"Q. … Ans: …" line; options are built from the correct answer '
        '+ 3 distractors drawn from OTHER answers in the same book. '
        'Fewer than 3 distinct other answers → the question is '
        'EXCLUDED with its reason, never guessed.',
    example: 'Q. What is the capital of Pakistan? Ans: Islamabad',
    status: 'supported',
    provedBy: 'F8 Sir Tauqeer 284; F13 US History 515; F9 IDIOMS 1067',
  ),
  LayoutPattern(
    id: 'flashcard-dash',
    name: 'Flashcard, dash-inline',
    recognition:
        'Question + " — " + short answer on one line. The answer walk '
        'stops at the next "?" line, so a list never swallows the '
        'next question into the previous answer.',
    example: 'What is the capital of France? — Paris',
    status: 'supported',
    provedBy: 'test/phase_a_gaps_test.dart (G6, 6/6)',
  ),
  LayoutPattern(
    id: 'flashcard-next-line',
    name: 'Flashcard, answer on next line',
    recognition:
        '"?"-terminated question (ASCII "?" or Urdu "؟") followed by '
        '1–2 short plain lines; stops at ".", a header, a footer, or '
        'any line containing "?" (the next question).',
    example: 'What is the capital of France?\nParis',
    status: 'supported',
    provedBy: 'F8 Sir Tauqeer 284; test/phase_a_gaps_test.dart (G6)',
  ),
  LayoutPattern(
    id: 'flashcard-trailing',
    name: 'Flashcard, trailing answer',
    recognition:
        'Short answer after the LAST "?" / "؟" / ":" that ends the '
        'stem; answer ≤ 60 chars, a noun phrase, never another '
        'question. A ":" split needs a real stem (≥ 3 words / list '
        'entry / sentence tail) so a bare label never splits.',
    example: 'What is the capital of France? Paris',
    status: 'supported',
    provedBy: 'F14 Sir Rizwan GSA (326 "?"); test/phase_a_gaps_test.dart',
  ),
  LayoutPattern(
    id: 'table-row-wise',
    name: 'Table, row-wise',
    recognition:
        'Question line(s) + 4 bare option lines + key letter and/or '
        'type label ("Noun", "Geography"); ≥ 2 rows; stem ≤ 400 chars. '
        'Tick/bold on an option resolve a key-less row; a key-vs-'
        'tick/bold disagreement is a recorded conflict, key wins.',
    example: 'Yesterday, I met ___ European\nA\nAn\nThe\nNone\n'
        'B\nArticle and its Types',
    status: 'supported',
    provedBy: 'Table photo ppsc123_1.jpg 32/32; F3 Pak Affairs 19',
  ),
  LayoutPattern(
    id: 'table-column-wise',
    name: 'Table, column-wise (OCR order)',
    recognition:
        'N questions, then N option-A values, N option-B, N option-C, '
        'N option-D, then a run of ≥ 3 key letters, then type labels. '
        'The pre-key region must group into exactly 5N items.',
    example: 'Q1..Q5, A1..A5, B1..B5, C1..C5, D1..D5, B A C D B, '
        'Noun Verb Adjective Adverb Pronoun',
    status: 'supported',
    provedBy: 'Table photo 32/32 (synthetic column order); '
        'test/phase_a_gaps_test.dart (G1, G7)',
  ),
  LayoutPattern(
    id: 'key-section',
    name: 'Answer key section (per paper / per month)',
    recognition:
        'A key section ("ANSWER KEY", "Answers") after a paper; '
        'entries join to candidates by (paper, number). A "?" entry '
        'is EXCLUDED, never guessed; an entry matching no question is '
        'reported as unmatched.',
    example: 'ANSWER KEY\n1. C  2. B  3. D …',
    status: 'supported',
    provedBy: 'F6 Pace (11 sections, 1115 applied); F12 MPT (140/140)',
  ),
  LayoutPattern(
    id: 'key-compact',
    name: 'Answer key, compact sequence ("1.A 2.B …")',
    recognition: 'No dedicated detector yet — key sections are parsed '
        'line-wise; a compact inline sequence has no test.',
    example: '1.A 2.B 3.C 4.D 5.A',
    status: 'unmeasured',
    provedBy: 'none — needs a real sample + test',
  ),
  LayoutPattern(
    id: 'options-3-4-column',
    name: 'Options in 3 / 4 columns on one line',
    recognition: 'No dedicated detector yet — the inline-option path '
        'likely handles it, but there is no real-file proof.',
    example: '(A) 1941 (B) 1942 (C) 1943 (D) 1944 on one line',
    status: 'unmeasured',
    provedBy: 'none — needs a real sample + test',
  ),
  LayoutPattern(
    id: 'multi-question-row',
    name: 'Multiple questions per row',
    recognition: 'No code path splits one line into 2+ questions.',
    example: '1. …? A) … B) …  2. …? A) … B) …',
    status: 'unsupported',
    provedBy: 'none — needs a real sample + test',
  ),
  LayoutPattern(
    id: 'italic-signal',
    name: 'Italic correct-option signal',
    recognition: 'No italic detection anywhere (font-name check '
        'covers bold only).',
    example: 'Correct option printed in italics',
    status: 'unsupported',
    provedBy: 'none — extractor work (font-name italic)',
  ),
  LayoutPattern(
    id: 'highlight-colour-signal',
    name: 'Highlight / colour correct-option signal',
    recognition: 'No highlight-annotation or colour detection; '
        'preprocessing drops colour (grayscale) before Tesseract.',
    example: 'Correct option highlighted yellow / printed in red',
    status: 'unsupported',
    provedBy: 'none — extractor work (annotations + colour)',
  ),
  LayoutPattern(
    id: 'cross-circle-underline-signal',
    name: 'Cross / circle / underline answer marks',
    recognition: 'Cross (✗/✘) has no text-level handler; circle and '
        'underline are drawings, not text — both need geometry from '
        'the extractor, not the parser.',
    example: '✗ on the wrong option; a circle around (B)',
    status: 'unsupported',
    provedBy: 'none — extractor geometry work',
  ),
  LayoutPattern(
    id: 'omr',
    name: 'OMR sheets / filled bubbles',
    recognition: 'No OMR code anywhere: no bubble detection, no sheet '
        'alignment, no fill threshold. Low-quality photos are a hard '
        'limit (a wrong bubble is a wrong answer presented as fact).',
    example: 'A B C D bubbles, one filled per question',
    status: 'unsupported',
    provedBy: 'none — new image-processing subsystem',
  ),
  LayoutPattern(
    id: 'cross-page-split',
    name: 'Question split across a page break',
    recognition:
        'Pages flatten into ONE line stream; blocks split ONLY at '
        'question-start lines, so a split question stitches '
        'naturally. Page furniture (footer / running header) at the '
        'break is skipped, never joined. Missing numbers are reported '
        'WITH pages; duplicates are reported with pages, both kept.',
    example: 'Stem + A–B on page 1, C–D + answer on page 2',
    status: 'supported',
    provedBy: 'test/cross_page_test.dart 11/11; F8 Sir Tauqeer 277→284',
  ),
  LayoutPattern(
    id: 'handwritten-mark',
    name: 'Handwritten tick / circle (student mark)',
    recognition:
        'No signal separates a pen tick from a printed tick in OCR '
        'text. Rule: a tick/bold on an OCR page lands the question '
        'UNVERIFIED at confidence 0.6 (markProvenance "ocr") until '
        'the user confirms it in manual correction.',
    example: 'Pen tick on option B in a camera photo',
    status: 'partial',
    provedBy: 'test/unverified_marks_test.dart 10/10 (flagging); '
        'accuracy UNMEASURED',
  ),
];
