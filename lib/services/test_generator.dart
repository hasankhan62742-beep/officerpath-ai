import 'dart:convert';
import 'dart:math';

import '../models/exam.dart';
import '../models/question.dart';

/// Canonical PPSC one-paper section order (user, 19 Nov 2026): the
/// order sections appear in a PPSC paper. Used to order test groups
/// when a test mixes sections from MULTIPLE sources; a single paper
/// keeps its own section order (see [generateTest]).
const canonicalSubjectOrder = [
  'General Knowledge',
  'Pakistan Studies',
  'Islamiat',
  'English',
  'Urdu',
  'Mathematics',
  'Everyday Science',
  'Computer',
  'Current Affairs',
];

/// Maps a section title to its canonical PPSC subject name, or null
/// when it is not a recognised subject. Name variants map to the
/// same slot ("Pakistan Affairs" / "Pakistan Studies" → "Pakistan
/// Studies", "Maths" → "Mathematics", "GK" → "General Knowledge").
/// The check order is about disambiguation, not the final sort: e.g.
/// "current affairs" is checked before "pakistan", so "Pakistan
/// Current Affairs" is a Current Affairs section, not Pakistan
/// Studies; "computer" is checked before "science", so "Computer
/// Science" is Computer, not Everyday Science.
String? _canonicalNameFor(String label) {
  final lower = label.toLowerCase().trim();
  if (lower.contains('general knowledge') || lower == 'gk') {
    return 'General Knowledge';
  }
  if (lower.contains('current affairs')) return 'Current Affairs';
  if (lower.contains('pakistan')) return 'Pakistan Studies';
  if (lower.contains('islam')) return 'Islamiat';
  if (lower.contains('english')) return 'English';
  if (lower.contains('urdu')) return 'Urdu';
  if (lower.contains('math')) return 'Mathematics';
  if (lower.contains('computer') ||
      lower == 'it' ||
      lower.contains('information technology')) {
    return 'Computer';
  }
  if (lower.contains('everyday science') || lower.contains('science')) {
    return 'Everyday Science';
  }
  return null;
}

/// The section identity of a question: its book part (the section
/// title structure detection assigned, e.g. "General Knowledge",
/// "Pakistan Affairs") when present, else its subject label.
/// Normalised to a canonical PPSC subject name when the title maps
/// to one, so the same subject under different book titles is one
/// group. A title that maps to no canonical subject ("Paper 1",
/// "CSS 2000", "UNO") is kept as-is — it is its own section.
String sectionLabelFor(Question q) {
  final raw = q.part.trim().isNotEmpty ? q.part.trim() : q.subject.label;
  return _canonicalNameFor(raw) ?? raw;
}

/// One contiguous section run inside a generated test: the section
/// label and the 1-based question range it covers ("English —
/// Q11–20"). Consecutive questions with the same section identity
/// form one run.
class TestSection {
  const TestSection({
    required this.label,
    required this.start,
    required this.end,
  });

  /// e.g. "English", "Pakistan Studies", "Paper 1".
  final String label;

  /// 1-based first question number of this section in the test.
  final int start;

  /// 1-based last question number of this section in the test.
  final int end;
}

/// The section runs of a question list, in order. The test screen
/// uses it to show a section banner when the section changes; it
/// works on any list (a grouped test, a retry list, a resumed test).
List<TestSection> testSections(List<Question> questions) {
  final sections = <TestSection>[];
  for (var i = 0; i < questions.length; i++) {
    final label = sectionLabelFor(questions[i]);
    if (sections.isNotEmpty && sections.last.label == label) {
      sections[sections.length - 1] = TestSection(
        label: label,
        start: sections.last.start,
        end: i + 1,
      );
    } else {
      sections.add(TestSection(label: label, start: i + 1, end: i + 1));
    }
  }
  return sections;
}

/// Builds a random test ONLY from the sources the user ticked as prepared.
/// Options are shuffled per question so answer positions can't be memorised.
///
/// SUBJECT-GROUPED ORDER (PPSC pattern, user 19 Nov 2026): the test
/// is grouped by subject/section, in sequence — all GK first, then
/// all English, then all Maths, … — NEVER randomly interleaved
/// across subjects. The pool is grouped by section identity
/// ([sectionLabelFor]); the groups are ordered, then `count` is
/// distributed across them (even split, capped by availability, any
/// shortfall redistributed); questions are shuffled WITHIN each group
/// only, then the groups are concatenated in order.
///
/// Group order: when ALL picked questions come from ONE paper/book,
/// the groups keep THAT paper's own section order (first-seen in the
/// bank, i.e. page order — the PPSC order by construction, e.g.
/// General Knowledge then Pakistan Affairs). When the test mixes
/// sections from several sources, the groups follow
/// [canonicalSubjectOrder]; sections that map to no canonical subject
/// ("Paper 1", "CSS 2000") come last, in first-seen order.
List<Question> generateTest({
  required List<Question> bank,
  required Set<String> sourceIds,
  required int count,
  int? seed,
}) {
  final pool = bank.where((q) => sourceIds.contains(q.sourceId)).toList();
  if (pool.isEmpty || count <= 0) return [];
  final take = count > pool.length ? pool.length : count;

  // Group the pool by section. The first-seen index is the bank
  // (import/page) order — the book's own section order.
  final groups = <String, List<Question>>{};
  final firstSeen = <String, int>{};
  for (var i = 0; i < pool.length; i++) {
    final label = sectionLabelFor(pool[i]);
    groups.putIfAbsent(label, () => []).add(pool[i]);
    firstSeen.putIfAbsent(label, () => i);
  }
  final labels = groups.keys.toList();

  final singleSource = pool.map((q) => q.sourceId).toSet().length == 1;
  if (singleSource) {
    // One paper: its own section order (first-seen in the bank).
    labels.sort((a, b) => firstSeen[a]!.compareTo(firstSeen[b]!));
  } else {
    // Several sources: the canonical PPSC list; ties (two sections
    // in the same canonical slot, e.g. two "Other" parts) keep
    // first-seen order.
    int canonicalIndex(String label) {
      final idx = canonicalSubjectOrder.indexOf(label);
      return idx == -1 ? canonicalSubjectOrder.length : idx;
    }

    labels.sort((a, b) {
      final c = canonicalIndex(a).compareTo(canonicalIndex(b));
      if (c != 0) return c;
      return firstSeen[a]!.compareTo(firstSeen[b]!);
    });
  }

  // Distribute `take` across the groups: an even split, capped by
  // each group's size, with any shortfall redistributed to groups
  // that still have questions (in group order). Never
  // concatenate-then-take — that would front-load the first subject.
  final shares = List<int>.filled(labels.length, 0);
  final base = take ~/ labels.length;
  final rem = take % labels.length;
  var allocated = 0;
  for (var i = 0; i < labels.length; i++) {
    final want = base + (i < rem ? 1 : 0);
    final size = groups[labels[i]]!.length;
    shares[i] = want < size ? want : size;
    allocated += shares[i];
  }
  var shortfall = take - allocated;
  while (shortfall > 0) {
    var gave = false;
    for (var i = 0; i < labels.length && shortfall > 0; i++) {
      if (shares[i] < groups[labels[i]]!.length) {
        shares[i]++;
        shortfall--;
        gave = true;
      }
    }
    if (!gave) break;
  }

  // Shuffle WITHIN each group only (the seed stays deterministic),
  // then concatenate the groups in order. Options are shuffled per
  // question exactly as before.
  final baseSeed = seed ?? DateTime.now().millisecondsSinceEpoch;
  final rng = Random(baseSeed);
  final optRng = Random(baseSeed + 1);
  final picked = <Question>[];
  for (var i = 0; i < labels.length; i++) {
    final group = List<Question>.of(groups[labels[i]]!);
    group.shuffle(rng);
    picked.addAll(group.take(shares[i]));
  }
  return picked.map((q) {
    final order = [0, 1, 2, 3]..shuffle(optRng);
    return q.copyWithShuffledOptions(order);
  }).toList();
}

/// Result of one attempt. Scoring follows the commission rule:
/// +1 per correct, -[negative] per wrong, 0 for skipped.
/// Questions WITHOUT an answer (correctIndex -1, "no-answers" mode,
/// 20 Nov 2026) are never scored: they count in [unscored] only —
/// never correct, never wrong, never skipped — and the percent /
/// pass mark are computed over the SCORED questions only ([scoredTotal]).
class AttemptResult {
  const AttemptResult({
    required this.questions,
    required this.answers,
    required this.markedForReview,
    required this.correct,
    required this.wrong,
    required this.skipped,
    required this.unscored,
    required this.score,
    required this.percent,
    required this.passed,
    required this.perSubject,
    required this.wrongQuestions,
    required this.durationSeconds,
  });

  final List<Question> questions;

  /// question index -> chosen option index (null = skipped).
  final Map<int, int?> answers;
  final Set<int> markedForReview;
  final int correct;
  final int wrong;
  final int skipped;

  /// Questions with no attached answer — asked, never scored.
  final int unscored;

  /// Questions that carry an answer (the only ones that can score).
  int get scoredTotal => questions.length - unscored;

  /// True when at least one question had no answer.
  bool get hasUnscored => unscored > 0;

  /// True when NO question had an answer — there is no result to show.
  bool get allUnscored => questions.isNotEmpty && unscored == questions.length;
  final double score;
  final double percent;
  final bool passed;

  /// subject label -> {'correct': n, 'total': n}
  final Map<String, Map<String, int>> perSubject;
  final List<Question> wrongQuestions;
  final int durationSeconds;

  /// Average seconds spent per question.
  double get secondsPerQuestion =>
      questions.isEmpty ? 0 : durationSeconds / questions.length;

  /// Raw score before negative marking (= number correct, +1 each).
  double get rawScore => correct.toDouble();

  /// Total marks deducted: wrong × exam negative marking (0.25 each).
  double negativeDeduction(double negativeMarking) =>
      wrong * negativeMarking;

  /// Final score = raw score − deduction. Same as [score].

  /// Subjects sorted worst-first, for the "weak topics" list.
  List<MapEntry<String, Map<String, int>>> get weakSubjects {
    final entries = perSubject.entries.toList();
    entries.sort((a, b) {
      double rate(Map<String, int> m) =>
          m['total']! == 0 ? 1 : m['correct']! / m['total']!;
      return rate(a.value).compareTo(rate(b.value));
    });
    return entries;
  }

  AttemptRecord toRecord({
    required String examId,
    required String examName,
    required String attemptedAtIso,
  }) {
    // The book the test was drawn from: the questions' source labels
    // (usually one book; if the user mixed books, both are named).
    final books = <String>{
      for (final q in questions)
        if (q.sourceLabel.trim().isNotEmpty) q.sourceLabel.trim(),
    };
    return AttemptRecord(
      examId: examId,
      examName: examName,
      bookTitle: books.join(' + '),
      totalQuestions: questions.length,
      correct: correct,
      wrong: wrong,
      skipped: skipped,
      score: score,
      percent: percent,
      passed: passed,
      durationSeconds: durationSeconds,
      attemptedAtIso: attemptedAtIso,
      perSubjectJson: jsonEncode(perSubject),
      wrongQuestionIdsJson: jsonEncode(
        wrongQuestions.map((q) => q.id).whereType<int>().toList(),
      ),
    );
  }
}

AttemptResult scoreAttempt({
  required List<Question> questions,
  required Map<int, int?> answers,
  required Set<int> markedForReview,
  required ExamPattern exam,
  required int durationSeconds,
}) {
  var correct = 0;
  var wrong = 0;
  var skipped = 0;
  var unscored = 0;
  final perSubject = <String, Map<String, int>>{};
  final wrongQuestions = <Question>[];

  for (var i = 0; i < questions.length; i++) {
    final q = questions[i];
    // No attached answer: never scored, never counted as
    // correct/wrong/skipped, and never added to the subject totals —
    // the answer was never in the book, so nothing can be judged.
    if (!q.hasAnswer) {
      unscored++;
      continue;
    }
    final entry = perSubject.putIfAbsent(
      q.subject.label,
      () => {'correct': 0, 'total': 0},
    );
    entry['total'] = entry['total']! + 1;

    final chosen = answers[i];
    if (chosen == null) {
      skipped++;
    } else if (chosen == q.correctIndex) {
      correct++;
      entry['correct'] = entry['correct']! + 1;
    } else {
      wrong++;
      wrongQuestions.add(q);
    }
  }

  final score = correct - wrong * exam.negativeMarking;
  // Percent / pass are over SCORED questions only: an answerless
  // question must not drag the percent down (it was never judged).
  final total = questions.length - unscored;
  // AUDIT F18: the raw score may go negative (0 correct, 20 wrong at
  // −0.25 → −5.00) but the PERCENTAGE floors at 0 — commission result
  // cards never show a negative percent. `score` itself stays negative
  // so the breakdown still shows the real deduction.
  final percent = total == 0 ? 0.0 : max(0.0, score / total * 100);
  final passed = percent >= exam.passPercent;

  // The subject-wise breakdown follows the test's GROUP order: the
  // subjects in the order they first appear in the (grouped)
  // question list. Built explicitly from that order, not left to
  // map-insertion accident — so the result screen shows GK first,
  // then English, then Maths, matching the test itself.
  // Answerless questions have no perSubject entry (never scored),
  // so only scored questions define the order.
  final subjectOrder = <String>[];
  for (final q in questions) {
    if (!q.hasAnswer) continue;
    if (!subjectOrder.contains(q.subject.label)) {
      subjectOrder.add(q.subject.label);
    }
  }
  final orderedPerSubject = <String, Map<String, int>>{
    for (final label in subjectOrder) label: perSubject[label]!,
  };

  return AttemptResult(
    questions: questions,
    answers: answers,
    markedForReview: markedForReview,
    correct: correct,
    wrong: wrong,
    skipped: skipped,
    unscored: unscored,
    score: score,
    percent: percent,
    passed: passed,
    perSubject: orderedPerSubject,
    wrongQuestions: wrongQuestions,
    durationSeconds: durationSeconds,
  );
}
