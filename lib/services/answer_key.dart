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
///    no question in its own segment gets a second chance in other
///    segments (only when that segment's own key has no entry for the
///    number); entries matching nothing anywhere are reported in
///    [SegmentedText.unmatchedKeyEntries] via the parser, never
///    silently dropped or force-joined.
///
/// 2. **Key-entry parsing.** A key section is treated as one token
///    stream ([parseKeyEntries]), so compact runs ("1.C 2.A 3.B …" on
///    one line) and multi-column layouts (entries out of reading order)
///    both work — entries are looked up by number, never by position.
///    Supported entry shapes: "1. C", "1-C", "1) C", "1: C", "Q1: C",
///    "1. A) Asif Ali Zardari" (letter + text), "61. (C) 3" and
///    "62. (A) Portable Document Format" (number + "(letter)" + full
///    answer text — the letter wins, the text is the fallback), and
///    "1. Asif Ali Zardari" (answer as TEXT, matched against the
///    question's options by the caller via `_resolveAnswer`).
library;

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
  });

  final List<SegmentedLine> questionLines;

  /// keyEntries[paperLabel][questionNumber] = raw answer token
  /// (a letter "C", a number "3", or the option's own text).
  final Map<String, Map<int, String>> keyEntries;

  /// How many key headings were found (0 when the book has no key).
  final int keySectionsFound;

  /// Watermark / promo / phone noise lines filtered out before
  /// parsing (Examveda / organisation files). They never became
  /// question lines.
  final int noiseLinesFiltered;
}

final _paperKindRe = r'(paper|test|set|part|section)';
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
final _keyEntryStartRe = RegExp(
  r'(?:^|\s)(?:Q\s*)?(\d+)\s*[\.\)\:\-](?=\s|[A-Da-d]\b|$)',
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
  final t = stripBoldMarkers(line).replaceAll(RegExp(r'[✓✔]'), '').trim();
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
      // Explicit paper reference wins; otherwise the paper whose
      // questions precede the key; otherwise the current heading.
      keyPaper = _paperRefIn(line) ?? lastQuestionPaper;
      keySectionsFound++;
      keyEntries.putIfAbsent(keyPaper, () => <int, String>{});
      continue;
    }
    final paperLabel = _paperHeadingLabel(line);
    if (paperLabel != null) {
      flushKey();
      inKey = false;
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
    if (_questionStartRe.hasMatch(line)) {
      lastQuestionPaper = currentPaper;
    }
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
  );
}
