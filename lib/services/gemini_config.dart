/// Gemini configuration — ONE place for the model id, endpoint and
/// cost guardrails (v1.2, Option A: the user enters their own free
/// Gemini key in Settings; the owner pays Rs 0).
///
/// MODEL: `gemini-3.5-flash-lite` is the PRIMARY model. Live-tested
/// 19 Nov 2026: `gemini-2.5-flash-lite` returns HTTP 404 ("no longer
/// available to new users") — it must NOT be used as primary. The
/// fallback is never a Pro model (a Pro call would cost ~10x and burn
/// the free tier); if the primary 404s, the app reports the error
/// honestly instead of silently switching to an expensive model.
///
/// COSTS (Nov 2026 rates, ESTIMATES — label them as such in the UI):
/// ~$0.021–0.029 (~Rs 6–8) per 100 MCQs generated; one scanned Urdu
/// page via Gemini vision ≈ $0.0004 (~Rs 0.11); answer inference
/// ≈ $0.00002/question. The free tier (500 Flash-Lite requests/day,
/// SHARED per project) does NOT scale for a server key — which is why
/// v1.2 uses the user's own key (Option A), never a shared server key.
class GeminiConfig {
  const GeminiConfig._();

  /// Primary model id — the ONLY model id in the app. Do not add a
  /// second model id elsewhere; change it here.
  static const String modelId = 'gemini-3.5-flash-lite';

  /// Gemini Developer API generateContent endpoint (v1beta).
  static const String endpoint =
      'https://generativelanguage.googleapis.com/v1beta/models/'
      '$modelId:generateContent';

  /// Free key from Google AI Studio (shown in Settings when no key
  /// is configured — the user creates their own key, free).
  static const String aiStudioUrl = 'https://aistudio.google.com/apikey';

  /// Image width sent to Gemini vision: a 1000×1400 page ≈ 1,032
  /// image tokens; a 4K render would cost ~4x for no benefit.
  static const int visionImageWidth = 1000;

  /// Max output tokens per generation call (a 100-MCQ batch fits;
  /// larger books are chunked, never given a bigger cap).
  static const int maxOutputTokensGeneration = 4096;

  /// Max output tokens per answer-inference call (one index + a
  /// one-line reason per question, batched).
  static const int maxOutputTokensInference = 1024;

  /// Max output tokens per vision OCR call (a page of transcription).
  static const int maxOutputTokensOcr = 2048;

  /// Generation temperature: low, so the model copies the book's
  /// facts instead of inventing new ones.
  static const double temperature = 0.2;

  /// Daily AI caps (per user, per day, counted on-device):
  /// free users 2 AI books/day, Premium 10. A "book" here is one
  /// AI generation / inference run over one book's text.
  static const int freeDailyAiBooks = 2;
  static const int premiumDailyAiBooks = 10;

  /// Max characters of book text sent per generation chunk. A chunk
  /// is one Gemini call; a book is split into chunks of at most this
  /// size so no call carries a whole 200-page book.
  static const int maxCharsPerChunk = 12000;

  /// Max questions requested per generation chunk.
  static const int maxQuestionsPerChunk = 25;
}

/// What went wrong with a Gemini call, in user-facing terms. The app
/// never shows a raw HTTP body to the user — it maps it to one of
/// these, with a concrete next step.
enum GeminiFailureKind {
  /// No key is stored yet — Settings must collect one first.
  noKey,

  /// No network / the request timed out.
  noInternet,

  /// HTTP 429 or a quota error — the free limit is reached.
  quota,

  /// HTTP 404 on the model, or 400/401/403 (bad / revoked key).
  badKeyOrModel,

  /// The model returned something that is not usable JSON / text.
  badResponse,

  /// Anything else (HTTP 5xx, unexpected status).
  unknown,
}

class GeminiException implements Exception {
  const GeminiException(this.kind, this.message);

  final GeminiFailureKind kind;

  /// User-facing message (already plain language, no raw body).
  final String message;

  @override
  String toString() => message;
}
