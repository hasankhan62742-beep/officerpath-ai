import 'answer_key.dart';

/// Book structure detection: which parts / papers / sections a book
/// has, where each starts, and how many questions each holds — so the
/// upload screen can ask the user WHICH part to build the test from
/// (whole book, one paper, or a page range).
///
/// Two APIs, deliberately separate:
///
/// * [detectBookStructure] — raw structural detection from the pages.
///   It lists chapter/section headings even in a prose book with no
///   MCQs (Pak Affairs notes → chapters). The AI-generation path uses
///   this directly: chapters are the units to generate from.
/// * [ParseResult.parts] (see `mcq_parser.dart`) — the TEST-BUILDING
///   parts: only parts with at least one parsed question, falling back
///   to a single "Poori book" part when the book has no questions at
///   all. A part with 0 questions is not a part for test building, and
///   a letter (e.g. an admission letter whose header names a post)
///   must never be misdetected as a question paper.
///
/// Detection is CONSERVATIVE: a heading is a short line, not a
/// question / option / answer line, not a repeating header/footer, and
/// followed by real content before the next heading. Ordinary
/// sentences are never promoted to headings.

/// One page of text, 1-based page number.
class PageText {
  const PageText(this.page, this.text);

  final int page;
  final String text;
}

/// One detected part / paper / section of a book.
class BookPart {
  const BookPart({
    required this.title,
    required this.startPage,
    required this.endPage,
    required this.questionCount,
    this.pendingCount = 0,
  });

  /// e.g. "Pakistan Current Affairs", "Paper 1", "Poori book".
  final String title;

  /// 1-based, inclusive. The first part always starts at page 1.
  final int startPage;

  /// 1-based, inclusive.
  final int endPage;

  /// Questions in this part. For [detectBookStructure] this counts
  /// question-start lines in the part's span (an estimate); the parse
  /// pipeline overwrites it with the exact parsed count.
  final int questionCount;

  /// Answer-pending questions in this part (parsed, but no usable
  /// answer yet). A part with only pending questions still appears in
  /// the parts list (PPSC-66 §5.5, 20 Nov 2026) — its questions exist,
  /// they just cannot be tested until an answer is attached.
  final int pendingCount;

  BookPart copyWith({
    String? title,
    int? startPage,
    int? endPage,
    int? questionCount,
    int? pendingCount,
  }) {
    return BookPart(
      title: title ?? this.title,
      startPage: startPage ?? this.startPage,
      endPage: endPage ?? this.endPage,
      questionCount: questionCount ?? this.questionCount,
      pendingCount: pendingCount ?? this.pendingCount,
    );
  }

  Map<String, dynamic> toMap() => {
    'title': title,
    'startPage': startPage,
    'endPage': endPage,
    'questionCount': questionCount,
    'pendingCount': pendingCount,
  };

  factory BookPart.fromMap(Map<String, dynamic> map) => BookPart(
    title: map['title'] as String? ?? '',
    startPage: map['startPage'] as int? ?? 1,
    endPage: map['endPage'] as int? ?? (map['startPage'] as int? ?? 1),
    questionCount: map['questionCount'] as int? ?? 0,
    pendingCount: map['pendingCount'] as int? ?? 0,
  );
}

/// The detected structure of a book: its parts in document order.
class BookStructure {
  const BookStructure({
    required this.parts,
    required List<int> headingLineIndices,
  }) : _headingLineIndices = headingLineIndices;

  final List<BookPart> parts;

  /// 0-based line index (in the flattened page-ordered line stream)
  /// of each part's heading; -1 for the "Poori book" fallback part.
  /// Parallel to [parts].
  final List<int> _headingLineIndices;

  /// Title of the part containing the line at [lineIndex] (0-based in
  /// the flattened page-ordered line stream), or '' when the book has
  /// no parts or the index is unknown (< 0). Lines before the first
  /// heading belong to the first part.
  String partForLine(int lineIndex) {
    if (parts.isEmpty || lineIndex < 0) return '';
    var title = parts.first.title;
    for (var i = 0; i < parts.length; i++) {
      if (_headingLineIndices[i] <= lineIndex) {
        title = parts[i].title;
      }
    }
    return title;
  }
}

/// Fallback part title when no structure is detected.
const wholeBookPartTitle = 'Poori book';

/// Flattens [pages] (page order) into trimmed non-empty lines, each
/// tagged with its page and its 0-based index in the stream. The parse
/// pipeline uses this exact flattening, so line indices line up with
/// [BookStructure.partForLine].
List<SegmentedLine> flattenPages(List<PageText> pages) {
  final out = <SegmentedLine>[];
  for (final p in pages) {
    for (final raw in p.text.split('\n')) {
      final t = raw.trim();
      if (t.isEmpty) continue;
      out.add(SegmentedLine(t, defaultPaperLabel, p.page, out.length));
    }
  }
  return out;
}

final _questionStartRe = RegExp(
  r'^(Q\s*\d*[\.\)\:]|\d+[\.\)](?!\d))\s*\S',
  caseSensitive: false,
);
final _optionLineRe = RegExp(r'^\(?([A-Da-d])[\)\.\:\-]\s*(.+)$');
final _answerLineRe = RegExp(
  r'^(?:(?:Correct|Right)\s+Answers?|Correct|Right|Answers?|Ans|Key)\s*[:\-]\s*(.+)$',
  caseSensitive: false,
);
final _footerRe = RegExp(
  r'page\s*\d+\s*$',
  caseSensitive: false,
);
final _explanationRe = RegExp(
  r'^(Explanation|Exp)\s*[:\-]\s*(.+)$',
  caseSensitive: false,
);
final _subjectRe = RegExp(r'^Subject\s*[:\-]\s*(.+)$', caseSensitive: false);

/// A repeating header line that is never a question continuation
/// (month titles, "Current Affairs …", "Year 2026 …", "Papers of
/// 2026" — the running heads of the Sir Tauqeer / 112 books).
bool _looksLikeHeaderLine(String line) {
  final t = line.trim();
  final lower = t.toLowerCase();
  if (monthHeadingLabel(t) != null) return true;
  if (lower.startsWith('current affairs') && !t.endsWith('?')) return true;
  // Any year, not just 2026: the PPSC-66 book runs "Papers of 2021"
  // and "Year 2021" headers, and the old hardcoded 2026 let them
  // through as part titles (baseline §5.5).
  if (RegExp(r'^year\s+(19|20)\d\d').hasMatch(lower)) return true;
  if (RegExp(r'^papers of\s+(19|20)\d\d').hasMatch(lower)) return true;
  return false;
}

/// Subject / section phrases that mark a heading when they appear in
/// a short line ("Pakistan Current Affairs", "International
/// Organizations and General Affairs", "General Knowledge").
const _subjectPhrases = [
  'current affairs',
  'general affairs',
  'general knowledge',
  'pakistan affairs',
  'pakistan studies',
  'international organizations',
  'everyday science',
  'islamiat',
  'islamic studies',
  'computer science',
  'computer fundamental',
  'computer fundamentals',
  'mathematics',
  'geography',
  'history',
  'economics',
  'physics',
  'chemistry',
  'biology',
  'botany',
  'zoology',
  'sociology',
  'psychology',
  'philosophy',
  'political science',
  'english',
  'urdu',
  'universe',
  'units of measurement',
];

/// Post names that can title a paper ("Sub Inspector 2024",
/// "PPSC Sub Inspector Past Paper 2024", or the bare post name).
const _postNames = [
  'assistant sub inspector',
  'sub inspector',
  'assistant',
  'lecturer',
  'junior clerk',
  'senior clerk',
  'constable',
  'patwari',
  'stenographer',
  'inspector',
  'asi',
];

const _smallWords = {
  'a',
  'an',
  'the',
  'of',
  'and',
  'in',
  'on',
  'for',
  'to',
  'with',
  'before',
  'after',
  'from',
  'by',
  'at',
};

int _alphaWordCount(String text) {
  return RegExp(r'[A-Za-z]+').allMatches(text).length;
}

String _repeatKey(String text) {
  return text
      .toLowerCase()
      .replaceAll(RegExp(r'\d+'), '#')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

bool _isTitleCase(String text) {
  final words = RegExp(r"[A-Za-z][A-Za-z'’\-]*").allMatches(text).toList();
  if (words.isEmpty) return false;
  for (final w in words) {
    final word = w.group(0)!;
    final first = word[0];
    final lower = word.toLowerCase();
    if (_smallWords.contains(lower)) continue;
    if (first != first.toUpperCase() || first == first.toLowerCase()) {
      return false;
    }
  }
  return true;
}

bool _isAllCaps(String text) {
  final letters = RegExp(r'[A-Za-z]').allMatches(text).toList();
  if (letters.length < 2) return false;
  return letters.every((m) => m.group(0) == m.group(0)!.toUpperCase());
}

/// A paper / test / set heading: "Paper 1", "Paper No. 1", "Test 2",
/// "Set A", "Model Paper 1", "Past Paper", "Mock Test 3".
bool _isPaperHeading(String text) {
  final lower = text.toLowerCase();
  if (RegExp(
    r'^(paper|test|set|model paper|past paper|sample paper|mock test|mock paper)\b',
  ).hasMatch(lower)) {
    return true;
  }
  if (lower.contains('past paper') ||
      lower.contains('model paper') ||
      lower.contains('mock test') ||
      lower.contains('mock paper')) {
    return true;
  }
  return RegExp(
    r'^(paper|test|set)\s*(no\.?|#)?\s*(\d+|[a-z])\b',
  ).hasMatch(lower);
}

/// A post-named paper heading. A bare post name ("Sub Inspector") or
/// a post name with a paper signal (Paper / Past / year) counts; a
/// post name glued to a code ("JUNIOR CLERK - 40H2025", an admission
/// letter header) does NOT — that is a letter, not a paper.
bool _isPostHeading(String text) {
  final lower = text.toLowerCase();
  final hasPost = _postNames.any((p) => lower.contains(p));
  if (!hasPost) return false;
  if (lower.contains('paper') ||
      lower.contains('past') ||
      lower.contains('model') ||
      lower.contains('mock') ||
      RegExp(r'\b(19|20)\d\d\b').hasMatch(lower)) {
    return true;
  }
  // Bare post name only: short line, nothing but the post (+ "ppsc").
  final cleaned = lower
      .replaceAll('ppsc', '')
      .replaceAll(RegExp(r'[^a-z ]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return _postNames.any((p) => cleaned == p) && _alphaWordCount(text) <= 4;
}

/// "Chapter 3", "Part 2", "Section 1", "Unit 4" (with optional title).
bool _isChapterHeading(String text) {
  return RegExp(
    r'^(chapter|part|section|unit)\s+(\d+|[ivx]+)\b',
    caseSensitive: false,
  ).hasMatch(text);
}

/// A year-section heading: "CSS 2000", "CSS 2026", "Special CSS
/// 2023" (US History past papers — one part per year). The title
/// line "CSS 2000 - 2026" (a RANGE) is NOT a part — the line must be
/// exactly one year (with an optional "Special" prefix).
/// Returns the normalised label ("CSS 2023") or null.
String? yearHeadingLabel(String text) {
  final t = stripBoldMarkers(text).trim();
  final m = RegExp(
    r'^(?:special\s+)?css\s+((?:19|20)\d\d)$',
    caseSensitive: false,
  ).firstMatch(t);
  if (m == null) return null;
  return 'CSS ${m.group(1)}';
}

/// An organisation-card heading (organisation file): an ALL-CAPS
/// line naming an organisation — "UNITED NATIONS ORGANIZATION",
/// "FOOD AND AGRICULTURE ORGANIZATION". The all-caps requirement is
/// the guard: a sentence that merely mentions an organisation
/// ("The organization was founded in 1945") is not all-caps and
/// never becomes a heading.
bool _isOrgHeading(String text) {
  final lower = text.toLowerCase();
  if (!lower.contains('organization') &&
      !lower.contains('organisation')) {
    return false;
  }
  return _isAllCaps(text) && _alphaWordCount(text) <= 8;
}

/// A line starting with a question number whose digits were misread
/// by OCR ("S1." for "51.", "I2." for "12.", "$1." for "51." — the
/// leading letter/symbol is the misread digit). Clean numbers are
/// already caught by [_questionStartRe]; this catches the noisy
/// ones. The leading slot accepts only the question prefix "Q" or a
/// misread digit (category separation, 20 Nov 2026): an arbitrary
/// letter ("A12.") is not a number and must not exclude a line from
/// becoming a title. A real heading never starts with a 1–3 char
/// letter/digit token + separator ("2021 Current Affairs" has 4
/// digits + a space, no separator; "Chapter 3" has no separator
/// after the word).
final _misreadNumberStartRe = RegExp(
  r'^(?:Q|[IiLlOoSsBbZz$§])?[0-9IlOSBZ$§]{1,3}[.\)\:\-]\s',
);

/// An option marker ANYWHERE in the line ("(A) …", "(B) …" — or the
/// OCR misreads "(8)" / "(0)" for "(B)" / "(D)"). A question stem or
/// option tail carrying one is question content, never a heading.
/// "(BS-16)" does not match (the char after B is a letter, not a
/// bracket or space), so paper headings are untouched.
final _optionMarkerAnywhereRe = RegExp(r'\([A-Da-d08][\)\s]');

/// Strong heading: short line matching a paper / post / chapter /
/// subject / month / year / org pattern. Works at any position in
/// the book.
bool _isStrongHeading(String text) {
  if (text.length > 70 || _alphaWordCount(text) > 10) return false;
  if (text.endsWith('.') || text.endsWith('?') || text.endsWith('!')) {
    return false;
  }
  // A line containing "?" anywhere is a question, never a heading
  // (a GSA question "… in the universe is __________? Hydrogen"
  // contains the subject word "universe" but is a question, not a
  // chapter title).
  if (text.contains('?')) return false;
  final lower = text.toLowerCase();
  if (_isPaperHeading(text) ||
      _isPostHeading(text) ||
      _isChapterHeading(text) ||
      _isOrgHeading(text)) {
    return true;
  }
  // Year section: "CSS 2000" (US History) — one part per year.
  if (yearHeadingLabel(text) != null) return true;
  // Month section: "September 2026", "Current Affairs October 2026"
  // (the Sir Tauqeer + Pace books are split by month; a bare month
  // line with no subject phrase still counts).
  if (monthHeadingLabel(text) != null) return true;
  // A line starting lowercase is a sentence fragment (an OCR stem
  // continuation — "difficult I thjnk he speaks English…", "to
  // English of word: …"), never a subject heading: real headings
  // are Title-Case or ALL-CAPS. Applies ONLY to the subject-phrase
  // branch, so paper / month / chapter headings above are
  // unaffected (and Urdu-start lines have no case to check).
  if (text.isNotEmpty &&
      RegExp(r'[a-z]').hasMatch(text[0]) &&
      text[0] == text[0].toLowerCase()) {
    return false;
  }
  return _subjectPhrases.any((p) => lower.contains(p));
}

/// Generic heading: short Title-Case / ALL-CAPS line. Only trusted at
/// the top of a page's content (first content line) — mid-page, a
/// short title-case line is usually a sub-heading or a sentence.
bool _isGenericHeading(String text) {
  if (text.length > 60) return false;
  final words = _alphaWordCount(text);
  if (words < 2 || words > 8) return false;
  if (text.endsWith('.') || text.endsWith('?') || text.endsWith('!')) {
    return false;
  }
  if (text.toLowerCase().startsWith('note:')) return false;
  return _isTitleCase(text) || _isAllCaps(text);
}

/// A line that is never a heading: question, option, answer, key
/// heading, footer, or a repeating header/footer. Month headings are
/// EXEMPT from the repeat rule: "Current Affairs October 2026" repeats
/// on every page of its section and IS the part boundary (deduped to
/// one part per month later); a running header like "Pakistan Affairs"
/// has no month + year and is still excluded.
bool _isExcludedLine(String text, Set<String> repeats) {
  if (_questionStartRe.hasMatch(text)) return true;
  if (_optionLineRe.hasMatch(text)) return true;
  if (_answerLineRe.hasMatch(text)) return true;
  if (isAnswerKeyHeading(text)) return true;
  if (_footerRe.hasMatch(text)) return true;
  // OCR noise (20 Nov 2026): a question stem whose number was
  // misread ("S1. Choose the best English translation…") or a stem
  // / option tail carrying an option marker mid-line ("…speaks
  // English. (A whether", "English Grammar (8) Unusual/openly")
  // is question content, never a heading — the phone's PPSC-66
  // parts were titled with exactly these stems.
  if (_misreadNumberStartRe.hasMatch(text)) return true;
  if (_optionMarkerAnywhereRe.hasMatch(text)) return true;
  // A worked-solution heading, its "Final Answer:" closer, and a
  // "(Note: …)" evidence line are never parts/sections (110/109
  // editions) — even when short enough to look like a heading.
  if (isSolutionHeading(text)) return true;
  if (finalAnswerRe.hasMatch(text)) return true;
  if (noteContent(text) != null) return true;
  if (monthHeadingLabel(text) != null) return false;
  // A running header/footer is never a part title (PPSC-66 baseline
  // §5.5: "Papers of 2021 521", "524 Advanced FPJC MCQs Model Papers
  // (Volume 2)" and bare "522" all became part titles). Years are
  // any year, not just 2026. A heading never starts with a bare page
  // number — a real heading starting with a year ("2021 Current
  // Affairs") is untouched because a year (1900–2099) is not a page
  // number, and a question start ("524. …") carries punctuation
  // after the number, not a space.
  if (RegExp(r'^papers of\s+(19|20)\d\d\b', caseSensitive: false)
      .hasMatch(text)) {
    return true;
  }
  if (RegExp(r'^year\s+(19|20)\d\d\b', caseSensitive: false)
      .hasMatch(text)) {
    return true;
  }
  if (RegExp(r'^\d{1,4}$').hasMatch(text)) return true;
  final pagePrefix =
      RegExp(r'^[^A-Za-z0-9]?\d{1,4}\s+[A-Z]').firstMatch(text);
  if (pagePrefix != null) {
    final n = int.tryParse(
      RegExp(r'\d+').firstMatch(text)!.group(0)!,
    );
    if (n != null && (n < 1900 || n > 2099)) return true;
  }
  if (repeats.contains(_repeatKey(text))) return true;
  return false;
}

/// A key-entry line ("1. C", "2. B", "3. ?" — MPT / Pace key
/// tables). It LOOKS like a question start (number + separator) but
/// is an answer-key entry, not a question — the question-span
/// pre-pass must never treat it as a question start (it would mark
/// the heading after the key as a "continuation" of the key entry).
bool _isKeyEntryLine(String text) {
  return RegExp(
    r'^\s*(?:Q\s*)?\d+\s*[\.\)\:\-]\s*[A-Da-d\?]\b',
  ).hasMatch(text);
}

/// A fact-card label line ("ESTABLISHED OCTOBER 24. 1945", "MEMBER
/// 193" — organisation file). A fact line is CONTENT for the
/// heading-retention check: a card heading followed by its facts is
/// a real section, not a bare title.
bool _isFactLine(String text) {
  final first = text.trim().split(RegExp(r'\s+')).first.toUpperCase();
  const labels = {
    'ESTABLISHED',
    'FOUNDED',
    'MEMBER',
    'MEMBERS',
    'HEADQUARTER',
    'HEADQUARTERS',
    'SECRETARY',
    'SECRATARY',
    'PRESIDENT',
    'DIRECTOR',
    'LANGUAGE',
    'ORGANS',
  };
  if (labels.contains(first)) return true;
  // "<ORG> DAY" (e.g. "UNO DAY", "FAO DAY").
  return text.trim().toUpperCase().contains(' DAY ');
}

/// A line with real content after a heading: a question line, a long
/// line, a long-ish prose line, or a fact-card label line. Short
/// title/subtitle lines do not count — that is how a book title
/// ("PPSC CURRENT AFFAIRS" + its subtitle line) is recognised as a
/// title, not a section.
bool _isContentLine(String text) {
  if (_questionStartRe.hasMatch(text)) return true;
  if (_isFactLine(text)) return true;
  if (text.length > 60) return true;
  return _alphaWordCount(text) > 8;
}

class _Heading {
  _Heading({required this.lineIndex, required this.page, required this.title});

  final int lineIndex;
  final int page;
  final String title;
}

/// Detects the parts of a book from its pages (page order).
///
/// Headings are short lines that are not questions / options / answers
/// / key sections / repeating headers / footers. Two tiers: strong
/// headings (paper / post / chapter / subject patterns) anywhere, and
/// generic Title-Case headings only at the top of a page's content.
/// A heading split across two short lines ("Pakistan Current" /
/// "Affairs") is joined when the joined line is a strong heading.
/// Headings with no content before the next heading (book titles and
/// subtitles) are dropped. With no headings, one "Poori book" part
/// covers pages 1..N.
BookStructure detectBookStructure(List<PageText> pages) {
  if (pages.isEmpty) return const BookStructure(parts: [], headingLineIndices: []);
  final lines = flattenPages(pages);
  final totalPages = pages
      .map((p) => p.page)
      .fold(0, (a, b) => a > b ? a : b);

  // 1. Repeating headers/footers: the same normalised line on >= 3
  //    pages (page numbers collapse to '#').
  final pageSets = <String, Set<int>>{};
  for (final l in lines) {
    final key = _repeatKey(l.text);
    if (key.isEmpty) continue;
    pageSets.putIfAbsent(key, () => <int>{}).add(l.page);
  }
  final repeats = <String>{
    for (final e in pageSets.entries)
      if (e.value.length >= 3) e.key,
  };

  // 2. First content line of each page (first line that is not a
  //    repeat / footer / key heading / blank).
  final firstOnPage = <int, int>{}; // page -> line index
  for (final l in lines) {
    if (firstOnPage.containsKey(l.page)) continue;
    if (repeats.contains(_repeatKey(l.text))) continue;
    if (_footerRe.hasMatch(l.text)) continue;
    if (isAnswerKeyHeading(l.text)) continue;
    firstOnPage[l.page] = l.lineIndex;
  }

  // 2b. Question-span marking (item D): a question's lines — start,
  //     continuations, options — are never headings. A multi-line
  //     question that wraps across a page break puts its continuation
  //     at the top of the next page, where the generic-heading rule
  //     would otherwise promote it ("January 2026 suggested a",
  //     "Minister of AJK?", "Englishman to land on the New England
  //     coast,"). Mark every line that belongs to a question so the
  //     heading scan skips it. A question runs from its start line
  //     until its answer / explanation, the next question start, a
  //     key / month / year / chapter heading, or ~5 lines (a question
  //     wraps at most ~4 lines). Unnumbered flashcard questions
  //     (a "?"-terminated line + its short answer lines, Sir Tauqeer /
  //     US History / GSA) are marked the same way — a flashcard
  //     answer ("December 1941", a "➢ …? Hydrogen" bullet) is never
  //     a part heading either.
  final inQuestion = <int>{};
  for (var idx = 0; idx < lines.length; idx++) {
    final t = stripBoldMarkers(lines[idx].text).trim();
    // A key-entry line ("1. C", "2. B" in a key table) LOOKS like a
    // question start but is not a question — never mark it, or the
    // heading after the key ("Paper 2") gets marked as its
    // "continuation" and is lost as a part.
    if (_isKeyEntryLine(t)) continue;
    // A probable question start: a clean number ("51. …") OR an
    // OCR-misread one ("S1. …" — the digit read as a letter).
    // Marking the span means its stem continuations can never
    // become part titles, even when the number itself is garbled.
    if (!_questionStartRe.hasMatch(t) &&
        !_misreadNumberStartRe.hasMatch(t)) {
      continue;
    }
    inQuestion.add(idx);
    var j = idx + 1;
    while (j < lines.length && j - idx <= 5) {
      final nt = stripBoldMarkers(lines[j].text).trim();
      if (nt.isEmpty) break;
      if (_questionStartRe.hasMatch(nt)) break;
      if (_misreadNumberStartRe.hasMatch(nt)) break;
      if (isAnswerKeyHeading(nt)) break;
      if (monthHeadingLabel(nt) != null) break;
      if (yearHeadingLabel(nt) != null) break;
      if (_isChapterHeading(nt)) break;
      if (_optionLineRe.hasMatch(nt)) {
        inQuestion.add(j);
        j++;
        continue;
      }
      if (_answerLineRe.hasMatch(nt) ||
          _explanationRe.hasMatch(nt) ||
          _subjectRe.hasMatch(nt)) {
        break;
      }
      if (_looksLikeHeaderLine(nt)) break;
      inQuestion.add(j);
      j++;
    }
  }
  // Flashcard spans: a "?"-terminated line (unnumbered, so the loop
  // above did not catch it) + the next 1–2 short plain lines (its
  // answer) are one question, never a heading.
  for (var idx = 0; idx < lines.length; idx++) {
    final t = stripBoldMarkers(lines[idx].text).trim();
    if (!t.endsWith('?')) continue;
    // A "?" key entry ("3. ?" — MPT) is not a flashcard question.
    if (_isKeyEntryLine(t)) continue;
    if (inQuestion.contains(idx)) continue;
    if (_questionStartRe.hasMatch(t)) continue;
    inQuestion.add(idx);
    var j = idx + 1;
    var taken = 0;
    while (j < lines.length && taken < 2) {
      final nt = stripBoldMarkers(lines[j].text).trim();
      if (nt.isEmpty) {
        j++;
        continue;
      }
      if (nt.length > 100) break;
      if (nt.endsWith('?')) break;
      if (_questionStartRe.hasMatch(nt)) break;
      if (isAnswerKeyHeading(nt)) break;
      if (monthHeadingLabel(nt) != null) break;
      if (yearHeadingLabel(nt) != null) break;
      if (_isChapterHeading(nt)) break;
      if (_optionLineRe.hasMatch(nt) ||
          _answerLineRe.hasMatch(nt) ||
          _explanationRe.hasMatch(nt) ||
          _subjectRe.hasMatch(nt)) {
        break;
      }
      if (_looksLikeHeaderLine(nt)) break;
      inQuestion.add(j);
      taken++;
      j++;
    }
  }

  // 3. Scan for headings.
  // A bare month+year line ("December 1941") is a section ONLY when
  // it repeats (a running month header, e.g. "October 2026" on every
  // page of its section) or carries a subject prefix ("Current
  // Affairs October 2026"). A one-off month+year — an answer like
  // "December 1941" (Pearl Harbor) — is not a section.
  bool isRealMonthSection(String title) {
    if (monthHeadingLabel(title) == null) return true;
    final lower = title.toLowerCase();
    if (_subjectPhrases.any((p) => lower.contains(p))) return true;
    return repeats.contains(_repeatKey(title));
  }

  final headings = <_Heading>[];
  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    // A line inside a question (start / continuation / option) is
    // never a heading — see the question-span marking above.
    if (inQuestion.contains(line.lineIndex)) {
      i++;
      continue;
    }
    // Bold markers (U+E000) are extractor plumbing, not text — strip
    // them before any heading check so a bold heading ("Pakistan
    // Current Affairs") titles its part cleanly.
    final text = stripBoldMarkers(line.text).trim();
    if (!_isExcludedLine(text, repeats)) {
      // Split heading? Try joining with the next short line first.
      var title = text;
      var consumed = 1;
      if (i + 1 < lines.length) {
        final next = stripBoldMarkers(lines[i + 1].text).trim();
        if (_isJoinableContinuation(next, repeats)) {
          final joined = '$text $next';
          // Join when the joined line is a strong heading ("Pakistan
          // Current" + "Affairs"), OR when both lines are ALL-CAPS
          // and the joined line is a generic heading — an
          // organisation name split across two lines ("INTERNATIONAL
          // FUND AND" + "AGRICULUTURAL DEVELOPMENT"). A title-case
          // heading + subtitle never joins (both lines must be caps).
          if (_isStrongHeading(joined) ||
              (_isAllCaps(text) &&
                  _isAllCaps(next) &&
                  _isGenericHeading(joined))) {
            title = joined;
            consumed = 2;
          }
        }
      }
      // A year heading is normalised ("Special CSS 2023" → "CSS
      // 2023") so a repeated year dedupes to one part.
      final yearLabel = yearHeadingLabel(title);
      if (yearLabel != null) title = yearLabel;
      final isHeading =
          (isRealMonthSection(title) && _isStrongHeading(title)) ||
          (firstOnPage[line.page] == line.lineIndex &&
              _isGenericHeading(title));
      if (isHeading) {
        headings.add(
          _Heading(lineIndex: line.lineIndex, page: line.page, title: title),
        );
        i += consumed;
        continue;
      }
    }
    i++;
  }

  // 4. Drop headings with no content before the next heading
  //    (book titles / subtitles, e.g. "PPSC CURRENT AFFAIRS" followed
  //    only by its subtitle line before the first real section).
  final kept = <_Heading>[];
  for (var h = 0; h < headings.length; h++) {
    final start = headings[h].lineIndex + 1;
    final end = h + 1 < headings.length
        ? headings[h + 1].lineIndex
        : lines.length;
    var hasContent = false;
    for (var j = start; j < end; j++) {
      if (_isContentLine(lines[j].text)) {
        hasContent = true;
        break;
      }
    }
    if (hasContent) kept.add(headings[h]);
  }

  // 5. Drop a later heading that repeats an earlier title exactly
  //    (a section title reused as a running head on another page).
  final deduped = <_Heading>[];
  final seenTitles = <String>{};
  for (final h in kept) {
    if (seenTitles.add(h.title.toLowerCase())) deduped.add(h);
  }

  if (deduped.isEmpty) {
    return BookStructure(
      parts: [
        BookPart(
          title: wholeBookPartTitle,
          startPage: 1,
          endPage: totalPages,
          questionCount: lines.where((l) => _questionStartRe.hasMatch(l.text)).length,
        ),
      ],
      headingLineIndices: [-1],
    );
  }

  final parts = <BookPart>[];
  final indices = <int>[];
  for (var h = 0; h < deduped.length; h++) {
    final startPage = h == 0 ? 1 : deduped[h].page;
    var endPage = h + 1 < deduped.length
        ? deduped[h + 1].page - 1
        : totalPages;
    if (endPage < startPage) endPage = startPage;
    final from = deduped[h].lineIndex;
    final to = h + 1 < deduped.length
        ? deduped[h + 1].lineIndex
        : lines.length;
    var count = 0;
    for (var j = from; j < to; j++) {
      if (_questionStartRe.hasMatch(lines[j].text)) count++;
    }
    parts.add(
      BookPart(
        title: deduped[h].title,
        startPage: startPage,
        endPage: endPage,
        questionCount: count,
      ),
    );
    indices.add(deduped[h].lineIndex);
  }
  return BookStructure(parts: parts, headingLineIndices: indices);
}

/// A short continuation line that may complete a split heading
/// ("Affairs" after "Pakistan Current", "Current Affairs" after
/// "International"): short, no digits, not a question / option /
/// answer / footer / repeat. The continuation may itself be a strong
/// heading — that is exactly the split-heading case.
bool _isJoinableContinuation(String text, Set<String> repeats) {
  if (text.length > 30) return false;
  if (_alphaWordCount(text) > 3) return false;
  if (RegExp(r'\d').hasMatch(text)) return false;
  if (text.endsWith('.') || text.endsWith('?') || text.endsWith('!')) {
    return false;
  }
  if (_isExcludedLine(text, repeats)) return false;
  return text.isNotEmpty && text[0] == text[0].toUpperCase();
}
