import '../../models/exam.dart';
import '../answer_key.dart';
import '../book_structure.dart';
import '../mcq_parser.dart';

/// Format registry for the extraction engine (Phase A, v2.0.0).
///
/// HONEST SCOPE — read this before extending it. A full refactor of
/// the parser into per-format classes was NOT done: the 634-test
/// suite is the safety net, and moving the block / one-liner /
/// q-only / flashcard paths out of _parseImpl in one pass risked
/// it. What exists here is the modular structure the next format
/// plugs into:
///
/// * every format the engine knows is DESCRIBED in one place
///   ([FormatRegistry.all]) — id, human label, recognition rule,
///   where its code lives, and which test proves it;
/// * ONE format is EXTRACTED as the proof: the table format, behind
///   [TableFormatHandler], which delegates to the public
///   [parseTableFormat] entry point in mcq_parser.dart. The registry
///   is the single place that entry point is reached from outside
///   the parser (see [FormatRegistry.table]);
/// * the other formats are marked `embeddedIn: '_parseImpl'` — their
///   code still lives in the shared implementation. Extracting one
///   of them means: move its function(s) into
///   `lib/services/extraction/<format>.dart`, give it a handler
///   class like [TableFormatHandler], register it here, and add a
///   test that the handler and the old path agree.
///
/// HOW TO ADD A NEW FORMAT (extension point):
/// 1. Write the detector + parser as a pure function on
///    `List<SegmentedLine>` (same shape as [parseTableFormat]) in a
///    new file under `lib/services/extraction/`.
/// 2. Add a [FormatDescriptor] below with a handler that calls it.
/// 3. Wire it into _parseImpl BEFORE the block loop (like the
///    table call) or as a block-loop branch — whichever the format
///    needs — and consume its lines so no later pass re-reads them.
/// 4. Add a regression test in `test/` that runs the format through
///    [parseMcqs] end to end, plus a negative test (prose that must
///    NOT become this format).
/// 5. Document it in `docs/universal-formats.md` and
///    `docs/extraction-audit.md` with MEASURED counts, never a
///    claim without a test.
class FormatRegistry {
  const FormatRegistry._();

  /// All formats the engine knows, in the order _parseImpl tries
  /// them (table first, then the block loop's block → one-liner →
  /// q-only → flashcard order).
  static const List<FormatDescriptor> all = [
    FormatDescriptor(
      id: 'table',
      label: 'Table grid (Question | A | B | C | D | key | type)',
      recognition:
          'Column-wise: a run of ≥ 3 key letters with the pre-key '
          'region grouping into exactly 5N items. Row-wise: question '
          'line(s) + 4 bare option lines anchored by a key letter or '
          'a type label; ≥ 2 rows.',
      codeLocation: 'lib/services/mcq_parser.dart (parseTableFormat)',
      provingTest: 'test/table_format_test.dart',
      handler: TableFormatHandler(),
    ),
    FormatDescriptor(
      id: 'block',
      label: 'Standard block (Q + 4 options + Answer line)',
      recognition:
          'Numbered question start ("Q1." / "1.") followed by 4 '
          'option lines and an answer line, key entry, tick, bold or '
          'asterisk signal.',
      codeLocation: 'lib/services/mcq_parser.dart (_parseImpl block loop)',
      provingTest: 'test/realfile_counts_test.dart (F1, F6, F12)',
      embeddedIn: '_parseImpl',
    ),
    FormatDescriptor(
      id: 'one-liner',
      label: 'One-liner (Q + (a)–(d) inline)',
      recognition:
          'Question + all 4 options on one line, markers (a)/(b)/'
          '(c)/(d) or A./B./C./D. in a consecutive run.',
      codeLocation: 'lib/services/mcq_parser.dart (_parseOneLiner)',
      provingTest: 'test/universal_formats_test.dart (GSA)',
      embeddedIn: '_parseImpl',
    ),
    FormatDescriptor(
      id: 'q-only',
      label: 'Q-only (Q + direct answer, options from the book pool)',
      recognition:
          '"Q. … Ans: …" line, or a "?"-terminated stem with an '
          'answer token in the following lines; distractors are other '
          'answers in the same book, never invented.',
      codeLocation: 'lib/services/mcq_parser.dart (_qOnlyAnswer)',
      provingTest: 'test/realfile_counts_test.dart (F8, F13, F14)',
      embeddedIn: '_parseImpl',
    ),
    FormatDescriptor(
      id: 'flashcard',
      label: 'Flashcard ("?" + short plain answer)',
      recognition:
          'Dash-inline ("Q? — Answer"), trailing answer after the '
          'last "?" / ":" / "؟", or answer on the next line(s). '
          'Unnumbered lists work; the answer never swallows the next '
          'question (see test/phase_a_gaps_test.dart G6).',
      codeLocation: 'lib/services/mcq_parser.dart (_scanFlashcards)',
      provingTest: 'test/phase_a_gaps_test.dart (G6)',
      embeddedIn: '_parseImpl',
    ),
  ];

  /// The table-format handler — the one extracted format. This is
  /// the supported way to reach [parseTableFormat] from outside the
  /// parser (new code should use this, not call the parser's
  /// internals directly).
  static const TableFormatHandler table = TableFormatHandler();

  /// Looks a format up by id, or null when the engine has no such
  /// format (an unknown format is never guessed — the caller falls
  /// back to the block loop).
  static FormatDescriptor? byId(String id) {
    for (final f in all) {
      if (f.id == id) return f;
    }
    return null;
  }
}

/// One format the engine knows: what it looks like, where its code
/// lives, and what proves it works. [handler] is non-null only for
/// formats extracted behind a handler class; [embeddedIn] names the
/// function an un-extracted format still lives in.
class FormatDescriptor {
  const FormatDescriptor({
    required this.id,
    required this.label,
    required this.recognition,
    required this.codeLocation,
    required this.provingTest,
    this.handler,
    this.embeddedIn,
  });

  final String id;
  final String label;
  final String recognition;
  final String codeLocation;
  final String provingTest;

  /// The handler when this format is extracted ([TableFormatHandler]
  /// today); null while the format still lives inside _parseImpl.
  final TableFormatHandler? handler;

  /// Name of the function the format still lives in, when it has no
  /// handler yet.
  final String? embeddedIn;

  /// True when the format is extracted behind a handler (addable
  /// without touching the parser's shared implementation).
  bool get isExtracted => handler != null;
}

/// The extracted table-format handler (the modularisation proof).
/// Delegates to the parser's public table entry point; the
/// column-wise and row-wise machines stay in mcq_parser.dart until
/// a later extraction moves them (their shared private helpers —
/// _TableSink, the type-label tables — are still parser-internal).
class TableFormatHandler {
  const TableFormatHandler();

  TableParseResult parse(
    List<SegmentedLine> lines, {
    BookStructure? structure,
    required String sourceId,
    required String sourceLabel,
    Subject defaultSubject = Subject.gk,
  }) {
    return parseTableFormat(
      lines,
      structure: structure,
      sourceId: sourceId,
      sourceLabel: sourceLabel,
      defaultSubject: defaultSubject,
    );
  }
}
