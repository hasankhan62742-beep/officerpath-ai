import 'dart:math';

import '../models/exam.dart';
import '../models/question.dart';
import 'answer_key.dart';
import 'book_structure.dart';
import 'paper_identity.dart';

/// Parses MCQs from plain text (pasted text, .txt file, text extracted
/// from a PDF, or OCR output) into [Question]s.
///
/// Books come in different shapes, so the parser accepts three formats
/// and reports how many questions came from each (see
/// [ParseResult.formatCounts] — shown in the upload preview):
///
/// **(a) Standard block** — one question per block, options on their own
/// lines:
/// ```text
/// Q1. What is the capital of Pakistan?
/// A) Lahore
/// B) Karachi
/// C) Islamabad
/// D) Quetta
/// Answer: C
/// Explanation: Islamabad became the capital in 1967.
/// Subject: Pakistan Studies
/// ```
/// Tolerant variants: `1.` instead of `Q1.`, `A.` / `(A)` / `A:` instead
/// of `A)`, `Correct: C` / `Ans: C` / `Answer: 3` instead of `Answer: C`,
/// and an answer given as text (`Correct: Islamabad`) is matched against
/// the options.
///
/// **(b) One-liner** — question + all 4 options on one line:
/// ```text
/// 1. What is the capital of Pakistan? (a) Lahore (b) Karachi (c) Islamabad (d) Quetta
/// Ans: (c)
/// ```
/// Option markers may be `(a)` / `a)` / `A.` / `1)` / `(i)` … and may be
/// separated by spaces, commas or semicolons. The answer may sit on the
/// same line (`Ans: (c)`, `Answer: C`, `Correct: Islamabad`) or on the
/// next line (`(c)` alone also works).
///
/// **(c) Q-only (no options)** — a question with a direct answer:
/// ```text
/// Q. What is the capital of Pakistan? Ans: Islamabad
/// ```
/// These are imported too: the 4 options are built from the correct
/// answer plus 3 distractors drawn from OTHER questions' answers in the
/// same book (never the correct answer twice). If the book has fewer
/// than 3 usable distinct distractors for such a question, the question
/// is EXCLUDED from tests and listed in [ParseResult.excluded] with the
/// reason — fake options are never invented and items are never dropped
/// silently.
///
/// A question without a recognisable answer is skipped and counted in
/// [ParseResult.skipped]. Every question still ends up with exactly 4
/// options (A–D) — that rule is never relaxed.
/// **Answer keys (two-pass)** — many books print no answer inside each
/// question; the answers live in a trailing "ANSWER KEY" section, one
/// per paper (or per month). Such questions are kept as answerless
/// candidates in pass one and joined to their key entry by (paper,
/// number) in pass two (see `answer_key.dart`). A key section is never
/// parsed as questions, and a question the key cannot answer is listed
/// in [ParseResult.questionsMissingAnswers] instead of failing the
/// import. A key entry matching no question anywhere is reported in
/// [ParseResult.unmatchedKeyEntries].
///
/// **(d) Flashcard (no options, no "Ans:" marker)** — a question
/// whose following plain line(s) are the direct answer (the Sir
/// Tauqeer book: one Q&A per page, "Who won the 2026 Nobel Peace
/// Prize?" → "Navanethem 'Navi' Pillay (South Africa)"). Imported as
/// Q-only (options from the book's answer pool). Only in the
/// page-aware parse ([parseMcqsFromPages]): the answer must be short
/// (≤ 100 chars/line, ≤ 2 lines), on the same page as the question,
/// and never a header / month title — so explanation prose (long
/// lines, and blocks that HAVE option lines) can never be swallowed
/// as an answer.
///
/// **Multi-line questions and answers** — a question may wrap 2–4
/// lines ("On which date was emergency and / Governor's Rule imposed
/// in Khyber / Pakhtunkhwa"); continuation lines are joined into the
/// question text for every format. Answers wrap too ("Navanethem
/// "Navi" Pillay (South / Africa)") and are joined the same way.
///
/// **Answer signals and precedence** — the correct answer may come
/// from an explicit answer line, the book's answer key, a tick mark
/// (✓/✔ on the correct option), a bold option, or an asterisk (`*`
/// after the correct option — the Dogar answer marker). Precedence:
/// answer line > key > tick > bold > asterisk > AI inference. When
/// signals conflict, the higher-precedence one wins and the conflict is
/// recorded in [ParseResult.conflicts] — never silently resolved.
/// [ParseResult.answerSources] counts questions per signal source
/// ("20 key se, 12 tick se, 8 bold se") for the upload preview.
///
/// **Page-aware parsing** — [parseMcqsFromPages] takes per-page text
/// and tags every question with its 1-based PDF page and its book
/// part ([Question.page], [Question.part]); [parseMcqs] keeps working
/// for TXT / pasted text (page 0, part '').
/// One label:value fact from an infographic fact-card book (the
/// organisation file): "ESTABLISHED: OCTOBER 24, 1945". The label and
/// value were joined across the wide gap on the card (or from adjacent
/// lines when the extractor split them). [part] is the card/section
/// the fact belongs to (the org name), [page] its 1-based PDF page.
/// Spellings are preserved exactly as printed ("SECRATARY"), never
/// silently corrected. The AI-generation step builds MCQs from these.
class FactPair {
  const FactPair({
    required this.label,
    required this.value,
    this.part = '',
    this.page = 0,
    this.isStatement = false,
  });

  final String label;
  final String value;
  final String part;
  final int page;

  /// True when the fact has no Label:Value split — the whole line IS
  /// the fact (a dash/bullet statement, e.g. the Urdu paste's
  /// "رسول اللہ ﷺ کے اونٹنی کا نام قصواء تھا۔"). For a statement fact
  /// [label] == [value] == the statement text. Validation allows an
  /// option that appears verbatim inside a statement fact (see
  /// [validateGenerated] in ai_generation.dart).
  final bool isStatement;

  Map<String, dynamic> toMap() => {
    'label': label,
    'value': value,
    'part': part,
    'page': page,
    'isStatement': isStatement,
  };

  factory FactPair.fromMap(Map<String, dynamic> m) => FactPair(
    label: m['label'] as String? ?? '',
    value: m['value'] as String? ?? '',
    part: m['part'] as String? ?? '',
    page: m['page'] as int? ?? 0,
    isStatement: m['isStatement'] as bool? ?? false,
  );
}

class ParseResult {
  const ParseResult({
    required this.questions,
    required this.parsed,
    required this.skipped,
    this.errors = const [],
    this.formatCounts = const {},
    this.generatedOptions = 0,
    this.excluded = const [],
    this.keySectionsFound = 0,
    this.keyEntriesApplied = 0,
    this.questionsMissingAnswers = const [],
    this.parts = const [],
    this.answerSources = const {},
    this.conflicts = const [],
    this.unmatchedKeyEntries = const [],
    this.notes = const [],
    this.unmatchedNotes = const [],
    this.fiveOptionNormalised = 0,
    this.fiveOptionAnswerE = 0,
    this.numberGaps = const [],
    this.numberDuplicates = const [],
    this.noiseLinesFiltered = 0,
    this.facts = const [],
    this.answerPending = const [],
    this.keyPaperReport = const [],
  });

  final List<Question> questions;
  final int parsed;
  final int skipped;
  final List<String> errors;

  /// How many questions came from each format: 'block', 'one-liner',
  /// 'q-only', 'table'. Shown in the upload preview before saving.
  final Map<String, int> formatCounts;

  /// Questions whose 4 options were built from the book's own answer
  /// pool (format 'q-only').
  final int generatedOptions;

  /// Human-readable reasons for Q-only questions that could NOT be
  /// imported (too few distinct answers in the book to build options).
  final List<String> excluded;

  /// How many "Answer Key" sections were found in the book (0 when the
  /// book has no key — inline answers only).
  final int keySectionsFound;

  /// How many questions got their answer from the key (second pass).
  final int keyEntriesApplied;

  /// Answerless questions the key could NOT answer, e.g.
  /// "Paper 1 Q4 — no key entry". The import still succeeds with the
  /// questions the key did cover.
  final List<String> questionsMissingAnswers;

  /// Test-building parts: only parts with at least one parsed
  /// question (exact counts, recomputed from [questions]); a single
  /// "Poori book" part when the book has no questions at all. The
  /// selection screen offers these (plus a page-range picker). Empty
  /// for the string path ([parseMcqs]) — no pages, no parts.
  final List<BookPart> parts;

  /// Questions grouped by [Question.part], for the selection screen.
  /// A question with part '' lands under ''.
  Map<String, List<Question>> get questionsByPart {
    final out = <String, List<Question>>{};
    for (final q in questions) {
      out.putIfAbsent(q.part, () => <Question>[]).add(q);
    }
    return out;
  }

  /// How many questions got their answer from each signal source, for
  /// the upload preview ("20 key se, 12 tick se, 8 bold se, 5 AI se"):
  /// keys are 'answer-line', 'key', 'tick', 'bold', 'asterisk',
  /// 'flashcard', 'ai'. Only non-zero sources appear.
  final Map<String, int> answerSources;

  /// Signal conflicts, e.g. "Block 3: answer line says B but the tick
  /// is on C — using the answer line". The higher-precedence signal
  /// won; the user can see the disagreement instead of it being
  /// silently resolved.
  final List<String> conflicts;

  /// Answer-key entries that matched no question in any paper/month
  /// segment, e.g. "Paper 2 key entry 61 — no matching question" (a
  /// key printed for a paper that is not in this book). Reported, never
  /// silently dropped or force-joined to another paper's questions.
  final List<String> unmatchedKeyEntries;

  /// Every "(Note: …)" evidence line found in the book (109 edition).
  /// Notes are attached to the nearest preceding question's
  /// [Question.explanation] (prefixed "Note: ") so the AI-inference
  /// step can match their content against the options; this list is
  /// the transparency record that none was dropped.
  final List<String> notes;

  /// Notes that could not be matched: no preceding question to attach
  /// to, or attached but matching none of that question's options
  /// (see [_noteMatchesOptions] — a cheap substring proxy; the real
  /// matching is the AI agent's job). Kept in diagnostics, never
  /// silently discarded.
  final List<String> unmatchedNotes;

  /// Questions normalised from 5 options (A–E, Examveda) to the
  /// app's exact-4 rule. "812 questions normalised 5→4" in the
  /// preview/diagnostics.
  final int fiveOptionNormalised;

  /// Of [fiveOptionNormalised], how many had the answer on E — E's
  /// text was kept as the 4th option and one wrong A–D option (D)
  /// dropped instead. "35 kept 'None of these' as 4th option".
  final int fiveOptionAnswerE;

  /// Missing question-number ranges, e.g. "Q4–Q45 (42 questions
  /// missing — pages not provided)" (MPT file: the book itself flags
  /// "⚠ Q4–45: page not provided"). Computed from the parsed
  /// questions' numbers, WITH the pages that bound each gap
  /// ("Q9 missing between Q8 (page 1) and Q10 (page 2)"). Gaps are
  /// reported, never silently renumbered or filled.
  final List<String> numberGaps;

  /// Duplicated question numbers, e.g. "Q8 appears twice
  /// (page 1, page 2)". Both copies are kept as parsed (they are two
  /// different questions in the book); the duplication is reported in
  /// the preview diagnostics so the user can check it — never
  /// silently merged, never silently dropped.
  final List<String> numberDuplicates;

  /// Noise lines filtered out (Examveda / organisation files):
  /// standalone watermark digit lines, promo lines (incl. the
  /// compiler's phone number — never stored), bare phone-number
  /// lines, and foreign-script ad blocks. They never became
  /// questions or errors.
  final int noiseLinesFiltered;

  /// Label:value facts from infographic fact-card books (the
  /// organisation file), joined across the wide label–value gap.
  /// Empty for ordinary MCQ books.
  final List<FactPair> facts;

  /// Questions with 4 options but NO usable answer — candidates for
  /// AI answer inference (v1.2). The book gave the options (and
  /// maybe an explanation / "(Note: …)" as evidence) but no answer
  /// line and no matching key entry (File 2), or the key explicitly
  /// says "?" (MPT Q3/Q106, reason 'unknown-key'). Inference is an
  /// EXPLICIT user choice — these are never guessed silently, and
  /// they are never counted in [parsed].
  final List<PendingQuestion> answerPending;

  /// Plain-language key-paper report for the preview: per-paper
  /// attribution ("Key 'Paper 60' se 42 jawab lage.") plus any key
  /// whose named paper has no questions in the import ("Key 'Paper
  /// 60' mili, lekin is PDF mein Paper 60 ke sawal nahi — key nahi
  /// lagayi."). Strict paper rule, owner 20 Nov 2026.
  final List<String> keyPaperReport;
}

/// One question that has an answer but no options yet.
class _QOnly {
  _QOnly({
    required this.text,
    required this.answer,
    required this.explanation,
    required this.subject,
    this.page = 0,
    this.lineIndex = -1,
    this.answerSource = 'answer-line',
  });

  final String text;
  final String answer;
  final String explanation;
  final Subject subject;

  /// 1-based PDF page (0 = unknown); 0-based line index in the
  /// flattened stream (-1 = unknown). Carried to the built [Question].
  final int page;
  final int lineIndex;

  /// 'answer-line' for an "Ans: …" line, 'flashcard' for a flashcard
  /// Q&A (no marker in the book).
  final String answerSource;
}

/// One question that has 4 options but no answer yet — a candidate for
/// the second (answer-key) pass. Only kept when the question is
/// numbered, so the key can join it by (paper, number).
class _AnswerlessCandidate {
  _AnswerlessCandidate({
    required this.blockIndex,
    required this.text,
    required this.options,
    required this.format,
    required this.paper,
    required this.number,
    required this.subject,
    required this.explanation,
    this.page = 0,
    this.lineIndex = -1,
    this.tickIndex,
    this.boldOptions = const [],
  });

  final int blockIndex;
  final String text;
  final List<String> options;
  final String format;
  final String paper;
  final int number;
  final Subject subject;
  final String explanation;

  /// 1-based PDF page (0 = unknown); 0-based line index. Carried to
  /// the built [Question] so part assignment survives the key join.
  final int page;
  final int lineIndex;

  /// Tick / bold signals seen on this question's options (for the
  /// precedence + conflict rules when the key answers it): the index
  /// of the ticked option (null when none / ambiguous), and the
  /// per-option bold flags, parallel to [options].
  final int? tickIndex;
  final List<bool> boldOptions;
}

/// The question number from a block's first line ("Q12." / "12." /
/// "Q.12:" → 12), or null when the question is unnumbered ("Q. …").
/// The "Q." + digits + separator shape ("Q.1:") needs the optional
/// dot before the digits — the old `^(?:Q\s*)?(\d+)` could not match
/// "Q.1:" at all.
int? _questionNumber(String firstLine) {
  final m = RegExp(
    // A decimal ("92.97 m …") is not a question number: the separator
    // must not be followed by another digit.
    r'^(?:Q\s*\.?\s*)?(\d+)\s*[\.\)\:](?!\d)',
    caseSensitive: false,
  ).firstMatch(firstLine);
  if (m == null) return null;
  return int.tryParse(m.group(1)!);
}

/// Strips the question-number prefix from [text]: the dotted / "Q"
/// forms via [questionPrefixRe], plus a BARE number ("3 What …?" —
/// the PakMCQs 500-GK format, digits + space, no dot). The bare
/// strip is CASE-SENSITIVE on purpose: [questionPrefixRe] is
/// case-insensitive, and under case-insensitive matching `[a-z]`
/// also matches capitals, so a `(?![a-z0-9])` lookahead there would
/// reject "3 What …" as well as "3 apples …" (caught by a probe
/// 19 Nov 2026 — the imported regex matched nothing bare). The
/// bare strip only fires when the text ends with "?" / "؟" (a
/// complete question stem): a wrapped stem ("3 What is the capital"
/// with no "?") keeps its number, and a list item ("3 apples are
/// red.") or a year line ("1917 was …") never ends with "?" so it
/// never strips. Residual ambiguity: a question that OPENS with a
/// year ("1947 Was a leap year?") loses the year — the dotted form
/// ("1947. Was …") was already stripped the same way. _questionNumber
/// deliberately does NOT accept bare numbers (a stray year would
/// pollute the numbering diagnostics), so bare-numbered books get no
/// gap report.
String _stripQuestionNumberPrefix(String text) {
  var t = text.replaceFirst(questionPrefixRe, '');
  final trimmed = t.trimRight();
  if (trimmed.endsWith('?') || trimmed.endsWith('؟')) {
    t = t.replaceFirst(RegExp(r'^\d+\s+(?![a-z0-9])'), '');
  }
  return t;
}

/// Routing gate (governing spec 19 Nov 2026): the deterministic LOCAL
/// parser runs FIRST for every format, and it WINS whenever it found
/// anything (`parsedCount > 0`). AI is only a last resort — the local
/// parser genuinely extracted 0 MCQs — and even then the user sees
/// diagnostics first and is ASKED. (AI generation itself is PARKED
/// under the current spec: the uploaded PDF is the only source of
/// questions; this gate is what keeps the AI path from ever
/// pre-empting a successful local parse.)
bool localParseSuffices({required int parsedCount}) => parsedCount > 0;

/// Ligatures (U+FB00–U+FB06) to plain letters. Phase A (G9): direct
/// [parseMcqs]/[parseMcqsFromPages] callers used to bypass the
/// normalisation that the PDF extractor and [parseTextInBackground]
/// apply, so a ligature ("oﬃcially") survived into the stored
/// question text and broke matching. This is the same mapping as
/// [_normalizeLigatures] in pdf_text_extractor.dart (kept as a local
/// copy because that file imports this one — no import cycle);
/// normalising twice is idempotent, so the extractor path is safe.
String _normalizeLigaturesLocal(String text) {
  if (!text.contains('\uFB00') &&
      !text.contains('\uFB01') &&
      !text.contains('\uFB02') &&
      !text.contains('\uFB03') &&
      !text.contains('\uFB04') &&
      !text.contains('\uFB05') &&
      !text.contains('\uFB06')) {
    return text;
  }
  return text
      .replaceAll('\uFB00', 'ff')
      .replaceAll('\uFB01', 'fi')
      .replaceAll('\uFB02', 'fl')
      .replaceAll('\uFB03', 'ffi')
      .replaceAll('\uFB04', 'ffl')
      .replaceAll('\uFB05', 'st')
      .replaceAll('\uFB06', 'st');
}

/// Parses MCQs from plain text (TXT / pasted text). Page numbers are
/// unknown here (page 0, part '' on every question); use
/// [parseMcqsFromPages] for PDFs / OCR output, where pages are known.
/// The signature is unchanged from v1.1.
ParseResult parseMcqs(
  String rawText, {
  required String sourceId,
  required String sourceLabel,
  Subject defaultSubject = Subject.gk,
  // Where the text came from: 'printed' (the book's own text layer
  // / pasted text — a tick/bold mark is official) or 'ocr' (read by
  // OCR from a scan or camera photo — a tick/bold could be the
  // student's pen, so those questions are UNVERIFIED). Default
  // 'printed': pasted / TXT text is the book's own text.
  String markProvenance = 'printed',
}) {
  // G9: normalise ligatures here (not only in the extractor), so a
  // direct parseMcqs caller never stores "oﬃcially" with U+FB03.
  final lines = _normalizeLigaturesLocal(rawText)
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();

  // First, split off any answer-key sections (and paper headings):
  // key lines must never become question blocks.
  final segmented = segmentText(lines);
  return _parseImpl(
    segmented,
    sourceId: sourceId,
    sourceLabel: sourceLabel,
    defaultSubject: defaultSubject,
    markProvenance: markProvenance,
  );
}

/// Parses MCQs from per-page text (PDF text layer or OCR output, in
/// page order). Every parsed question is tagged with its 1-based PDF
/// page and its book part ([Question.page], [Question.part]), and
/// [ParseResult.parts] lists the test-building parts with exact
/// question counts. This is the entry point the import service uses;
/// [parseMcqs] is only for TXT / pasted text.
///
/// [ocrPages] is the set of 1-based page numbers whose text came from
/// OCR (a scan or camera photo) rather than the PDF text layer — the
/// import service passes its `ocrPages` list. A tick/bold answer mark
/// on an OCR page could be the student's pen, so those questions are
/// marked UNVERIFIED ([Question.markProvenance] 'ocr') until the user
/// confirms them in manual correction.
ParseResult parseMcqsFromPages(
  List<PageText> pages, {
  required String sourceId,
  required String sourceLabel,
  Subject defaultSubject = Subject.gk,
  Set<int> ocrPages = const {},
}) {
  // G9: normalise ligatures per page, as in [parseMcqs] — a direct
  // parseMcqsFromPages caller (tests, OCR re-parse) must not bypass it.
  final normalisedPages = [
    for (final p in pages) PageText(p.page, _normalizeLigaturesLocal(p.text)),
  ];
  final flat = flattenPages(normalisedPages);
  final structure = detectBookStructure(normalisedPages);
  final segmented = segmentLines(flat);
  return _parseImpl(
    segmented,
    structure: structure,
    sourceId: sourceId,
    sourceLabel: sourceLabel,
    defaultSubject: defaultSubject,
    ocrPages: ocrPages,
  );
}

// ---------------------------------------------------------------------------
// Table-format MCQs (v1.3) — a printed Question | A | B | C | D | key | type
// grid, e.g. the user's CamScanner grammar page ("Adjective and its
// Types", "Article and its Types"). OCR reads such a page in one of two
// orders:
//   * COLUMN-wise (ML Kit / Tesseract on a scan): all questions, then
//     all option-A values, then B, C, D, then the key letters, then the
//     type labels. The phone preview of the failing page showed exactly
//     this — questions only in the first lines.
//   * ROW-wise (a text PDF, or Gemini vision asked for rows): question
//     line(s) + 4 bare option lines + key letter + type label, repeated.
// A row is only accepted when its 4 options are present; the key letter
// is the correct answer, so no answer-pool or guessing is involved.
// Rows without a usable key become [PendingQuestion]s (AI inference),
// never silently dropped. A table with up to 10 columns is accepted:
// extra columns (a 5th option, a marks column, a row-number column)
// are normalised or ignored, never a reason to reject the book.
// ---------------------------------------------------------------------------

/// One cell of table text: the cleaned line plus where it came from, so
/// a parsed table question keeps its page / part like any other question.
/// [bold] / [tick] are the extractor's answer signals on this cell
/// (a bolded or ticked option); they are read BEFORE the markers are
/// stripped from [text].
class _TableCell {
  const _TableCell(
    this.text,
    this.lineIndex,
    this.page,
    this.paper, {
    this.bold = false,
    this.tick = false,
  });

  final String text;
  final int lineIndex;
  final int page;
  final String paper;
  final bool bold;
  final bool tick;
}

/// Result of the table-format pass. [questions] are the scored rows
/// (key / tick / bold resolved); [pending] are rows with 4 options but
/// no usable answer (AI inference). [consumedLineIndices] are the
/// [SegmentedLine.lineIndex] values the table used, so [_parseImpl]
/// excludes them from the block loop — the Q-only pool never steals a
/// table row. [conflicts] records signal disagreements (key vs tick /
/// bold) the same way the standard parser does.
class TableParseResult {
  const TableParseResult({
    this.questions = const [],
    this.pending = const [],
    this.consumedLineIndices = const {},
    this.skipped = 0,
    this.errors = const [],
    this.conflicts = const [],
    this.fiveOptionNormalised = 0,
    this.fiveOptionAnswerE = 0,
  });

  final List<Question> questions;
  final List<PendingQuestion> pending;
  final Set<int> consumedLineIndices;
  final int skipped;
  final List<String> errors;
  final List<String> conflicts;
  final int fiveOptionNormalised;
  final int fiveOptionAnswerE;
}

/// A standalone answer-key letter on its own line: "A"–"E"
/// (optionally "A." / "B)"). The key column of a printed MCQ table.
/// "E" is included because a 5-option table's key can be E.
final _tableKeyLetterRe = RegExp(r'^\(?\s*([A-Ea-e])\s*[\)\.\:]?\s*$');

/// An option marker inside an option cell ("A. Latin", "B) German",
/// "(C) French" — the Computer-questions table, 20 Nov 2026). Group 1
/// is the marker letter, group 2 the option text. Same shape as the
/// block parser's option lines; a bare single letter ("A") is NOT a
/// marker (it can be the article "a" as an option value).
final _optionMarkerRe = RegExp(r'^\(?([A-Da-d])[\)\.\:\-]\s*(.+)$');

/// True when [t] is a page footer ("Page 1", "Page 1 of 71") — never
/// table content, never a question stem.
bool _isTablePageFooter(String t) {
  return RegExp(
    r'^page\s+\d+\s*(of\s+\d+)?\s*$',
    caseSensitive: false,
  ).hasMatch(t.trim());
}

/// A single A–D letter as an OPTION value: the article "a" is printed
/// as "A" (row 27: options "A", "An", "The", "None of these"). "E" is
/// never an option — it is always the key of a 5-option row.
final _tableArticleLetterRe =
    RegExp(r'^\(?\s*([A-Da-d])\s*[\)\.\:]?\s*$');

/// Grammar type words that appear in a table's last column. Deliberately
/// narrow: a bare category name ("Adjective", "Quantitative adjective",
/// "Indefinite Article"), never a sentence fragment — "part of" is NOT
/// a label (it is a wrapped question tail), so "part"/"speech" are not
/// in this list.
const _tableTypeWords = {
  'adjective',
  'article',
  'pronoun',
  'noun',
  'verb',
  'adverb',
  'preposition',
  'conjunction',
  'interjection',
  'demonstrative',
  'quantitative',
  'qualitative',
  'possessive',
  'indefinite',
  'definite',
  'distributive',
  'interrogative',
  'relative',
  'numeral',
  'proper',
  'common',
  'collective',
  'abstract',
  'material',
  'countable',
  'uncountable',
  'attributive',
  'predicative',
  'comparative',
  'superlative',
  'positive',
  'personal',
  'reflexive',
  'emphatic',
  'degree',
};

/// True when [line] looks like a table type-label cell for
/// consumption purposes: short (≤ 45 chars, ≤ 4 words), no digits, no
/// question mark. Looser than [_isTableTypeLabel] — a garbled label
/// ("article a/is") is still table structure, never a question.
bool _isTableLabelish(String line) {
  final t = stripBoldMarkers(line).trim();
  if (t.isEmpty || t.length > 45) return false;
  if (RegExp(r'[0-9?]').hasMatch(t)) return false;
  return t.split(RegExp(r'\s+')).length <= 4;
}

/// True when [line] is a type-label line from a grammar table's last
/// column: 1–4 words, no digits, and every word a grammar type word
/// ("Adjective", "Quantitative adjective", "Indefinite Article",
/// "Comparative adjective (as/as degree)", "Comparative. adjective").
/// Parenthetical remarks and trailing stops are ignored. A question or
/// an option never looks like this on its own line.
bool _isTableTypeLabel(String line) {
  var t = stripBoldMarkers(line).trim();
  if (t.isEmpty || t.length > 45) return false;
  if (RegExp(r'[0-9?!\[\]{}|/\\]').hasMatch(t)) return false;
  // A parenthetical remark ("(as/as degree)") is not a word.
  t = t.replaceAll(RegExp(r'\([^)]*\)'), '').trim();
  if (t.isEmpty) return false;
  final words = t.split(RegExp(r'\s+'));
  if (words.isEmpty || words.length > 4) return false;
  return words.every((w) {
    final clean = w.replaceAll(RegExp(r'[.,;:]+$'), '').toLowerCase();
    // "of" / "and" are glue inside a label ("Degree of Adjective"),
    // not category words themselves.
    return _tableTypeWords.contains(clean) ||
        clean == 'of' ||
        clean == 'and';
  });
}

/// True when [line] is a stray type-label line between table rows
/// (empty buffer): a strict type label, OR a garbled label that is
/// still recognisably a label — short, no digits/'?', and containing
/// at least one grammar type word ("article a/is" is row 26's
/// garbled label, not row 27's question). Two guards keep real short
/// question starts safe: (a) the type-word requirement ("Choose the
/// correct sentence" and "Bring me__" contain no type word, so they
/// are never skipped); (b) a question/action word ("modifies",
/// "which", "choose"…) means the line is a question, not a label —
/// row 1's stem "An adjective modifies a" contains the type word
/// "adjective" but also the verb "modifies", so it is kept.
bool _isStrayTableLabel(String line) {
  if (_isTableTypeLabel(line)) return true;
  if (!_isTableLabelish(line)) return false;
  final t = stripBoldMarkers(line).trim().toLowerCase();
  final words = t.split(RegExp(r'\s+')).map(
    (w) => w.replaceAll(RegExp(r'[.,;:]+$'), ''),
  );
  // A question/action word means this is a question stem, not a label.
  if (words.any(_tableQuestionWords.contains)) return false;
  return t.split(RegExp(r'[\s/]+')).any(
    (w) =>
        _tableTypeWords.contains(w.replaceAll(RegExp(r'[.,;:]+$'), '')),
  );
}

/// Words that only ever appear in a question stem, never in a type
/// label: action verbs and question words. (Copula/auxiliary verbs —
/// is/are/was/were/has/have — are deliberately NOT here: they can
/// appear inside a garbled label, e.g. "article a/is".)
const _tableQuestionWords = {
  'modifies',
  'means',
  'called',
  'refers',
  'shows',
  'describes',
  'indicates',
  'denotes',
  'identifies',
  'classify',
  'choose',
  'fill',
  'complete',
  'identify',
  'select',
  'find',
  'which',
  'what',
  'who',
  'when',
  'where',
  'how',
  'give',
  'write',
  'name',
  'state',
  'define',
};

/// True when [line] is a table section heading: "Adjective and its
/// Types", "Article and its Types". Structure, never a question — the
/// heading is skipped, not parsed. (A question ending in "…and its
/// types?" does not match: the '?' breaks the end anchor.)
bool _isTableSectionHeading(String line) {
  final t = stripBoldMarkers(line).trim();
  return RegExp(r'and\s+its\s+types\s*$', caseSensitive: false).hasMatch(t);
}

/// True when [line] looks like an in-table section-heading row
/// ("Interjection", "Parts of Speech Identification",
/// "Gerund / Infinitives / Participle" — the interjection table,
/// 20 Nov 2026): short (≤ 45 chars, ≤ 8 words), no digits, no '?'
/// or '!', not ending in '.'. The caller must ALSO require that the
/// cell is alone on its line and the next cell is a bare Sr.#, so a
/// real question stem (which shares its row's line and is followed
/// by its options, never by a bare number) can never be eaten.
bool _isTableHeadingRow(String line) {
  final t = stripBoldMarkers(line).trim();
  if (t.isEmpty || t.length > 45) return false;
  if (RegExp(r'[0-9?!]').hasMatch(t)) return false;
  if (t.endsWith('.')) return false;
  return t.split(RegExp(r'\s+')).length <= 8;
}

/// True when [line] is a bare table column header ("Question",
/// "Answer", "Type", "Key") — structure, never content.
bool _isTableColumnHeader(String line) {
  final t = stripBoldMarkers(line).trim().toLowerCase();
  return {
    'question',
    'questions',
    'answer',
    'answers',
    'key',
    'type',
    'option',
    'options',
    'q.no',
    'q no',
    's.no',
    'sr',
    'sr.#',
    'sr#',
    'sr.no',
    'sr. no',
    'sr. #',
    'ans',
    'ans.',
    'no.',
  }.contains(t);
}

/// Splits the segmented lines into table cells: '|' (a table ruling
/// read as a character) splits a line into cells, and a key letter
/// merged onto the end of a type label ("Adverb A") splits into the
/// label + the letter. Bold / tick markers are recorded on the cell
/// before they are stripped from the text. Anything else is kept as-is.
List<_TableCell> _tableCells(List<SegmentedLine> lines) {
  final cells = <_TableCell>[];
  for (final l in lines) {
    for (final part in l.text.split('|')) {
      final raw = part.trim();
      if (raw.isEmpty) continue;
      final bold = raw.contains('\uE000');
      final tick = _hasTick(raw);
      final t = _stripTicks(_cleanStored(raw));
      if (t.isEmpty) continue;
      // Key letter merged onto a type label: "Adverb A" → ["Adverb",
      // "A"]. Only when the prefix IS a type label — a trailing " A"
      // on any other line ("Choose option A") is left alone, so no
      // fake key is ever created.
      final m = RegExp(r'^(.+?)\s+([A-D])$').firstMatch(t);
      if (m != null && _isTableTypeLabel(m.group(1)!)) {
        cells.add(
          _TableCell(m.group(1)!, l.lineIndex, l.page, l.paper, bold: bold),
        );
        cells.add(
          _TableCell(m.group(2)!, l.lineIndex, l.page, l.paper),
        );
        continue;
      }
      cells.add(
        _TableCell(t, l.lineIndex, l.page, l.paper, bold: bold, tick: tick),
      );
    }
  }
  return cells;
}

/// Words that can never end a sentence on their own — when a line ends
/// with one of these AND the next line starts with a blank ("___"),
/// the blank line continues the same question ("He is the" +
/// "___ in the class."). Deliberately narrow: "do" is NOT in the list
/// ("…than I do" + "___baby likes…" is a new question, not a wrap).
const _tableContinuationWords = {
  'the',
  'a',
  'an',
  'of',
  'to',
  'in',
  'on',
  'for',
  'with',
  'by',
  'at',
  'from',
  'into',
  'and',
  'or',
  'but',
  'than',
  'as',
  'his',
  'her',
  'their',
  'my',
  'your',
  'its',
  'this',
  'that',
  'these',
  'those',
  'is',
  'are',
  'was',
  'were',
  'be',
  'been',
};

/// Groups [cells] into items: a line continues the previous item when
/// it is a wrapped fragment of it. A line is a continuation when:
///   * it starts with a lowercase letter, the previous item is long
///     (≥ 25 chars — a wrapped sentence, not a complete short value)
///     and does not end with '.', '?', ':' or '!', AND either the
///     previous item ends with a function word ("In the sentence \"My
///     bag is under the" + "kitchen table,…") or the line is a short
///     tail ending in ':' or '?' ("…In this sentence" + "five is:").
///     The extra condition matters: a complete sentence-option
///     ("This is a most perfect example") must NOT swallow the next
///     lowercase option ("smarter than"); or
///   * it starts with a blank ("___") and the previous item ends with
///     a continuation word ("He is the" + "___ in the class."); or
///   * it is a very short fragment (≤ 2 words, ≤ 12 chars) and the
///     previous item ends with ':' (the target word of a "word: …"
///     question: "…parts of speech word:" + "much").
/// Section headings and column headers are skipped (structure, not
/// content). Anything else starts a new item.
List<List<_TableCell>> _groupTableItems(List<_TableCell> cells) {
  final items = <List<_TableCell>>[];
  for (final cell in cells) {
    final t = cell.text;
    if (_isTableSectionHeading(t) || _isTableColumnHeader(t)) continue;
    if (items.isEmpty) {
      items.add([cell]);
      continue;
    }
    final prev = items.last;
    final prevText = prev.map((c) => c.text).join(' ');
    final prevTrim = prevText.trim();
    final prevEndsSentence =
        RegExp(r'[.?:!]$').hasMatch(prevTrim) || prevTrim.endsWith('"');
    final firstChar = t.isEmpty ? '' : t[0];
    final startsLower = firstChar.isNotEmpty &&
        firstChar == firstChar.toLowerCase() &&
        RegExp(r'[a-z]').hasMatch(firstChar);
    final startsBlank = t.startsWith('_');
    final prevLastWord = prevTrim
        .split(RegExp(r'\s+'))
        .last
        .replaceAll(RegExp(r'[^\w]'), '')
        .toLowerCase();
    final words = t.split(RegExp(r'\s+')).length;
    final isShortFragment = words <= 2 && t.length <= 12;
    // A lowercase line continues a long item only when the item ends
    // with a function word ("…under the" + "kitchen table,…") or the
    // line is a short tail ending in ':' or '?' ("…In this sentence"
    // + "five is:"). Without this, a complete sentence-option
    // ("This is a most perfect example", 29 chars) would swallow the
    // next lowercase option ("smarter than").
    const functionWords = {
      'the',
      'a',
      'an',
      'is',
      'are',
      'was',
      'were',
      'of',
      'to',
      'in',
      'on',
      'for',
      'with',
      'by',
      'and',
      'or',
      'but',
      'than',
      'as',
      'at',
      'from',
      'into',
      'his',
      'her',
      'their',
      'my',
      'your',
      'its',
      'this',
      'that',
      'these',
      'those',
      'be',
      'been',
      'being',
      'have',
      'has',
      'had',
    };
    final isShortTail =
        words <= 3 && t.length <= 15 && RegExp(r'[:?]$').hasMatch(t.trim());
    final continues = (startsLower &&
            !prevEndsSentence &&
            prevTrim.length >= 25 &&
            (functionWords.contains(prevLastWord) || isShortTail)) ||
        (startsBlank &&
            !prevEndsSentence &&
            _tableContinuationWords.contains(prevLastWord)) ||
        (isShortFragment && prevTrim.endsWith(':'));
    if (continues) {
      prev.add(cell);
    } else {
      items.add([cell]);
    }
  }
  return items;
}

/// Accumulates table rows for one parse attempt: scored questions,
/// answer-pending rows, consumed line indices, and diagnostics.
class _TableSink {
  final questions = <Question>[];
  final pending = <PendingQuestion>[];
  final consumed = <int>{};
  final conflicts = <String>[];
  final errors = <String>[];
  var skipped = 0;
  var fiveOptionNormalised = 0;
  var fiveOptionAnswerE = 0;

  /// Rows whose answer came from the row's key letter (not tick /
  /// bold). The small-table guard in [_parseTableRowWise] uses it:
  /// a table of < 3 rows is accepted only when EVERY row is
  /// key-anchored (see there for the F16 proof).
  var keyedRows = 0;

  /// Adds one table row. [keyLetter] is the row's key-column letter
  /// (null = no key); [tickIndex]/[boldIndex] are the tick/bold
  /// signals on the options (null = none). Precedence: key > tick >
  /// bold; a disagreement is recorded in [conflicts], never silently
  /// resolved. A 5-option row is normalised to the app's exact-4 rule
  /// ([_normaliseFiveOptions]); a row with no key and 5 options drops
  /// E. Validation: a real stem (≥ 10 chars) and 4 non-empty options.
  /// Duplicate option text is the book's own defect (the grammar table
  /// prints the same value twice in one row) — the row is still usable
  /// when the key is unambiguous, so only an all-identical option set
  /// is rejected.
  /// [number] is the row's book number (the Sr.# value, null when the
  /// table prints none) and [paper] its paper segment — both ride
  /// onto a pending row so a separately attached answer key can match
  /// it by (paper, number). Option cells may carry their own letter
  /// marker ("A. Latin"): the marker is stripped, and it must match
  /// the column position — a mismatch makes the answer unverifiable,
  /// so the row is left pending and the reason is reported in
  /// [errors] (never silently reassigned).
  void addRow({
    required List<_TableCell> rowCells,
    required String questionText,
    required List<String> options,
    required String? keyLetter,
    int? tickIndex,
    int? boldIndex,
    required int page,
    required String part,
    required Subject subject,
    required String sourceId,
    required String sourceLabel,
    int? number,
    required String paper,
  }) {
    for (final c in rowCells) {
      consumed.add(c.lineIndex);
    }
    // A key-vs-tick/bold disagreement in this row makes its answer
    // UNVERIFIED (governing spec: never present a conflicted answer
    // as certain — the v2 preview surfaces it for manual correction).
    final conflictsBefore = conflicts.length;
    final qText = questionText.trim();
    var opts = options.map((o) => o.trim()).toList();
    var correct = -1;
    if (keyLetter != null) {
      final m = _tableKeyLetterRe.firstMatch(keyLetter.trim());
      if (m != null) {
        correct = m.group(1)!.toUpperCase().codeUnitAt(0) - 65;
      }
    }
    // Option markers ("A. Latin" — the Computer-questions table):
    // strip the marker (the stored option is "Latin") and verify it
    // against the column position. A marker that disagrees with its
    // column makes the key letter ambiguous — the key could mean a
    // column or a marker — so the answer is distrusted below and the
    // row is left pending, never guessed.
    var markerMismatch = false;
    final strippedOpts = <String>[];
    for (var k = 0; k < opts.length; k++) {
      final m = _optionMarkerRe.firstMatch(opts[k]);
      if (m != null) {
        final markerLetter =
            m.group(1)!.toUpperCase().codeUnitAt(0) - 65;
        if (markerLetter != k) markerMismatch = true;
        strippedOpts.add(m.group(2)!.trim());
      } else {
        strippedOpts.add(opts[k]);
      }
    }
    opts = strippedOpts;
    if (markerMismatch) correct = -1;
    if (opts.length == 5) {
      if (correct < 0 || correct > 4) {
        opts = opts.sublist(0, 4);
        fiveOptionNormalised++;
      } else {
        final n = _normaliseFiveOptions(
          opts,
          correct,
          List.filled(5, false),
        );
        opts = n.options;
        correct = n.correctIndex;
        fiveOptionNormalised++;
        if (n.dropped == 'D') fiveOptionAnswerE++;
      }
    }
    // G7 (Phase A): the stem cap is 400 chars, not 200 — a real
    // table question can be a long sentence (grammar tables print
    // full example sentences as stems). The anchor (key letter /
    // type label) still guards against garbled-OCR blobs becoming
    // rows, so the higher cap does not weaken that guard.
    if (qText.length < 10 ||
        qText.length > 400 ||
        opts.length != 4 ||
        opts.any((o) => o.isEmpty) ||
        opts.toSet().length == 1) {
      skipped++;
      return;
    }
    var resolved = correct;
    var answerSource = '';
    if (!markerMismatch && resolved < 0 && tickIndex != null) {
      resolved = tickIndex;
      answerSource = 'tick';
    }
    if (!markerMismatch && resolved < 0 && boldIndex != null) {
      resolved = boldIndex;
      answerSource = 'bold';
    }
    if (resolved >= 0) {
      answerSource = keyLetter != null ? 'key' : answerSource;
    }
    if (markerMismatch) {
      // The markers disagree with the columns: the answer cannot be
      // verified, so the row stays pending (below) and the reason is
      // reported in the preview via ParseResult.errors — never
      // silently reassigned to another option.
      final shortQ =
          qText.length > 40 ? '${qText.substring(0, 40)}…' : qText;
      errors.add(
        'Table row "$shortQ": option markers disagree with the '
        'columns (e.g. a "B." marker in the A column) — the answer '
        'cannot be verified, so the row is left pending.',
      );
    }
    if (keyLetter != null && correct >= 0) {
      final shortQ = qText.length > 40 ? '${qText.substring(0, 40)}…' : qText;
      if (tickIndex != null && tickIndex != correct) {
        conflicts.add(
          'Table row "$shortQ": key says '
          '${String.fromCharCode(65 + correct)} but the tick is on '
          '${String.fromCharCode(65 + tickIndex)} — using the key.',
        );
      }
      if (boldIndex != null && boldIndex != correct) {
        conflicts.add(
          'Table row "$shortQ": key says '
          '${String.fromCharCode(65 + correct)} but the bold option is '
          '${String.fromCharCode(65 + boldIndex)} — using the key.',
        );
      }
    }
    if (resolved >= 0 && resolved < 4) {
      if (keyLetter != null) keyedRows++;
      questions.add(
        Question(
          text: qText,
          options: opts,
          correctIndex: resolved,
          subject: subject,
          sourceId: sourceId,
          sourceLabel: sourceLabel,
          page: page,
          part: part,
          answerSource: answerSource,
          answerVerified: conflicts.length == conflictsBefore,
        ),
      );
    } else {
      pending.add(
        PendingQuestion(
          text: qText,
          options: opts,
          subject: subject,
          page: page,
          part: part,
          reason: markerMismatch
              ? 'option-marker-mismatch'
              : 'no-key-entry',
          number: number,
          paper: paper,
        ),
      );
    }
  }
}

/// The subject for a table row, from the nearest preceding section
/// heading ("Adjective and its Types" → English) or the table's title
/// line ("Computer Most Important Questions" → Maths & Computer).
/// A non-grammar heading falls back to [fallback] — never guessed.
/// Keywords are topic words, not the book's title: 'computer' maps to
/// Maths & Computer; English-grammar topics (interjection, gerund,
/// participle, …) map to English.
Subject _tableSubjectFor(
  List<_TableCell> allCells,
  int questionLineIndex,
  Subject fallback,
) {
  // Cells per line (for the lone-line checks below).
  final perLine = <int, int>{};
  for (final c in allCells) {
    perLine[c.lineIndex] = (perLine[c.lineIndex] ?? 0) + 1;
  }
  var heading = '';
  for (final c in allCells) {
    if (c.lineIndex >= questionLineIndex) break;
    // A section heading ("Adjective and its Types") or an in-table
    // heading row ("Interjection", "Gerund / Infinitives /
    // Participle") — the latter only when alone on its line.
    if (_isTableSectionHeading(c.text) ||
        (perLine[c.lineIndex] == 1 && _isTableHeadingRow(c.text))) {
      heading = c.text;
    }
  }
  // The table title: the first line, when it is a lone cell (it is not
  // a section heading, so the loop above never catches it).
  var title = '';
  if (allCells.isNotEmpty) {
    final firstLine = allCells
        .map((c) => c.lineIndex)
        .reduce((a, b) => a < b ? a : b);
    if (perLine[firstLine] == 1) {
      title =
          allCells.firstWhere((c) => c.lineIndex == firstLine).text;
    }
  }
  final lower = '$heading $title'.toLowerCase();
  if (lower.contains('computer')) return Subject.mathsComputer;
  if (lower.contains('adjective') ||
      lower.contains('article') ||
      lower.contains('noun') ||
      lower.contains('verb') ||
      lower.contains('adverb') ||
      lower.contains('pronoun') ||
      lower.contains('interjection') ||
      lower.contains('gerund') ||
      lower.contains('participle') ||
      lower.contains('infinitive') ||
      lower.contains('tense') ||
      lower.contains('preposition') ||
      lower.contains('conjunction') ||
      lower.contains('parts of speech') ||
      lower.contains('grammar') ||
      lower.contains('english')) {
    return Subject.english;
  }
  return fallback;
}

/// Column-wise table: the OCR order for a scanned table page — N
/// questions, then N option-A values, then N option-B, N option-C,
/// N option-D, then N key letters, then N type labels. The key run is
/// the anchor: the longest run of consecutive key-letter cells must be
/// ≥ 3 (G7 Phase A: was ≥ 5). The pre-key region must group into exactly 5N items (N
/// questions + 4N option values); anything else is not a table, and the
/// function returns empty (the normal block flow then handles the text).
TableParseResult _parseTableColumnWise(
  List<SegmentedLine> lines, {
  BookStructure? structure,
  required String sourceId,
  required String sourceLabel,
  Subject defaultSubject = Subject.gk,
}) {
  final cells = _tableCells(lines);
  // Longest run of consecutive key-letter cells.
  var bestStart = -1;
  var bestLen = 0;
  var runStart = -1;
  for (var i = 0; i <= cells.length; i++) {
    final isKey =
        i < cells.length && _tableKeyLetterRe.hasMatch(cells[i].text);
    if (isKey && runStart < 0) runStart = i;
    if (!isKey && runStart >= 0) {
      final len = i - runStart;
      if (len > bestLen) {
        bestLen = len;
        bestStart = runStart;
      }
      runStart = -1;
    }
  }
  // G7 (Phase A): the key run minimum is 3, not 5 — a small table
  // (3–4 rows, e.g. a chapter-end drill) is still a table. The
  // exact-5N grouping check below is the real guard against
  // non-table text, so the lower run minimum does not weaken it.
  if (bestLen < 3) return const TableParseResult();
  final n = bestLen;
  final ks = bestStart;
  // Type labels directly after the key run. A label the strict
  // checker does not recognise ("article a/is") is still table
  // structure, not a question — so the loop counts any short,
  // digit-free, question-free cell (≤ 45 chars, ≤ 4 words) as a label
  // and consumes it. The row is parsed either way.
  var typeCount = 0;
  var j = ks + n;
  while (j < cells.length && _isTableLabelish(cells[j].text)) {
    typeCount++;
    j++;
  }
  // The pre-key region holds the questions first, then the 4 option
  // columns. Group it into items; expect exactly 5N.
  final preKey = cells.sublist(0, ks);
  var items = _groupTableItems(preKey);
  if (items.length != 5 * n && items.length > 5 * n) {
    // Repair: a very short fragment the grouping split off its
    // question. Merge short items in the presumed question region
    // (the first items.length - 4N) back into the previous item, then
    // re-check.
    final qRegionLen = items.length - 4 * n;
    final repaired = <List<_TableCell>>[];
    for (var k = 0; k < items.length; k++) {
      final item = items[k];
      final text = item.map((c) => c.text).join(' ');
      final words = text.split(RegExp(r'\s+')).length;
      if (k < qRegionLen &&
          k > 0 &&
          words <= 2 &&
          text.length <= 12 &&
          repaired.isNotEmpty) {
        repaired.last.addAll(item);
      } else {
        repaired.add(item);
      }
    }
    items = repaired;
  }
  if (items.length != 5 * n) {
    return TableParseResult(
      errors: [
        'Table format lagta hai (key column mein $n answers mile) '
        'lekin sawal/options saaf nahi parhe — "Best quality (Gemini)" '
        'OCR se dobara try karein, ya AI se MCQs banayein.',
      ],
    );
  }
  final sink = _TableSink();
  final questionItems = items.sublist(0, n);
  final optionItems = items.sublist(n); // A1..AN, B1..BN, C1..CN, D1..DN
  final keyCells = cells.sublist(ks, ks + n);
  for (var i = 0; i < n; i++) {
    final qCells = questionItems[i];
    final qText = qCells.map((c) => c.text).join(' ');
    final optCells = [
      optionItems[i],
      optionItems[n + i],
      optionItems[2 * n + i],
      optionItems[3 * n + i],
    ];
    final opts = [
      for (final oc in optCells) oc.map((c) => c.text).join(' '),
    ];
    final rowCells = [
      ...qCells,
      for (final oc in optCells) ...oc,
      keyCells[i],
    ];
    // G1 (Phase A): pass the tick/bold signals through, like the
    // row-wise path does — a key-less column-wise row that is only
    // tick/bold-marked used to become pending instead of answered,
    // and a key-vs-tick/bold disagreement was never recorded as a
    // conflict. Each option item may span several cells (a wrapped
    // option); a mark on any of its cells marks that option.
    int? tickIndex;
    int? boldIndex;
    for (var k = 0; k < optCells.length && k < 4; k++) {
      if (tickIndex == null && optCells[k].any((c) => c.tick)) {
        tickIndex = k;
      }
      if (boldIndex == null && optCells[k].any((c) => c.bold)) {
        boldIndex = k;
      }
    }
    sink.addRow(
      rowCells: rowCells,
      questionText: qText,
      options: opts,
      keyLetter: keyCells[i].text,
      tickIndex: tickIndex,
      boldIndex: boldIndex,
      page: qCells.first.page,
      paper: qCells.first.paper,
      part: structure?.partForLine(qCells.first.lineIndex) ?? '',
      subject: _tableSubjectFor(
        cells,
        qCells.first.lineIndex,
        defaultSubject,
      ),
      sourceId: sourceId,
      sourceLabel: sourceLabel,
    );
  }
  // Section headings / column headers are structure: consume them so
  // the block loop never turns them into a question.
  for (final c in cells) {
    if (_isTableSectionHeading(c.text) || _isTableColumnHeader(c.text)) {
      sink.consumed.add(c.lineIndex);
    }
  }
  for (var k = 0; k < typeCount; k++) {
    sink.consumed.add(cells[ks + n + k].lineIndex);
  }
  return TableParseResult(
    questions: sink.questions,
    pending: sink.pending,
    consumedLineIndices: sink.consumed,
    skipped: sink.skipped,
    errors: sink.errors,
    conflicts: sink.conflicts,
    fiveOptionNormalised: sink.fiveOptionNormalised,
    fiveOptionAnswerE: sink.fiveOptionAnswerE,
  );
}

/// Subject words for a non-grammar table's type column ("Geography",
/// "Maths", "Science"). Used by the row-wise anchor: a type label is
/// a category name, not a sentence fragment — "The doctor
/// recommended" and "Choose the correct sentence" are not labels.
const _tableSubjectLabelWords = {
  'geography',
  'maths',
  'mathematics',
  'math',
  'science',
  'history',
  'physics',
  'chemistry',
  'biology',
  'english',
  'urdu',
  'islamiat',
  'islamic',
  'islamiyat',
  'pakistan',
  'current',
  'affairs',
  'general',
  'knowledge',
  'computer',
  'economics',
  'everyday',
  'world',
  'international',
  'national',
  'studies',
};

/// True when [line] is a type label that can anchor a row-wise row:
/// a strict grammar label, or a subject category (1–3 words, every
/// word a subject word). A sentence fragment ("The doctor
/// recommended", "Choose the correct sentence") is never a label.
bool _isTableAnchorLabel(String line) {
  if (_isTableTypeLabel(line)) return true;
  final t = stripBoldMarkers(line).trim();
  if (t.isEmpty || t.length > 32) return false;
  if (RegExp(r'[0-9?!\[\]{}|/\\]').hasMatch(t)) return false;
  final words = t.split(RegExp(r'\s+'));
  if (words.isEmpty || words.length > 3) return false;
  return words.every(
    (w) => _tableSubjectLabelWords.contains(
      w.replaceAll(RegExp(r'[.,;:]+$'), '').toLowerCase(),
    ),
  );
}

/// True when [line] looks like a trailing topic-label cell right
/// after a row's key letter ("Gerund", "Identification of Parts of
/// Speech", "Corelative Conjunction" — the interjection table,
/// 20 Nov 2026): short (≤ 45 chars, ≤ 5 words), no digits, no '?'.
/// Looser than [_isTableTypeLabel] (the vocabulary cannot know every
/// topic) — the caller must ALSO require the same line as the key, so
/// a following row's stem can never be eaten.
bool _isTableTrailingLabel(String line) {
  final t = stripBoldMarkers(line).trim();
  if (t.isEmpty || t.length > 45) return false;
  if (RegExp(r'[0-9?]').hasMatch(t)) return false;
  if (_tableKeyLetterRe.hasMatch(t)) return false;
  return t.split(RegExp(r'\s+')).length <= 5;
}

/// True when [line] could be an option value in a table row: 1–10
/// words, 3–60 chars, no letter prefix ("A) …" is a standard block,
/// not a table row), not a type label, not a heading, and not a
/// question tail. A line ending in '?' is a question, never an option;
/// a line ending in ':' is an option only when it is a real sentence
/// (≥ 15 chars — "The high you go, the cooler it is:"), never a bare
/// tail ("is:"). A single A–D letter IS an option here: the article
/// "a" is printed as "A" (row 27: options "A", "An", "The", "None of
/// these") — the key anchor after the run is what confirms the row,
/// not the letter itself.
bool _isTableOptionLine(String line) {
  final t = stripBoldMarkers(line).trim();
  if (t.isEmpty) return false;
  // A bare option MARKER with no text — "(A)", "A.", "B)" — is a
  // marker, not option content. On garbled OCR (Paper 60 tail:
  // "23. All / follo / (A) (B) (C) (D) / 24. Bi …") bare marker
  // lines otherwise collect as option cells AND as key anchors and
  // invent table rows (Phase A failure loop: the G7 minimum
  // 3→2 admitted a 2-row fragment "table"). A bare letter with NO
  // marker punctuation ("A" — the article option in a grammar
  // table) is still an option; only the explicit-marker shapes
  // are rejected.
  if (RegExp(r'^\(\s*[A-Da-d]\s*\)\s*$').hasMatch(t) ||
      RegExp(r'^[A-Da-d]\s*[\)\.\:]\s*$').hasMatch(t)) {
    return false;
  }
  if (_tableArticleLetterRe.hasMatch(t)) return true;
  // The pronoun "I" as an option value ("I", "Helped", "Him",
  // "I helped" — the interjection table Q243/Q244, 20 Nov 2026). A
  // question stem is never a lone "I" (it fails
  // [_looksLikeCompleteQuestion]), so this cannot eat a stem.
  if (t == 'I' || t == 'i') return true;
  // A bare number ("3", "42") is a numeric option value — the maths
  // row "What is 2 + 2?" has options 3/4/5/6. (The segmenter keeps
  // bare-digit runs of ≥ 3 for exactly this; see [_isNumericOptionRun]
  // in answer_key.dart.)
  if (RegExp(r'^\d{1,4}$').hasMatch(t)) return true;
  // Two-letter options ("An", "At", "Of") are real — the article
  // "a" is one letter, its companions are two. Single characters
  // other than A–D are not options.
  if (t.length < 2 || t.length > 60) return false;
  final words = t.split(RegExp(r'\s+'));
  // 10, not 8: a real option reaches 9 words ("right click worksheet
  // range object & choose format object" — the computer table Q80,
  // 20 Nov 2026). The key anchor after the run is what confirms the
  // row, not the option length.
  if (words.isEmpty || words.length > 10) return false;
  if (t.endsWith('?')) return false;
  if (t.endsWith(':') && t.length < 15) return false;
  if (_optionRe.hasMatch(t)) return false;
  // NOTE: type-label words are NOT excluded here. In a grammar table
  // the options ARE grammar terms ("Noun", "Verb", "Adjective") — the
  // key letter after the run is what confirms the row, not the option
  // vocabulary.
  if (_isTableSectionHeading(t) || _isTableColumnHeader(t)) return false;
  return true;
}

/// True when the joined [bufferText] looks like a complete question:
/// long enough to be a question, or closed by sentence punctuation.
bool _looksLikeCompleteQuestion(String bufferText) {
  final t = bufferText.trim();
  return t.length >= 15 || RegExp(r'[.?:!]$').hasMatch(t);
}

/// Collects the option run starting at [cells[i]]: consecutive
/// option-like cells, up to 5 (a 5-option table is normalised to 4).
/// A single A–D letter is an option while the run is short, but after
/// 4 options the next single letter is the key, not a 5th option — the
/// run stops there so the anchor can read it. Returns the run
/// (possibly empty). Pure lookahead — consumes nothing.
List<_TableCell> _collectTableOptionRun(
  List<_TableCell> cells,
  int i,
  Map<int, int> cellsPerLine,
) {
  final run = <_TableCell>[];
  for (var k = i; k < cells.length && run.length < 5; k++) {
    if (_tableKeyLetterRe.hasMatch(cells[k].text) && run.length >= 4) break;
    final cellText = cells[k].text;
    // The trailing topic-label cell ("Gerund", "Infinitive" — the
    // interjection table, 20 Nov 2026) is option-like, so without
    // this it is swallowed as a 5th option and a key-less row loses
    // its anchor entirely. Stop the run at 4 when the next cell
    // looks like a label on the same line and the cell after it is
    // the next row's Sr.# (a bare number): a genuine 5th option is
    // followed by its key letter, never by a bare number.
    if (run.length == 4 &&
        k + 1 < cells.length &&
        cells[k].lineIndex == run.last.lineIndex &&
        _isTableTrailingLabel(cellText) &&
        RegExp(r'^\d{1,4}$').hasMatch(cells[k + 1].text)) {
      break;
    }
    var optionLike = _isTableOptionLine(cellText);
    if (!optionLike && (cellsPerLine[cells[k].lineIndex] ?? 0) > 1) {
      // An option cell with an explicit marker ("A. Home tab" — the
      // Computer table, 20 Nov 2026) is an option when it sits on a
      // multi-cell ('|') line: the marker + the row structure prove
      // it. On a lone line, "A. ..." is a standard-block option line
      // and must stay out of the table pass (see
      // [_isTableOptionLine]). The marker is stripped first so the
      // content is judged as a bare option.
      final m =
          _optionMarkerRe.firstMatch(stripBoldMarkers(cellText).trim());
      if (m != null) optionLike = _isTableOptionLine(m.group(2)!);
    }
    if (!optionLike) break;
    run.add(cells[k]);
  }
  return run;
}

/// Row-wise table: question line(s) + 4 bare option lines + key letter
/// + type label, repeated. A row is confirmed ONLY by the anchor after
/// its options: a key letter, or a type label (a strict grammar label
/// or a subject category). A "next line looks like a question" anchor
/// is deliberately NOT used: on garbled OCR text almost any short line
/// looks like a question, and it invents rows. A key-less row becomes
/// answer-pending. A 5-cell run
/// whose first cell is a short fragment after a ':' question is a
/// question tail, not an option ("…parts of speech word:" + "much" +
/// 4 options) — the tail goes back into the question. Requires ≥ 2
/// rows (G7 Phase A: was ≥ 3 — a 2-row drill table is still a table,
/// and the anchor requirement is the real guard), else this was not
/// a table.
TableParseResult _parseTableRowWise(
  List<SegmentedLine> lines, {
  BookStructure? structure,
  required String sourceId,
  required String sourceLabel,
  Subject defaultSubject = Subject.gk,
}) {
  final cells = _tableCells(lines);
  final sink = _TableSink();
  var buffer = <_TableCell>[];
  var bufferText = '';
  var bufferEndsColon = false;
  // The Sr.# value of the row being built (null when unknown).
  int? rowNumber;
  // Cells per source line: an in-table section heading is alone on
  // its line, a data row never is.
  final cellsPerLine = <int, int>{};
  for (final c in cells) {
    cellsPerLine[c.lineIndex] = (cellsPerLine[c.lineIndex] ?? 0) + 1;
  }
  // Header lines and title lines (Sr.# table, 20 Nov 2026): a line is
  // a header line when any of its cells is a column header ("Sr.#",
  // "Question", "Ans"); a lone line immediately before a header line
  // is the table's title ("Computer Most Important Questions"). Both
  // are skipped in the loop below — without this, the title buffers
  // as a stem and pairs with the header's A–D as options, a spurious
  // pending question (OCR probe verdict). A title never ends with
  // '?' / '؟' / ':' and is never a question start — an instruction
  // stem ("Choose the correct answer:") is protected by that.
  final headerLines = <int>{};
  for (final c in cells) {
    if (_isTableColumnHeader(c.text)) headerLines.add(c.lineIndex);
  }
  final titleLines = <int>{};
  {
    final lineOrder = <int>[];
    for (final c in cells) {
      if (lineOrder.isEmpty || lineOrder.last != c.lineIndex) {
        lineOrder.add(c.lineIndex);
      }
    }
    for (var k = 0; k + 1 < lineOrder.length; k++) {
      if (cellsPerLine[lineOrder[k]] == 1 &&
          headerLines.contains(lineOrder[k + 1])) {
        final t = cells
            .firstWhere((c) => c.lineIndex == lineOrder[k])
            .text
            .trim();
        if (!t.endsWith('?') &&
            !t.endsWith('؟') &&
            !t.endsWith(':') &&
            _questionNumber(t) == null) {
          titleLines.add(lineOrder[k]);
        }
      }
    }
  }
  // Row-number trust (interjection table, 20 Nov 2026): the book's
  // own Sr.# can be wrong (162, 164 after 251/253). A number is
  // trusted only when it exceeds every earlier number (a new
  // maximum); anything else is out of sequence and must never join
  // an answer by number, so the row carries no number. Answered
  // rows are unaffected — their Ans letter is positional, in-row.
  var maxRowNumber = 0;
  String? numberingBreak;
  void recordSerial(int n) {
    if (n > maxRowNumber) {
      maxRowNumber = n;
      rowNumber = n;
    } else {
      numberingBreak ??= '$n after $maxRowNumber';
      rowNumber = null;
    }
  }

  var i = 0;
  while (i < cells.length) {
    final cell = cells[i];
    final t = cell.text;
    if (_isTableSectionHeading(t) || _isTableColumnHeader(t)) {
      i++;
      continue;
    }
    // Title line (see above): never content. Consumed, so the block
    // pass never sees it either.
    if (titleLines.contains(cell.lineIndex)) {
      sink.consumed.add(cell.lineIndex);
      i++;
      continue;
    }
    // A header row's A–D cells are column labels, not options. (The
    // header line is recognised by its other cells — "Sr.#",
    // "Question", "Ans" — so a data row's single-letter options are
    // unaffected: they sit on data lines, never header lines.)
    if (headerLines.contains(cell.lineIndex) &&
        _tableKeyLetterRe.hasMatch(t)) {
      i++;
      continue;
    }
    // A page footer ("Page 1 of 71") is never content — skip it so
    // it cannot join the next row's stem.
    if (_isTablePageFooter(t)) {
      i++;
      continue;
    }
    // An in-table section heading ("Interjection", "Parts of Speech
    // Identification" — the interjection table, 20 Nov 2026): a lone
    // short phrase on its own line, followed by the next row's Sr.#.
    // Without this, the heading buffers into the next row's stem.
    // The guards keep real stems safe: a stem is never alone on its
    // line in a '|' table (its row shares the line), and a stem is
    // never followed by a bare number (its options follow it).
    if (buffer.isEmpty &&
        cellsPerLine[cell.lineIndex] == 1 &&
        _isTableHeadingRow(t) &&
        i + 1 < cells.length &&
        RegExp(r'^\d{1,4}$').hasMatch(cells[i + 1].text)) {
      sink.consumed.add(cell.lineIndex);
      i++;
      continue;
    }
    // A bare serial number ("1", "27") with an empty question buffer
    // is the Sr.# column value, not a question start — record it as
    // the row's number and skip it, so it never joins the stem.
    // (A stem that genuinely opens with a bare year would lose it
    // here — the same documented ambiguity as
    // [_stripQuestionNumberPrefix]; a Sr.# column is far more common
    // in these tables than a year-opening stem.)
    if (buffer.isEmpty && RegExp(r'^\d{1,4}$').hasMatch(t)) {
      recordSerial(int.parse(t));
      i++;
      continue;
    }
    // A row starts only after a complete-looking question.
    if (buffer.isNotEmpty && _looksLikeCompleteQuestion(bufferText)) {
      var run = _collectTableOptionRun(cells, i, cellsPerLine);
      if (run.length == 4 || run.length == 5) {
        var j = i + run.length;
        String? keyLetter;
        String? typeLabel;
        if (j < cells.length && _tableKeyLetterRe.hasMatch(cells[j].text)) {
          keyLetter = cells[j].text;
          j++;
        }
        if (j < cells.length && _isTableAnchorLabel(cells[j].text)) {
          typeLabel = cells[j].text;
          j++;
        }
        // Trailing topic-label column ("Gerund", "Identification of
        // Parts of Speech" — the interjection table, 20 Nov 2026):
        // the cell right after the key, on the SAME line, that looks
        // like a label belongs to this row even when the label
        // vocabulary does not know the words. Without this, the label
        // buffers into the next row's stem. The same-line guard is
        // what keeps a following row's stem safe: a stem lives on its
        // own line. (Deliberately NOT used in the 5-cell recovery
        // below: there a short 5th cell can be a real 5th option.)
        if (typeLabel == null &&
            j < cells.length &&
            cells[j].lineIndex == cells[j - 1].lineIndex &&
            _isTableTrailingLabel(cells[j].text)) {
          typeLabel = cells[j].text;
          j++;
        }
        var anchored = keyLetter != null || typeLabel != null;
        // Recovery: a 5-cell run whose last cell is a type label — the
        // no-key row (4 options + label) at the END of the book, with
        // no line after it to anchor it. The label was swallowed as a
        // 5th option; strip it back out and the row is anchored. The
        // check is STRICT (a real type label, not any short line):
        // on garbled OCR a loose check strips real option fragments
        // ("Bring me__", "Choose the correct sentence") and invents
        // rows. (A genuine 5-option row is unaffected: its line after
        // the run is a key letter, so `anchored` is already true.)
        if (!anchored &&
            run.length == 5 &&
            _isTableAnchorLabel(run.last.text)) {
          typeLabel = run.last.text;
          run = run.sublist(0, 4);
          j = i + run.length + 1; // Past the 4 options and the label.
          anchored = true;
        }
        if (anchored) {
          // A 5-cell run after a ':' question whose first cell is a
          // short fragment is a question tail ("much"), not an option.
          if (run.length == 5 && bufferEndsColon) {
            final first = run.first.text;
            final firstWords = first.split(RegExp(r'\s+')).length;
            if (firstWords <= 2 && first.length <= 12) {
              buffer.add(run.first);
              bufferText = '$bufferText ${run.first.text}'.trim();
              bufferEndsColon = false;
              run = _collectTableOptionRun(cells, i + 1, cellsPerLine);
              if (run.length != 4) {
                // Not a row after all — the "options" were a wrap.
                i++;
                continue;
              }
              j = i + 1 + run.length;
              keyLetter = null;
              typeLabel = null;
              if (j < cells.length &&
                  _tableKeyLetterRe.hasMatch(cells[j].text)) {
                keyLetter = cells[j].text;
                j++;
              }
              if (j < cells.length && _isTableAnchorLabel(cells[j].text)) {
                typeLabel = cells[j].text;
                j++;
              }
              if (typeLabel == null &&
                  j < cells.length &&
                  cells[j].lineIndex == cells[j - 1].lineIndex &&
                  _isTableTrailingLabel(cells[j].text)) {
                typeLabel = cells[j].text;
                j++;
              }
              // Re-check the anchor after the tail move: without a
              // key, a type label, or a new question next, this is a
              // wrap, not a row.
              final reAnchored = keyLetter != null || typeLabel != null;
              if (!reAnchored) {
                i++;
                continue;
              }
            }
          }
          final opts = [for (final c in run) c.text];
          final rowCells = [...buffer, ...run];
          // j points past the key and type cells: the type (if any)
          // is cells[j-1], the key (if any) is the cell before it.
          if (typeLabel != null) rowCells.add(cells[j - 1]);
          if (keyLetter != null) {
            rowCells.add(cells[typeLabel != null ? j - 2 : j - 1]);
          }
          int? tickIndex;
          int? boldIndex;
          for (var k = 0; k < run.length && k < 4; k++) {
            if (run[k].tick && tickIndex == null) tickIndex = k;
            if (run[k].bold && boldIndex == null) boldIndex = k;
          }
          sink.addRow(
            rowCells: rowCells,
            questionText: bufferText,
            options: opts,
            keyLetter: keyLetter,
            tickIndex: tickIndex,
            boldIndex: boldIndex,
            page: buffer.first.page,
            number: rowNumber,
            paper: buffer.first.paper,
            part: structure?.partForLine(buffer.first.lineIndex) ?? '',
            subject: _tableSubjectFor(
              cells,
              buffer.first.lineIndex,
              defaultSubject,
            ),
            sourceId: sourceId,
            sourceLabel: sourceLabel,
          );
          buffer = [];
          bufferText = '';
          bufferEndsColon = false;
          rowNumber = null;
          i = j;
          continue;
        }
        // Not a row — the "options" were a question wrap.
      }
    }
    // A stray key letter outside a row is not content. A stray
    // type-label line is skipped only between rows (empty buffer):
    // inside a question it may be an option value ("Noun",
    // "Adjective" are both), so it must reach the run attempt /
    // buffer instead. A garbled label ("article a/is") is still a
    // label — see [_isStrayTableLabel] — and must never prefix the
    // next question's stem.
    if (_tableKeyLetterRe.hasMatch(t) ||
        (buffer.isEmpty && _isStrayTableLabel(t))) {
      i++;
      continue;
    }
    // Bound the question buffer: a real table question wraps at most
    // 4 lines (~400 chars). Without the bound, garbled OCR text
    // accumulates into a giant blob that eventually "matches" a random
    // run of short lines and becomes a nonsense row. When the buffer
    // overflows, drop it and start fresh at this line. (G7 Phase A:
    // 3 lines / 200 chars was too tight — a full example sentence as
    // a stem wraps to 3 lines and can exceed 200 chars.)
    if (buffer.length >= 4 || bufferText.length > 400) {
      if (RegExp(r'^\d{1,4}$').hasMatch(t)) {
        recordSerial(int.parse(t));
        buffer = [];
        bufferText = '';
      } else {
        buffer = [cell];
        bufferText = t;
        rowNumber = null;
      }
      bufferEndsColon = t.trim().endsWith(':');
      i++;
      continue;
    }
    buffer.add(cell);
    bufferText = bufferText.isEmpty ? t : '$bufferText $t';
    bufferEndsColon = t.trim().endsWith(':');
    i++;
  }
  if (numberingBreak != null) {
    sink.errors.add(
      'Table Sr.# out of sequence ($numberingBreak) — out-of-sequence '
      'row numbers cannot be trusted, so those rows carry no number '
      'for key matching. They can still be answered by hand.',
    );
  }
  final totalRows = sink.questions.length + sink.pending.length;
  if (totalRows < 2) {
    return const TableParseResult();
  }
  // Small-table guard (Phase A failure loop): a table of < 3 rows is
  // accepted ONLY when every row is key-anchored. Proof: the F16
  // organisation file's fact lists ("Competitive Exam ESTABLISHED
  // MARCH 17, 1958" + MEMBER / HEADQUARTER / … fact lines) form 2
  // bold-anchored "rows" with no key — lowering the minimum to 2
  // without this guard parsed them as 2 fake MCQs
  // (org_realfile_test went 0 → 2). A genuine 2-row table carries
  // its key letters, so keyed rows still parse. Rejection returns
  // EMPTY (no consumed lines), so the lines fall through to the
  // block / flashcard handling instead of vanishing.
  if (totalRows < 3 && sink.keyedRows < totalRows) {
    return const TableParseResult();
  }
  for (final c in cells) {
    if (_isTableSectionHeading(c.text) ||
        _isTableColumnHeader(c.text) ||
        _isTablePageFooter(c.text)) {
      sink.consumed.add(c.lineIndex);
    }
  }
  return TableParseResult(
    questions: sink.questions,
    pending: sink.pending,
    consumedLineIndices: sink.consumed,
    skipped: sink.skipped,
    errors: sink.errors,
    conflicts: sink.conflicts,
    fiveOptionNormalised: sink.fiveOptionNormalised,
    fiveOptionAnswerE: sink.fiveOptionAnswerE,
  );
}

/// Table-format entry point: tries column-wise first (the OCR order
/// for a scanned table page), then row-wise (a text PDF / Gemini
/// vision rows). Returns empty when the text is not a table. When the
/// text LOOKS like a table (type labels present) but no scored row was
/// parsed, a short Roman-Urdu hint is returned in [errors] so the
/// upload dialog can tell the user what to try next instead of a bare
/// "No MCQs found". Pending (unanswered) rows are kept alongside the
/// hint — they are never presented as correct answers.
TableParseResult parseTableFormat(
  List<SegmentedLine> lines, {
  BookStructure? structure,
  required String sourceId,
  required String sourceLabel,
  Subject defaultSubject = Subject.gk,
}) {
  final columnWise = _parseTableColumnWise(
    lines,
    structure: structure,
    sourceId: sourceId,
    sourceLabel: sourceLabel,
    defaultSubject: defaultSubject,
  );
  if (columnWise.questions.isNotEmpty || columnWise.pending.isNotEmpty) {
    return columnWise;
  }
  final rowWise = _parseTableRowWise(
    lines,
    structure: structure,
    sourceId: sourceId,
    sourceLabel: sourceLabel,
    defaultSubject: defaultSubject,
  );
  if (rowWise.questions.isNotEmpty) {
    return rowWise;
  }
  // No SCORED row was found. If the text is table-shaped (many type
  // labels) the user gets the hint even when a few pending rows
  // survived: on garbled OCR the row-wise machine can assemble
  // plausible-looking but wrong pending rows from the jumbled columns,
  // and "try best-quality OCR" is the honest guidance. The pending
  // rows are kept alongside the hint (they are unanswered, so no wrong
  // answer is ever presented as correct).
  final cells = _tableCells(lines);
  var typeLabels = 0;
  for (final c in cells) {
    if (_isTableTypeLabel(c.text)) typeLabels++;
  }
  final errors = <String>[
    ...columnWise.errors,
    ...rowWise.errors,
  ];
  if (errors.isEmpty && typeLabels >= 5) {
    errors.add(
      'Table format lagta hai (type labels mile: $typeLabels) lekin '
      'sawal/options/key saaf nahi parhe — "Best quality (Gemini)" OCR '
      'se dobara try karein, ya AI se MCQs banayein.',
    );
  }
  return TableParseResult(
    questions: rowWise.questions,
    pending: rowWise.pending,
    consumedLineIndices: rowWise.consumedLineIndices,
    skipped: rowWise.skipped,
    errors: errors,
    conflicts: rowWise.conflicts,
    fiveOptionNormalised: rowWise.fiveOptionNormalised,
    fiveOptionAnswerE: rowWise.fiveOptionAnswerE,
  );
}

/// Shared implementation for [parseMcqs] and [parseMcqsFromPages].
/// [structure] is null for the string path (no parts, part '').
ParseResult _parseImpl(
  SegmentedText segmented, {
  BookStructure? structure,
  required String sourceId,
  required String sourceLabel,
  Subject defaultSubject = Subject.gk,
  // OCR provenance (governing spec 19 Nov 2026): 1-based pages whose
  // text came from OCR, and the provenance for text with no page
  // (the string path). A tick/bold mark on an OCR page could be the
  // student's pen, not the book's — see the post-processing below.
  Set<int> ocrPages = const {},
  String markProvenance = 'printed',
}) {
  final questions = <Question>[];
  final errors = <String>[];
  final conflicts = <String>[];
  final formatCounts = <String, int>{
    'block': 0,
    'one-liner': 0,
    'q-only': 0,
    'table': 0,
  };
  final answerSources = <String, int>{};
  final qOnly = <_QOnly>[];
  final candidates = <_AnswerlessCandidate>[];
  var skipped = 0;
  // Declared here (not in the second pass) so the first pass can
  // count key entries it consumes for tick/bold questions (below).
  var keyEntriesApplied = 0;
  // Per-paper key attribution for the preview ("Key 'Paper 60' se N
  // jawab lage") — incremented wherever keyEntriesApplied is.
  final keyAppliedByPaper = <String, int>{};
  // MASTER DIRECTIVE Part 8 (20 Nov 2026): every in-book key join
  // goes through decideKeyMatch (see keyMatchDecisions in
  // answer_key.dart). Only VERIFIED auto-assigns silently; HIGH
  // CONFIDENCE is applied but flagged in keyPaperReport — the upload
  // preview shows the flag and the user's Save is the confirmation
  // (the parser runs before the preview, so the preview + Save is
  // the only existing confirmation path for an in-book key).
  // NEEDS REVIEW / UNVERIFIED / MISMATCH are never applied: their
  // entries are withheld HERE — removed from the join map, so the
  // joins below see no token, the entries are never reported as
  // "unmatched", and the decision reason is reported in
  // keyPaperReport instead.
  final keyDecisions = keyMatchDecisions(
    segmented,
    sourceDocumentId: sourceId,
  );
  final withheldKeyDecisions = <String, KeyMatchDecision>{};
  for (final e in keyDecisions.entries) {
    final d = e.value;
    final applies = d.mayAutoAssign ||
        d.confidence == KeyMatchConfidence.highConfidence;
    if (!applies) {
      withheldKeyDecisions[e.key] = d;
      segmented.keyEntries.remove(e.key);
    }
  }
  // 5→4 normalisation (Examveda), number gaps (MPT), noise filter
  // (Examveda / organisation), fact cards (organisation).
  var fiveOptionNormalised = 0;
  var fiveOptionAnswerE = 0;
  // Line-level noise (bare watermark digits, promo, phone) was already
  // filtered in [segmentLines]; block-level foreign-script noise is
  // added in the block loop below.
  var noiseLinesFiltered = segmented.noiseLinesFiltered;
  // Question numbers, mapped to the pages each number was parsed on
  // (one entry per parsed question — a number parsed twice has two
  // entries). Drives the numbering diagnostics: missing numbers
  // (gaps) and duplicated numbers, both reported WITH page numbers
  // in the preview (a duplicate across a page break is a book error,
  // not a parse error — report it, never silently merge or drop).
  final parsedNumberPages = <int, List<int>>{};
  void recordNumber(int number, int page) {
    parsedNumberPages.putIfAbsent(number, () => <int>[]).add(page);
  }
  final facts = <FactPair>[];
  // Declared here (not in the Q-only pool section below) so the block
  // loop and second pass can exclude defective / "?" questions.
  final excluded = <String>[];
  // Answer-pending questions for AI inference (v1.2): 4 options, no
  // usable answer. Filled by the "?" branches and the unanswered loop.
  final pending = <PendingQuestion>[];
  // The missing-answers report, built alongside the pending list
  // (PPSC-66 §5.5, 20 Nov 2026): one entry per pending question, in
  // the same order — so the report and the pending list can never
  // disagree (the old code built the report from skipped blocks:
  // Q10 appeared twice, Q2 not at all, and '?' / marker-mismatch
  // pendings were missing entirely). [addPending] is the only way
  // to create a pending question in this function; the table pass
  // pendings are noted at the merge below. The wording matches the
  // old report exactly for the cases it covered.
  final questionsMissingAnswers = <String>[];
  void noteMissingAnswer(PendingQuestion p, {String? failedToken}) {
    final label = p.number != null
        ? '${p.paper} Q${p.number}'
        : '${p.paper} (unnumbered)';
    final detail = failedToken != null
        ? '— key entry "$failedToken" matches no option'
        : p.reason == 'unknown-key'
            ? '— answer unknown (the answer key says "?")'
            : p.reason == 'option-marker-mismatch'
                ? '— option markers disagree, answer not trusted'
                : '— no key entry';
    questionsMissingAnswers.add('$label $detail');
  }

  void addPending(PendingQuestion p, {String? failedToken}) {
    pending.add(p);
    noteMissingAnswer(p, failedToken: failedToken);
  }

  // Split into blocks: a new block starts at a question line.
  // A worked-solution block ("Solution:" … "Final Answer:") is one
  // block with its question: its numbered working steps ("2. Let x
  // be …") look like question starts but must never split the block.
  // The solution ends at an answer line (Final Answer / Answer). If a
  // solution has no answer line at all, a question-start line is only
  // treated as a new question when option lines follow it within a
  // few lines (a real question has options; a working step does not).
  final blocks = <List<SegmentedLine>>[];
  var current = <SegmentedLine>[];
  final questionStart = RegExp(
    r'^(Q\s*\d*[\.\)\:]|\d+[\.\)](?!\d))\s*\S',
    caseSensitive: false,
  );
  bool optionsFollow(List<SegmentedLine> lines, int from) {
    var found = 0;
    for (var j = from; j < lines.length && j < from + 8; j++) {
      if (_optionRe.hasMatch(_cleanStored(lines[j].text))) {
        found++;
        if (found >= 2) return true;
      }
    }
    return false;
  }

  // The FIRST option line must be close (within 4 lines of the
  // candidate stem): a genuine stem's own options follow almost
  // immediately — a second stem line, or one junk line
  // ("Mcqsplanet.com"), at most. An explanation-prose line only
  // "sees" the NEXT question's options, 8 lines away — splitting
  // there cuts the current question's prose into the next block and
  // traps the next stem behind it in a prose-first block that can
  // never split again (it has no options yet when the stem arrives),
  // so the trapped question's text ends with prose, not '?', and the
  // pending gate fails. F2 lost 18 pending items exactly this way
  // (a prose line split item 1's block; item 2's stem then sat in
  // the prose-first block and vanished).
  //
  // Length is the second half of the guard: prose lines are long
  // full-width sentences (>70 chars), while genuine stems and their
  // wraps are short instruction lines. If ANY line between the
  // candidate and its first option is long, this is a prose run, not
  // a stem run — do not split. (A genuine long stem in a full-width
  // book would also be blocked; it then merges as it did before the
  // numberless split existed — a missed question, never a
  // fabrication.)
  //
  // Count is the third half: at most TWO non-option lines may sit
  // between the candidate and its first option (a wrapped second
  // stem line + one junk line). Short prose defeats the distance
  // guard alone — a 1-line prose paragraph + a 1-line stem puts the
  // next option 4 lines from the prose line — but then the next
  // stem is ALSO between them, so the count exceeds two and the
  // split is blocked.
  bool firstOptionClose(List<SegmentedLine> lines, int from) {
    for (var j = from; j < lines.length && j < from + 4; j++) {
      final t = _cleanStored(lines[j].text);
      if (_optionRe.hasMatch(t)) return j - from <= 2;
      if (t.length > 70) return false;
    }
    return false;
  }

  var inSolution = false;
  // v1.3: table-format MCQs (a printed Question | A | B | C | D | key |
  // type grid, e.g. the user's CamScanner grammar page). Parsed BEFORE
  // the block loop, and its lines are excluded from it — the Q-only
  // answer pool must never steal a table row that already has its own
  // 4 options + key. G2 (Phase A): each row counts under ITS OWN
  // answerSource ('key' / 'tick' / 'bold') — the old code counted
  // every table row as 'key', so F3's 19 bold-resolved rows showed
  // as "19 key se" in the preview when the truth is "19 bold se".
  // Rows with no usable key go to [pending] for manual correction.
  final table = parseTableFormat(
    segmented.questionLines,
    structure: structure,
    sourceId: sourceId,
    sourceLabel: sourceLabel,
    defaultSubject: defaultSubject,
  );
  if (table.questions.isNotEmpty) {
    questions.addAll(table.questions);
    formatCounts['table'] =
        (formatCounts['table'] ?? 0) + table.questions.length;
    for (final q in table.questions) {
      if (q.answerSource.isNotEmpty) {
        answerSources[q.answerSource] =
            (answerSources[q.answerSource] ?? 0) + 1;
      }
    }
  }
  for (final p in table.pending) {
    addPending(p);
  }
  skipped += table.skipped;
  errors.addAll(table.errors);
  conflicts.addAll(table.conflicts);
  fiveOptionNormalised += table.fiveOptionNormalised;
  fiveOptionAnswerE += table.fiveOptionAnswerE;
  final qLines = segmented.questionLines
      .where((l) => !table.consumedLineIndices.contains(l.lineIndex))
      .toList();
  // v1.2 (File 2): UNNUMBERED questions — a line ending in '?' (or
  // Urdu '؟') with ≥2 option lines following within 8 lines is a
  // question start too (books that print no numbers at all, e.g. the
  // June-2025 Current Affairs pack: "What was the death toll…?" +
  // A. 5 / B. 9 / C. 12 / D. 15 + explanation prose, no answer
  // anywhere). Safety rule against splitting a WRAPPED question
  // (its first line can end in '?' too): a '?' line only splits when
  // the current block is NOT an unfinished question — i.e. the
  // current block already has option lines (previous question done),
  // or its first line is not a question start at all (front matter /
  // header junk). A flashcard question ('?' + short answer, NO
  // options) never splits — optionsFollow is false for it.
  bool isUnnumberedQuestionStart(String clean) =>
      (clean.endsWith('?') || clean.endsWith('؟')) &&
      clean.length > 8;
  // Phase A failure loop (PakMCQs 500 GK): BARE-NUMBERED questions
  // ("3 What colour is vermilion a shade of?" — digits + space, no
  // dot) are question starts too. The '?' terminator is what makes
  // the bare number safe: a list item ("3 apples are red.") or a
  // year ("1917 was …") does not end with '?', and a wrapped
  // question's first line ends mid-sentence, not with '?'. Without
  // this, a bare-numbered book collapses into ONE block and only
  // its first Q&A is ever found (PakMCQs parsed 0/500).
  bool isBareNumberQuestionStart(String clean) =>
      (clean.endsWith('?') || clean.endsWith('؟')) &&
      RegExp(r'^\d+\s+(?![a-z0-9])').hasMatch(clean);
  // True once the current block was started by a split at a question
  // start (numbered, bare-number, '?' or numberless — see below).
  // The initial block is front matter until proven otherwise; a block
  // created by a split IS a question in progress, even when its first
  // line is a numberless stem that matches no question-start regex
  // (PPSC-66 Q2: "Change the voice of the following sentence:" +
  // "Are they blaming us for nothing?" — the second line must NOT
  // split the stem in two).
  var currentIsQuestion = false;
  bool currentHasOptions() => current.any(
        (l) => _optionRe.hasMatch(_cleanStored(l.text)),
      );
  // A plausible question-stem start: more than one word, not a bare
  // domain / junk line ("Mcqsplanet.com", "International"), not a
  // digit start ("92.97m at the Paris 2024 Games." is prose, and a
  // numbered question matches [questionStart] instead), and short
  // enough to be an instruction line rather than a full-width prose
  // sentence. Used both to keep junk/prose lines from STARTING a
  // numberless split and to tell whether a split-created block is
  // really a question in progress (F2: a block starting with prose
  // or junk is not — a '?' tail inside it must still split, so the
  // question survives as the fragment pending it always was).
  bool isPlausibleStemStart(String clean) {
    if (clean.isEmpty) return false;
    if (!clean.contains(' ')) return false;
    if (clean.length > 70) return false;
    if (RegExp(r'^[0-9]').hasMatch(clean)) return false;
    return true;
  }

  bool currentIsUnfinishedQuestion() {
    if (current.isEmpty) return false;
    final first = _cleanStored(current.first.text);
    if (!currentIsQuestion &&
        !questionStart.hasMatch(first) &&
        !isUnnumberedQuestionStart(first)) {
      return false; // Front matter / header — not a question.
    }
    // A numbered first line ("Q177. …") or an unnumbered '?' stem
    // is a question whatever its length: the ≤70 plausibility cap
    // is only for NUMBERLESS, non-'?' first lines (F2 prose/junk).
    // Without this, a long numbered stem (>70 chars) was judged
    // "not a question", so its '?' tail split it away from its head
    // (MPT Q177/Q116: head stranded in the previous block, tail
    // parsed as a fragment, key entry unmatched).
    if (currentIsQuestion &&
        !questionStart.hasMatch(first) &&
        !isUnnumberedQuestionStart(first) &&
        !isPlausibleStemStart(first)) {
      return false; // Split-created, but starts with junk/prose —
      // not a question in progress; a '?' tail may split it.
    }
    return !currentHasOptions();
  }
  // A numberless stem line (PPSC-66 p1: "Give the meaning of Idiom:
  // Spick and Span", "Choose the correct synonym Wheedle:"): not an
  // option, not an answer line, not a numbered/'?' start (those are
  // handled by the branches above). Only ever used as a split
  // trigger together with [currentHasAllOptions] (the previous
  // question is done — a wrap comes BEFORE the options, never after)
  // and [optionsFollow] (a real question's options follow).
  //
  // A wrapped option's tail is NOT a stem (PPSC-66 Q13: "(B) Should
  // the poor be looked down upon by" / "you?" — the tail is short,
  // ends with '?', and the block already has options, so without
  // this guard it splits the question in two and both halves fail).
  // The tail continues the block's last option line — reuse the
  // standard parser's continuation test.
  //
  // Two more guards (20 Nov 2026, found by the full suite):
  // (a) never split an UNFINISHED block — a stem-like line inside a
  // question with fewer than 4 option lines is a running head or a
  // continuation, not a new question (cross_page: "Current Affairs"
  // at the top of page 2, inside Q7 which only had (A)/(B) so far —
  // splitting there cut the question in half and both halves died).
  // Only a block with all 4 option lines is a finished question.
  // (b) never split on a metadata line — "Explanation: ..." and
  // "Subject: ..." belong to the CURRENT question (mcq_parser_test:
  // splitting at "Explanation: Islamabad became the capital in
  // 1967." cut Q1's block before its "Subject: Pakistan Studies"
  // line, so Q1 lost its subject).
  bool currentHasAllOptions() =>
      current.where((l) => _optionRe.hasMatch(_cleanStored(l.text))).length >=
      4;
  bool isOptionContinuationLine(String clean) {
    for (var k = current.length - 1; k >= 0; k--) {
      final t = _cleanStored(current[k].text);
      if (_optionRe.hasMatch(t)) return _isOptionContinuation(t, clean);
    }
    return false;
  }
  bool isNumberlessStemStart(String clean) {
    if (clean.isEmpty) return false;
    if (!isPlausibleStemStart(clean)) return false;
    if (_optionRe.hasMatch(clean)) return false;
    // A 5th option ("E. None of these") is an OPTION, not a stem:
    // without this the split cut 5-option questions apart after D,
    // and the orphaned "E. …" line became a fake q-only question
    // (Examveda: 15+ "E. …" fabrications, and the parent question
    // lost its E option — and its answer when the answer was E).
    if (_optionERe.hasMatch(clean)) return false;
    if (_answerLineRe.hasMatch(clean)) return false;
    if (_explanationRe.hasMatch(clean)) return false;
    if (_subjectRe.hasMatch(clean)) return false;
    if (questionStart.hasMatch(clean)) return false;
    if (isUnnumberedQuestionStart(clean)) return false;
    return true;
  }

  for (var li = 0; li < qLines.length; li++) {
    final line = qLines[li];
    final cleanLine = _cleanStored(line.text);
    if (isSolutionHeading(cleanLine)) {
      inSolution = true;
      current.add(line);
      continue;
    }
    if (inSolution) {
      if (_answerLineRe.hasMatch(cleanLine)) {
        // An answer line ends the solution block.
        inSolution = false;
        current.add(line);
        continue;
      }
      if ((questionStart.hasMatch(cleanLine) ||
              isBareNumberQuestionStart(cleanLine) ||
              (isUnnumberedQuestionStart(cleanLine) &&
                  !currentIsUnfinishedQuestion())) &&
          optionsFollow(qLines, li + 1)) {
        // A real new question (options follow) — the solution had no
        // answer line; end it here and split.
        inSolution = false;
        if (current.isNotEmpty) {
          blocks.add(current);
          current = <SegmentedLine>[];
          currentIsQuestion = true;
        }
        current.add(line);
        continue;
      }
      // Solution working — never a new block.
      current.add(line);
      continue;
    }
    if ((questionStart.hasMatch(cleanLine) ||
            isBareNumberQuestionStart(cleanLine)) &&
        current.isNotEmpty) {
      blocks.add(current);
      current = <SegmentedLine>[];
      currentIsQuestion = true;
    } else if (isUnnumberedQuestionStart(cleanLine) &&
        optionsFollow(qLines, li + 1) &&
        current.isNotEmpty &&
        !currentIsUnfinishedQuestion()) {
      blocks.add(current);
      current = <SegmentedLine>[];
      currentIsQuestion = true;
    } else if (isNumberlessStemStart(cleanLine) &&
        !isOptionContinuationLine(cleanLine) &&
        firstOptionClose(qLines, li + 1) &&
        optionsFollow(qLines, li + 1) &&
        current.isNotEmpty &&
        currentHasAllOptions()) {
      // Numberless stem after a finished question (PPSC-66 p1: Q3–Q9
      // have no number in the OCR — their stems were swallowed into
      // the previous question's block and vanished). A junk line here
      // only forms a block with no usable question, which is skipped,
      // never fabricated.
      blocks.add(current);
      current = <SegmentedLine>[];
      currentIsQuestion = true;
    }
    current.add(line);
  }
  if (current.isNotEmpty) blocks.add(current);

  // Number recovery from sequence position (PPSC-66, 20 Nov 2026):
  // page-edge clipping drops the question numbers (Q1, Q3–Q9 have no
  // number in the OCR), and a numberless block can never join its key
  // entry by number. A run of numberless OPTION-bearing blocks (only
  // those can become questions — junk blocks never consume a number)
  // is numbered by interpolation, ONLY when the run length exactly
  // fills the gap between its numbered neighbours; a leading run
  // before the first numbered block counts back from it (numbering
  // starts at 1). Any mismatch leaves the numbers null — never
  // guess. A trailing run (after the last numbered block) is left
  // null too: a new section may restart numbering there, and
  // guessing forward would join the wrong key entries.
  final recoveredNumbers = List<int?>.filled(blocks.length, null);
  {
    int? blockNumber(int i) {
      final first = blocks[i].first.text;
      final clean = _cleanStored(first);
      return _questionNumber(first) ??
          (isBareNumberQuestionStart(clean)
              ? int.tryParse(
                  RegExp(r'^\d+').firstMatch(clean)!.group(0)!,
                )
              : null);
    }

    // Group by the paper of the block's first OPTION line, not its
    // first line: a block that opens with front matter ("Papers of
    // 2021 521", before the "MODEL PAPER 66" heading) carries the
    // default paper on that line, while its question — and its
    // options — belong to the paper that follows. Grouping by the
    // first line stranded Q1 under "Paper 1" and broke the whole
    // leading run (Q1–Q9 never recovered their numbers).
    String blockPaper(int i) {
      for (final l in blocks[i]) {
        if (_optionRe.hasMatch(_cleanStored(l.text))) return l.paper;
      }
      return blocks[i].first.paper;
    }

    final byPaper = <String, List<int>>{};
    for (var i = 0; i < blocks.length; i++) {
      if (blocks[i].any(
        (l) => _optionRe.hasMatch(_cleanStored(l.text)),
      )) {
        byPaper.putIfAbsent(blockPaper(i), () => []).add(i);
      }
    }
    for (final indices in byPaper.values) {
      int? lastKnown;
      var i = 0;
      while (i < indices.length) {
        final n = blockNumber(indices[i]);
        if (n != null) {
          lastKnown = n;
          i++;
          continue;
        }
        var j = i;
        while (j < indices.length && blockNumber(indices[j]) == null) {
          j++;
        }
        final runLen = j - i;
        final next = j < indices.length ? blockNumber(indices[j]) : null;
        if (next != null &&
            lastKnown != null &&
            next - lastKnown - 1 == runLen) {
          for (var k = 0; k < runLen; k++) {
            recoveredNumbers[indices[i + k]] = lastKnown + 1 + k;
          }
        } else if (next != null &&
            lastKnown == null &&
            next - 1 == runLen) {
          for (var k = 0; k < runLen; k++) {
            recoveredNumbers[indices[i + k]] = k + 1;
          }
        }
        // Otherwise ambiguous (gap != run length, or trailing run):
        // leave null — never guess.
        i = j;
      }
    }
  }

  void bump(String format) {
    formatCounts[format] = (formatCounts[format] ?? 0) + 1;
  }

  void countSource(String source) {
    if (source.isEmpty) return;
    answerSources[source] = (answerSources[source] ?? 0) + 1;
  }

  // "(Note: …)" evidence (109 edition). Every note found is recorded
  // in [allNotes] (transparency — none is dropped); a note attached
  // to a question whose options it does not match, or with no
  // preceding question at all, is also recorded in [unmatchedNotes]
  // (diagnostics). A note is inference EVIDENCE, not an explicit
  // answer — it never outranks a key / tick / bold signal.
  final allNotes = <String>[];
  final unmatchedNotes = <String>[];

  void recordAttachedNote(String note, List<String> options, String where) {
    allNotes.add(note);
    if (!_noteMatchesOptions(note, options)) {
      unmatchedNotes.add(
        '$where: note "$note" matches none of the question\'s options '
        '— kept as evidence.',
      );
    }
  }

  /// Attaches [notes] to [explanation] and records them against
  /// [options] (for the match diagnostics above). Returns the
  /// combined explanation.
  String attachNotesTo(
    String explanation,
    List<String> notes,
    List<String> options,
    String where,
  ) {
    for (final note in notes) {
      recordAttachedNote(note, options, where);
    }
    return _withNotes(explanation, notes);
  }

  /// Notes from a block that yielded no question: attach them to the
  /// nearest preceding question (the last built Question, else the
  /// last Q-only item), or — when there is no preceding question at
  /// all — keep them in diagnostics. Never silently discarded.
  void attachOrphanNotes(List<String> notes, String where) {
    for (final note in notes) {
      allNotes.add(note);
      if (questions.isNotEmpty) {
        final last = questions.last;
        questions[questions.length - 1] = last.copyWith(
          explanation: _withNotes(last.explanation, [note]),
        );
        if (!_noteMatchesOptions(note, last.options)) {
          unmatchedNotes.add(
            '$where: note "$note" matches none of the nearest '
            'question\'s options — kept as evidence.',
          );
        }
      } else if (qOnly.isNotEmpty) {
        // Q-only items have no options yet (built after the loop),
        // so the option-match check cannot run here — the note is
        // kept as evidence on the item for the AI step to match.
        final last = qOnly.last;
        qOnly[qOnly.length - 1] = _QOnly(
          text: last.text,
          answer: last.answer,
          explanation: _withNotes(last.explanation, [note]),
          subject: last.subject,
          page: last.page,
          lineIndex: last.lineIndex,
          answerSource: last.answerSource,
        );
      } else {
        unmatchedNotes.add(
          '$where: note "$note" has no preceding question — kept in '
          'diagnostics.',
        );
      }
    }
  }

  /// A key entry for this question's (paper, number), when one exists.
  /// Precedence is answer-line > key > tick > bold > asterisk, so:
  /// * tick/bold/asterisk answer + key → the key CONFIRMS (same
  ///   option) or OVERRIDES (different option, conflict recorded);
  ///   the source becomes 'key' and the entry is consumed + counted.
  /// * answer-line answer + key → the answer line WINS (source stays
  ///   'answer-line'); the entry is still consumed (it matched a
  ///   question, so it must not be reported as unmatched) and a
  ///   conflict is recorded only when it disagrees.
  /// * key token matches no option → the tick/bold/asterisk/answer-line
  ///   answer stands, a conflict is recorded, the entry is consumed.
  /// * key token is "?" (answer unknown, MPT "3. ?") → the key
  ///   explicitly says the answer is unknown. An answer-line answer
  ///   still wins (it outranks the key); a tick/bold/asterisk answer
  ///   does NOT — the question is marked unknown (unknown: true) and
  ///   the caller EXCLUDES it with reason, never guesses.
  /// Returns the (possibly key-corrected) (correctIndex, answerSource,
  /// unknown).
  ({int correctIndex, String answerSource, bool unknown}) applyKeyIfPresent({
    required String paper,
    required int? number,
    required List<String> options,
    required int correctIndex,
    required String answerSource,
    required int? tickIndex,
    required int? asteriskIndex,
    required List<bool> boldOptions,
    required String where,
  }) {
    if (number == null) {
      return (
        correctIndex: correctIndex,
        answerSource: answerSource,
        unknown: false,
      );
    }
    final paperKeys = segmented.keyEntries[paper];
    final token = paperKeys?.remove(number);
    if (token == null) {
      return (
        correctIndex: correctIndex,
        answerSource: answerSource,
        unknown: false,
      );
    }
    // "?" — the book's key says the answer is unknown.
    if (isUnknownKeyToken(token)) {
      if (answerSource == 'answer-line') {
        // Explicit answer in the question outranks the key's "unknown".
        return (
          correctIndex: correctIndex,
          answerSource: answerSource,
          unknown: false,
        );
      }
      // Tick/bold/asterisk do not outrank an explicit "unknown" —
      // never guess.
      return (
        correctIndex: correctIndex,
        answerSource: answerSource,
        unknown: true,
      );
    }
    final keyCorrect = resolveAnswerToken(token, options);
    String letter(int i) => String.fromCharCode(65 + i);
    if (keyCorrect == null) {
      conflicts.add(
        '$where: $paper Q$number key entry "$token" matches no option '
        '— using the $answerSource answer.',
      );
      return (
        correctIndex: correctIndex,
        answerSource: answerSource,
        unknown: false,
      );
    }
    if (answerSource == 'answer-line') {
      if (keyCorrect != correctIndex) {
        conflicts.add(
          '$where: $paper Q$number key says ${letter(keyCorrect)} but '
          'the answer line says ${letter(correctIndex)} — using the '
          'answer line.',
        );
      }
      return (
        correctIndex: correctIndex,
        answerSource: answerSource,
        unknown: false,
      );
    }
    // tick / bold / asterisk: the key outranks all three.
    if (keyCorrect != correctIndex) {
      final signal = answerSource == 'tick'
          ? 'the tick is on ${letter(tickIndex ?? correctIndex)}'
          : answerSource == 'asterisk'
              ? 'the asterisk is on ${letter(asteriskIndex ?? correctIndex)}'
              : 'the bold option is ${letter(boldOptions.indexOf(true))}';
      conflicts.add(
        '$where: $paper Q$number key says ${letter(keyCorrect)} but '
        '$signal — using the key.',
      );
    }
    keyEntriesApplied++;
    keyAppliedByPaper[paper] = (keyAppliedByPaper[paper] ?? 0) + 1;
    return (correctIndex: keyCorrect, answerSource: 'key', unknown: false);
  }

  for (var b = 0; b < blocks.length; b++) {
    final rawBlock = blocks[b];
    // "(Note: …)" lines are answer evidence, never questions/options:
    // pull them out of the block's lines so no format handler sees
    // them, and attach them to this block's question (or, when the
    // block yields no question, to the nearest preceding question).
    final noteTexts = <String>[];
    // Non-final: the title-furniture trim below may drop leading lines.
    var block = <SegmentedLine>[];
    for (final l in rawBlock) {
      final note = noteContent(l.text);
      if (note != null) {
        noteTexts.add(note);
      } else {
        block.add(l);
      }
    }
    if (block.isEmpty) {
      // The whole block was note line(s) — no question here.
      attachOrphanNotes(noteTexts, 'Block ${b + 1}');
      continue;
    }
    // Title furniture at the head of a block (PPSC-66 Q1: the book's
    // title block — "TEHSILDAR/ …", "(BS-16) - 2021", "English
    // Morning", "English Grammar" — sits in front of the first
    // question's stem, so the stem came out as the title instead of
    // the question). The real stem is the first line before the
    // options that is a question start, ends with '?'/'؟', or has ≥ 4
    // words; leading lines before it that are all-caps or short
    // (≤ 3 words) title lines are furniture, never the question. A
    // genuine short stem ("Translate: Apple") has no longer stem line
    // before its options, so it is never trimmed.
    {
      final firstOptionIdx =
          block.indexWhere((l) => _optionRe.hasMatch(l.text));
      final headEnd = firstOptionIdx == -1 ? block.length : firstOptionIdx;
      var stemIdx = -1;
      for (var i = 0; i < headEnd; i++) {
        final t = _cleanStored(block[i].text);
        final words = t
            .split(RegExp(r'\s+'))
            .where((w) => w.isNotEmpty)
            .length;
        // A title line can itself be long ("TEHSILDAR/ CONSOLIDATION
        // OFFICER/ HILL TORRENT" is 5 words) — length alone does not
        // make it a stem. A real stem is sentence-case (has a
        // lowercase letter); a title line is all-caps. A numbered
        // line is always a stem start, even when all-caps.
        final allCaps = !RegExp(r'[a-z]').hasMatch(t) &&
            RegExp(r'[A-Z]').hasMatch(t);
        if (questionStart.hasMatch(t) ||
            (!allCaps &&
                (t.endsWith('?') || t.endsWith('؟') || words >= 4))) {
          stemIdx = i;
          break;
        }
      }
      if (stemIdx > 0) {
        var allFurniture = true;
        for (var i = 0; i < stemIdx; i++) {
          final t = _cleanStored(block[i].text);
          final words = t
              .split(RegExp(r'\s+'))
              .where((w) => w.isNotEmpty)
              .length;
          final allCaps = !RegExp(r'[a-z]').hasMatch(t) &&
              RegExp(r'[A-Z]').hasMatch(t);
          // A numbered line is a question, never furniture.
          if (questionStart.hasMatch(t) ||
              (!allCaps && words > 3) ||
              t.endsWith('?') ||
              t.endsWith('؟')) {
            allFurniture = false;
            break;
          }
        }
        if (allFurniture) block = block.sublist(stemIdx);
      }
    }
    final firstLine = block.first.text;
    // The block's paper is the paper of its first OPTION line when it
    // has one: a block that opens with front matter ("Papers of 2021
    // 521", before the "MODEL PAPER 66" heading) carries the default
    // paper on its first line, while its question belongs to the paper
    // that follows. Using the first line's paper stranded Q1 under
    // "Paper 1", where no key could ever join it. Blocks without
    // options (q-only / flashcard) keep the first line's paper.
    String? optionPaper;
    for (final l in block) {
      if (_optionRe.hasMatch(l.text)) {
        optionPaper = l.paper;
        break;
      }
    }
    final paper = optionPaper ?? block.first.paper;
    // Bare-numbered questions ("52 Who founded …?") carry no dotted
    // number, so _questionNumber returns null for them — but the
    // question DID parse, and leaving its number unrecorded reports
    // a false "Q52 missing" gap (PPSC Foodgrains 2013, 19 Nov 2026:
    // Q52 parsed yet was reported missing between Q51 and Q53).
    // Record the bare number too, with the same '?' guard as the
    // splitter — a stray year line never parses as a question, so it
    // can never be recorded here. (Consistent with the strip: a
    // "1947 Was a leap year?" stem already loses its year in the
    // stored text; its number 1947 is recorded the same way.)
    final cleanFirst = _cleanStored(firstLine);
    final number = _questionNumber(firstLine) ??
        (isBareNumberQuestionStart(cleanFirst)
            ? int.tryParse(
                RegExp(r'^\d+').firstMatch(cleanFirst)!.group(0)!,
              )
            : null) ??
        // Sequence recovery (PPSC-66): a number clipped at the page
        // edge is recovered from its neighbours above. Never a guess
        // — [recoveredNumbers] is null unless the run exactly filled
        // its gap.
        recoveredNumbers[b];
    final page = block.first.page;
    final part = structure?.partForLine(block.first.lineIndex) ?? '';
    // Multi-line question: first line + continuations, and the lines
    // after them (options / answers / explanations).
    final split = _splitQuestionAndRest(block);
    final qText = split.questionText;
    final rest = split.rest;

    // --- (b) One-liner: question + 4 options on the first line. ---
    final oneLiner = _parseOneLiner(firstLine);
    if (oneLiner != null && oneLiner.questionText.isNotEmpty) {
      // Defective in the book itself ("[cut off]" options, or an
      // in-book "could not determine" note): EXCLUDE with the book's
      // own reason, never guess, never silently drop.
      final oneLinerDefect = _defectReason(oneLiner.options, rest);
      if (oneLinerDefect != null) {
        final label = number != null ? '$paper Q$number' : 'Block ${b + 1}';
        excluded.add('$label — $oneLinerDefect.');
        skipped++;
        // The question existed — consume its key entry (if any) so it
        // is not also reported as an unmatched key entry.
        if (number != null) segmented.keyEntries[paper]?.remove(number);
        attachOrphanNotes(noteTexts, 'Block ${b + 1}');
        continue;
      }
      final answerToken =
          oneLiner.answerToken ?? _answerTokenFromLines(rest);
      final subject = _subjectFromLines(rest, defaultSubject);
      final explanation = _explanationFromLines(rest);
      // A conflict anywhere in this block's resolution (signals
      // disagreeing, or a key entry matching no option) makes the
      // answer UNVERIFIED — the v2 preview must surface it for manual
      // correction instead of presenting it as certain.
      final conflictsBefore = conflicts.length;
      final resolved = _resolveSignals(
        answerToken: answerToken,
        options: oneLiner.options,
        tickIndex: oneLiner.tickIndex,
        boldOptions: oneLiner.boldOptions,
        asteriskIndex: oneLiner.asteriskIndex,
        where: 'Block ${b + 1}',
      );
      conflicts.addAll(resolved.conflicts);
      final resolvedCorrect = resolved.correctIndex;
      if (resolvedCorrect != null) {
        // A key entry for this (paper, number) confirms/overrides a
        // tick/bold/asterisk answer (key outranks all three); an
        // answer-line answer is never overridden by a key.
        final keyed = applyKeyIfPresent(
          paper: paper,
          number: number,
          options: oneLiner.options,
          correctIndex: resolvedCorrect,
          answerSource: resolved.answerSource,
          tickIndex: oneLiner.tickIndex,
          asteriskIndex: oneLiner.asteriskIndex,
          boldOptions: oneLiner.boldOptions,
          where: 'Block ${b + 1}',
        );
        // Key says "?" (answer unknown): EXCLUDE with reason, never
        // guess — even though a tick/bold/asterisk signal was present.
        if (keyed.unknown) {
          final label = number != null ? '$paper Q$number' : 'Block ${b + 1}';
          excluded.add(
            '$label — answer unknown (the answer key says "?").',
          );
          addPending(
            PendingQuestion(
              text: oneLiner.questionText,
              options: oneLiner.options,
              subject: subject,
              explanation: explanation,
              page: page,
              part: part,
              reason: 'unknown-key',
              number: number,
              paper: paper,
            ),
          );
          skipped++;
          attachOrphanNotes(noteTexts, 'Block ${b + 1}');
          continue;
        }
        if (number != null) recordNumber(number, page);
        questions.add(
          Question(
            text: oneLiner.questionText,
            options: oneLiner.options,
            correctIndex: keyed.correctIndex,
            subject: subject,
            sourceId: sourceId,
            sourceLabel: sourceLabel,
            explanation: attachNotesTo(
              explanation,
              noteTexts,
              oneLiner.options,
              'Block ${b + 1}',
            ),
            page: page,
            part: part,
            answerSource: keyed.answerSource,
            boldOptions: oneLiner.boldOptions,
            answerVerified: conflicts.length == conflictsBefore,
          ),
        );
        bump('one-liner');
        countSource(keyed.answerSource);
        continue;
      }
      // A one-liner without a usable answer is a key candidate when it
      // is numbered; otherwise it is skipped, as before — but kept as
      // answer-PENDING for AI inference (File 2 shape, unnumbered).
      if (number != null) {
        candidates.add(
          _AnswerlessCandidate(
            blockIndex: b,
            text: oneLiner.questionText,
            options: oneLiner.options,
            format: 'one-liner',
            paper: paper,
            number: number,
            subject: subject,
            explanation: attachNotesTo(
              explanation,
              noteTexts,
              oneLiner.options,
              'Block ${b + 1}',
            ),
            page: page,
            lineIndex: block.first.lineIndex,
            tickIndex: oneLiner.tickIndex,
            boldOptions: oneLiner.boldOptions,
          ),
        );
        continue;
      }
      if (oneLiner.options.length == 4 &&
          (oneLiner.questionText.trim().endsWith('?') ||
              oneLiner.questionText.trim().endsWith('؟'))) {
        addPending(
          PendingQuestion(
            text: oneLiner.questionText,
            options: oneLiner.options,
            subject: subject,
            explanation: attachNotesTo(
              explanation,
              noteTexts,
              oneLiner.options,
              'Block ${b + 1}',
            ),
            page: page,
            part: part,
            reason: 'no-key-entry',
            number: number,
            paper: paper,
          ),
        );
      }
      skipped++;
      attachOrphanNotes(noteTexts, 'Block ${b + 1}');
      errors.add(
        'Block ${b + 1}: one-line question has no usable answer '
        '(need "Ans: (c)" / "Answer: C" / "Correct: <option text>").',
      );
      continue;
    }

    // --- (a) Standard block: options on their own lines. ---
    final standard = _parseStandardBlock(
      qText,
      rest,
      defaultSubject,
      where: 'Block ${b + 1}',
    );
    if (standard != null && standard.questionText.isNotEmpty) {
      // A conflict anywhere in this block's resolution makes the
      // answer UNVERIFIED (see the one-liner site above).
      final conflictsBefore = conflicts.length;
      conflicts.addAll(standard.conflicts);
      // Defective in the book itself ("[cut off]" options, or an
      // in-book "could not determine" note — MPT Q3/Q106): EXCLUDE
      // with the book's own reason, never guess, never silently drop.
      // Runs before any key/tick/bold resolution.
      final defect = _defectReason(standard.options, rest);
      if (defect != null) {
        final label = number != null ? '$paper Q$number' : 'Block ${b + 1}';
        excluded.add('$label — $defect.');
        skipped++;
        // The question existed — consume its key entry (if any) so it
        // is not also reported as an unmatched key entry.
        if (number != null) segmented.keyEntries[paper]?.remove(number);
        attachOrphanNotes(noteTexts, 'Block ${b + 1}');
        continue;
      }
      // 5→4 normalisation already happened inside the standard parse
      // (when the answer was known); count it for the preview.
      if (standard.droppedFive != null) {
        fiveOptionNormalised++;
        if (standard.droppedFive == 'D') fiveOptionAnswerE++;
      }
      if (standard.correctIndex != null) {
        // A key entry for this (paper, number) confirms/overrides a
        // tick/bold/asterisk answer (key outranks all three); an
        // answer-line answer is never overridden by a key.
        final keyed = applyKeyIfPresent(
          paper: paper,
          number: number,
          options: standard.options,
          correctIndex: standard.correctIndex!,
          answerSource: standard.answerSource,
          tickIndex: standard.tickIndex,
          asteriskIndex: standard.asteriskIndex,
          boldOptions: standard.boldOptions,
          where: 'Block ${b + 1}',
        );
        // Key says "?" (answer unknown): EXCLUDE with reason, never
        // guess — even though a tick/bold/asterisk signal was present.
        if (keyed.unknown) {
          final label = number != null ? '$paper Q$number' : 'Block ${b + 1}';
          excluded.add(
            '$label — answer unknown (the answer key says "?").',
          );
          addPending(
            PendingQuestion(
              text: standard.questionText,
              options: standard.options,
              subject: standard.subject,
              explanation: standard.explanation,
              page: page,
              part: part,
              reason: 'unknown-key',
              number: number,
              paper: paper,
            ),
          );
          skipped++;
          attachOrphanNotes(noteTexts, 'Block ${b + 1}');
          continue;
        }
        if (number != null) recordNumber(number, page);
        questions.add(
          Question(
            text: standard.questionText,
            options: standard.options,
            correctIndex: keyed.correctIndex,
            subject: standard.subject,
            sourceId: sourceId,
            sourceLabel: sourceLabel,
            explanation: attachNotesTo(
              standard.explanation,
              noteTexts,
              standard.options,
              'Block ${b + 1}',
            ),
            page: page,
            part: part,
            answerSource: keyed.answerSource,
            boldOptions: standard.boldOptions,
            answerVerified: conflicts.length == conflictsBefore,
          ),
        );
        bump('block');
        countSource(keyed.answerSource);
        continue;
      }
      // 4 options but no (usable) answer: a key candidate when
      // numbered, otherwise skipped, as before.
      if (number != null) {
        candidates.add(
          _AnswerlessCandidate(
            blockIndex: b,
            text: standard.questionText,
            options: standard.options,
            format: 'block',
            paper: paper,
            number: number,
            subject: standard.subject,
            explanation: attachNotesTo(
              standard.explanation,
              noteTexts,
              standard.options,
              'Block ${b + 1}',
            ),
            page: page,
            lineIndex: block.first.lineIndex,
            tickIndex: standard.tickIndex,
            boldOptions: standard.boldOptions,
          ),
        );
        continue;
      }
      // Unnumbered + answerless (File 2: the question has 4 options
      // + explanation prose, no number, no key anywhere): keep it as
      // answer-PENDING for AI inference (explicit user choice) — the
      // key could never join it by number anyway. Still counted as
      // skipped + reported, never silently imported. The '?' guard
      // matters: an instruction sentence followed by an A–D list
      // (an admission letter's penalties list) is NOT a question and
      // must never become pending.
      if (standard.options.length == 4 &&
          (standard.questionText.trim().endsWith('?') ||
              standard.questionText.trim().endsWith('؟'))) {
        addPending(
          PendingQuestion(
            text: standard.questionText,
            options: standard.options,
            subject: standard.subject,
            explanation: attachNotesTo(
              standard.explanation,
              noteTexts,
              standard.options,
              'Block ${b + 1}',
            ),
            page: page,
            part: part,
            reason: 'no-key-entry',
            paper: paper,
          ),
        );
      }
      skipped++;
      attachOrphanNotes(noteTexts, 'Block ${b + 1}');
      errors.add(
        'Block ${b + 1}: skipped — has 4 options but no usable answer '
        '(need an Answer line or a matching Answer Key entry).',
      );
      continue;
    }

    // --- (c) Q-only: a direct answer, no options. ---
    // A block that HAS option lines is a malformed standard block, not
    // a Q-only question — never silently convert it (e.g. 1 option +
    // "Answer: A" must be skipped, not rebuilt from the answer pool).
    final hasOptionLine =
        rest.any((l) => _optionRe.hasMatch(l.text)) ||
        _parseOneLiner(firstLine) != null;
    final qOnlyAnswer = hasOptionLine
        ? null
        : _qOnlyAnswer(firstLine, page, rest);
    // OCR-debris guard: a Q-only question needs a REAL stem. A bare
    // "(A)" line after a garbled fragment ("Wh to e", "All follo",
    // "Bi", "T" — facing-page bleed on camera photos) is not a
    // question; without this guard the fragment becomes a fake
    // question with pool-built options. Real stems are ≥ 10 chars
    // with ≥ 2 words ("What is UNO?" is 12 chars, 3 words).
    if (qOnlyAnswer != null &&
        qText.isNotEmpty &&
        _isRealQOnlyStem(qText)) {
      // Q-only items have no options yet (built from the answer pool
      // after the loop), so the note → option match check cannot run
      // here — the note is kept as evidence on the item for the AI
      // step to match, and recorded in allNotes.
      allNotes.addAll(noteTexts);
      qOnly.add(
        _QOnly(
          text: _stripAnswerTail(qText, const []),
          answer: qOnlyAnswer,
          explanation: _withNotes(_explanationFromLines(rest), noteTexts),
          subject: _subjectFromLines(rest, defaultSubject),
          page: page,
          lineIndex: block.first.lineIndex,
        ),
      );
      continue;
    }

    // --- (d) Flashcard: "?"-terminated question + short plain answer
    // lines, in a block with no option lines at all. The scan adds
    // [_QOnly] items with answerSource 'flashcard'; it returns true
    // when it found at least one, so the block is not also skipped.
    // A note in this block attaches to the last flashcard found (the
    // nearest preceding question in reading order).
    final qOnlyBefore = qOnly.length;
    if (_scanFlashcards(block, qOnly, defaultSubject)) {
      if (noteTexts.isNotEmpty && qOnly.length > qOnlyBefore) {
        allNotes.addAll(noteTexts);
        final last = qOnly.last;
        qOnly[qOnly.length - 1] = _QOnly(
          text: last.text,
          answer: last.answer,
          explanation: _withNotes(last.explanation, noteTexts),
          subject: last.subject,
          page: last.page,
          lineIndex: last.lineIndex,
          answerSource: last.answerSource,
        );
      }
      continue;
    }

    // A block that never looked like a question (book title, section
    // header, footer — e.g. the front matter before Q1, or a "PPSC
    // Current Affairs | 40 MCQs Page 1" footer) is not a failed
    // question: drop it silently instead of reporting it as skipped.
    // Its notes still attach to the nearest preceding question.
    // A foreign-script ad block (Bengali) is counted as filtered
    // noise, not silently dropped uncounted.
    // Phase A: a BARE-numbered question start ("52 Who founded …?")
    // IS a question — if it failed every path (e.g. its only answer
    // was footer debris), it must be SKIPPED with a reason, never
    // silently dropped (PakMCQs: 2 footer-answer questions vanished
    // with no trace until this guard).
    if (!questionStart.hasMatch(firstLine) &&
        !isBareNumberQuestionStart(cleanFirst)) {
      if (_isForeignScriptNoiseBlock(block)) {
        noiseLinesFiltered += block.length;
      }
      attachOrphanNotes(noteTexts, 'Block ${b + 1}');
      continue;
    }
    skipped++;
    attachOrphanNotes(noteTexts, 'Block ${b + 1}');
    if (qText.isEmpty) {
      errors.add('Block ${b + 1}: skipped — empty question text.');
    } else {
      errors.add(
        'Block ${b + 1}: skipped — need 4 options + an Answer line, '
        'a one-line question with (a)–(d), or a "Q … Ans: …" line.',
      );
    }
  }

  // --- Second pass: apply the answer key to answerless candidates. ---
  // A key entry joins to the candidate with the same number in the SAME
  // paper/month segment, and is consumed — Paper 2's key can never
  // answer Paper 1's questions. Candidates the key cannot answer are
  // skipped and listed, never guessed; the import still succeeds.
  final unanswered = <_AnswerlessCandidate>[];
  // Key tokens that existed for a candidate but matched none of its
  // options (kept for the "matches no option" error — the entry is
  // consumed whether it resolves or not, so it never gets a fallback
  // second chance in another paper).
  final failedTokens = <_AnswerlessCandidate, String>{};
  for (final c in candidates) {
    final paperKeys = segmented.keyEntries[c.paper];
    final token = paperKeys?.remove(c.number);
    // "?" — the book's key says the answer is unknown: EXCLUDE with
    // reason, never guess. (A tick/bold signal on this candidate does
    // not outrank an explicit "unknown".)
    if (token != null && isUnknownKeyToken(token)) {
      excluded.add(
        '${c.paper} Q${c.number} — answer unknown (the answer key says "?").',
      );
      // 5-option candidates cannot become pending questions (the app
      // needs exactly 4 options; normalising needs the answer) — they
      // stay excluded with their reason, never guessed.
      if (c.options.length == 4) {
        addPending(
          PendingQuestion(
            text: c.text,
            options: c.options,
            subject: c.subject,
            explanation: c.explanation,
            page: c.page,
            part: structure?.partForLine(c.lineIndex) ?? '',
            reason: 'unknown-key',
            number: c.number,
            paper: c.paper,
          ),
        );
      }
      skipped++;
      continue;
    }
    final correct = token == null ? null : resolveAnswerToken(token, c.options);
    if (token != null && correct == null) failedTokens[c] = token;
    if (correct != null) {
      // A tick / bold signal on this question that disagrees with the
      // key is a conflict (the key wins — it outranks tick and bold).
      if (c.tickIndex != null && c.tickIndex != correct) {
        conflicts.add(
          'Block ${c.blockIndex + 1}: ${c.paper} Q${c.number} key says '
          '${String.fromCharCode(65 + correct)} but the tick is on '
          '${String.fromCharCode(65 + c.tickIndex!)} — using the key.',
        );
      }
      final boldIdx = [
        for (var i = 0; i < c.boldOptions.length; i++)
          if (c.boldOptions[i]) i,
      ];
      if (boldIdx.length == 1 && boldIdx.first != correct) {
        conflicts.add(
          'Block ${c.blockIndex + 1}: ${c.paper} Q${c.number} key says '
          '${String.fromCharCode(65 + correct)} but the bold option is '
          '${String.fromCharCode(65 + boldIdx.first)} — using the key.',
        );
      }
      // 5-option candidate (A–E, Examveda): normalise to exactly 4
      // now that the key has resolved the answer.
      var finalOptions = c.options;
      var finalBold = c.boldOptions;
      var finalCorrect = correct;
      if (c.options.length == 5) {
        final n = _normaliseFiveOptions(c.options, correct, c.boldOptions);
        finalOptions = n.options;
        finalBold = n.boldOptions;
        finalCorrect = n.correctIndex;
        fiveOptionNormalised++;
        if (n.dropped == 'D') fiveOptionAnswerE++;
      }
      recordNumber(c.number, c.page);
      questions.add(
        Question(
          text: c.text,
          options: finalOptions,
          correctIndex: finalCorrect,
          subject: c.subject,
          sourceId: sourceId,
          sourceLabel: sourceLabel,
          explanation: c.explanation,
          page: c.page,
          part: structure?.partForLine(c.lineIndex) ?? '',
          answerSource: 'key',
          boldOptions: finalBold,
        ),
      );
      bump(c.format);
      countSource('key');
      keyEntriesApplied++;
      keyAppliedByPaper[c.paper] = (keyAppliedByPaper[c.paper] ?? 0) + 1;
      continue;
    }
    unanswered.add(c);
  }

  // Strict paper rule (owner, 20 Nov 2026): there is NO cross-paper
  // fallback — a key entry that matched nothing in its own segment is
  // reported below, never applied to another paper's questions. (The
  // mid-page-key case the old fallback served is already handled in
  // [segmentLines]: a bare key heading belongs to the paper whose
  // questions precede it.)
  final unmatchedKeyEntries = <String>[];
  for (final paperEntry in segmented.keyEntries.entries) {
    for (final numberEntry in paperEntry.value.entries) {
      unmatchedKeyEntries.add(
        '${paperEntry.key} key entry ${numberEntry.key} '
        '— no matching question',
      );
    }
  }
  if (unmatchedKeyEntries.isNotEmpty) {
    final sample = unmatchedKeyEntries.take(2).join('; ');
    errors.add(
      'Answer Key has ${unmatchedKeyEntries.length} entries with no '
      'matching question (e.g. $sample).',
    );
  }

  // Candidates still unanswered after both key passes.
  for (final c in unanswered) {
    skipped++;
    // Kept for AI inference (explicit user choice) — never guessed.
    // 5-option candidates cannot become pending questions (exactly 4
    // options are required; normalising needs the answer) — and so
    // they have no missing-answers entry either (the report mirrors
    // the pending list); they are still reported in [errors] below.
    final token = failedTokens[c];
    if (c.options.length == 4) {
      addPending(
        PendingQuestion(
          text: c.text,
          options: c.options,
          subject: c.subject,
          explanation: c.explanation,
          page: c.page,
          part: structure?.partForLine(c.lineIndex) ?? '',
          reason: 'no-key-entry',
          number: c.number,
          paper: c.paper,
        ),
        failedToken: token,
      );
    }
    if (token == null) {
      errors.add(
        'Block ${c.blockIndex + 1}: ${c.paper} Q${c.number} has 4 '
        'options but no usable answer (no Answer line and no matching '
        'Answer Key entry).',
      );
    } else {
      errors.add(
        'Block ${c.blockIndex + 1}: ${c.paper} Q${c.number} key entry '
        '"$token" matches none of its 4 options.',
      );
    }
  }

  // --- Build options for Q-only questions from the book's own answers.
  // Pool = correct answers of parsed questions + answers of Q-only items.
  final pool = <String>{};
  String norm(String s) => s.trim().toLowerCase();
  for (final q in questions) {
    pool.add(q.options[q.correctIndex]);
  }
  for (final item in qOnly) {
    pool.add(item.answer);
  }
  final poolNorm = <String, String>{};
  for (final a in pool) {
    poolNorm.putIfAbsent(norm(a), () => a);
  }

  var generated = 0;
  final random = Random();
  for (final item in qOnly) {
    final distractors = poolNorm.entries
        .where((e) => e.key != norm(item.answer))
        .map((e) => e.value)
        .toList()
      ..shuffle(random);
    if (distractors.length < 3) {
      excluded.add(
        '"${_short(item.text)}" — only ${distractors.length} other '
        'distinct answer(s) in this book, need 3 to build 4 options.',
      );
      skipped++;
      continue;
    }
    final options = [item.answer, ...distractors.take(3)]..shuffle(random);
    questions.add(
      Question(
        text: item.text,
        options: options,
        correctIndex: options.indexWhere(
          (o) => norm(o) == norm(item.answer),
        ),
        subject: item.subject,
        sourceId: sourceId,
        sourceLabel: sourceLabel,
        explanation: item.explanation,
        page: item.page,
        part: structure?.partForLine(item.lineIndex) ?? '',
        answerSource: item.answerSource,
      ),
    );
    generated++;
    countSource(item.answerSource);
    bump('q-only');
  }

  // --- Test-building parts (exact parsed counts). ---
  // A part appears when it has at least one parsed question OR at
  // least one answer-pending question (PPSC-66 §5.5, 20 Nov 2026: a
  // part with only pending questions — Paper 67's General Knowledge,
  // 10 pending, 0 parsed — used to vanish from this list even though
  // its questions exist). [questionCount] stays the parsed count
  // (testable questions); [pendingCount] carries the pending ones.
  // When the book has no questions at all, a single "Poori book" part
  // (so the import still reports 0 MCQs with a sensible parts list —
  // a letter is never misdetected as a question paper).
  final parts = <BookPart>[];
  if (structure != null &&
      (questions.isNotEmpty || pending.isNotEmpty)) {
    final byPart = <String, List<Question>>{};
    for (final q in questions) {
      byPart.putIfAbsent(q.part, () => <Question>[]).add(q);
    }
    final pendingByPart = <String, List<PendingQuestion>>{};
    for (final p in pending) {
      pendingByPart.putIfAbsent(p.part, () => <PendingQuestion>[]).add(p);
    }
    for (final sp in structure.parts) {
      final qs = byPart[sp.title] ?? const <Question>[];
      final ps = pendingByPart[sp.title] ?? const <PendingQuestion>[];
      if (qs.isEmpty && ps.isEmpty) continue;
      // Page range = the span of this part's questions' pages, not
      // the heading span: a heading can sit mid-page, so the heading
      // span alone is wrong (F1: "Pakistan Current Affairs" Q8–10
      // are on page 2, after the "International" heading — the part
      // is pages 1–2, not 1–1).
      final pages = [
        for (final q in qs) q.page,
        for (final p in ps) p.page,
      ].where((p) => p > 0);
      final start = pages.isEmpty
          ? sp.startPage
          : pages.reduce((a, b) => a < b ? a : b);
      final end = pages.isEmpty
          ? sp.endPage
          : pages.reduce((a, b) => a > b ? a : b);
      parts.add(
        sp.copyWith(
          questionCount: qs.length,
          pendingCount: ps.length,
          startPage: start,
          endPage: end,
        ),
      );
    }
    // A question whose part is '' (before the first heading) belongs
    // to the first part — extend its range to cover those pages too.
    final unparted = byPart[''];
    final unpartedPending = pendingByPart[''];
    if (parts.isNotEmpty &&
        ((unparted != null && unparted.isNotEmpty) ||
            (unpartedPending != null && unpartedPending.isNotEmpty))) {
      final pages = [
        for (final q in unparted ?? const <Question>[]) q.page,
        for (final p in unpartedPending ?? const <PendingQuestion>[])
          p.page,
      ].where((p) => p > 0);
      final start = pages.isEmpty
          ? parts[0].startPage
          : [parts[0].startPage, ...pages].reduce((a, b) => a < b ? a : b);
      final end = pages.isEmpty
          ? parts[0].endPage
          : [parts[0].endPage, ...pages].reduce((a, b) => a > b ? a : b);
      parts[0] = parts[0].copyWith(
        questionCount:
            parts[0].questionCount + (unparted?.length ?? 0),
        pendingCount:
            parts[0].pendingCount + (unpartedPending?.length ?? 0),
        startPage: start,
        endPage: end,
      );
    }
  }
  if (parts.isEmpty && structure != null) {
    final totalPages = structure.parts.isEmpty
        ? 0
        : structure.parts.last.endPage;
    parts.add(
      BookPart(
        title: wholeBookPartTitle,
        startPage: 1,
        endPage: totalPages,
        questionCount: questions.length,
        pendingCount: pending.length,
      ),
    );
  }

  // Number gaps and duplicates (MPT file): the parsed questions'
  // numbers, sorted; any missing number between the lowest and
  // highest is a gap the book itself does not provide (pages not
  // supplied), and any number parsed twice is a duplicate. Both are
  // reported WITH page numbers in the preview diagnostics, never
  // renumbered, merged or filled. A gap/duplicate is only reported
  // when the book has numbered questions at all (Q-only/flashcard
  // books have no numbers to gap).
  final numberGaps = _computeNumberGaps(parsedNumberPages);
  final numberDuplicates = _computeNumberDuplicates(parsedNumberPages);
  // Fact cards (organisation file): label–value pairs, extracted in
  // a separate pass alongside MCQ parsing — a fact book has 0 MCQs,
  // so the facts ARE the deliverable (agent C generates from them).
  facts.addAll(_extractFacts(segmented.questionLines, structure));

  // Mark provenance (governing spec 19 Nov 2026, official vs
  // student marks): every question records where its answer mark
  // came from. A tick/bold on an OCR page (scan / camera photo)
  // could be the STUDENT'S pen, not the book's — those questions are
  // UNVERIFIED (confidence 0.9 × 0.6 = 0.54) until the user confirms
  // them in manual correction; they are never silently presented as
  // correct.
  // An asterisk, key or answer line is printed text, not a pen mark,
  // so it stays verified even on an OCR page. A question from the
  // text layer / pasted text is 'printed'.
  for (var i = 0; i < questions.length; i++) {
    final q = questions[i];
    final provenance =
        (q.page != 0 && ocrPages.contains(q.page)) || markProvenance == 'ocr'
        ? 'ocr'
        : 'printed';
    if (provenance == 'ocr' &&
        (q.answerSource == 'tick' || q.answerSource == 'bold')) {
      questions[i] = q.copyWith(
        answerVerified: false,
        confidence: Question.confidenceForSource(
          q.answerSource,
          verified: false,
        ),
        markProvenance: 'ocr',
      );
    } else {
      questions[i] = q.copyWith(markProvenance: provenance);
    }
  }

  // Key-paper report for the preview (strict paper rule, owner
  // 20 Nov 2026): which paper each applied key belonged to, and any
  // key whose named paper has no questions in this import (applied
  // to nothing, reported plainly — never silently to another paper).
  final keyPaperReport = <String>[];
  for (final e in keyAppliedByPaper.entries) {
    keyPaperReport.add("Key '${e.key}' se ${e.value} jawab lage.");
  }
  // HIGH CONFIDENCE keys were applied, but they are NOT verified —
  // the preview must show the flag so the user confirms them before
  // saving (Part 8: the preview + Save is the confirmation path).
  // Only keys that actually applied get the flag.
  for (final e in keyDecisions.entries) {
    if (e.value.confidence == KeyMatchConfidence.highConfidence &&
        keyAppliedByPaper.containsKey(e.key)) {
      keyPaperReport.add(
        "Key '${e.key}' HIGH CONFIDENCE se lagi — ${e.value.reason} "
        'Save karne se pehle tasdeeq karein.',
      );
    }
  }
  // Withheld keys (NEEDS REVIEW / UNVERIFIED / MISMATCH): never
  // applied — the decision reason is the report, so the user knows
  // exactly why the key did not answer anything.
  for (final e in withheldKeyDecisions.entries) {
    keyPaperReport.add(
      "Key '${e.key}' nahi lagayi — ${e.value.reason}",
    );
  }
  final papersWithQuestions = {
    for (final l in segmented.questionLines) l.paper,
  };
  for (final paper in segmented.explicitKeyPapers) {
    if (!papersWithQuestions.contains(paper)) {
      keyPaperReport.add(
        "Key '$paper' mili, lekin is PDF mein $paper ke sawal nahi — "
        'key nahi lagayi.',
      );
    }
  }

  return ParseResult(
    questions: questions,
    parsed: questions.length,
    skipped: skipped,
    errors: errors,
    formatCounts: formatCounts,
    generatedOptions: generated,
    excluded: excluded,
    keySectionsFound: segmented.keySectionsFound,
    keyEntriesApplied: keyEntriesApplied,
    questionsMissingAnswers: questionsMissingAnswers,
    parts: parts,
    answerSources: answerSources,
    conflicts: conflicts,
    unmatchedKeyEntries: unmatchedKeyEntries,
    notes: allNotes,
    unmatchedNotes: unmatchedNotes,
    fiveOptionNormalised: fiveOptionNormalised,
    fiveOptionAnswerE: fiveOptionAnswerE,
    numberGaps: numberGaps,
    numberDuplicates: numberDuplicates,
    noiseLinesFiltered: noiseLinesFiltered,
    facts: facts,
    answerPending: pending,
    keyPaperReport: keyPaperReport,
  );
}

/// Missing question-number ranges from the sorted set of parsed
/// question numbers. E.g. {1,2,3,46,47} → ["Q4–Q45 (42 questions
/// missing)"]. Single missing numbers are reported as "Q7 (1 question
/// missing)". Empty when there are fewer than 2 numbers (nothing to
/// gap) or no gap at all.
/// Missing question numbers, WITH the pages that bound each gap —
/// e.g. "Q9 missing between Q8 (page 1) and Q10 (page 2)". [numberPages]
/// maps each parsed question number to the pages it was parsed on.
/// A gap is a book problem (a page not supplied, or a numbering
/// error in the book), never a parse error — reported in the preview
/// diagnostics, never silently skipped. Page 0 = unknown (TXT /
/// pasted text) — the gap is reported without pages then.
List<String> _computeNumberGaps(Map<int, List<int>> numberPages) {
  final numbers = numberPages.keys.toList()..sort();
  if (numbers.length < 2) return const [];
  String pagesOf(int n) {
    final ps = numberPages[n]!.where((p) => p != 0).toSet().toList()
      ..sort();
    return ps.isEmpty ? '' : ' (page ${ps.join(', page ')})';
  }

  final gaps = <String>[];
  for (var i = 0; i + 1 < numbers.length; i++) {
    final a = numbers[i];
    final b = numbers[i + 1];
    if (b - a <= 1) continue;
    final missing = b - a - 1;
    final span = 'between Q$a${pagesOf(a)} and Q$b${pagesOf(b)}';
    if (missing == 1) {
      gaps.add('Q${a + 1} missing $span (1 question missing)');
    } else {
      gaps.add('Q${a + 1}–Q${b - 1} missing $span ($missing questions missing)');
    }
  }
  return gaps;
}

/// Duplicated question numbers, WITH the pages each copy was parsed
/// on — e.g. "Q8 appears twice (page 1, page 2)". A number repeated
/// across a page break is usually the book re-numbering a section
/// (or a real duplicate question); both copies are kept as parsed
/// (they are two different questions in the book), and the
/// duplication is reported in the preview diagnostics so the user can
/// check it — never silently merged, never silently dropped. A number
/// parsed twice on the SAME page is reported the same way.
List<String> _computeNumberDuplicates(Map<int, List<int>> numberPages) {
  final dups = <String>[];
  for (final n in numberPages.keys.toList()..sort()) {
    final pages = numberPages[n]!;
    if (pages.length < 2) continue;
    final known = pages.where((p) => p != 0).toList()..sort();
    final where = known.isEmpty
        ? '(page unknown)'
        : '(page ${known.join(', page ')})';
    dups.add('Q$n appears ${pages.length} times $where');
  }
  return dups;
}

String _short(String s) => s.length > 60 ? '${s.substring(0, 60)}…' : s;

/// Strips bold-run markers (and trims) from text that is about to be
/// stored — a question, option or answer must never carry the
/// extractor's inline bold marker.
String _cleanStored(String s) => stripBoldMarkers(s).trim();

/// Tick marks that can sit on the correct option: ✓ (U+2713) or
/// ✔ (U+2714), before or after the option text.
bool _hasTick(String s) => s.contains('\u2713') || s.contains('\u2714');

/// Removes tick marks from stored option text.
String _stripTicks(String s) =>
    s.replaceAll('\u2713', '').replaceAll('\u2714', '').trim();

/// An asterisk answer marker: a `*` at the END of an option's text,
/// with or without a space before it, and with or without one trailing
/// punctuation mark after it ("HTML*", "F5 *", "Flaming.*"). This is
/// the answer signal of Dogar-style Pakistani MCQ books: the book
/// prints a `*` after the correct option instead of an answer key.
/// A `*` in the MIDDLE of the text ("2 * 3 = 6", a multiplication)
/// is not a marker and is never stripped.
bool _hasAsterisk(String s) {
  final t = stripBoldMarkers(s).trim();
  return RegExp(r'\*\s*[.,;:\)]?\s*$').hasMatch(t);
}

/// Removes a trailing asterisk answer marker (and the space before
/// it), keeping any trailing punctuation: "HTML*" → "HTML",
/// "F5 *" → "F5", "Flaming.*" → "Flaming.". A `*` anywhere else in
/// the text is left untouched.
String _stripAsterisks(String s) {
  final t = stripBoldMarkers(s).trim();
  return t
      .replaceFirstMapped(
        RegExp(r'\*\s*([.,;:\)])?\s*$'),
        (m) => m.group(1) ?? '',
      )
      .trim();
}

/// Strips a leading tick from an option line: "✓ B) China",
/// "✔ B) China", "(✓) B) China". Returns the cleaned line and whether
/// a tick was present (it marks the option on this line).
({String line, bool tick}) _stripLeadingTick(String line) {
  var s = line.trimLeft();
  var tick = false;
  if (s.startsWith('\u2713') || s.startsWith('\u2714')) {
    tick = true;
    s = s.substring(1).trimLeft();
  } else if (s.startsWith('(\u2713)') || s.startsWith('(\u2714)')) {
    tick = true;
    s = s.substring(3).trimLeft();
  }
  return (line: s, tick: tick);
}

/// True when [line] continues the last option [lastOptionText] that
/// wrapped over two OCR lines — the printed option ran past the
/// column/page edge and its tail (often the `*` answer marker, e.g.
/// "key repeatedly*") sits on the next line. The last option must be
/// an open sentence (no terminal punctuation), and the line must look
/// like a continuation: it starts lowercase (the sentence goes on),
/// or the last option ends with a function word (mid-phrase). A long
/// line is explanation prose, never a continuation.
bool _isOptionContinuation(String lastOptionText, String line) {
  final t = line.trim();
  if (t.isEmpty || t.length > 80) return false;
  final last = lastOptionText.trim();
  if (last.isEmpty) return false;
  if (RegExp(r'[.!?:;]$').hasMatch(last)) return false;
  final startsLower =
      t.isNotEmpty && RegExp(r'[a-z]').hasMatch(t[0]);
  final lastWord = last
      .split(RegExp(r'\s+'))
      .last
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z]'), '');
  const functionWords = {
    'the',
    'a',
    'an',
    'and',
    'or',
    'of',
    'to',
    'in',
    'on',
    'for',
    'with',
    'is',
    'are',
    'was',
    'were',
    'but',
    'not',
    'both',
    'at',
    'by',
    'as',
    'from',
    'that',
    'which',
    'who',
    'when',
    'where',
  };
  return startsLower || functionWords.contains(lastWord);
}

/// One option's stored text plus its signals, from the raw segment the
/// extractor produced: bold (a bold-run marker anywhere in the
/// segment), tick (a ✓/✔ anywhere in it) and asterisk (a `*` at the
/// END of the segment — the Dogar answer marker). All three markers
/// are stripped from the stored text.
({String text, bool bold, bool tick, bool asterisk}) _extractOption(
  String raw,
) {
  return (
    text: _stripAsterisks(_stripTicks(stripBoldMarkers(raw))).trim(),
    bold: hasBoldMarker(raw),
    tick: _hasTick(raw),
    asterisk: _hasAsterisk(raw),
  );
}

/// A line that is never a flashcard answer or an answer continuation:
/// a month title ("Current Affairs October 2026"), a book/section
/// title ("Year 2026 Current Affairs (Oct-Jan)"), a cover line. Used
/// so a section header is never swallowed as an answer.
bool _looksLikeHeaderLine(String line) {
  final t = line.trim();
  final lower = t.toLowerCase();
  if (monthHeadingLabel(t) != null) return true;
  if (lower.startsWith('current affairs') && !t.endsWith('?')) return true;
  if (lower.startsWith('year 2026')) return true;
  if (lower.startsWith('papers of 2026')) return true;
  return false;
}

/// A page footer ("Page 1", "PPSC Current Affairs | 40 MCQs Page 1")
/// is never content — in particular it must never be joined to an
/// answer token as a "continuation" (a footer after "Correct Answer:
/// B" would corrupt the token to "B Page 1", which resolves to
/// nothing and drops the question).
final _pageFooterRe = RegExp(r'page\s*\d+\s*$', caseSensitive: false);

/// True when [next] may continue an answer token: a plain short line
/// on the same page as the answer line ([answerPage]; 0 = unknown,
/// no page check), not a question / option / answer / explanation /
/// header, and not a complete sentence (a line ending in "." is
/// explanation prose, not a wrapped answer). Used for multi-line
/// answers ("Correct Answer: Asif Ali" + "Zardari", and flashcard
/// answers that wrap: "Navanethem … (South" + "Africa)").
bool _isAnswerContinuation(SegmentedLine next, int answerPage) {
  if (answerPage != 0 && next.page != answerPage) return false;
  final t = _cleanStored(next.text);
  if (t.isEmpty || t.length > 80) return false;
  if (t.endsWith('.')) return false;
  // A bullet / dash line ("• Good luck!", "– Note: …") is a note or
  // decoration, never the continuation of an answer — without this,
  // "Answer: C" followed by "• Good luck!" becomes the token
  // "C • Good luck!", which resolves to nothing and drops the MCQ.
  if (RegExp(r'^[•\-–—*]\s').hasMatch(t)) return false;
  if (_pageFooterRe.hasMatch(t)) return false;
  if (_looksLikeHeaderLine(t)) return false;
  if (_questionStartLineRe.hasMatch(next.text)) return false;
  if (_optionRe.hasMatch(next.text)) return false;
  if (_answerLineRe.hasMatch(next.text)) return false;
  if (_explanationRe.hasMatch(next.text)) return false;
  if (_subjectRe.hasMatch(next.text)) return false;
  if (_bareAnswerRe.hasMatch(next.text)) return false;
  return true;
}

/// Splits a block into its question lines and the rest. The question
/// text is the first line (number prefix stripped) plus continuation
/// lines: plain lines after it, before the first option / answer /
/// explanation / subject line, at most 3 of them, stopping after a
/// line ending in "?" (a wrapped question ends there). A line carrying
/// option markers inline ("moved its capital? (A) Japan …") stops the
/// question lines — the standard parser splits it into a question
/// tail + options.
///
/// CROSS-PAGE (19 Nov 2026): a question's stem may be split across a
/// page break — the stem ends at the bottom of page N and continues at
/// the top of page N+1. The continuation is joined into ONE question
/// text (never truncated, never a new question). The continuation may
/// move forward one page at a time (never backwards, never skip a
/// page), and page furniture at the boundary is SKIPPED, never joined
/// into the question: a footer ("Page 1") at the bottom of the old
/// page, or a running header ("Current Affairs 2026") / footer at the
/// top of the new page. Without the furniture skip, "Which river
/// flows through" + "Page 1" becomes the stored stem.
({String questionText, List<SegmentedLine> rest}) _splitQuestionAndRest(
  List<SegmentedLine> block,
) {
  final first = block.first;
  final qBuf = StringBuffer(
    _cleanStored(_stripQuestionNumberPrefix(first.text)),
  );
  final firstPage = first.page;
  var restStart = 1;
  var continuations = 0;
  var prevEndsQuestion = qBuf.toString().endsWith('?') ||
      qBuf.toString().endsWith('؟');
  // The page the continuation is currently being read from. Starts
  // on the question's own page; moves forward one page at a time
  // when the stem crosses a page break.
  var currentPage = firstPage;
  for (var i = 1; i < block.length; i++) {
    final seg = block[i];
    final line = seg.text;
    // Page furniture is never a continuation — a footer at the bottom
    // of the question's page, or a running header / footer at the top
    // of the next page, is skipped (and consumed, so it does not land
    // in `rest` either, where it could be misread as an option).
    if (_pageFooterRe.hasMatch(line) ||
        _looksLikeHeaderLine(line) ||
        isNoiseLine(line)) {
      restStart = i + 1;
      continue;
    }
    // Cross-page stem: the continuation may move to the immediately
    // next page. A jump of more than one page, or backwards, ends
    // the question (the lines belong to a later question, not this
    // stem). Page 0 = unknown (TXT / pasted text) — no page check.
    if (firstPage != 0 && seg.page != currentPage) {
      if (seg.page == currentPage + 1) {
        currentPage = seg.page;
      } else {
        break;
      }
    }
    if (continuations >= 3) break;
    if (prevEndsQuestion) break;
    if (_optionRe.hasMatch(line) ||
        _answerLineRe.hasMatch(line) ||
        _explanationRe.hasMatch(line) ||
        _subjectRe.hasMatch(line) ||
        _bareAnswerRe.hasMatch(line) ||
        isSolutionHeading(line) ||
        finalAnswerRe.hasMatch(line) ||
        _hasInlineOptionMarkers(line)) {
      break;
    }
    // The '?' test must use the CLEANED line: the raw line can carry
    // a trailing bold marker (U+E000) after the '?', so the raw line
    // ends with the marker, not '?', and the loop would swallow the
    // next line (junk, or the next question's stem) into this one.
    // (F2: "Mcqsplanet.com" was appended to every two-line '?' stem,
    // so the pending gate failed and 10 real questions were lost.)
    final cleanLine = _cleanStored(line.trim());
    qBuf.write(' ');
    qBuf.write(cleanLine);
    continuations++;
    prevEndsQuestion =
        cleanLine.endsWith('?') || cleanLine.endsWith('؟');
    restStart = i + 1;
  }
  return (
    questionText: qBuf.toString().trim(),
    rest: block.sublist(restStart),
  );
}

/// True when [line] carries two or more option markers in a
/// consecutive run ("(A) 1941 (B) 1942", "A. Japan B. Indonesia …").
/// Used to stop question-continuation collection (the standard parser
/// splits such a line) and by the standard parser itself.
bool _hasInlineOptionMarkers(String line) {
  return _splitOptionLine(line) != null;
}

/// Splits a line carrying MULTIPLE options ("(A) 1941 (B) 1942",
/// "A. Japan B. Indonesia C. Egypt D. None of these") into its option
/// texts, plus the text before the first marker (a question tail for
/// wrapped one-liners: "moved its capital? (A) Japan …"). Returns null
/// when the line holds fewer than two option markers, the markers are
/// not a consecutive run (A,B / B,C / A,B,C,D …), or a non-empty prefix
/// does not start the option set at A (so a prose line that merely
/// mentions "(A) … (B) …" is not split). A lone "(B)" inside an
/// option's text cannot fake a split: the run must be consecutive.
({String prefix, List<String> options})? _splitOptionLine(String line) {
  // Phase A failure loop (PPSC Foodgrains 2013, Q4): the marker must
  // start at a word boundary — start of line, whitespace, '(', ',' or
  // ';'. The old regex matched a letter + '.' INSIDE a word, so
  // "(B) 80 Sec. ✓" split at the "c." of "Sec." into options
  // ["80 Se", "✓"] — option B truncated, option C empty, and the
  // tick landed on the empty C (correct_index 2 instead of 1).
  // Abbreviations ending in a–d + '.' ("Sec.", "St.", "No.", "Rs.")
  // are common in option text; a real marker is never glued to the
  // previous word ("Lahore(a)" is not a format these books print).
  final markerRe =
      RegExp(r'(?:^|[\s\(,;])\(?\s*([A-Da-d])\s*[\)\.\:]');
  final matches = markerRe.allMatches(line).toList();
  if (matches.length < 2) return null;
  final prefix = line.substring(0, matches[0].start).trim();
  final letters = matches.map((m) => m.group(1)!.toUpperCase()).toList();
  for (var i = 1; i < letters.length; i++) {
    if (letters[i].codeUnitAt(0) != letters[i - 1].codeUnitAt(0) + 1) {
      return null;
    }
  }
  // A non-empty prefix is a question tail: it must open the option
  // set at A ("…? (A) … (B) …"). A bare two-option line ("(C) 1944
  // (D) 1946") may start at any letter.
  if (prefix.isNotEmpty && letters.first != 'A') return null;
  final options = <String>[];
  for (var k = 0; k < matches.length; k++) {
    final start = matches[k].end;
    final end = k + 1 < matches.length ? matches[k + 1].start : line.length;
    final text = line
        .substring(start, end)
        .trim()
        .replaceAll(RegExp(r'[\s,;]+$'), '')
        .trim();
    if (text.isEmpty) return null;
    options.add(text);
  }
  if (options.length > 4) return null;
  return (prefix: prefix, options: options);
}

/// Resolves the correct answer from the available signals, in
/// precedence order: explicit answer line > key (applied by the caller
/// via [applyKeyIfPresent]) > tick > bold > asterisk. A null
/// [correctIndex] means no signal resolved (the caller keeps the
/// question as an answer-key candidate). Conflicts are recorded, never
/// silently resolved: when a lower signal disagrees with the winner,
/// the message says which signal won.
({int? correctIndex, String answerSource, List<String> conflicts})
_resolveSignals({
  required String? answerToken,
  required List<String> options,
  int? tickIndex,
  required List<bool> boldOptions,
  int? asteriskIndex,
  required String where,
}) {
  final conflicts = <String>[];
  String letter(int i) => String.fromCharCode(65 + i);
  final boldIndices = [
    for (var i = 0; i < boldOptions.length; i++)
      if (boldOptions[i]) i,
  ];
  final explicit = answerToken == null
      ? null
      : resolveAnswerToken(answerToken, options);
  if (explicit != null) {
    if (tickIndex != null && tickIndex != explicit) {
      conflicts.add(
        '$where: answer line says ${letter(explicit)} but the tick is '
        'on ${letter(tickIndex)} — using the answer line.',
      );
    }
    if (boldIndices.length == 1 && boldIndices.first != explicit) {
      conflicts.add(
        '$where: answer line says ${letter(explicit)} but the bold '
        'option is ${letter(boldIndices.first)} — using the answer line.',
      );
    }
    if (asteriskIndex != null && asteriskIndex != explicit) {
      conflicts.add(
        '$where: answer line says ${letter(explicit)} but the asterisk '
        'is on ${letter(asteriskIndex)} — using the answer line.',
      );
    }
    return (
      correctIndex: explicit,
      answerSource: 'answer-line',
      conflicts: conflicts,
    );
  }
  if (tickIndex != null) {
    if (boldIndices.length == 1 && boldIndices.first != tickIndex) {
      conflicts.add(
        '$where: tick is on ${letter(tickIndex)} but the bold option '
        'is ${letter(boldIndices.first)} — using the tick.',
      );
    }
    if (asteriskIndex != null && asteriskIndex != tickIndex) {
      conflicts.add(
        '$where: tick is on ${letter(tickIndex)} but the asterisk is '
        'on ${letter(asteriskIndex)} — using the tick.',
      );
    }
    return (
      correctIndex: tickIndex,
      answerSource: 'tick',
      conflicts: conflicts,
    );
  }
  if (boldIndices.length == 1) {
    if (asteriskIndex != null && asteriskIndex != boldIndices.first) {
      conflicts.add(
        '$where: bold option is ${letter(boldIndices.first)} but the '
        'asterisk is on ${letter(asteriskIndex)} — using the bold.',
      );
    }
    return (
      correctIndex: boldIndices.first,
      answerSource: 'bold',
      conflicts: conflicts,
    );
  }
  if (boldIndices.length > 1) {
    conflicts.add(
      '$where: ${boldIndices.length} options are bold '
      '(${boldIndices.map(letter).join(', ')}) — bold signal ignored, '
      'answer still needed.',
    );
  }
  if (asteriskIndex != null) {
    return (
      correctIndex: asteriskIndex,
      answerSource: 'asterisk',
      conflicts: conflicts,
    );
  }
  return (correctIndex: null, answerSource: '', conflicts: conflicts);
}

/// Flashcard scan for one block that produced nothing (no standard /
/// one-liner / Q-only hit) and holds no option lines. Three shapes,
/// in ONE pass (no shape regressing another):
/// (a) answer on the NEXT line (Sir Tauqeer): a "?"-terminated
///     question, the short plain answer line(s) after it.
/// (b) dash-separated, SAME line (US History): "1. America was named
///     after — Amerigo Vespucci" — split on EM DASH (U+2014) or EN
///     DASH (U+2013) as a separator; a plain hyphen ("Turkey-Greece",
///     "Rush-Bagot") is never a separator. A trailing dash ("…? —")
///     takes the answer from the next line(s).
/// (c) trailing answer, SAME line (GSA): "1. Who discovered the Solar
///     System? Copernicus" / "8. … are called: Meteors" — split at
///     the LAST "?" or ":" that ends the question stem; the answer is
///     the text after it (multi-line answers joined the same way).
/// Each hit becomes a [_QOnly] with answerSource 'flashcard'.
/// Returns true when at least one flashcard was found, so the block
/// is not also reported as skipped.
///
/// Guards (each one matters): the block must contain NO option line
/// (so a mcqsplanet question + explanation prose can never be
/// swallowed — its options block the scan); the question must end
/// with "?" (shape a) or the split point must end it (shapes b/c);
/// the answer lines must be on the SAME page as the question (a page
/// break ends the answer), short (≤ 100 chars each, ≤ 2 lines,
/// ≤ 160 total), plain (not a question / option / answer /
/// explanation / header line), and stop after a line ending in "."
/// (a complete sentence ends the answer). Lines already used by an
/// earlier flashcard in this block are never re-used. A number prefix
/// ("1. ", "Q.1:") is stripped from the stored question text.
bool _scanFlashcards(
  List<SegmentedLine> block,
  List<_QOnly> qOnly,
  Subject defaultSubject,
) {
  if (block.any((l) => _optionRe.hasMatch(l.text))) return false;
  final consumed = <int>{};
  var found = 0;

  // Walk back from [endIdx] for the question start: at most 3 lines
  // back, stopping at a consumed line, a header, an option / answer /
  // explanation line, or a line ending in "?" (the previous
  // question's end). CROSS-PAGE: the question may start on the
  // previous page (its stem split across the break) — walk back one
  // page at a time, never further.
  int walkBack(int endIdx) {
    var qStart = endIdx;
    var back = 0;
    var currentPage = block[endIdx].page;
    while (qStart - 1 >= 0 && back < 3) {
      final prev = block[qStart - 1];
      if (consumed.contains(qStart - 1)) break;
      if (block[endIdx].page != 0 && prev.page != currentPage) {
        if (prev.page == currentPage - 1) {
          currentPage = prev.page;
        } else {
          break;
        }
      }
      final pt = _cleanStored(prev.text);
      if (pt.isEmpty || pt.length > 150) break;
      if (pt.endsWith('?')) break;
      if (_looksLikeHeaderLine(pt)) break;
      if (_optionRe.hasMatch(prev.text) ||
          _answerLineRe.hasMatch(prev.text) ||
          _explanationRe.hasMatch(prev.text) ||
          _subjectRe.hasMatch(prev.text) ||
          _bareAnswerRe.hasMatch(prev.text)) {
        break;
      }
      qStart--;
      back++;
    }
    return qStart;
  }

  // Walk forward from [startIdx] for answer continuation lines
  // (plain, short, at most 2 lines; a line ending in "." ends the
  // answer). [first] is an answer fragment already on the anchor
  // line (shapes b/c); shape (a) passes ''. CROSS-PAGE: the answer
  // may continue on the next page — walk forward one page at a time,
  // skipping page furniture (a footer / running header at the top of
  // the new page is never part of the answer).
  List<String> walkForward(int startIdx, String first) {
    final aLines = <String>[];
    if (first.isNotEmpty) aLines.add(first);
    // The page the answer starts on (0 = unknown, or no lines after
    // the anchor — startIdx may equal block.length when the anchor
    // is the block's last line; never index out of bounds).
    final startPage = startIdx < block.length ? block[startIdx].page : 0;
    var currentPage = startPage;
    for (var j = startIdx; j < block.length && aLines.length < 2; j++) {
      if (consumed.contains(j)) break;
      final a = block[j];
      if (startPage != 0 && a.page != currentPage) {
        if (a.page == currentPage + 1) {
          currentPage = a.page;
        } else {
          break;
        }
      }
      final at = _cleanStored(a.text);
      if (at.isEmpty) continue;
      // Page furniture at the break is skipped, never an answer line.
      if (_pageFooterRe.hasMatch(at) ||
          _looksLikeHeaderLine(at) ||
          isNoiseLine(at)) {
        continue;
      }
      if (at.length > 100) break;
      // G6 (Phase A): stop at ANY question mark in the line, not
      // only a trailing one. The next flashcard in a list often
      // starts mid-line ("Who wrote Hamlet? — Shakespeare"): the old
      // endsWith('?') check swallowed that whole line as an answer
      // continuation, polluting the previous answer ("Paris Who
      // wrote Hamlet? — Shakespeare") and losing the middle
      // question. An answer continuation is a plain fragment; a
      // '?'/'؟' anywhere in it means a new question starts here.
      // (A wrapped answer that itself contains a '?' is vanishingly
      // rare in these books; the line is then scanned on its own.)
      if (at.contains('?') || at.contains('؟')) break;
      if (_looksLikeHeaderLine(at)) break;
      if (_questionStartLineRe.hasMatch(a.text) ||
          _optionRe.hasMatch(a.text) ||
          _answerLineRe.hasMatch(a.text) ||
          _explanationRe.hasMatch(a.text) ||
          _subjectRe.hasMatch(a.text) ||
          _bareAnswerRe.hasMatch(a.text)) {
        break;
      }
      aLines.add(at);
      consumed.add(j);
      if (at.endsWith('.')) break;
    }
    return aLines;
  }

  // Build one flashcard from a question spanning lines [qStart..i]
  // (line i's text replaced by [qPartOnLine] when the question ends
  // mid-line, e.g. before a dash) and an answer starting with
  // [firstAnswer] on the anchor line plus continuations after it.
  // Returns true when a flashcard was added.
  bool addFlashcard(
    int qStart,
    int i,
    String qPartOnLine,
    String firstAnswer,
  ) {
    // Page furniture inside the walked-back range (a footer at the
    // bottom of the previous page) is never part of the question.
    final qLines = [
      for (var k = qStart; k < i; k++)
        if (!_pageFooterRe.hasMatch(block[k].text) &&
            !_looksLikeHeaderLine(block[k].text) &&
            !isNoiseLine(block[k].text))
          _cleanStored(block[k].text),
      qPartOnLine,
    ];
    var questionText = _stripQuestionNumberPrefix(
      qLines.join(' '),
    ).trim();
    if (questionText.length < 3) return false;
    final aLines = walkForward(i + 1, firstAnswer);
    if (aLines.isEmpty) return false;
    final answer = _cleanAnswerToken(aLines.join(' ').trim());
    if (answer.isEmpty ||
        answer.length > 160 ||
        _isPageIndicatorOnly(answer)) {
      return false;
    }
    for (var k = qStart; k <= i; k++) {
      consumed.add(k);
    }
    qOnly.add(
      _QOnly(
        text: questionText,
        answer: answer,
        explanation: '',
        subject: defaultSubject,
        page: block[i].page,
        lineIndex: block[i].lineIndex,
        answerSource: 'flashcard',
      ),
    );
    found++;
    return true;
  }

  for (var i = 0; i < block.length; i++) {
    if (consumed.contains(i)) continue;
    final qEnd = block[i];
    final qEndText = _cleanStored(qEnd.text);
    if (qEndText.isEmpty) continue;
    // Shape (b) — dash-separated. Checked first: a dash line's
    // question also ends with "?" ("…? —"), so shape (a) would
    // swallow the dash + answer into the question text.
    final dashM = RegExp(r'\s[—–]\s*').firstMatch(qEndText);
    if (dashM != null) {
      final qPart = qEndText.substring(0, dashM.start).trim();
      final aPart = qEndText.substring(dashM.end).trim();
      if (qPart.length >= 3 && !_looksLikeHeaderLine(qPart)) {
        if (addFlashcard(walkBack(i), i, qPart, aPart)) continue;
      }
    }
    // Shape (c) — trailing answer after the LAST "?" or ":" that
    // ends the question stem. The answer is short (≤ 60 chars), a
    // noun phrase, never another question. For ":", the char before
    // must be a letter (a time "10:30" is not a split point) and the
    // answer must start with a letter.
    final trailM = _trailingAnswerSplit(qEndText);
    if (trailM != null) {
      final qPart = trailM.$1;
      final aPart = trailM.$2;
      if (qPart.length >= 10 && !_looksLikeHeaderLine(qPart)) {
        if (addFlashcard(walkBack(i), i, qPart, aPart)) continue;
      }
    }
    // Shape (a) — "?"-terminated question, answer on the next line(s).
    // "؟" (U+061F) counts too — it is the question mark Urdu uses.
    if (!qEndText.endsWith('?') && !qEndText.endsWith('؟')) continue;
    final qStart = walkBack(i);
    final questionText = _stripQuestionNumberPrefix(
      [
        for (var k = qStart; k <= i; k++) _cleanStored(block[k].text),
      ].join(' '),
    ).trim();
    if (questionText.length < 3) continue;
    final aLines = walkForward(i + 1, '');
    if (aLines.isEmpty) continue;
    final answer = _cleanAnswerToken(aLines.join(' ').trim());
    if (answer.isEmpty ||
        answer.length > 160 ||
        _isPageIndicatorOnly(answer)) {
      continue;
    }
    for (var k = qStart; k <= i; k++) {
      consumed.add(k);
    }
    qOnly.add(
      _QOnly(
        text: questionText,
        answer: answer,
        explanation: '',
        subject: defaultSubject,
        page: qEnd.page,
        lineIndex: qEnd.lineIndex,
        answerSource: 'flashcard',
      ),
    );
    found++;
  }
  return found > 0;
}

/// Split point for flashcard shape (c): the LAST "?" or ":" in [text]
/// that ends the question stem, with a short answer after it.
/// Returns (questionPart, answerPart), or null when there is no
/// trailing answer (the line ends at "?" / ":", or the text after the
/// split is not a plausible short answer). A ":" split requires the
/// char before it to be a letter and the answer to start with a
/// letter (so "10:30" never splits); a "?" split has no such guard
/// ("?" is unambiguous). The answer must be ≤ 60 chars and contain
/// no "?" (it is an answer, not a question).
(String, String)? _trailingAnswerSplit(String text) {
  // Last "?" (ASCII or Arabic ؟ U+061F — the question mark Urdu
  // actually uses) with non-empty text after it. Urdu flashcards
  // ("…کیا تھا؟ قصواء") end with ؟, not ?; without this they parse 0.
  final qIdx = text.lastIndexOf(RegExp(r'[?؟]'));
  if (qIdx >= 0 && qIdx + 1 < text.length) {
    final qPart = text.substring(0, qIdx + 1).trim();
    final aPart = text.substring(qIdx + 1).trim();
    if (qPart.length >= 10 &&
        aPart.isNotEmpty &&
        aPart.length <= 60 &&
        !aPart.contains('?') &&
        !aPart.contains('؟')) {
      return (qPart, aPart);
    }
  }
  // Last ":" with non-empty text after it (letter before, letter first).
  // The ":" split needs a REAL stem: ≥ 3 words, a list entry (digit
  // "1.", letter "a.", bullet ""), or a sentence tail — a "." followed
  // by a space and a capital letter ("Philadelphia. Ratified:" is the
  // tail of a real sentence, not a label). A bare label ("HANDWRITTEN:")
  // or a margin note ("HANDWRITTEN note:") has none of these, so it
  // never becomes a fake flashcard question.
  final cIdx = text.lastIndexOf(':');
  if (cIdx > 0 && cIdx + 1 < text.length) {
    final before = text[cIdx - 1];
    final after = text.substring(cIdx + 1).trim();
    if (_isAsciiLetter(before) && after.isNotEmpty && _isAsciiLetter(after[0])) {
      final qPart = text.substring(0, cIdx + 1).trim();
      final qWords =
          qPart.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
      final numbered = RegExp(r'^(\d+|[a-zA-Z])\s*[\.\)]\s*').hasMatch(qPart) ||
          RegExp(r'^[•\-–—*]\s*').hasMatch(qPart);
      final sentenceTail = RegExp(r'\.\s+[A-Z]').hasMatch(qPart);
      if (qPart.length >= 10 &&
          (qWords >= 3 || numbered || sentenceTail) &&
          after.length <= 60 &&
          !after.contains('?')) {
        return (qPart, after);
      }
    }
  }
  return null;
}

/// True when [ch] is an ASCII letter (A–Z / a–z).
bool _isAsciiLetter(String ch) {
  final c = ch.codeUnitAt(0);
  return (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
}

/// Strips a trailing "Ans: …" / "Answer: …" tail from question text.
String _stripAnswerTail(String qText, List<String> options) {
  final clean = _cleanStored(qText);
  final idx = clean.toLowerCase().indexOf(
    RegExp(r'\b((?:correct|right)\s+answers?|ans|answer|correct)\s*[:\-]'),
  );
  if (idx < 0) return clean;
  return clean.substring(0, idx).trim();
}

final _optionRe = RegExp(r'^\(?([A-Da-d])[\)\.\:\-]\s*(.+)$');

/// The 5th option marker (E) — used ONLY inside [_parseStandardBlock]
/// after A–D are already collected, so a prose "E. coli" is never
/// mistaken for an option. [_optionRe] stays A–D everywhere else.
final _optionERe = RegExp(r'^\(?([Ee])[\)\.\:\-]\s*(.+)$');

/// Normalises a 5-option set (A–E, Examveda) to the app's exact-4 rule.
/// - Answer is A–D: drop E (usually "None" / "None of these").
/// - Answer is E: keep E's text as the 4th option, drop D (the last
///   wrong A–D option — all of A–D are wrong when the answer is E),
///   and record which letter was dropped.
/// Returns (options, correctIndex, boldOptions, droppedLetter). When
/// options.length != 5, returns the inputs unchanged (dropped null).
({
  List<String> options,
  int correctIndex,
  List<bool> boldOptions,
  String? dropped,
}) _normaliseFiveOptions(
  List<String> options,
  int correctIndex,
  List<bool> boldOptions,
) {
  if (options.length != 5) {
    return (
      options: options,
      correctIndex: correctIndex,
      boldOptions: boldOptions,
      dropped: null,
    );
  }
  if (correctIndex < 4) {
    // Answer is A–D: drop E.
    return (
      options: options.sublist(0, 4),
      correctIndex: correctIndex,
      boldOptions: boldOptions.length == 5
          ? boldOptions.sublist(0, 4)
          : List.filled(4, false),
      dropped: 'E',
    );
  }
  // Answer is E: keep E's text as the 4th option, drop D.
  return (
    options: [options[0], options[1], options[2], options[4]],
    correctIndex: 3,
    boldOptions: boldOptions.length == 5
        ? [boldOptions[0], boldOptions[1], boldOptions[2], boldOptions[4]]
        : List.filled(4, false),
    dropped: 'D',
  );
}

/// Defect markers: an option whose text is (or contains) one of these
/// bracketed markers is cut off / missing / illegible in the book
/// itself (MPT Q3: "(B) [cut off]"). And an in-book note that the
/// question could not be determined ("⚠ Could not determine /
/// defective", MPT Q106).
final _defectOptionRe = RegExp(
  r'\[\s*(cut\s*off|missing|illegible|not\s*clear|unreadable|damaged|torn|blurred|incomplete)\s*\]',
  caseSensitive: false,
);
final _defectNoteRe = RegExp(
  r'could\s+not\s+(be\s+)?determine|cannot\s+(be\s+)?determine|not\s+determinable',
  caseSensitive: false,
);

/// Reason a question is defective (MPT file), or null when it is not.
/// A question is defective when ANY option is a bracketed defect
/// marker ("[cut off]" / "[missing]" / "[illegible]") — a test
/// question needs all four options real — or when the block carries
/// an in-book "could not determine / defective" note (checked on the
/// lines AFTER the question text, never the question stem itself).
/// Defective questions are EXCLUDED with the book's own reason, never
/// guessed, never silently dropped.
/// True when [block] is a foreign-script ad block, not content
/// (Examveda / organisation files: Bengali ad text on page 1). The
/// block has no question/option/answer structure at all, and most of
/// its letters are in a non-Latin, non-Arabic script (Bengali here).
/// Urdu/Arabic-script content is NEVER noise — it lives inside
/// question blocks (MPT file), so this only fires on blocks with no
/// question structure. Used to COUNT the filtered lines, not to
/// change the drop (such blocks were already silently dropped).
bool _isForeignScriptNoiseBlock(List<SegmentedLine> block) {
  if (block.isEmpty) return false;
  var letters = 0;
  var bengali = 0;
  for (final l in block) {
    final t = _cleanStored(l.text);
    if (_questionStartLineRe.hasMatch(l.text) ||
        _optionRe.hasMatch(l.text) ||
        _answerLineRe.hasMatch(l.text)) {
      return false;
    }
    for (final r in t.runes) {
      if ((r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A)) {
        letters++;
      } else if (r >= 0x0980 && r <= 0x09FF) {
        letters++;
        bengali++;
      }
    }
  }
  return letters >= 3 && bengali * 2 > letters;
}

/// Known fact-card labels (organisation file — "WORLD INTERNATIONAL
/// ORGANIZATION"). A label is the left-hand word(s) of a label–value
/// pair; the value is everything after it. The book's misspelling
/// "SECRATARY" is a label too — it is recognised (so the pair is
/// found) but stored EXACTLY as printed, never corrected. Labels are
/// matched LONGEST-first, so "DIRECTOR GENERAL" wins over "DIRECTOR"
/// and "GENERAL SECRATARY" over "GENERAL".
const _factLabels = [
  'DIRECTOR GENERAL',
  'GENERAL SECRETARY',
  'GENERAL SECRATARY',
  'SECRETARY GENERAL',
  'SECRETARY',
  'SECRATARY',
  'ESTABLISHED',
  'FOUNDED',
  'HEADQUARTERS',
  'HEADQUARTER',
  'PRESIDENT',
  'DIRECTOR',
  'MEMBERS',
  'MEMBER',
  'LANGUAGE',
  'ORGANS',
  'DAY',
];

/// The longest known fact label that [text] starts with (case
/// insensitive), or null. The label must be followed by a gap /
/// space and a value (or be the whole line — a label awaiting its
/// value on the next line).
String? _factLabelAt(String text) {
  final upper = text.toUpperCase();
  for (final label in _factLabels) {
    if (upper == label) return label;
    if (upper.startsWith('$label ') || upper.startsWith('$label\t')) {
      return label;
    }
  }
  // "<ORG> DAY" (e.g. "UNO DAY", "FAO DAY", "ICAO DAY") — a
  // day-label: any short all-caps word(s) + " DAY".
  final dayM = RegExp(r'^([A-Z][A-Z ]{0,12})\s+DAY\b').firstMatch(upper);
  if (dayM != null) return '${dayM.group(1)} DAY';
  return null;
}

/// Recovers the space the extractor lost between an all-caps word
/// and a following number ("OCTOBER24. 1945" → "OCTOBER 24. 1945",
/// "APRIL4, 1947" → "APRIL 4, 1947"). This is NOT a spelling
/// correction — the book prints "OCTOBER 24. 1945"; the extractor's
/// word-gap heuristic dropped the space. Source spellings
/// ("SECRATARY", "ANTANIO", "PURTEEGAL") are left untouched.
String _recoverMonthDaySpace(String value) {
  return value.replaceAllMapped(
    RegExp(r'([A-Z]{3,})(\d)'),
    (m) => '${m.group(1)} ${m.group(2)}',
  );
}

/// Extracts label–value facts (organisation file) from the segmented
/// lines. Two arrival shapes (the app's own extraction):
/// * one line: "ESTABLISHED OCTOBER 24. 1945" (label + wide gap +
///   value on the same visual line — the gap collapses to a space,
///   a bold marker separates the runs). Split at the label.
/// * two lines: a bare label line ("ESTABLISHED") followed on the
///   SAME page by a value line (not a label / heading / question /
///   option / answer). Join them.
/// Each fact carries the card (part) it belongs to (from [structure])
/// and its page. A label with no value, and a value with no label,
/// are never stored. Promo / watermark / phone lines are already
/// filtered by [segmentLines] and never reach here.
List<FactPair> _extractFacts(
  List<SegmentedLine> lines,
  BookStructure? structure,
) {
  final facts = <FactPair>[];
  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    final text = stripBoldMarkers(line.text).trim();
    final label = _factLabelAt(text);
    if (label == null) {
      i++;
      continue;
    }
    // The label as printed (preserve the book's case/spelling).
    final printedLabel = text.substring(0, label.length);
    var value = text.substring(label.length).trim();
    final part = structure?.partForLine(line.lineIndex) ?? '';
    if (value.isNotEmpty) {
      // Same-line pair.
      facts.add(
        FactPair(
          label: printedLabel,
          value: _recoverMonthDaySpace(value),
          part: part,
          page: line.page,
        ),
      );
      i++;
      continue;
    }
    // Bare label — the value is the next line (same page, plain).
    if (i + 1 < lines.length) {
      final next = lines[i + 1];
      if (next.page == line.page) {
        final nt = stripBoldMarkers(next.text).trim();
        if (nt.isNotEmpty &&
            _factLabelAt(nt) == null &&
            !_questionStartLineRe.hasMatch(nt) &&
            !_optionRe.hasMatch(nt) &&
            !_answerLineRe.hasMatch(nt) &&
            !isAnswerKeyHeading(nt) &&
            monthHeadingLabel(nt) == null) {
          facts.add(
            FactPair(
              label: printedLabel,
              value: _recoverMonthDaySpace(nt),
              part: part,
              page: line.page,
            ),
          );
          i += 2;
          continue;
        }
      }
    }
    // Label with no value — not a fact, never stored.
    i++;
  }
  return facts;
}

String? _defectReason(
  List<String> options,
  List<SegmentedLine> restLines,
) {
  for (final o in options) {
    final m = _defectOptionRe.firstMatch(o);
    if (m != null) {
      return 'defective: an option is "${m.group(0)}" (cut off in the book)';
    }
  }
  for (final l in restLines) {
    if (_defectNoteRe.hasMatch(l.text)) {
      return 'defective: the book says it could not be determined';
    }
  }
  return null;
}

/// A question-start line: "Q1. …", "Q. …", "12. …", "12) …", "Q.1: …".
/// (answer_key.dart has the same pattern as a private regex; this is
/// the mcq_parser copy for the helpers below.)
final _questionStartLineRe = RegExp(
  r'^(Q\s*\d*[\.\)\:]|\d+[\.\)](?!\d))\s*\S',
  caseSensitive: false,
);

/// An answer line: "Answer: C", "Ans: (c)", "Correct: Islamabad" —
/// and the multi-word forms books actually print: "Correct Answer:
/// B) Asif Ali Zardari", "Correct Answers: C", "Right Answer: A",
/// "Answer Key: C", and the solution-closer "Final Answer: (C) 80"
/// (110 edition — same precedence as an explicit answer line, top of
/// the chain). The answer token is the named group `token`.
final _answerLineRe = RegExp(
  r'^(?:Final\s+Answers?|(?:Correct|Right)\s+Answers?|Correct|Right|Answers?|Ans|Key)\s*[:\-]\s*(?<token>.+)$',
  caseSensitive: false,
);
final _bareAnswerRe = RegExp(r'^[\(\[]?\s*([A-Da-d1-4])\s*[\)\]]?\s*$');
final _explanationRe = RegExp(
  r'^(Explanation|Exp)\s*[:\-]\s*(.+)$',
  caseSensitive: false,
);
final _subjectRe = RegExp(r'^Subject\s*[:\-]\s*(.+)$', caseSensitive: false);


/// Cross-check for a "Final Answer: (X) `<value>`" token: the trailing
/// value (e.g. "80") should be the letter's option text. Returns a
/// conflict message when the value exactly matches a DIFFERENT
/// option's text (the letter still wins — the caller records the
/// conflict but keeps the letter's index), or null when the value
/// confirms the letter or matches nothing (OCR junk is ignored).
String? _finalAnswerValueConflict(
  String token,
  List<String> options,
  int correctIndex,
) {
  final m = RegExp(
    r'^[\(\[]?\s*([A-Ea-e1-5])\s*(?:[\)\.\:\-]\s*)?(.*)$',
  ).firstMatch(token.trim());
  if (m == null) return null;
  var rest = m.group(2)!.trim();
  if (rest.isEmpty) return null;
  // Trailing punctuation / OCR junk after the value is not the value.
  rest = rest.replaceAll(RegExp(r'[^A-Za-z0-9]+$'), '').trim();
  if (rest.isEmpty) return null;
  final lower = rest.toLowerCase();
  if (options[correctIndex].trim().toLowerCase() == lower) return null;
  for (var i = 0; i < options.length; i++) {
    if (i == correctIndex) continue;
    if (options[i].trim().toLowerCase() == lower) {
      return 'Final Answer letter says ${String.fromCharCode(65 + correctIndex)} '
          'but the value "$rest" matches option ${String.fromCharCode(65 + i)} '
          '("${options[i]}") — using the letter.';
    }
  }
  return null;
}

/// Appends "(Note: …)" evidence lines to an explanation (the 109
/// edition's parenthetical notes). Notes are kept verbatim, prefixed
/// "Note: ", so the AI-inference step can match their content against
/// the options exactly as it does for explanations.
String _withNotes(String explanation, List<String> notes) {
  if (notes.isEmpty) return explanation;
  final notePart = notes.map((n) => 'Note: $n').join('\n');
  if (explanation.isEmpty) return notePart;
  return '$explanation\n$notePart';
}

/// Cheap deterministic proxy for "does this note answer this
/// question": the note text contains one of the question's option
/// texts (case-insensitive). Options shorter than 3 chars are skipped
/// — a 1–2 char value ("80") would match almost any note. The real
/// note → option matching is the AI agent's job; this only decides
/// whether a note is surfaced in diagnostics as "matches no option".
bool _noteMatchesOptions(String note, List<String> options) {
  final lower = note.toLowerCase();
  for (final o in options) {
    final opt = o.trim().toLowerCase();
    if (opt.length >= 3 && lower.contains(opt)) return true;
  }
  return false;
}

/// First answer token found in [lines] (Answer/Ans/Correct/Key line or a
/// bare "(c)" line), or null. A text answer that wraps to the next
/// line is joined with it (see [_isAnswerContinuation]).
/// Cleans an extracted answer token (short answer text, e.g. a
/// q-only "Ans:" value or a flashcard answer). Two bleed-through
/// shapes, both from scrambled / watermarked PDFs (PakMCQs 500 GK,
/// 19 Nov 2026):
/// (1) Watermark bleed — a URL is never part of a short answer, so
/// "Washington Redskins www.pakmcqs.com.pk" becomes "Washington
/// Redskins". (Question text is NOT stripped — a question may
/// legitimately mention a URL.)
/// (2) Merged next-question bleed — "Six. 39 which film had song
/// Springtime for Hitler?" is the answer "Six." followed by the
/// next question, merged by the two-column reading order. Cut at
/// ". NNN " when the remainder contains "?" (a real question
/// follows). A legit answer with a number ("Chapter 5 Summary")
/// has no "?" and is kept whole; "The 3 musketeers?" has no
/// ". " before the number and is kept whole.
String _cleanAnswerToken(String token) {
  var t = token.replaceAll(RegExp(r'\s*(?:https?://|www\.)\S+'), '').trim();
  final m = RegExp(r'\.\s+\d{1,3}\s+').firstMatch(t);
  if (m != null && t.substring(m.end).contains('?')) {
    t = t.substring(0, m.start + 1).trim();
  }
  // (3) Page-number + next-question bleed — "American 48 6 Goa
  // used to be a colony of which nation?": the answer "American",
  // then a footer page number (48), then the next question's
  // number (6) and stem. Cut at the FIRST bare number when the
  // remainder starts with ANOTHER bare number and contains "?".
  // The second number's follower must NOT be a question word —
  // "Henry 8 364 Which country …" is the answer "Henry 8" plus
  // the question number 364, and rule (4) below cuts it correctly
  // on 364 instead. "The 3 musketeers?" has no second number and
  // is kept whole.
  final m2 = RegExp(
    r'\s\d{1,3}\s+(?=\d{1,3}\s+(?![A-Za-z](?:hat|hich|ho|hom|hose|hen|here|hy|ow|ame)\b)[A-Z])',
    caseSensitive: false,
  ).firstMatch(t);
  if (m2 != null && t.substring(m2.end).contains('?')) {
    t = t.substring(0, m2.start).trim();
  }
  // (4) Bare-number + question-stem bleed — "Mustard 228 Which
  // Norwegian politicians name became a word for …": the answer,
  // then the next question's number and stem, with NO period, NO
  // page number, and the stem truncated before its "?" by the
  // column break — so rules (2) and (3) cannot fire. Two cuts:
  // (4a) the remainder starts with a question word (case-
  // insensitive — this book's stems sometimes start lowercase,
  // "39 which film …?") and is long enough to be a stem (≥ 15);
  // (4b) the remainder starts with a capital and is long (≥ 25)
  // — a noun-start stem ("116 Aescapalious emblem staff snake …").
  // Guards: "Chapter 5 Summary." is too short for either cut and
  // is kept; "Henry 8 364 Which country …" cuts on the SECOND
  // number (364), so "Henry 8" survives; "Apollo 11 Mission
  // Control" (15 chars) is below the (4b) threshold and is kept.
  final m4 = RegExp(
    r'\s\d{1,3}\s+(?=[A-Za-z](?:hat|hich|ho|hom|hose|hen|here|hy|ow|ame)\b)',
    caseSensitive: false,
  ).firstMatch(t);
  if (m4 != null && t.substring(m4.end).length >= 15) {
    t = t.substring(0, m4.start).trim();
  } else {
    final m5 = RegExp(r'\s\d{1,3}\s+(?=[A-Z])').firstMatch(t);
    if (m5 != null && t.substring(m5.end).length >= 25) {
      t = t.substring(0, m5.start).trim();
    }
  }
  return t;
}

/// A token that is ONLY a page indicator ("- 2 of 62", "Page 11")
/// is footer debris, never an answer. (A bare number alone, "42",
/// CAN be a legit answer — "What is 6 x 7?" — and is kept.)
bool _isPageIndicatorOnly(String token) {
  final t = token.trim();
  return RegExp(r'^-?\s*\d+\s+of\s+\d+\.?$').hasMatch(t) ||
      RegExp(r'^page\s+\d+\.?$', caseSensitive: false).hasMatch(t);
}

String? _answerTokenFromLines(List<SegmentedLine> lines) {
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].text;
    final ans = _answerLineRe.firstMatch(line);
    if (ans != null) {
      var token = _cleanStored(ans.namedGroup('token')!);
      if (i + 1 < lines.length &&
          _isAnswerContinuation(lines[i + 1], lines[i].page)) {
        token = '$token ${_cleanStored(lines[i + 1].text)}'.trim();
      }
      final cleaned = _cleanAnswerToken(token);
      // Footer debris as the "answer" — keep scanning; the real
      // answer may be on a later line. Never return it as the answer.
      if (cleaned.isEmpty || _isPageIndicatorOnly(cleaned)) continue;
      return cleaned;
    }
    if (_bareAnswerRe.hasMatch(line)) {
      final cleaned = _cleanAnswerToken(
        _bareAnswerRe.firstMatch(line)!.group(1)!,
      );
      if (cleaned.isEmpty || _isPageIndicatorOnly(cleaned)) continue;
      return cleaned;
    }
  }
  return null;
}

String _explanationFromLines(List<SegmentedLine> lines) {
  for (final seg in lines) {
    final exp = _explanationRe.firstMatch(seg.text);
    if (exp != null) return _cleanStored(exp.group(2)!);
  }
  return '';
}

Subject _subjectFromLines(List<SegmentedLine> lines, Subject fallback) {
  for (final seg in lines) {
    final sub = _subjectRe.firstMatch(seg.text);
    if (sub != null) return Subject.fromLabel(sub.group(1)!);
  }
  return fallback;
}

class _Standard {
  _Standard({
    required this.questionText,
    required this.options,
    required this.correctIndex,
    required this.answerSource,
    required this.boldOptions,
    required this.explanation,
    required this.subject,
    this.tickIndex,
    this.asteriskIndex,
    this.conflicts = const [],
    this.droppedFive,
  });

  /// Multi-line question text (continuations joined; a wrapped
  /// one-liner's tail appended when its options sat on a later line).
  final String questionText;

  final List<String> options;

  /// Null when the block has 4 options but no (usable) answer signal —
  /// the caller keeps it as an answer-key candidate instead of
  /// dropping it.
  final int? correctIndex;

  /// Which signal resolved the answer: 'answer-line' | 'tick' |
  /// 'bold' | 'asterisk' | '' (none — key candidate).
  final String answerSource;

  /// Per-option bold flags, parallel to [options] (the extractor's
  /// bold-run signal, exposed for tests and the preview).
  final List<bool> boldOptions;

  /// Index of the ticked option, when exactly one option carries
  /// ✓/✔ (null when none, or when several are ticked — ambiguous).
  final int? tickIndex;

  /// Index of the asterisked option, when exactly one option carries
  /// a trailing `*` (null when none, or when several are asterisked —
  /// ambiguous). The Dogar answer marker.
  final int? asteriskIndex;

  final String explanation;
  final Subject subject;

  /// Signal conflicts recorded while resolving (see [_resolveSignals]).
  final List<String> conflicts;

  /// Letter dropped by a 5→4 normalisation (Examveda): 'E' when the
  /// answer was A–D (E dropped), 'D' when the answer was E (E's text
  /// kept as the 4th option, D dropped). Null when no normalisation
  /// happened (4 options, or a 5-option candidate with no answer yet).
  final String? droppedFive;
}

/// Standard block: options on their own lines + an answer line.
/// [qText] is the multi-line question text from
/// [_splitQuestionAndRest]; [rest] is the lines after it. Returns null
/// when the block does not have exactly 4 options. [correctIndex] is
/// null when no answer signal resolved — the caller keeps the block as
/// an answer-key candidate. Two options may share one line ("(A) 1941
/// (B) 1942", the scanned-paper shape); a line's question tail is
/// appended to the question text when its options open the set.
_Standard? _parseStandardBlock(
  String qText,
  List<SegmentedLine> rest,
  Subject fallback, {
  String where = 'Block',
}) {
  var questionText = qText;
  final options = <String>[];
  final boldOptions = <bool>[];
  final tickedIndices = <int>[];
  // Asterisked options (Dogar `*` answer marker): exactly one is a
  // signal; several are ambiguous — ignored, conflict recorded.
  final asteriskedIndices = <int>[];
  // Raw option segments, parallel to [options]: the un-cleaned text
  // of each option, so a wrapped option's continuation line can be
  // appended and the signals (bold / tick / asterisk) re-extracted
  // from the JOINED text (the `*` often sits on the continuation).
  final rawOptions = <String>[];
  var explanation = '';
  var subject = fallback;
  var hasSubject = false;
  String? answerToken;
  // "Final Answer:" token, when the answer came from a solution
  // closer (for the value cross-check below).
  String? finalAnswerToken;
  // Worked-solution state: lines between "Solution:" and the answer
  // are working/explanation, never new options or questions.
  var inSolution = false;
  final solutionBuf = StringBuffer();

  // Appends [rawText] to the last option and re-extracts its signals
  // from the JOINED text (the `*` / tick / bold often sit on the
  // continuation). Returns true when a join happened. Used for a
  // wrapped option's tail: its own line, a split line's prefix, or an
  // option line's prefix.
  bool joinContinuation(String rawText) {
    if (options.isEmpty) return false;
    if (!_isOptionContinuation(options.last, rawText)) return false;
    final last = options.length - 1;
    final wasTick = tickedIndices.contains(last);
    final wasAsterisk = asteriskedIndices.contains(last);
    rawOptions[last] = '${rawOptions[last]} ${_cleanStored(rawText)}'.trim();
    final o = _extractOption(rawOptions[last]);
    options[last] = o.text;
    boldOptions[last] = o.bold;
    tickedIndices.remove(last);
    asteriskedIndices.remove(last);
    if (o.tick || wasTick) tickedIndices.add(last);
    if (o.asterisk || wasAsterisk) asteriskedIndices.add(last);
    return true;
  }

  for (var i = 0; i < rest.length; i++) {
    final segLine = rest[i];
    var line = segLine.text;
    // A leading tick ("✓ B) China", "(✓) B) China") marks the first
    // option on this line.
    final leading = _stripLeadingTick(line);
    line = leading.line;
    final lineTick = leading.tick;

    // "Solution:" heading — the working that follows is explanation,
    // never new options or questions (the block splitter already kept
    // it in this block). Text after the colon is the first working line.
    if (isSolutionHeading(line)) {
      inSolution = true;
      final after = solutionHeadingRe.firstMatch(line)?.group(1) ?? '';
      if (_cleanStored(after).isNotEmpty) {
        solutionBuf.writeln(_cleanStored(after));
      }
      continue;
    }
    if (inSolution) {
      // An answer line inside the working still resolves as an
      // explicit answer and ends the solution block.
      final solAns = _answerLineRe.firstMatch(line);
      if (solAns != null) {
        inSolution = false;
        answerToken = _cleanStored(solAns.namedGroup('token')!);
        if (finalAnswerRe.hasMatch(line)) finalAnswerToken = answerToken;
        if (i + 1 < rest.length &&
            _isAnswerContinuation(rest[i + 1], segLine.page)) {
          answerToken =
              '$answerToken ${_cleanStored(rest[i + 1].text)}'.trim();
          if (finalAnswerToken != null) finalAnswerToken = answerToken;
          i++;
        }
        continue;
      }
      // Working / explanation — never an option or a question start.
      final cleaned = _cleanStored(line);
      if (cleaned.isNotEmpty) solutionBuf.writeln(cleaned);
      continue;
    }

    // Two (or more) options on one line.
    final split = _splitOptionLine(line);
    if (split != null &&
        options.length + split.options.length <= 4) {
      if (split.prefix.isNotEmpty && options.isEmpty) {
        questionText =
            '$questionText ${_cleanStored(split.prefix)}'.trim();
      } else if (split.prefix.isNotEmpty) {
        // The prefix is the previous option's wrapped tail
        // ("actual data (B) …") — join it before adding the new ones.
        joinContinuation(split.prefix);
      }
      for (var k = 0; k < split.options.length; k++) {
        final o = _extractOption(split.options[k]);
        options.add(o.text);
        rawOptions.add(split.options[k]);
        boldOptions.add(o.bold);
        if (o.tick || (lineTick && k == 0)) {
          tickedIndices.add(options.length - 1);
        }
        if (o.asterisk) asteriskedIndices.add(options.length - 1);
      }
      continue;
    }

    final opt = _optionRe.firstMatch(line);
    if (opt != null && options.length < 4) {
      // A prefix before this option's marker is the previous option's
      // wrapped tail ("actual data (B) …") — join it first.
      final optPrefix = line.substring(0, opt.start).trim();
      if (optPrefix.isNotEmpty) joinContinuation(optPrefix);
      final o = _extractOption(opt.group(2)!.trim());
      options.add(o.text);
      rawOptions.add(opt.group(2)!.trim());
      boldOptions.add(o.bold);
      if (o.tick || lineTick) tickedIndices.add(options.length - 1);
      if (o.asterisk) asteriskedIndices.add(options.length - 1);
      continue;
    }
    // 5th option (E) — only after A–D are collected (see [_optionERe]).
    if (options.length == 4) {
      final optE = _optionERe.firstMatch(line);
      if (optE != null) {
        final o = _extractOption(optE.group(2)!.trim());
        options.add(o.text);
        rawOptions.add(optE.group(2)!.trim());
        boldOptions.add(o.bold);
        if (o.tick || lineTick) tickedIndices.add(options.length - 1);
        if (o.asterisk) asteriskedIndices.add(options.length - 1);
        continue;
      }
    }
    final ans = _answerLineRe.firstMatch(line);
    if (ans != null) {
      answerToken = _cleanStored(ans.namedGroup('token')!);
      if (finalAnswerRe.hasMatch(line)) finalAnswerToken = answerToken;
      // A text answer that wraps to the next line is joined with it.
      if (i + 1 < rest.length &&
          _isAnswerContinuation(rest[i + 1], segLine.page)) {
        answerToken =
            '$answerToken ${_cleanStored(rest[i + 1].text)}'.trim();
        if (finalAnswerToken != null) finalAnswerToken = answerToken;
        i++;
      }
      continue;
    }
    if (_bareAnswerRe.hasMatch(line) && answerToken == null) {
      answerToken = _bareAnswerRe.firstMatch(line)!.group(1)!;
      continue;
    }
    final exp = _explanationRe.firstMatch(line);
    if (exp != null) {
      explanation = _cleanStored(exp.group(2)!);
      continue;
    }
    final sub = _subjectRe.firstMatch(line);
    if (sub != null) {
      subject = Subject.fromLabel(sub.group(1)!);
      hasSubject = true;
      continue;
    }
    // A wrapped option's continuation line: the printed option ran
    // past the line edge, so its tail (often the `*` marker) sits on
    // the next line. Join it into the last option. Any other plain
    // line after the options started is explanation prose / noise —
    // ignored. (Plain lines BEFORE the first option are question
    // continuations, already joined by [_splitQuestionAndRest].)
    if (options.isNotEmpty) {
      joinContinuation(_cleanStored(line));
    }
  }

  if (options.length != 4 && options.length != 5) return null;
  // Exactly one ticked option is a signal; several ticked options are
  // ambiguous — the tick is ignored (recorded as a conflict below).
  // Same rule for the asterisk marker.
  final tickIndex = tickedIndices.length == 1 ? tickedIndices.first : null;
  final asteriskIndex =
      asteriskedIndices.length == 1 ? asteriskedIndices.first : null;
  final resolved = _resolveSignals(
    answerToken: answerToken,
    options: options,
    tickIndex: tickIndex,
    boldOptions: boldOptions,
    asteriskIndex: asteriskIndex,
    where: where,
  );
  // 5-option set (A–E, Examveda): normalise to exactly 4 now that the
  // answer is known. When the answer is not yet known (candidate),
  // the 5 options ride through and the second pass normalises them
  // once the key resolves the answer.
  var normOptions = options;
  var normBold = boldOptions;
  var normCorrect = resolved.correctIndex;
  var normAsterisk = asteriskIndex;
  String? droppedFive;
  if (options.length == 5 && resolved.correctIndex != null) {
    final n = _normaliseFiveOptions(
      options,
      resolved.correctIndex!,
      boldOptions,
    );
    normOptions = n.options;
    normBold = n.boldOptions;
    normCorrect = n.correctIndex;
    droppedFive = n.dropped;
    // Remap the asterisk index through the same drop: dropping E
    // removes index 4; dropping D removes index 3 and shifts E to 3.
    if (normAsterisk != null) {
      if (droppedFive == 'E') {
        if (normAsterisk == 4) normAsterisk = null;
      } else if (droppedFive == 'D') {
        if (normAsterisk == 3) {
          normAsterisk = null;
        } else if (normAsterisk == 4) {
          normAsterisk = 3;
        }
      }
    }
  }
  final conflicts = <List<String>>[resolved.conflicts];
  if (tickedIndices.length > 1) {
    conflicts.add([
      '$where: ${tickedIndices.length} options are ticked '
      '(${tickedIndices.map((i) => String.fromCharCode(65 + i)).join(', ')}) '
      '— tick signal ignored, answer still needed.',
    ]);
  }
  if (asteriskedIndices.length > 1) {
    conflicts.add([
      '$where: ${asteriskedIndices.length} options are asterisked '
      '(${asteriskedIndices.map((i) => String.fromCharCode(65 + i)).join(', ')}) '
      '— asterisk signal ignored, answer still needed.',
    ]);
  }
  // "Final Answer: (X) <value>" cross-check: the trailing value
  // should be the letter's option text. The letter still wins; a
  // value matching a different option is recorded, never silently
  // resolved.
  if (finalAnswerToken != null && normCorrect != null) {
    final valueConflict = _finalAnswerValueConflict(
      finalAnswerToken,
      normOptions,
      normCorrect,
    );
    if (valueConflict != null) conflicts.add(['$where: $valueConflict']);
  }
  // The worked solution is the question's explanation.
  final solutionText = solutionBuf.toString().trim();
  final fullExplanation = [explanation, solutionText]
      .where((s) => s.isNotEmpty)
      .join('\n');
  return _Standard(
    questionText: questionText,
    options: normOptions,
    correctIndex: normCorrect,
    answerSource: resolved.answerSource,
    boldOptions: normBold,
    tickIndex: tickIndex,
    asteriskIndex: normAsterisk,
    explanation: fullExplanation,
    subject: hasSubject ? subject : fallback,
    conflicts: conflicts.expand((c) => c).toList(),
    droppedFive: droppedFive,
  );
}

class _OneLiner {
  _OneLiner({
    required this.questionText,
    required this.options,
    this.answerToken,
    this.tickIndex,
    this.asteriskIndex,
    this.boldOptions = const [],
  });

  final String questionText;
  final List<String> options;
  final String? answerToken;

  /// Index of the ticked option, when exactly one option carries
  /// ✓/✔ (null when none, or when several are ticked).
  final int? tickIndex;

  /// Index of the asterisked option, when exactly one option carries
  /// a trailing `*` (null when none, or when several are asterisked).
  final int? asteriskIndex;

  /// Per-option bold flags, parallel to [options].
  final List<bool> boldOptions;
}

/// One-liner: question + 4 options on one line. The 4 option markers
/// must appear as a complete sequence — (a)(b)(c)(d), 1 2 3 4, or
/// (i)(ii)(iii)(iv) — so a stray "(a)" or a leading "1." in the question
/// text cannot fake a match.
_OneLiner? _parseOneLiner(String line) {
  final markerRe = RegExp(
    r'[\(\[]?\s*(iv|iii|ii|i|[a-dA-D]|[1-4])\s*[\)\.\:]',
    caseSensitive: false,
  );
  final matches = markerRe.allMatches(line).toList();
  if (matches.length < 4) return null;

  const sequences = [
    ['a', 'b', 'c', 'd'],
    ['1', '2', '3', '4'],
    ['i', 'ii', 'iii', 'iv'],
  ];
  for (var w = 0; w + 3 < matches.length; w++) {
    final window = matches.sublist(w, w + 4);
    final keys = window
        .map((m) => m.group(1)!.toLowerCase())
        .toList();
    final isSeq = sequences.any(
      (s) =>
          s[0] == keys[0] &&
          s[1] == keys[1] &&
          s[2] == keys[2] &&
          s[3] == keys[3],
    );
    if (!isSeq) continue;

    final questionText = _stripTicks(
      _cleanStored(
        line.substring(0, window[0].start).replaceFirst(
          questionPrefixRe,
          '',
        ),
      ),
    );
    if (questionText.isEmpty) return null;

    final options = <String>[];
    final boldOptions = <bool>[];
    final tickedIndices = <int>[];
    final asteriskedIndices = <int>[];
    for (var k = 0; k < 4; k++) {
      final start = window[k].end;
      final end = k < 3 ? window[k + 1].start : line.length;
      var text = line.substring(start, end).trim();
      // A trailing answer tail ("Ans: (c)") belongs to the answer, not
      // to option 4.
      if (k == 3) {
        final tail = RegExp(
          r'\b((?:correct|right)\s+answers?|correct|right|ans|answer|key)\s*[:\-]\s*(.+)$',
          caseSensitive: false,
        ).firstMatch(text);
        if (tail != null) {
          text = text.substring(0, tail.start).trim();
        }
      }
      text = text
          .replaceAll(RegExp(r'[\s,;:\-]+$'), '')
          .replaceAll(RegExp(r'^[\s,;:\-]+'), '')
          .trim();
      if (text.isEmpty) return null;
      final o = _extractOption(text);
      if (o.text.isEmpty) return null;
      options.add(o.text);
      boldOptions.add(o.bold);
      if (o.tick) tickedIndices.add(k);
      if (o.asterisk) asteriskedIndices.add(k);
    }

    // Answer on the same line, after the last option.
    String? answerToken;
    final tail = RegExp(
      r'\b((?:correct|right)\s+answers?|correct|right|ans|answer|key)\s*[:\-]\s*(.+)$',
      caseSensitive: false,
    ).firstMatch(line.substring(window[3].end));
    if (tail != null) answerToken = _cleanStored(tail.group(2)!);
    return _OneLiner(
      questionText: questionText,
      options: options,
      answerToken: answerToken,
      tickIndex: tickedIndices.length == 1 ? tickedIndices.first : null,
      asteriskIndex:
          asteriskedIndices.length == 1 ? asteriskedIndices.first : null,
      boldOptions: boldOptions,
    );
  }
  return null;
}

/// Answer for a Q-only block: same-line "Q … Ans: X" or an answer line
/// in the following lines. Returns null when there is no answer. A
/// text answer that wraps to the next line is joined with it.
/// True when [stem] is a real Q-only question stem, not OCR debris.
/// A fragment block's bare "(A)" line is only an answer when the
/// stem reads like a question: ≥ 10 chars, ≥ 2 words, and at least
/// one word ≥ 3 chars (so "Wh to e" / "All follo" / "Bi" / "T" —
/// facing-page bleed — are rejected, while short real questions
/// like "What is UNO?" pass).
bool _isRealQOnlyStem(String stem) {
  final t = stem.trim();
  if (t.length < 10) return false;
  final words = t.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.length < 2) return false;
  if (!words.any((w) => w.length >= 3)) return false;
  return true;
}

String? _qOnlyAnswer(String firstLine, int firstPage, List<SegmentedLine> rest) {
  final inline = RegExp(
    r'\b((?:correct|right)\s+answers?|correct|right|ans|answer|key)\s*[:\-]\s*(.+)$',
    caseSensitive: false,
  ).firstMatch(firstLine);
  if (inline != null) {
    var a = _cleanStored(inline.group(2)!);
    if (a.isNotEmpty) {
      if (rest.isNotEmpty &&
          _isAnswerContinuation(rest.first, firstPage)) {
        a = '$a ${_cleanStored(rest.first.text)}'.trim();
      }
      final cleaned = _cleanAnswerToken(a);
      // Footer debris as the "answer" — fall through to the rest
      // scan instead of returning it; the real answer may follow.
      if (cleaned.isNotEmpty && !_isPageIndicatorOnly(cleaned)) {
        return cleaned;
      }
    }
  }
  return _answerTokenFromLines(rest);
}
