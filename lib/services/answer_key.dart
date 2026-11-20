/// Answer-key support for [parseMcqs] (see `mcq_parser.dart`).
///
/// Many MCQ books — including the user's mcqsplanet Current Affairs
/// packs — print NO answer inside each question. The answers live in a
/// trailing "ANSWER KEY" section, sometimes one key per paper
/// ("Paper 1 Answer Key", "Answers – Paper 2"). v1.1 skipped every such
/// question ("no question matched the formats"); this file lets the
/// parser join them back up.
///
/// Two passes, driven by [segmentText]:
///
/// 1. **Segmentation.** The raw lines are split into question lines and
///    key sections. A key section starts at a key heading ("Answer Key",
///    "Answers", "Key", "Answer Keys", "Paper 1 Answer Key",
///    "Answers – Paper 1", "Test 1 Key", "Set A Key", "(Answer Key)")
///    and runs until the next paper/key heading, the next real
///    question, or end of text. Key-section lines are EXCLUDED from
///    question parsing — they are never questions. Paper headings
///    ("Paper 1", "Paper No. 1", "Test 1", "Set A") and month headings
///    ("January 2026" — the Pace book numbers its questions per month)
///    split the book into segments; questions are numbered within each
///    segment, and a key entry joins to the question with the same
///    number in the SAME segment. With no headings the whole book is
///    one segment ([defaultPaperLabel]).
///
///    A bare key heading (no paper named) belongs to the paper whose
///    questions immediately PRECEDE it — a key printed at the top of a
///    page belongs to the paper that ended on the previous page, not
///    to the paper whose heading follows it. A key entry that matches
///    no question in its own segment is reported in
///    [SegmentedText.unmatchedKeyEntries] via the parser, never
///    silently dropped or force-joined to another paper (strict paper
///    rule, owner 20 Nov 2026: one paper's key NEVER answers another
///    paper's questions, even when that paper's own key has no entry
///    for the number).
///
/// 2. **Key-entry parsing.** A key section is treated as one token
///    stream ([parseKeyEntries]), so compact runs ("1.C 2.A 3.B …" on
///    one line) and multi-column layouts (entries out of reading order)
///    both work — entries are looked up by number, never by position.
///    Supported entry shapes: "1. C", "1-C", "1) C", "1: C", "Q1: C",
///    "Q1 C" (a Q-prefixed entry needs no separator), "1. A) Asif Ali
///    Zardari" (letter + text), "61. (C) 3" and
///    "62. (A) Portable Document Format" (number + "(letter)" + full
///    answer text — the letter wins, the text is the fallback), and
///    "1. Asif Ali Zardari" (answer as TEXT, matched against the
///    question's options by the caller via [resolveAnswerToken]).
///
/// Strict paper rule (owner, 20 Nov 2026): a key applies ONLY to the
/// paper it names. A key entry joins the question with the same
/// number in the SAME segment — never another paper, even when that
/// paper's key has no entry for the number (the old cross-paper
/// "second chance" fallback is gone). [SegmentedText.explicitKeyPapers]
/// records which papers were named explicitly by a key heading, so
/// the parser can report a key whose paper has no questions at all
/// instead of silently applying it elsewhere.
library;

import '../models/question.dart';
import 'paper_identity.dart';

/// Inline marker the extractor appends at the END of a bold text run
/// (U+E000, private use — never in real book text). The parser reads
/// it as the "bold" answer signal and strips it before storing any
/// text, so it never reaches a stored question / option / answer.
const boldRunMarker = '\uE000';

/// True when [s] carries a bold run (see [boldRunMarker]).
bool hasBoldMarker(String s) => s.contains(boldRunMarker);

/// Removes every bold-run marker from [s].
String stripBoldMarkers(String s) => s.replaceAll(boldRunMarker, '');

/// Question-number prefix, shared by the parser's strip and number
/// extraction: "Q.1:", "Q1.", "Q. 1.", "Q.", "1.", "12)". The old
/// `Q\s*\d*[\.\)\:]` matched only "Q." of "Q.1:" and left "1: " at the
/// start of the question text. The bare-`Q` alternative requires a
/// separator, so a question starting "Quality …" is never stripped.
/// NOTE (Phase A): a bare-number alternative ("3 What …?") does NOT
/// belong here — this regex is case-insensitive, and under
/// case-insensitive matching `[a-z]` also matches capitals, so a
/// `(?![a-z0-9])` lookahead would reject "3 What …" as well as
/// "3 apples …". The bare-number strip lives in mcq_parser.dart
/// ([_stripQuestionNumberPrefix], case-sensitive) instead.
final questionPrefixRe = RegExp(
  r'^(?:Q\s*\.?\s*\d+\s*[\.\)\:]?|Q\s*[\.\)\:]|\d+\s*[\.\)\:])\s*',
  caseSensitive: false,
);

/// A "Solution:" heading line (worked-solution block, e.g. the 110
/// edition's maths questions). Matches "Solution", "Solution:",
/// "Solution: Let x = …", "SOLUTION:" — the group is the working text
/// after the colon, if any. It does NOT match a sentence that merely
/// contains the word ("Find the solution of x" has no colon/dash
/// after "Solution"). Solution working lines are explanation, never
/// new questions or options (see the parser's solution guard).
final solutionHeadingRe = RegExp(
  r'^\s*solution\s*(?:[:\-]\s*(.*))?$',
  caseSensitive: false,
);

/// True when [line] is a "Solution:" heading (see [solutionHeadingRe]).
bool isSolutionHeading(String line) =>
    solutionHeadingRe.hasMatch(stripBoldMarkers(line).trim());

/// A "Final Answer:" line — the line that closes a worked-solution
/// block (110 edition: "Final Answer: (C) 80"). Matches the clean
/// form and the OCR-noisy form ("Final Answer:(C)80" — no space after
/// the colon, trailing garbage). The answer token is group 1; resolve
/// it by letter, using any trailing value as a cross-check.
final finalAnswerRe = RegExp(
  r'^\s*final\s+answers?\s*:\s*(.+)$',
  caseSensitive: false,
);

/// A "(Note: …)" / "(Note - …)" / "Note: …" line — answer evidence
/// (the 109 edition prints a parenthetical note stating the fact
/// that answers a nearby question). Returns the note content, or null
/// when [line] is not a note line. A trailing ")" is stripped when
/// the line opens with "(" (the parenthetical's closing paren — the
/// sentence's own period is kept).
String? noteContent(String line) {
  final clean = stripBoldMarkers(line).trim();
  final m = RegExp(
    r'^\(?\s*note\s*[:\-]\s*(.+)$',
    caseSensitive: false,
  ).firstMatch(clean);
  if (m == null) return null;
  var content = m.group(1)!.trim();
  if (clean.startsWith('(') && content.endsWith(')')) {
    content = content.substring(0, content.length - 1).trim();
  }
  return content.isEmpty ? null : content;
}

/// Label used for the (single) paper segment when the book has no paper
/// headings at all.
const defaultPaperLabel = 'Paper 1';

/// One line that belongs to the question body, tagged with the paper
/// segment it was found in (and, for page-aware parsing, its 1-based
/// PDF page and its 0-based index in the flattened line stream).
class SegmentedLine {
  const SegmentedLine(this.text, this.paper, [this.page = 0, this.lineIndex = -1]);

  final String text;
  final String paper;

  /// 1-based PDF page; 0 = unknown (TXT / pasted text).
  final int page;

  /// 0-based index in the flattened page-ordered line stream;
  /// -1 = unknown. Used to assign a question its book part.
  final int lineIndex;
}

/// Result of [segmentText]: the question lines (key sections and
/// headings removed) plus the parsed key entries per paper segment.
class SegmentedText {
  const SegmentedText({
    required this.questionLines,
    required this.keyEntries,
    required this.keySectionsFound,
    this.noiseLinesFiltered = 0,
    this.explicitKeyPapers = const {},
  });

  final List<SegmentedLine> questionLines;

  /// keyEntries[paperLabel][questionNumber] = raw answer token
  /// (a letter "C", a number "3", or the option's own text).
  final Map<String, Map<int, String>> keyEntries;

  /// How many key headings were found (0 when the book has no key).
  final int keySectionsFound;

  /// Papers a key heading NAMED explicitly ("Answers – Paper 60",
  /// "ANSWER KEY PAPER 60") — as opposed to papers a bare heading
  /// ("ANSWER KEY") was merely attributed to via the preceding
  /// questions. Strict paper rule (owner, 20 Nov 2026): entries under
  /// an explicit paper apply ONLY to that paper; an explicit paper
  /// with no questions in the import is reported, never silently
  /// applied elsewhere.
  final Set<String> explicitKeyPapers;

  /// Watermark / promo / phone noise lines filtered out before
  /// parsing (Examveda / organisation files). They never became
  /// question lines.
  final int noiseLinesFiltered;
}

/// "Model" is a qualifier, not a kind: "MODEL PAPER 66" and
/// "ANSWER KEY: Model Paper 66" (PPSC-66, 20 Nov 2026 — the word
/// "Model" used to break both the paper-heading match and the
/// key-heading paper-ref strip, so the whole key went unrecognised).
/// The optional prefix is non-capturing, so the kind (group 1) and
/// id (group 2) numbering is unchanged everywhere this fragment is
/// used (paper headings, paper references, key-heading strips).
final _paperKindRe = r'(?:model\s+)?(paper|test|set|part|section)';
final _paperIdRe = r'([0-9]+|[A-Z])';

/// "Paper 1", "Paper No. 1", "Test 2", "Set A" — the whole line must be
/// (just) the heading, so "Part 1: Introduction" is not one.
final _paperHeadingRe = RegExp(
  '^$_paperKindRe\\s*(?:no\\.?|number|#)?\\s*$_paperIdRe\\s*[:\\-–—]?\\s*\$',
  caseSensitive: false,
);

/// A paper reference anywhere in a line ("Paper 1" in
/// "Answers – Paper 1").
final _paperRefRe = RegExp(
  '$_paperKindRe\\s*(?:no\\.?|number|#)?\\s*$_paperIdRe\\b',
  caseSensitive: false,
);

/// Key-heading words, after any paper reference has been stripped.
final _keyCoreRe = RegExp(
  r'^(answer\s*keys?|answers?|answer\s*sheet|correct\s*answers?|keys?)\s*[:\-–—]?\s*$',
  caseSensitive: false,
);

/// An "Explanation:" / "Associated Information:" heading (PPSC-66
/// Paper 67, 20 Nov 2026): prose + bullets explaining the PREVIOUS
/// question's answer — never a question. The whole line must be just
/// the heading (optional colon, optional leading bullet/dash), so a
/// stem that merely mentions explanation ("Explanation of the term
/// …") never matches.
final _explanationHeadingRe = RegExp(
  r'^[-•\s]*(explanation|associated\s+information)\s*:?\s*$',
  caseSensitive: false,
);

/// A question line: "Q1. …", "Q. …", "12. …", "12) …".
final _questionStartRe = RegExp(
  r'^(Q\s*\d*[\.\)\:]|\d+[\.\)](?!\d))\s*\S',
  caseSensitive: false,
);

/// An option on its own line: "A) …", "b. …", "(C) …".
final _optionLineRe = RegExp(r'^\(?([A-Da-d])[\)\.\:\-]\s*(.+)$');

/// An option marker inside a one-line question.
final _markerRe = RegExp(
  r'[\(\[]?\s*(iv|iii|ii|i|[a-dA-D]|[1-4])\s*[\)\.\:]',
  caseSensitive: false,
);

/// Month heading: "January 2026", "Current Affairs January 2026
/// (International & National …)", "September 2026". The month must
/// come first or right after a subject phrase — a question
/// continuation mentioning a month ("imposed in January 2026") is not
/// a heading. Month headings split key-join segments (the Pace book
/// numbers its questions per month, one "(Answer Key)" per month).
final _monthHeadingRe = RegExp(
  r'^\s*(?:current affairs|general affairs|general knowledge|pakistan affairs)?\s*'
  r'(January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)\b[^0-9]{0,20}\b(19|20)\d\d\b',
  caseSensitive: false,
);

const _fullMonthNames = {
  'jan': 'January',
  'feb': 'February',
  'mar': 'March',
  'apr': 'April',
  'may': 'May',
  'jun': 'June',
  'jul': 'July',
  'aug': 'August',
  'sep': 'September',
  'sept': 'September',
  'oct': 'October',
  'nov': 'November',
  'dec': 'December',
};

/// "January 2026" segment label for a month-heading line, or null.
/// Abbreviations are normalised to full month names so "Jan 2026"
/// and "January 2026" are the same segment.
String? monthHeadingLabel(String line) {
  final m = _monthHeadingRe.firstMatch(line);
  if (m == null) return null;
  final month = m.group(1)!.toLowerCase();
  final full = _fullMonthNames[month.substring(0, 3)] ??
      '${month[0].toUpperCase()}${month.substring(1)}';
  // The year is the 4-digit number after the month.
  final year = RegExp(r'\b(19|20)\d\d\b').firstMatch(line)?.group(0);
  if (year == null) return null;
  return '$full $year';
}

/// Start of one key entry inside a key token stream:
/// "1. ", "1-C ", "1) ", "Q1: ", "61. (C) …". After the separator
/// there must be whitespace, an answer letter, or end of blob — so a
/// decimal inside an answer ("43.75%") is never read as a new entry
/// ("43."), while compact runs ("1.C 2.A") still work.
// The lookahead accepts A–E, not just A–D: E is a real answer
// letter for 5-option questions (fiveOptionAnswerE), so a key entry
// "1-E" must be PARSED (and then reported unresolved if the question
// has only 4 options) rather than silently dropped.
final _keyEntryStartRe = RegExp(
  r'(?:^|\s)(?:Q\s*)?(\d+)\s*[\.\)\:\-](?=\s|[A-Ea-e]\b|$)',
  caseSensitive: false,
);

/// True when a key entry's raw token means "answer unknown" — the
/// book's key prints "?" for it (MPT file: "3. ?" / "106. ?"). Such a
/// question is EXCLUDED with reason, never guessed.
bool isUnknownKeyToken(String token) {
  final t = token.trim();
  return t == '?' || t == '??' || t.toLowerCase() == 'unknown';
}

/// True when [line] is watermark / promo noise, never content
/// (Examveda / organisation files):
/// * a bare digit line ("8", "93", "11" — a scattered watermark
///   digit; a real question number always carries punctuation
///   ("8.") or text, a real option starts with a letter, a key
///   entry has a letter after the number);
/// * a promo line ("LIKE & FOLLOW FACEBOOK PAGE FOR MORE INFORMATIVE
///   MATERIAL …" — the compiler's promo; its phone number must never
///   be stored, so the whole line is dropped);
/// * a bare phone-number line (digits / spaces / + / - / ( ) only,
///   ≥7 digits, no letters — never a question, option or answer).
/// A lone digit is noise ONLY when it is not part of a
/// question/option/answer/key line — these shapes never contain one.
/// Foreign-script (Bengali) ad blocks are handled at block level in
/// the parser (they are multi-line prose, not single noise lines);
/// Urdu/Arabic-script content inside a question is content, never
/// noise — this filter never looks at script alone.
bool isNoiseLine(String line) {
  final t = stripBoldMarkers(line).trim();
  if (t.isEmpty) return false;
  // Bare digit line (1–4 digits, nothing else).
  if (RegExp(r'^\d{1,4}$').hasMatch(t)) return true;
  // Promo line.
  final lower = t.toLowerCase();
  if (lower.contains('like') &&
      lower.contains('follow') &&
      lower.contains('facebook')) {
    return true;
  }
  if (lower.contains('for more informative material')) return true;
  // Running header / page furniture (PPSC-66, 20 Nov 2026): a book
  // title + page number that repeats on every page — never a
  // question. "Papers of 2021 521" (title + year + page) and "526
  // Advanced PPSC MCQs Model Papers (Volume 2)" (page + title +
  // volume). Neither shape can be a question stem: a stem never
  // starts with "Papers of YYYY NNN" and never ends with "(Volume
  // N)". A bare-numbered question ("52 Who founded …?") matches
  // neither — it has no "(Volume N)" tail and no "Papers of" head.
  if (RegExp(r'^papers of \d{4} \d+$').hasMatch(lower)) return true;
  if (RegExp(r'^\d{2,4}\s+\S.*\(volume \d+\)$').hasMatch(lower)) {
    return true;
  }
  // Bare phone-number line: only digits/spaces/+/-/()/., ≥7 digits.
  if (RegExp(r'^[\d\s\+\-\(\)\.]{7,}$').hasMatch(t) &&
      RegExp(r'\d').allMatches(t).length >= 7 &&
      !RegExp(r'[A-Za-z]').hasMatch(t)) {
    return true;
  }
  return false;
}

/// True when the bare-digit line at [index] in [lines] is part of a
/// run of ≥ 3 consecutive bare-digit lines — a numeric option set
/// ("What is 2 + 2?" → 3/4/5/6), not a page number. Page numbers are
/// isolated; a run of bare digits is an option column. (A run of 3
/// covers the 3-digits + "None of these" row.) Used by [segmentLines]
/// so the table pass can see numeric options; without it the noise
/// filter eats them before the table parser ever runs.
bool _isNumericOptionRun(List<String> lines, int index) {
  final bareDigit = RegExp(r'^\d{1,4}$');
  if (!bareDigit.hasMatch(stripBoldMarkers(lines[index]).trim())) {
    return false;
  }
  var count = 1;
  for (var j = index - 1; j >= 0; j--) {
    if (!bareDigit.hasMatch(stripBoldMarkers(lines[j]).trim())) break;
    count++;
  }
  for (var j = index + 1; j < lines.length; j++) {
    if (!bareDigit.hasMatch(stripBoldMarkers(lines[j]).trim())) break;
    count++;
  }
  return count >= 3;
}

/// True when the whole [line] consists solely of key entries — a
/// number + separator + a single answer letter or "?" (one entry, or
/// a compact multi-column row: "1. D 58. B 73. A 88. B", "57. A").
/// A question line never matches: after its number comes question
/// text ("1. What is …?"), not a bare letter. Used as a fallback in
/// [segmentLines] for key tables whose heading was separated from
/// its entries by column reordering (the MPT 4-column key table on a
/// page shared with Q199/Q200) — the entries are captured even when
/// no key section is open.
bool _isKeyOnlyLine(String line) {
  // Bold markers (U+E000) and ticks are extractor plumbing, not
  // text: the MPT key table is bold, so "57. A" must match.
  // Q-prefixed entry with no separator ("Q1 C") is normalised first,
  // so it counts as a key entry here too.
  final t = _normaliseBareQEntries(
    stripBoldMarkers(line).replaceAll(RegExp(r'[✓✔]'), ''),
  ).trim();
  if (t.isEmpty) return false;
  // (?=\s|$) after the letter/? — a bare "?" has no word boundary
  // (\b fails after a non-word char at end of string), so \b is
  // wrong here; whitespace-or-end is the right terminator.
  return RegExp(
    r'^(?:(?:Q\s*)?\d+\s*[\.\)\:\-]\s*(?:[A-Da-d]|\?)(?=\s|$)\s*)+$',
    caseSensitive: false,
  ).hasMatch(t);
}

String _normalisePaperLabel(String kind, String id) {
  final k = kind.toLowerCase();
  return '${k[0].toUpperCase()}${k.substring(1)} $id';
}

/// Paper heading label for [line], or null when it is not a heading.
String? _paperHeadingLabel(String line) {
  final m = _paperHeadingRe.firstMatch(line.trim());
  if (m == null) return null;
  return _normalisePaperLabel(m.group(1)!, m.group(2)!);
}

/// Paper reference found anywhere in [line], or null.
String? _paperRefIn(String line) {
  final m = _paperRefRe.firstMatch(line);
  if (m == null) return null;
  return _normalisePaperLabel(m.group(1)!, m.group(2)!);
}

/// True when [line] is a key heading, optionally combined with a paper
/// reference ("Paper 1 Answer Key", "Answers – Paper 1", "Test 1 Key").
/// The Pace book prints its keys as "(Answer Key)" and sometimes as
/// "Answer Key (January 2026)" — surrounding parens and a trailing
/// "(…)" label are stripped before matching. Public so structure
/// detection can exclude key sections too.
bool isAnswerKeyHeading(String line) {
  // Bold markers (U+E000, extractor plumbing) and ticks are not text:
  // the Pace book prints its keys bold, so "(Answer Key)" must match.
  var core = stripBoldMarkers(line)
      .replaceAll('✓', '')
      .replaceAll('✔', '')
      .trim();
  // Fully wrapped in parens/brackets: "(Answer Key)" → "Answer Key".
  final wrapped = RegExp(
    r'^[\(\[\{]\s*(.+?)\s*[\)\]\}]$',
  ).firstMatch(core);
  if (wrapped != null) core = wrapped.group(1)!;
  // Trailing "(…)" label: "Answer Key (January 2026)" → "Answer Key".
  core = core.replaceFirst(RegExp(r'\s*\([^)]*\)\s*$'), '').trim();
  // Strip a leading paper reference: "Paper 1 Answer Key".
  core = core.replaceFirst(
    RegExp(
      '^$_paperKindRe\\s*(?:no\\.?|number|#)?\\s*$_paperIdRe\\s*[-–—:]?\\s*',
      caseSensitive: false,
    ),
    '',
  );
  // Strip a trailing paper reference: "Answers – Paper 1".
  core = core.replaceFirst(
    RegExp(
      '\\s*[-–—:]?\\s*$_paperKindRe\\s*(?:no\\.?|number|#)?\\s*$_paperIdRe\\s*\$',
      caseSensitive: false,
    ),
    '',
  );
  return _keyCoreRe.hasMatch(core);
}

/// True when [line] is a one-line question: a complete (a)–(d) /
/// 1–4 / (i)–(iv) option sequence AND real question words before the
/// first option marker. A compact key line such as "1. A 2. B 3. C 4. D"
/// has no question words before its markers, so it is not one.
bool _isOneLinerQuestion(String line) {
  final prefix = questionPrefixRe.firstMatch(line);
  final rest = prefix == null ? line : line.substring(prefix.end);
  final matches = _markerRe.allMatches(rest).toList();
  if (matches.length < 4) return false;
  const sequences = [
    ['a', 'b', 'c', 'd'],
    ['1', '2', '3', '4'],
    ['i', 'ii', 'iii', 'iv'],
  ];
  for (var w = 0; w + 3 < matches.length; w++) {
    final window = matches.sublist(w, w + 4);
    final keys = window.map((m) => m.group(1)!.toLowerCase()).toList();
    final isSeq = sequences.any(
      (s) =>
          s[0] == keys[0] &&
          s[1] == keys[1] &&
          s[2] == keys[2] &&
          s[3] == keys[3],
    );
    if (!isSeq) continue;
    final questionText = rest.substring(0, window[0].start).trim();
    if (questionText.length >= 3) return true;
  }
  return false;
}

/// True when line [i] starts a real question while a key section is
/// open — i.e. the key section ends here. A key-entry line never
/// qualifies: it has no option lines after it and no question words
/// before its markers. The option lookahead stops at the next heading
/// or question start, so option lines belonging to a LATER question
/// (e.g. Paper 2's Q1 a few lines after Paper 1's last key entry) can
/// never end the key section early.
bool _startsQuestionWithOptions(List<String> lines, int i) {
  final line = lines[i];
  if (!_questionStartRe.hasMatch(line)) return false;
  if (_isOneLinerQuestion(line)) return true;
  // Options on their own lines shortly after the question line.
  for (var j = i + 1; j < lines.length && j <= i + 12; j++) {
    final next = lines[j];
    if (isAnswerKeyHeading(next) ||
        _paperHeadingLabel(next) != null ||
        _questionStartRe.hasMatch(next)) {
      return false;
    }
    if (_optionLineRe.hasMatch(next)) return true;
  }
  return false;
}

/// A Q-prefixed key entry with NO separator ("Q1 C", "Q12 B" — the
/// typed form) is rewritten to the separated form ("Q1: C") before
/// entry scanning, so the same entry regex handles it. The letter
/// must not be followed by a letter/digit, so "Q1 Correct …" is
/// never rewritten, and the Q must not be part of a longer word, so
/// "FAQ1 C" is untouched. Used by [parseKeyEntries] and by
/// [_isKeyOnlyLine], so a typed/pasted key and a key section agree on
/// which shapes are entries.
String _normaliseBareQEntries(String s) {
  return s.replaceAllMapped(
    RegExp(
      r'(^|[^A-Za-z0-9])Q\s*(\d+)\s+([A-Da-d])(?![A-Za-z0-9])',
      caseSensitive: false,
    ),
    (m) => '${m.group(1)}Q${m.group(2)}: ${m.group(3)}',
  );
}

/// Parses key entries out of one key section's text (lines joined into
/// a single token stream). Returns number → raw answer token; the first
/// entry wins when a number is repeated (e.g. a key printed twice).
/// Column reading order does not matter: entries are looked up by
/// number, never by position. The raw value is kept WHOLE — "A) Asif
/// Ali Zardari" and "61. (C) 3" keep their letter, because the caller
/// resolves letter-first (the letter wins, the text is the fallback);
/// stripping the letter here would throw the letter away.
/// Bold markers (U+E000, extractor plumbing) are stripped first: a
/// bold key table prints "57. A" — the marker sits between the
/// separator and the letter and would otherwise break the entry-start
/// lookahead.
Map<int, String> parseKeyEntries(String blob) {
  blob = stripBoldMarkers(blob);
  // "Q1 C" (no separator) is a key entry too — rewrite it first, so
  // the entry regex below sees the separated form.
  blob = _normaliseBareQEntries(blob);
  final entries = <int, String>{};
  final starts = _keyEntryStartRe.allMatches(blob).toList();
  for (var i = 0; i < starts.length; i++) {
    final number = int.tryParse(starts[i].group(1)!);
    if (number == null) continue;
    final valueStart = starts[i].end;
    final valueEnd = i + 1 < starts.length ? starts[i + 1].start : blob.length;
    var value = blob
        .substring(valueStart, valueEnd)
        .trim()
        .replaceAll(RegExp(r'[\s,;:\-]+$'), '')
        .trim();
    if (value.isEmpty) continue;
    entries.putIfAbsent(number, () => value);
  }
  return entries;
}

/// Splits plain [lines] (TXT / pasted text: no pages) into question
/// lines and answer-key sections. See [segmentLines] for the
/// page-aware form.
SegmentedText segmentText(List<String> lines) {
  return segmentLines([
    for (var i = 0; i < lines.length; i++)
      SegmentedLine(lines[i], defaultPaperLabel, 0, i),
  ]);
}

/// Splits [lines] into question lines and answer-key sections.
///
/// Key-section lines and heading lines are dropped from
/// [SegmentedText.questionLines]; paper headings only change the
/// current segment. Key entries are collected per paper segment in
/// [SegmentedText.keyEntries]. Page numbers and line indices ride
/// through untouched, so the caller can tag parsed questions.
SegmentedText segmentLines(List<SegmentedLine> lines) {
  final questionLines = <SegmentedLine>[];
  final keyEntries = <String, Map<int, String>>{};
  final explicitKeyPapers = <String>{};
  var keySectionsFound = 0;
  var noiseLinesFiltered = 0;
  var currentPaper = defaultPaperLabel;
  // Paper of the most recent question line seen. A bare key heading
  // ("ANSWER KEY" with no paper named) belongs to THIS paper — the
  // paper whose questions immediately precede the key — not to the
  // paper whose heading happens to follow it (a key printed at the
  // top of a page belongs to the paper that ended on the previous
  // page). Updated only outside key sections, so key-entry lines
  // ("1. C") can never move it.
  var lastQuestionPaper = currentPaper;
  var inKey = false;
  // Inside an "Explanation:" / "Associated Information:" block — its
  // lines are dropped from questionLines (see below).
  var inExplanation = false;
  // True once an option line has been seen since the last question
  // start — i.e. a COMPLETE question precedes the current line. An
  // "Explanation:" heading only opens the drop when this is true: a
  // bare "explanation:" line can also be part of a question stem
  // (PPSC-66 Q23: "Select one word that best matches the given" /
  // "explanation:" — an OCR line-break inside the stem), and
  // swallowing it would delete the whole question.
  var questionHasOptions = false;
  var keyPaper = currentPaper;
  final keyBuffer = <String>[];

  void flushKey() {
    if (keyBuffer.isEmpty) return;
    final map = keyEntries.putIfAbsent(keyPaper, () => <int, String>{});
    for (final e in parseKeyEntries(keyBuffer.join(' ')).entries) {
      map.putIfAbsent(e.key, () => e.value);
    }
    keyBuffer.clear();
  }

  // Plain texts, built once: the key-section lookahead works on them.
  final texts = lines.map((l) => l.text).toList();

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].text;
    // Watermark / promo / phone noise (Examveda / organisation):
    // dropped before any heading/key/question check, so it can never
    // become a question, a key entry, or a part heading. A bare-digit
    // run (numeric options) is NOT noise — it is kept for the table
    // pass (see [_isNumericOptionRun]).
    if (isNoiseLine(line) && !_isNumericOptionRun(texts, i)) {
      noiseLinesFiltered++;
      continue;
    }
    if (isAnswerKeyHeading(line)) {
      flushKey();
      inKey = true;
      inExplanation = false;
      // Explicit paper reference wins; otherwise the paper whose
      // questions precede the key; otherwise the current heading.
      final explicitPaper = _paperRefIn(line);
      keyPaper = explicitPaper ?? lastQuestionPaper;
      // Strict paper rule (owner, 20 Nov 2026): a heading that NAMES
      // a paper makes that paper explicit — its entries apply only to
      // it, never to another paper.
      if (explicitPaper != null) explicitKeyPapers.add(explicitPaper);
      keySectionsFound++;
      keyEntries.putIfAbsent(keyPaper, () => <int, String>{});
      continue;
    }
    final paperLabel = _paperHeadingLabel(line);
    if (paperLabel != null) {
      flushKey();
      inKey = false;
      inExplanation = false;
      currentPaper = paperLabel;
      continue;
    }
    // Month heading ("January 2026"): a new key-join segment, like a
    // paper heading. Never a question/option/answer line, and never a
    // line ending in "?" (a question continuation mentioning a month).
    final monthLabel = monthHeadingLabel(line);
    if (monthLabel != null &&
        !_questionStartRe.hasMatch(line) &&
        !_optionLineRe.hasMatch(line) &&
        !line.trim().endsWith('?')) {
      flushKey();
      inKey = false;
      inExplanation = false;
      currentPaper = monthLabel;
      continue;
    }
    if (inKey) {
      if (_startsQuestionWithOptions(texts, i)) {
        flushKey();
        inKey = false;
        // Fall through: this line is a question line.
      } else {
        keyBuffer.add(line);
        continue;
      }
    }
    // Key-entry line outside a key section — the heading was
    // separated from its entries by column reordering (MPT 4-column
    // key table on a page shared with Q199/Q200). Capture it for the
    // paper whose questions precede it; the usual flush points
    // (paper/month/key heading, end of text) attribute it.
    if (_isKeyOnlyLine(line)) {
      if (keyBuffer.isEmpty) keyPaper = lastQuestionPaper;
      keyBuffer.add(line);
      continue;
    }
    // Explanation / "Associated Information" blocks (PPSC-66 Paper
    // 67, 20 Nov 2026): prose + bullets explaining the PREVIOUS
    // question's answer — never questions. Dropped from questionLines,
    // so a bullet ("- Conquests:") can never become a q-only
    // flashcard and a year-led prose line ("1258. This was …") can
    // never split a block. The block ends at the next real question
    // (a question start with options following) or at a heading
    // (handled above). A numberless stem after an explanation is
    // swallowed by this rule — accepted limitation: in this book the
    // questions after explanations are numbered.
    if (inExplanation) {
      if (_startsQuestionWithOptions(texts, i)) {
        inExplanation = false;
        // Fall through: this line is a question line.
      } else {
        continue;
      }
    }
    if (_explanationHeadingRe.hasMatch(line.trim()) &&
        questionHasOptions) {
      inExplanation = true;
      continue;
    }
    if (_questionStartRe.hasMatch(line)) {
      lastQuestionPaper = currentPaper;
      questionHasOptions = false;
    }
    if (_optionLineRe.hasMatch(line)) questionHasOptions = true;
    questionLines.add(
      SegmentedLine(
        line,
        currentPaper,
        lines[i].page,
        lines[i].lineIndex,
      ),
    );
  }
  flushKey();

  return SegmentedText(
    questionLines: questionLines,
    keyEntries: keyEntries,
    keySectionsFound: keySectionsFound,
    noiseLinesFiltered: noiseLinesFiltered,
    explicitKeyPapers: explicitKeyPapers,
  );
}

/// Resolves an answer token to an option index: a letter (C), a number
/// (3), the option's own text ("Islamabad"), or a letter plus the text
/// ("B) Asif Ali Zardari" — the letter wins, the text is the fallback).
/// A letter in parens ("(C) 80", "(C)80" — the OCR-noisy Final Answer
/// form, no space after the paren) resolves by letter; the trailing
/// value is a cross-check for the caller (see
/// [resolveAnswerToken] is also the resolver for a separately
/// attached answer key (see [applyAttachedKey]).
int? resolveAnswerToken(String token, List<String> options) {
  final t = token.trim();
  // "Option C" (Examveda "Answer: Option X"): the word "Option" + a
  // letter. Resolve by the letter. A–E (not just A–D): a 5-option
  // question's answer can be E — the single-letter bounds check
  // below rejects E for a 4-option question.
  final optionLetter = RegExp(
    r'^option\s+([A-Ea-e1-5])\b',
    caseSensitive: false,
  ).firstMatch(t);
  if (optionLetter != null) {
    return resolveAnswerToken(optionLetter.group(1)!, options);
  }
  // "(C) 80" / "(C)80": letter in parens, then an optional value.
  // The paren makes it unambiguous (not a decimal like "3.14"), so
  // the space after the paren is optional — OCR drops it.
  final parenLetter = RegExp(
    r'^[\(\[]\s*([A-Ea-e1-5])\s*[\)\]]\s*(.*)$',
  ).firstMatch(t);
  if (parenLetter != null) {
    final byLetter = resolveAnswerToken(parenLetter.group(1)!, options);
    if (byLetter != null) return byLetter;
    final rest = parenLetter.group(2)!;
    if (rest.isNotEmpty) return resolveAnswerToken(rest, options);
    return null;
  }
  final stripped = t.replaceAll(RegExp(r'^[\(\[]|[\)\]]$'), '');
  // "B) Asif Ali Zardari" / "2. Paris": letter-or-number, then text.
  // A–E: a 5-option question's answer can be E.
  final letterText = RegExp(
    r'^\(?([A-Ea-e1-5])[\)\.\:\-]\s+(.+)$',
  ).firstMatch(stripped);
  if (letterText != null) {
    final byLetter = resolveAnswerToken(letterText.group(1)!, options);
    if (byLetter != null) return byLetter;
    return resolveAnswerToken(letterText.group(2)!, options);
  }
  final asNum = int.tryParse(stripped);
  if (asNum != null && asNum >= 1 && asNum <= options.length) {
    return asNum - 1;
  }
  if (stripped.length == 1) {
    final c = stripped.toUpperCase().codeUnitAt(0);
    if (c >= 65 && c < 65 + options.length) return c - 65;
  }
  final lower = stripped.toLowerCase();
  for (var i = 0; i < options.length; i++) {
    if (options[i].trim().toLowerCase() == lower) return i;
  }
  return null;
}


/// Outcome of applying a separately attached answer key to the
/// pending (unanswered) questions of one import (20 Nov 2026,
/// owner's flow: "Jawab wali key attach karein"). The key is matched
/// by question NUMBER only, never by position — and never guessed:
/// a number with no key entry, a "?" token, or a token that matches
/// no option stays pending.
class KeyAttachResult {
  const KeyAttachResult({
    required this.filled,
    required this.stillMissingNumbers,
    required this.unnumberedStillMissing,
    required this.unresolvedNumbers,
    required this.orphanKeyPapers,
    this.parseFailed = false,
  });

  /// Pending-list index → resolved option index (0–3).
  final Map<int, int> filled;

  /// Book numbers still without a usable answer (no key entry, a
  /// "?" token, or an unresolvable token), sorted ascending.
  final List<int> stillMissingNumbers;

  /// Pending questions with no book number at all — a key can never
  /// match them by number, so they stay pending whatever the key says.
  final int unnumberedStillMissing;

  /// Book numbers whose key entry exists but matched NO option
  /// (e.g. the key says "E" for a 4-option question, or a text
  /// answer that is none of the options). A subset of
  /// [stillMissingNumbers].
  final List<int> unresolvedNumbers;

  /// Papers the attached key NAMED ("Answers – Paper 60") that have
  /// no pending questions in this import — their entries were applied
  /// to nothing, per the strict paper rule.
  final List<String> orphanKeyPapers;

  /// True when the key text contained ZERO parseable entries — the
  /// caller must say so plainly and guess nothing.
  final bool parseFailed;
}

/// Applies a separately attached answer key ([keyText] — typed/pasted
/// text, or the text read from an attached key photo/PDF) to [pending].
///
/// The key text is segmented exactly like book text ([segmentText]),
/// so a heading that names a paper ("Answers – Paper 60") scopes its
/// entries to that paper ONLY (strict paper rule, owner 20 Nov 2026:
/// one paper's key never answers another paper's questions). Entries
/// under NO named paper (a bare key — "1-C 2-B …" with no heading)
/// apply to every pending question by number. A pending question
/// first looks in its own paper's entries, then in the bare entries.
///
/// A "?" token means the key itself says the answer is unknown — the
/// question stays pending, never guessed. An entry that resolves to no
/// option is reported in [KeyAttachResult.unresolvedNumbers], never
/// force-matched. Returns [KeyAttachResult.parseFailed] when the key
/// text has no parseable entries at all.
KeyAttachResult applyAttachedKey({
  required String keyText,
  required List<PendingQuestion> pending,
}) {
  final lines = keyText
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      // A bare paper-title line ("MODEL PAPER 66") is furniture in a
      // standalone key: left in, it would close the key section and
      // strand the entries after it. Paper identity for scoping comes
      // from a KEY heading ("Answers – Paper 60"), never from a bare
      // title line.
      .where((l) => !_paperHeadingRe.hasMatch(l))
      .toList();
  // A key with no heading of its own ("1-C 2-B", "1. Islamabad") has
  // no key section to land in: a text answer would read as a question
  // line and be lost. Open a synthetic section so every entry routes
  // into the key buffer; it names no paper, so its entries stay bare
  // (apply to any pending question by number).
  if (!lines.any(isAnswerKeyHeading)) {
    lines.insert(0, 'ANSWER KEY');
  }
  final seg = segmentText(lines);
  final explicit = seg.explicitKeyPapers;
  // Bare (unscoped) entries: every paper the key did NOT name
  // explicitly. In key-only text with no question lines, a bare
  // heading lands its entries under [defaultPaperLabel]; a named
  // heading lands them under its paper.
  final bareEntries = <int, String>{};
  var totalEntries = 0;
  for (final e in seg.keyEntries.entries) {
    totalEntries += e.value.length;
    if (!explicit.contains(e.key)) {
      for (final entry in e.value.entries) {
        bareEntries.putIfAbsent(entry.key, () => entry.value);
      }
    }
  }
  // Papers the key named that have no pending questions at all.
  final pendingPapers = {for (final p in pending) p.paper};
  final orphanKeyPapers = explicit
      .where((paper) => !pendingPapers.contains(paper))
      .toList()
    ..sort();
  final filled = <int, int>{};
  final stillMissing = <int>[];
  final unresolved = <int>[];
  var unnumberedStillMissing = 0;
  for (var i = 0; i < pending.length; i++) {
    final p = pending[i];
    final number = p.number;
    if (number == null) {
      unnumberedStillMissing++;
      continue;
    }
    // Own paper first, then the bare entries.
    final ownEntries = seg.keyEntries[p.paper];
    final token = ownEntries?[number] ?? bareEntries[number];
    if (token == null || isUnknownKeyToken(token)) {
      stillMissing.add(number);
      continue;
    }
    final correct = resolveAnswerToken(token, p.options);
    if (correct == null) {
      stillMissing.add(number);
      unresolved.add(number);
      continue;
    }
    filled[i] = correct;
  }
  stillMissing.sort();
  unresolved.sort();
  return KeyAttachResult(
    filled: filled,
    stillMissingNumbers: stillMissing,
    unnumberedStillMissing: unnumberedStillMissing,
    unresolvedNumbers: unresolved,
    orphanKeyPapers: orphanKeyPapers,
    parseFailed: totalEntries == 0,
  );
}

/// --- MASTER DIRECTIVE Part 8 wiring (20 Nov 2026) ---
///
/// Per-key-paper match decisions for one segmented import: for every
/// paper label that has key entries, [decideKeyMatch] over the key's
/// identity against the questions' identity, with position + coverage
/// evidence from the segmentation. The parser's key join must go
/// through this map:
/// * VERIFIED → auto-assigns silently (the key names its paper and
///   the questions are that paper's).
/// * HIGH CONFIDENCE → the parser applies it, but flags it in
///   keyPaperReport: the upload preview shows the flag and the
///   user's Save is the confirmation. The parser runs BEFORE the
///   preview, so the preview + Save is the only existing user
///   confirmation path for an in-book key — there is no per-key
///   confirm dialog to wait on. Withholding HIGH would also break
///   the normal case (a bare key at the end of a single-paper book,
///   and the Pace book's per-month bare keys — both pinned by
///   existing tests), which is not a fix.
/// * NEEDS REVIEW / UNVERIFIED / MISMATCH → never applied; the
///   parser withholds the entries and reports the decision reason
///   in keyPaperReport instead.
///
/// Identity facts (never numbers alone, never nearest-key):
/// * An EXPLICIT key (its heading named a paper) carries that
///   paper's number + title. A BARE key carries NO identity — its
///   paper attribution (the preceding paper) is position evidence,
///   never identity.
/// * The question paper's identity comes from the paper label
///   ("Paper 66" → number 66 + title "Paper 66"; "January 2026" →
///   title only; the default "Paper 1" → number 1).
/// * [paperCountInDocument] counts PAPER-kind labels only
///   (Paper/Test/Set/Part/Section) — a month label is a section
///   within one paper, not a paper of its own, so a book grouped by
///   month is still one paper and its per-month bare keys stay HIGH
///   CONFIDENCE instead of NEEDS REVIEW.
/// * Coverage: at least one key entry number appears among the
///   question-line numbers of that paper. Corroboration, never
///   proof — coverage alone never verifies (see [decideKeyMatch]).
///   Clipped numbers (PPSC-66 Q1/Q3–Q9) only weaken coverage; an
///   explicit key is VERIFIED by number + title regardless.
/// * Exclusive coverage: no key entry number appears in any OTHER
///   segment's question numbers. This is the discriminator for a
///   bare key in a multi-paper document — entry 61 matching only
///   Paper 1 (Paper 2 has Q1) is exclusive, entry 1 matching both
///   papers is not. All other segments count, not just paper-kind
///   labels: the gate is deliberately conservative, since a wrong
///   HIGH costs a mis-answered paper while a NEEDS REVIEW costs
///   only one explicit key-attach tap. (A month-grouped book is
///   unaffected — it is one paper, so the single-paper branch
///   applies before exclusivity is ever consulted.)
Map<String, KeyMatchDecision> keyMatchDecisions(
  SegmentedText segmented, {
  required String sourceDocumentId,
}) {
  final decisions = <String, KeyMatchDecision>{};
  if (segmented.keyEntries.isEmpty) return decisions;

  // Question-line numbers per paper label, for coverage evidence.
  final questionNumbersByPaper = <String, Set<int>>{};
  for (final l in segmented.questionLines) {
    final n = _questionLineNumber(l.text);
    if (n != null) {
      questionNumbersByPaper.putIfAbsent(l.paper, () => <int>{}).add(n);
    }
  }

  // Paper-kind labels present in the document (question lines +
  // key labels). No paper-kind label at all means the whole book is
  // one paper (e.g. grouped by month only).
  final paperKindLabels = <String>{
    for (final l in segmented.questionLines)
      if (_isPaperKindLabel(l.paper)) l.paper,
    for (final k in segmented.keyEntries.keys)
      if (_isPaperKindLabel(k)) k,
  };
  final paperCount = paperKindLabels.isEmpty ? 1 : paperKindLabels.length;

  for (final entry in segmented.keyEntries.entries) {
    final label = entry.key;
    final explicit = segmented.explicitKeyPapers.contains(label);
    // Explicit: the key heading named this paper. Bare: no identity
    // — the attribution is positional only.
    final keyPaper = explicit
        ? _paperIdentityForLabel(label, sourceDocumentId)
        : PaperIdentity(sourceDocumentId: sourceDocumentId);
    final questionPaper = _paperIdentityForLabel(label, sourceDocumentId);
    final keyNumbers = entry.value.keys.toSet();
    final questionNumbers = questionNumbersByPaper[label] ?? const <int>{};
    final hasCoverage = keyNumbers.any(questionNumbers.contains);
    // Exclusive coverage: no key entry number appears in any other
    // segment's question numbers. An entry matching nothing at all
    // (an orphan, e.g. from a clipped number) does not break
    // exclusivity — it is reported as unmatched by the join, not
    // evidence for another paper.
    final otherNumbers = <int>{
      for (final e in questionNumbersByPaper.entries)
        if (e.key != label) ...e.value,
    };
    final hasExclusiveCoverage = hasCoverage &&
        keyNumbers.every((n) => !otherNumbers.contains(n));
    decisions[label] = decideKeyMatch(
      keyPaper: keyPaper,
      questionPaper: questionPaper,
      paperCountInDocument: paperCount,
      hasPositionEvidence: !explicit,
      hasCoverageEvidence: hasCoverage,
      hasExclusiveCoverageEvidence: hasExclusiveCoverage,
    );
  }
  return decisions;
}

/// Question number of a question-start line ("Q12. …" → 12,
/// "12) …" → 12), or null. Coverage evidence only — a numeric option
/// line ("3. 42") can match too, which is acceptable noise for a
/// corroborating signal (it can only add an overlap, never prove a
/// match on its own).
int? _questionLineNumber(String line) {
  final m = RegExp(
    r'^\s*(?:Q\s*\.?\s*)?(\d+)\s*[\.\)\:]',
    caseSensitive: false,
  ).firstMatch(line.trim());
  if (m == null) return null;
  return int.tryParse(m.group(1)!);
}

/// True when [label] is a paper-kind segment ("Paper 66", "Test 2",
/// "Set A", "Part 1", "Section 3", the default "Paper 1") as opposed
/// to a month segment ("January 2026"), which is a section within one
/// paper, not a paper of its own.
bool _isPaperKindLabel(String label) {
  return RegExp(
    r'^(paper|test|set|part|section)\s+\S+$',
    caseSensitive: false,
  ).hasMatch(label.trim());
}

/// Identity of the paper a segment label names: "Paper 66" → number
/// 66 + title "Paper 66"; "January 2026" → title only; anything else
/// → title only (never guessed).
PaperIdentity _paperIdentityForLabel(
  String label,
  String sourceDocumentId,
) {
  final m = RegExp(
    r'^(paper|test|set|part|section)\s+([0-9]+|[A-Z])$',
    caseSensitive: false,
  ).firstMatch(label.trim());
  return PaperIdentity(
    sourceDocumentId: sourceDocumentId,
    paperNumber: m?.group(2),
    paperTitle: label,
  );
}
