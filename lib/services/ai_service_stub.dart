import '../models/question.dart';

/// v2 PLUG-IN POINT — AI question generation + cloud sync.
///
/// v1 is deliberately offline-first and ships NO keys, NO backend calls.
/// When the user is ready for v2, implement [AiQuestionService] with
/// Gemini and wire Supabase auth in this file only — screens call this
/// abstraction, so no screen code has to change.
///
/// PROFIT DESIGN — GENERATE ONCE, CACHE, REUSE (non-negotiable):
/// AI generation runs ONCE per book, and the generated MCQs are saved in
/// the local sqflite `questions` table (see StorageService) exactly like
/// parsed MCQs. Every later test just shuffles those CACHED questions —
/// Gemini is NEVER called per test. This is what makes the pricing work:
/// at Gemini Flash rates ($0.75 input / $3.75 output per 1M tokens to
/// 31 Dec 2026, doubling 1 Jan 2027), one 100-MCQ generation costs
/// ≈ Rs 14. A student taking 100 tests a year from the same book still
/// costs ~Rs 14 in AI — against Rs 5,000 (1-year Premium) revenue.
/// Calling Gemini on every test would burn that margin for nothing.
///
/// HOW TO PLUG IN (v2, do NOT put keys in source code):
/// 1. Gemini: pass the key at build time with
///    `--dart-define=GEMINI_API_KEY=...` and read it with
///    `const String.fromEnvironment('GEMINI_API_KEY')`. Send the user's
///    uploaded book text to the Gemini `generateContent` endpoint with a
///    prompt that returns MCQs in the exact format `mcq_parser.dart`
///    accepts (Q + A–D + Answer: X + Explanation:). Parse the reply with
///    `parseMcqs()` and save via `StorageService.addSource()` — once.
///    Deduplicate against already-cached questions for that source before
///    saving, so re-generation never duplicates the bank.
/// 2. Supabase: add `supabase_flutter`, init with the project URL + anon
///    key (also via --dart-define), use it for email/Google sign-in and
///    for syncing attempts across devices. The local sqflite tables stay
///    the source of truth offline; Supabase is only a sync layer.
abstract class AiQuestionService {
  /// Generate MCQs from raw book text. v1 always throws — see below.
  Future<List<Question>> generateFromText(
    String bookText, {
    required String sourceId,
    required String sourceLabel,
    int count = 50,
  });
}

/// v1 stub: AI generation is NOT wired yet. The upload flow uses the
/// in-app parser instead (books that already contain MCQs).
class UnimplementedAiQuestionService implements AiQuestionService {
  @override
  Future<List<Question>> generateFromText(
    String bookText, {
    required String sourceId,
    required String sourceLabel,
    int count = 50,
  }) async {
    throw UnimplementedError(
      'AI generation is a v2 feature. Pass a book that already contains '
      'MCQs (Q + A–D + Answer:) or paste MCQ text — the in-app parser '
      'handles those today. To enable Gemini, implement '
      'AiQuestionService with a --dart-define GEMINI_API_KEY (never '
      'hard-code the key).',
    );
  }
}

/// v2 stub: Supabase auth + sync. v1 has no accounts by design.
class SupabaseSyncStub {
  /// Returns false in v1: no account, everything stays on-device.
  bool get isSignedIn => false;

  /// v2: sign in, then upload local attempts to Supabase.
  Future<void> syncAttempts() async {
    throw UnimplementedError(
      'Cloud sync is a v2 feature. Attempts are stored locally in v1.',
    );
  }
}
