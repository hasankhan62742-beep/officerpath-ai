import 'package:flutter/foundation.dart';

/// Exam patterns — VERIFIED 18 Nov 2026 (see README § Exam patterns).
///
/// PPSC: 100 MCQs, 100 marks, 90 min, -0.25 negative, 40% pass.
/// FPSC BS-16/17: 100 marks, 100 min, -0.25 negative, 40% overall.
/// CSS MPT: 200 questions, 200 marks, 200 min.
/// PMS / KPPSC / SPSC / BPSC: same one-paper pattern as PPSC by default
/// (100 / 90 min / -0.25). The user can change questions/minutes per test
/// on the setup screen; the pattern below is only the default.
enum Subject {
  gk('General Knowledge'),
  pakStudies('Pakistan Studies'),
  islamiat('Islamiat'),
  currentAffairs('Current Affairs'),
  english('English'),
  everydayScience('Everyday Science'),
  mathsComputer('Maths & Computer');

  const Subject(this.label);
  final String label;

  static Subject fromLabel(String label) {
    for (final s in Subject.values) {
      if (s.label.toLowerCase() == label.trim().toLowerCase()) return s;
    }
    // AUDIT m2: an unknown stored label used to silently become GK.
    debugPrint('Subject.fromLabel: unknown label "$label", using GK.');
    return Subject.gk;
  }
}

class ExamPattern {
  const ExamPattern({
    required this.id,
    required this.name,
    required this.shortName,
    required this.defaultQuestions,
    required this.defaultMinutes,
    required this.negativeMarking,
    required this.passPercent,
    required this.description,
  });

  final String id;
  final String name;
  final String shortName;

  /// Default full-paper size (user can pick 25 / 50 / 100 on setup).
  final int defaultQuestions;

  /// Default full-paper time in minutes.
  final int defaultMinutes;
  final double negativeMarking;

  /// Pass percentage, e.g. 40 means 40%.
  final double passPercent;
  final String description;

  /// Minutes allowed for a test of [questionCount] questions.
  /// Scales linearly from the full-paper pattern and rounds up to a
  /// whole minute, minimum 10 minutes.
  int minutesFor(int questionCount) {
    if (questionCount >= defaultQuestions) return defaultMinutes;
    final scaled =
        (defaultMinutes * questionCount / defaultQuestions).ceil();
    return scaled < 10 ? 10 : scaled;
  }

  /// Timer label, e.g. "90 min • 100 MCQs".
  String get patternLabel =>
      '$defaultQuestions MCQs • $defaultMinutes min • -$negativeMarking negative';

  static const List<ExamPattern> all = [
    ExamPattern(
      id: 'ppsc',
      name: 'PPSC — Punjab Public Service Commission',
      shortName: 'PPSC',
      defaultQuestions: 100,
      defaultMinutes: 90,
      negativeMarking: 0.25,
      passPercent: 40,
      description: 'One-paper MCQ screening test for Punjab govt posts.',
    ),
    ExamPattern(
      id: 'fpsc',
      name: 'FPSC — Federal Public Service Commission',
      shortName: 'FPSC',
      defaultQuestions: 100,
      defaultMinutes: 100,
      negativeMarking: 0.25,
      passPercent: 40,
      description: 'One-paper screening test, BS-16/17 posts.',
    ),
    ExamPattern(
      id: 'css_mpt',
      name: 'CSS MPT — MCQ-based Preliminary Test',
      shortName: 'CSS MPT',
      defaultQuestions: 200,
      defaultMinutes: 200,
      negativeMarking: 0.25,
      passPercent: 33,
      description:
          'First stage of CSS: 200 MCQs in 200 minutes. (Pass rule varies by year — check the FPSC ad.)',
    ),
    ExamPattern(
      id: 'pms',
      name: 'PMS — Provincial Management Service',
      shortName: 'PMS',
      defaultQuestions: 100,
      defaultMinutes: 90,
      negativeMarking: 0.25,
      passPercent: 40,
      description:
          'PMS screening / one-paper stage. Written papers are descriptive — this app covers the MCQ stage.',
    ),
    ExamPattern(
      id: 'kppsc',
      name: 'KPPSC — Khyber Pakhtunkhwa Public Service Commission',
      shortName: 'KPPSC',
      defaultQuestions: 100,
      defaultMinutes: 90,
      negativeMarking: 0.25,
      passPercent: 40,
      description: 'One-paper MCQ screening test for KP govt posts.',
    ),
    ExamPattern(
      id: 'spsc',
      name: 'SPSC — Sindh Public Service Commission',
      shortName: 'SPSC',
      defaultQuestions: 100,
      defaultMinutes: 90,
      negativeMarking: 0.25,
      passPercent: 40,
      description: 'One-paper MCQ screening test for Sindh govt posts.',
    ),
    ExamPattern(
      id: 'bpsc',
      name: 'BPSC — Balochistan Public Service Commission',
      shortName: 'BPSC',
      defaultQuestions: 100,
      defaultMinutes: 90,
      negativeMarking: 0.25,
      passPercent: 40,
      description: 'One-paper MCQ screening test for Balochistan govt posts.',
    ),
  ];

  static ExamPattern byId(String id) {
    // AUDIT m2: an unknown stored id used to silently become PPSC.
    final found = all.where((e) => e.id == id).firstOrNull;
    if (found == null) {
      debugPrint('ExamPattern.byId: unknown id "$id", using PPSC.');
    }
    return found ?? all.first;
  }

  /// Suggests an exam pattern from a book's title (v1.2 — the MPT
  /// fix). An MPT past paper (title contains "MPT", or "CSS" +
  /// "Preliminary") lands under the CSS MPT pattern (200 Q / 200
  /// marks / 200 min), NOT the PPSC default. Returns null when the
  /// title says nothing about the exam — the user keeps their
  /// manually picked exam. Title-only on purpose: the full text is
  /// not needed and a title match is what the user sees.
  static ExamPattern? suggestForTitle(String title) {
    final t = title.toLowerCase();
    if (t.contains('mpt')) return byId('css_mpt');
    if (t.contains('css') && t.contains('preliminary')) {
      return byId('css_mpt');
    }
    return null;
  }
}
