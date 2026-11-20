// Parse validation per MASTER DIRECTIVE Part 10.
//
// After a parse, every problem is DETECTED and FLAGGED — never
// silently repaired, never silently dropped. A missing answer stays
// missing (the question is kept answerless, never guessed); a
// duplicate stays a duplicate (reported, not merged); a conflict
// stays a conflict (both signals recorded, the answer unverified);
// an unmatched key entry stays unmatched (reported, never forced
// onto the nearest question); a suspected fabrication is flagged
// for review (never presented as a verified question).
//
// Pure module over [ParseResult]: no file I/O, no parser imports
// beyond the result type, so it is testable in isolation. The upload
// preview shows this report before anything is saved.
//
// KNOWN LIMIT (Part 13 gap): [Question] carries no structured paper
// identity (no paper number/title/year — only `part` + `sourceId`),
// and [ParseResult.keyPaperReport] is human-readable strings, so a
// key applied to the WRONG paper cannot be detected from the result
// alone. That check belongs in the key-join step (paper_identity.dart
// + the segmenter's paper attribution), not here; the raw
// key-paper notes are carried through in [ValidationReport.keyPaperNotes]
// so the preview can still show them. See the audit report.
library;

import 'mcq_parser.dart';

enum ValidationSeverity {
  /// Must be fixed or explicitly accepted before the import is used
  /// for scoring (duplicates, wrong-paper keys).
  error,

  /// Needs a human look before the test is taken (conflicts,
  /// unmatched keys, suspected fabrications).
  warning,

  /// Expected in normal operation (answerless questions in a book
  /// with no key) — shown, not alarming.
  info,
}

enum ValidationKind {
  missingAnswer,
  duplicateQuestion,
  duplicateNumber,
  conflictingAnswer,
  unmatchedKeyEntry,
  fabricationSuspect,
}

class ValidationIssue {
  const ValidationIssue({
    required this.kind,
    required this.severity,
    required this.detail,
    this.questionRef,
  });

  final ValidationKind kind;
  final ValidationSeverity severity;

  /// Plain-language detail, e.g. 'Paper 1 Q4 — no key entry'.
  final String detail;

  /// Short reference to the question, e.g. its text (truncated) or
  /// 'page 7', when known.
  final String? questionRef;

  @override
  String toString() =>
      '[${severity.name}/${kind.name}] $detail${questionRef == null ? '' : ' ($questionRef)'}';
}

class ValidationReport {
  const ValidationReport({
    required this.issues,
    required this.keyPaperNotes,
  });

  final List<ValidationIssue> issues;

  /// The parser's per-paper key attribution, verbatim
  /// (ParseResult.keyPaperReport), for the preview to show.
  final List<String> keyPaperNotes;

  List<ValidationIssue> get errors => issues
      .where((i) => i.severity == ValidationSeverity.error)
      .toList();
  List<ValidationIssue> get warnings => issues
      .where((i) => i.severity == ValidationSeverity.warning)
      .toList();

  /// True when nothing blocks using the import (warnings may still
  /// need a human look; infos are normal).
  bool get hasErrors => errors.isNotEmpty;

  Map<ValidationKind, int> get countsByKind {
    final m = <ValidationKind, int>{};
    for (final i in issues) {
      m[i.kind] = (m[i.kind] ?? 0) + 1;
    }
    return m;
  }

  String get summary {
    if (issues.isEmpty) return 'No validation issues.';
    final parts = countsByKind.entries
        .map((e) => '${e.value} ${e.key.name}')
        .join(', ');
    return '${issues.length} issue(s): $parts.';
  }
}

/// Validates one [ParseResult]. Never mutates it, never repairs
/// anything — it only reports.
ValidationReport validateParseResult(ParseResult r) {
  final issues = <ValidationIssue>[];

  // Missing answers: answerless questions the key could not answer.
  // Info, not error — an answerless book is legitimate (the
  // no-answers notice + test-without-answers mode, 20 Nov 2026);
  // the questions are kept, never guessed.
  for (final p in r.answerPending) {
    issues.add(ValidationIssue(
      kind: ValidationKind.missingAnswer,
      severity: ValidationSeverity.info,
      detail: 'No answer in the book — kept answerless, never scored.',
      questionRef: 'page ${p.page} :: ${p.text}',
    ));
  }
  for (final m in r.questionsMissingAnswers) {
    issues.add(ValidationIssue(
      kind: ValidationKind.missingAnswer,
      severity: ValidationSeverity.info,
      detail: m,
    ));
  }

  // Duplicate questions: the same text parsed twice. Error — a
  // duplicated question corrupts a test (same question twice, and a
  // key entry could land on the wrong copy). Never merged silently.
  final seenText = <String, int>{};
  for (final q in r.questions) {
    final key = q.text.trim().toLowerCase();
    seenText[key] = (seenText[key] ?? 0) + 1;
  }
  for (final e in seenText.entries) {
    if (e.value > 1) {
      issues.add(ValidationIssue(
        kind: ValidationKind.duplicateQuestion,
        severity: ValidationSeverity.error,
        detail: 'Question text parsed ${e.value} times.',
        questionRef: e.key,
      ));
    }
  }

  // Duplicate numbering (reported by the parser).
  for (final d in r.numberDuplicates) {
    issues.add(ValidationIssue(
      kind: ValidationKind.duplicateNumber,
      severity: ValidationSeverity.error,
      detail: d,
    ));
  }

  // Conflicting answer signals: recorded by the parser, never
  // silently resolved — the answer stays unverified until a human
  // confirms it.
  for (final c in r.conflicts) {
    issues.add(ValidationIssue(
      kind: ValidationKind.conflictingAnswer,
      severity: ValidationSeverity.warning,
      detail: c,
    ));
  }

  // Unmatched key entries: key entries that matched no question.
  // Never forced onto the nearest question (directive Part 8).
  for (final u in r.unmatchedKeyEntries) {
    issues.add(ValidationIssue(
      kind: ValidationKind.unmatchedKeyEntry,
      severity: ValidationSeverity.warning,
      detail: u,
    ));
  }

  // Suspected fabrications: a q-only/flashcard question whose text
  // has the shape of a key fragment or an explanation bullet, not a
  // real question (PPSC-66 baseline §4: "(A) Speak:", "- Conquests:",
  // "- Founder of the Ilkhanate:", "… - Mongol Emperor:",
  // "Oldest University in Europe:"). Flagged for review — never
  // presented as verified. Legitimate q-only/flashcard questions
  // (a "?"-terminated stem, an instruction stem like "Choose the
  // correct synonym …") do not match any branch.
  for (final q in r.questions) {
    if (q.answerSource != 'flashcard' && q.answerSource != 'q-only') {
      continue;
    }
    if (_looksFabricated(q.text)) {
      issues.add(ValidationIssue(
        kind: ValidationKind.fabricationSuspect,
        severity: ValidationSeverity.warning,
        detail:
            'Question looks like a key fragment or explanation bullet, not a real question — review before using.',
        questionRef: 'page ${q.page} :: ${q.text}',
      ));
    }
  }

  return ValidationReport(
    issues: issues,
    keyPaperNotes: List.of(r.keyPaperReport),
  );
}

bool _looksFabricated(String text) {
  final t = text.trim();
  if (t.isEmpty) return false;
  // (a) Starts with an option-letter marker: "(A) Speak:", "(B)
  // Muzzle:", "(C) [?" — a key fragment, never a question stem.
  if (RegExp(r'^\(?[A-Da-d]\)').hasMatch(t)) return true;
  // (b) A bullet label: "- Conquests:", "- The Fall of Baghdad:".
  if (RegExp(r'^[-–—•]\s').hasMatch(t)) return true;
  // (c) A dash-label tail: "… Halaku Khan was - Mongol Emperor:",
  // "… - The Siege:", "… - Aftermath:".
  if (RegExp(r'\s+[-–—]\s+[A-Z][^:]{0,40}:\s*$').hasMatch(t)) return true;
  // (d) A short bare label ending in ':' with no question mark and
  // no instruction verb: "Oldest University in Europe:".
  // Instruction stems ("Choose the correct synonym Wheedle:") are
  // real questions and are excluded by the verb check.
  if (t.endsWith(':') && !t.contains('?')) {
    final words = t.split(RegExp(r'\s+')).length;
    final first = t.split(RegExp(r'\s+')).first.toLowerCase();
    const instructionVerbs = {
      'choose',
      'select',
      'identify',
      'what',
      'which',
      'who',
      'when',
      'where',
      'give',
      'name',
      'find',
      'translate',
      'fill',
      'complete',
    };
    if (words <= 5 && !instructionVerbs.contains(first)) return true;
  }
  return false;
}
