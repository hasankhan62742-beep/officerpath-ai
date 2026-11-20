import 'dart:convert';

import '../models/exam.dart';
import '../models/question.dart';
import 'gemini_client.dart';
import 'gemini_config.dart';
import 'mcq_parser.dart';

/// AI MCQ generation + answer inference (v1.2, Option A — the user's
/// own Gemini key, model [GeminiConfig.modelId]).
///
/// CONTRACT (non-negotiable):
/// * Gemini is called ONCE per book. The generated questions are
///   saved in the local sqflite `questions` table exactly like parsed
///   MCQs — that save IS the cache. Every later test shuffles the
///   cached questions; Gemini is NEVER called per test.
/// * Every generated item is VALIDATED before saving: exactly 4
///   options, the answer is one of them, no duplicate options, no
///   duplicate question text. Distractors come from the book's own
///   facts where a fact pool exists — never invented.
/// * The app extracts the fact/value pool ITSELF and passes it
///   explicitly in the prompt (that is what made the live tests
///   compliant: 8/8 distractor-compliant on the Largest/Longest
///   subset, 9/9 valid on the Study-of subset).
/// * Language match: MCQs are generated IN THE SAME language as the
///   input — Urdu-script input → Urdu-script MCQs (questions, options
///   and explanations all in Urdu script; honorifics ﷺ preserved
///   exactly). Urdu is never transliterated into Roman unless the
///   input itself is Roman.
/// * Source spellings are kept AS-IS (e.g. "SECRATARY", "Haemotology",
///   "Opthalmology") — never silently corrected.

/// One MCQ as returned by Gemini (before validation).
class GeneratedMcq {
  const GeneratedMcq({
    required this.question,
    required this.options,
    required this.answerIndex,
    this.explanation = '',
  });

  final String question;
  final List<String> options;
  final int answerIndex;
  final String explanation;

  factory GeneratedMcq.fromMap(Map<String, dynamic> m) {
    final opts = (m['options'] as List? ?? const [])
        .map((o) => o.toString())
        .toList();
    return GeneratedMcq(
      question: (m['question'] as String? ?? '').trim(),
      options: opts,
      answerIndex: m['answer_index'] as int? ?? -1,
      explanation: (m['explanation'] as String? ?? '').trim(),
    );
  }
}

/// True when [text] is Urdu-script (Arabic-script Unicode range).
/// Used for the language-match rule and for OCR routing.
bool containsUrduScript(String text) {
  var urdu = 0;
  var latin = 0;
  for (final rune in text.runes) {
    if ((rune >= 0x0600 && rune <= 0x06FF) ||
        (rune >= 0x0750 && rune <= 0x077F) ||
        (rune >= 0xFB50 && rune <= 0xFDFF) ||
        (rune >= 0xFE70 && rune <= 0xFEFF)) {
      urdu++;
    } else if ((rune >= 0x41 && rune <= 0x5A) ||
        (rune >= 0x61 && rune <= 0x7A)) {
      latin++;
    }
  }
  return urdu > 0 && urdu >= latin;
}

String _norm(String s) =>
    s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

/// Dedupe facts by normalised "Label: Value" — the same fact printed
/// twice (e.g. "Study of Universe: Cosmology" twice) yields ONE
/// question, never two. Spellings are NOT normalised (as-is rule).
List<FactPair> dedupeFacts(List<FactPair> facts) {
  final seen = <String>{};
  final out = <FactPair>[];
  for (final f in facts) {
    final key = '${_norm(f.label)}:${_norm(f.value)}';
    if (seen.add(key)) out.add(f);
  }
  return out;
}

/// Noise lines that are never facts: share prompts, class ads,
/// headers without a value. The live tests proved these must be
/// filtered app-side — the model was told to ignore them, but the
/// app also never puts them in the fact pool.
bool isFactNoiseLine(String line) {
  final l = line.trim().toLowerCase();
  if (l.isEmpty) return true;
  if (l.contains('share with friends')) return true;
  if (l.contains('for preparation') && l.contains('join')) return true;
  if (l.startsWith('(') && l.endsWith(')')) return true;
  return false;
}

/// Extracts facts from plain text, two shapes:
/// * "Label: Value" lines (glossaries, Largest/Longest lists,
///   Study-of lists, fact cards) — the classic pool.
/// * Dash/bullet statement lines (e.g. the user's Urdu paste:
///   "— رسول اللہ ﷺ کے اونٹنی کا نام قصواء تھا۔") — the whole line
///   IS one fact ([FactPair.isStatement]); no colon required. Without
///   this, a 16-line fact list with a single ':' line built a 1-fact
///   pool and validation vetoed every question (Fixture A defect).
/// Lines without a colon and without a leading bullet are not facts —
/// prose books return an empty pool and generation falls back to
/// "MCQs only from the given text" without a pool constraint.
List<FactPair> extractFactPool(String text, {String part = '', int page = 0}) {
  final out = <FactPair>[];
  for (final raw in text.split('\n')) {
    var line = raw.trim();
    if (isFactNoiseLine(line)) continue;
    // Strip a leading bullet/dash marker ("— ", "- ", "• ", "* ").
    // The marker must be followed by whitespace, so "-0.25 ..." and
    // "-word" keep their leading dash.
    final stripped = line.replaceFirst(RegExp(r'^[—–\-•*·›]\s+'), '');
    final hadMarker = stripped != line;
    line = stripped;
    final idx = line.indexOf(':');
    if (idx >= 2) {
      final label = line.substring(0, idx).trim();
      final value = line.substring(idx + 1).trim();
      if (label.length <= 60 &&
          value.isNotEmpty &&
          value.length <= 120 &&
          !RegExp(r'^\d').hasMatch(label) &&
          label.toLowerCase() != 'note') {
        out.add(FactPair(label: label, value: value, part: part, page: page));
        continue;
      }
      // A colon line that fails the Label:Value guards (a long
      // sentence, a "Note: ...") can still be a statement fact —
      // fall through instead of dropping the line.
    }
    if (!hadMarker) continue;
    // Statement fact: the whole line is one fact. Guards keep
    // questions, MCQ options, one-word fragments and long prose
    // sentences out of the pool.
    if (line.length < 10 || line.length > 200) continue;
    if (line.endsWith('?') || line.endsWith('؟')) continue;
    if (line.split(RegExp(r'\s+')).length < 2) continue;
    if (RegExp(r'^\d').hasMatch(line)) continue;
    if (line.toLowerCase().startsWith('note:')) continue;
    // Never swallow an MCQ option line ("A) ...", "(A) ...").
    if (RegExp(r'^[A-E][.)]').hasMatch(line)) continue;
    if (RegExp(r'^\([A-E]\)').hasMatch(line)) continue;
    out.add(
      FactPair(
        label: line,
        value: line,
        isStatement: true,
        part: part,
        page: page,
      ),
    );
  }
  return dedupeFacts(out);
}

/// Splits [text] into chunks of at most [maxChars] characters,
/// breaking on blank lines so a fact / question is never cut in half.
/// A single over-long paragraph is hard-split at the limit.
List<String> chunkText(String text, [int maxChars = 12000]) {
  final paras = text
      .split(RegExp(r'\n\s*\n'))
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .toList();
  final chunks = <String>[];
  final buf = StringBuffer();
  void flush() {
    if (buf.isEmpty) return;
    chunks.add(buf.toString().trim());
    buf.clear();
  }

  for (final p in paras) {
    if (buf.isEmpty) {
      if (p.length > maxChars) {
        for (var i = 0; i < p.length; i += maxChars) {
          chunks.add(
            p.substring(i, i + maxChars > p.length ? p.length : i + maxChars),
          );
        }
      } else {
        buf.write(p);
      }
      continue;
    }
    if (buf.length + 2 + p.length > maxChars) {
      flush();
      if (p.length > maxChars) {
        for (var i = 0; i < p.length; i += maxChars) {
          chunks.add(
            p.substring(i, i + maxChars > p.length ? p.length : i + maxChars),
          );
        }
      } else {
        buf.write(p);
      }
    } else {
      buf.write('\n\n$p');
    }
  }
  flush();
  return chunks;
}

/// The strict generation prompt. The fact pool (when non-empty) is
/// pasted explicitly so distractors are drawn ONLY from it; the
/// language line forces same-language output.
String buildGenerationPrompt({
  required String chunk,
  required List<FactPair> facts,
  required bool urdu,
}) {
  final lang = urdu
      ? 'Write the questions, options, correct answer and explanation '
            'IN URDU SCRIPT (same as the input). Preserve honorifics '
            'exactly (e.g. ﷺ). Do NOT transliterate into Roman Urdu.'
      : 'Write the questions, options, correct answer and explanation '
            'IN THE SAME LANGUAGE as the input (English here).';
  final pool = facts.isEmpty
      ? ''
      : '\nFACT POOL (use ONLY these values/subjects as distractors — '
            'never invent one):\n${facts.map((f) => f.isStatement ? '- ${f.label}' : '${f.label}: ${f.value}').join('\n')}\n';
  return '''You are making multiple-choice questions ONLY from the text below.
Rules:
- Build questions ONLY from facts stated in the text. Never invent a fact, an option, or an answer.
- Each question has EXACTLY 4 options. The correct answer MUST be one of the 4 options.
- Distractors MUST come ONLY from other facts in the same text (other Values, other Labels' subjects, or words/phrases stated in other fact lines) — never invent one.
- If the same fact appears twice, make only ONE question for it. Never produce two identical questions.
- IGNORE noise lines (headers, share prompts, class ads) — build questions ONLY from real facts.
- Use the source text EXACTLY as written. Do NOT correct or normalise spellings.
- Vary the direction: some questions ask "Label is called?" (answer = the Value), others ask "Value is the study of?" (answer = the Label's subject).
- $lang
- Answer with JSON only, no other text.
- JSON format: {"questions": [{"question": "...", "options": ["...", "...", "...", "..."], "answer_index": 0, "explanation": "..."}]}
$pool
TEXT:
$chunk''';
}

/// Parses Gemini's JSON reply into [GeneratedMcq]s. Throws
/// [FormatException] when the reply is not the expected JSON.
List<GeneratedMcq> parseGeneratedJson(String raw) {
  final start = raw.indexOf('{');
  final end = raw.lastIndexOf('}');
  if (start < 0 || end <= start) {
    throw const FormatException('Gemini reply is not JSON.');
  }
  final decoded = jsonDecode(raw.substring(start, end + 1));
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Gemini reply is not a JSON object.');
  }
  final list = decoded['questions'] as List? ?? const [];
  return list
      .whereType<Map<String, dynamic>>()
      .map(GeneratedMcq.fromMap)
      .toList();
}

/// Result of validating generated MCQs.
class ValidationResult {
  const ValidationResult({required this.valid, required this.rejected});

  final List<GeneratedMcq> valid;

  /// Human-readable reasons for rejected items (never silent).
  final List<String> rejected;
}

/// Validates every generated item BEFORE saving:
/// exactly 4 options, non-empty question/options, answer index in
/// range, no duplicate options, no duplicate question text, and —
/// when a fact pool is supplied AND [enforcePool] is true — every
/// WRONG option must be a value or a label-subject from that pool
/// (never invented). For a STATEMENT fact (a dash/bullet line with no
/// Label:Value split) an option is also legal when it appears
/// verbatim — as a whole word or phrase — inside the statement
/// ("قصواء" inside the camel line), because that word IS one of the
/// book's own facts. [enforcePool] is false when the pool does not
/// cover the text (see [AiGenerationService.generateFromText]): a
/// single stray-colon fact must not veto the whole book. Returns the
/// valid items plus a reason for each rejection.
ValidationResult validateGenerated(
  List<GeneratedMcq> items, {
  List<FactPair> factPool = const [],
  bool enforcePool = true,
}) {
  final valid = <GeneratedMcq>[];
  final rejected = <String>[];
  final seenQuestions = <String>{};
  final allowed = <String>{};
  final statementTexts = <String>[];
  for (final f in factPool) {
    allowed.add(_norm(f.value));
    // The label's subject ("Study of Blood" → "Blood") is a legal
    // reverse-direction option.
    final subject = f.label.replaceAll(
      RegExp(r'^study of\s+', caseSensitive: false),
      '',
    );
    allowed.add(_norm(subject));
    allowed.add(_norm(f.label));
    if (f.isStatement) {
      statementTexts.add(_norm(f.label));
    }
  }

  /// True when [option] is one of the book's own facts: an exact
  /// pool value/subject, or a word/phrase stated verbatim inside a
  /// statement fact. An invented option matches neither.
  bool isFromFacts(String option) {
    final n = _norm(option);
    if (allowed.contains(n)) return true;
    for (final t in statementTexts) {
      if (' $t '.contains(' $n ')) return true;
    }
    return false;
  }

  for (final item in items) {
    final q = item.question.trim();
    if (q.isEmpty) {
      rejected.add('Empty question text — rejected.');
      continue;
    }
    if (!seenQuestions.add(_norm(q))) {
      rejected.add('Duplicate question "$q" — rejected.');
      continue;
    }
    if (item.options.length != 4) {
      rejected.add(
        '"$q" has ${item.options.length} options (need exactly 4) — rejected.',
      );
      continue;
    }
    if (item.options.any((o) => o.trim().isEmpty)) {
      rejected.add('"$q" has an empty option — rejected.');
      continue;
    }
    if (item.options.map(_norm).toSet().length != 4) {
      rejected.add('"$q" has duplicate options — rejected.');
      continue;
    }
    if (item.answerIndex < 0 || item.answerIndex > 3) {
      rejected.add('"$q" has no valid answer index — rejected.');
      continue;
    }
    if (factPool.isNotEmpty && enforcePool) {
      final correct = _norm(item.options[item.answerIndex]);
      var ok = true;
      for (var i = 0; i < 4; i++) {
        if (i == item.answerIndex) continue;
        if (!isFromFacts(item.options[i])) {
          rejected.add(
            '"$q": distractor "${item.options[i]}" is not from the '
            'book\'s own facts — rejected.',
          );
          ok = false;
          break;
        }
      }
      if (!ok) continue;
      // The correct answer must itself be a pool value/subject, or a
      // word/phrase stated in a statement fact.
      if (!isFromFacts(item.options[item.answerIndex])) {
        rejected.add(
          '"$q": answer "$correct" is not from the book\'s own facts '
          '— rejected.',
        );
        continue;
      }
    }
    valid.add(item);
  }
  return ValidationResult(valid: valid, rejected: rejected);
}

/// Turns validated items into [Question]s. The part/page labels of
/// the chunk they came from are preserved, so question↔part mapping
/// survives the AI path (selection + test grouping keep working).
List<Question> questionsFromGenerated(
  List<GeneratedMcq> items, {
  required String sourceId,
  required String sourceLabel,
  Subject defaultSubject = Subject.gk,
  String part = '',
  int page = 0,
}) {
  return items
      .map(
        (g) => Question(
          text: g.question,
          options: g.options,
          correctIndex: g.answerIndex,
          subject: defaultSubject,
          sourceId: sourceId,
          sourceLabel: sourceLabel,
          explanation: g.explanation,
          page: page,
          part: part,
          answerSource: 'ai',
          // AI-inferred / generated answers are UNVERIFIED by
          // definition (governing spec: never present an unverified
          // answer as correct without review).
          answerVerified: false,
        ),
      )
      .toList();
}

/// Prompt for answer inference: questions with 4 options + an
/// explanation / note as evidence, no marked answer. The model picks
/// the correct option INDEX per question. Batched (≤ 20/call).
String buildInferencePrompt(List<PendingQuestion> pending) {
  final buf = StringBuffer(
    'For each question below, pick the correct option using ONLY the '
    'question, its options and the evidence line (an explanation or '
    'note from the same book). Never guess from outside knowledge: '
    'if the evidence does not point to any option, answer -1.\n'
    'Answer with JSON only: '
    '{"answers": [{"answer_index": 0}, {"answer_index": -1}, ...]} '
    'in the SAME order as the questions.\n\n',
  );
  for (var i = 0; i < pending.length; i++) {
    final p = pending[i];
    buf.writeln('Q${i + 1}: ${p.text}');
    for (var j = 0; j < p.options.length; j++) {
      buf.writeln('  ${String.fromCharCode(65 + j)}) ${p.options[j]}');
    }
    if (p.explanation.trim().isNotEmpty) {
      buf.writeln('  Evidence: ${p.explanation.trim()}');
    }
    buf.writeln();
  }
  return buf.toString();
}

/// Parses the inference reply: a list of answer indices, same order
/// as the questions. -1 = "evidence does not point to any option"
/// (the question stays answer-pending, never guessed).
List<int> parseInferenceJson(String raw, int expected) {
  final start = raw.indexOf('{');
  final end = raw.lastIndexOf('}');
  if (start < 0 || end <= start) {
    throw const FormatException('Gemini reply is not JSON.');
  }
  final decoded = jsonDecode(raw.substring(start, end + 1));
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Gemini reply is not a JSON object.');
  }
  final list = decoded['answers'] as List? ?? const [];
  if (list.length != expected) {
    throw FormatException(
      'Gemini returned ${list.length} answers for $expected questions.',
    );
  }
  return list.map((a) {
    if (a is Map<String, dynamic>) return a['answer_index'] as int? ?? -1;
    if (a is int) return a;
    return -1;
  }).toList();
}

/// Runs generation + inference against Gemini. One instance per
/// import — it calls Gemini ONCE per book (chunked), never per test.
class AiGenerationService {
  AiGenerationService({GeminiClient? client}) : _client = client ?? GeminiClient();

  final GeminiClient _client;

  /// Generates MCQs from [text] (prose notes, glossary, fact cards).
  /// [facts] is the parser's fact pool when the book has one
  /// (organisation file) — otherwise the pool is extracted from the
  /// text itself. Returns the validated questions + rejection reasons.
  Future<({List<Question> questions, List<String> rejected})>
  generateFromText({
    required String text,
    required String sourceId,
    required String sourceLabel,
    List<FactPair> facts = const [],
    Subject defaultSubject = Subject.gk,
    String part = '',
    int page = 0,
  }) async {
    final supplied = facts.isNotEmpty;
    final pool = supplied
        ? dedupeFacts(facts)
        : extractFactPool(text, part: part, page: page);
    // The fact-pool constraint is enforced ONLY when the pool
    // actually covers the text. Caller-supplied facts (organisation
    // cards) are authoritative and always enforced. An auto-extracted
    // pool of >= 3 facts, or one covering >= half the text's lines,
    // is enforced; a smaller pool (e.g. ONE stray-colon fact in a
    // long prose chunk — the Fixture A shape) is treated as prose:
    // no pool in the prompt, no pool constraint in validation. A
    // single stray fact must never veto the whole book.
    final lineCount =
        text.split('\n').where((l) => l.trim().isNotEmpty).length;
    final enforcePool =
        supplied || pool.length >= 3 || pool.length * 2 >= lineCount;
    final urdu = containsUrduScript(text);
    final chunks = chunkText(text);
    final questions = <Question>[];
    final rejected = <String>[];
    final seenQuestions = <String>{};
    for (final chunk in chunks) {
      final prompt = buildGenerationPrompt(
        chunk: chunk,
        facts: enforcePool ? pool : const [],
        urdu: urdu,
      );
      final raw = await _client.generateContent(
        prompt: prompt,
        maxOutputTokens: GeminiConfig.maxOutputTokensGeneration,
      );
      final parsed = parseGeneratedJson(raw);
      final validated = validateGenerated(
        parsed,
        factPool: pool,
        enforcePool: enforcePool,
      );
      rejected.addAll(validated.rejected);
      for (final q in questionsFromGenerated(
        validated.valid,
        sourceId: sourceId,
        sourceLabel: sourceLabel,
        defaultSubject: defaultSubject,
        part: part,
        page: page,
      )) {
        // Cross-chunk dedupe by normalised question text.
        if (seenQuestions.add(_norm(q.text))) questions.add(q);
      }
      if (questions.length >=
          GeminiConfig.maxQuestionsPerChunk * chunks.length) {
        break;
      }
    }
    return (questions: questions, rejected: rejected);
  }

  /// Infers answers for [pending] questions (4 options + evidence,
  /// no marked answer). Returns the questions that got a confident
  /// answer (as `answerSource: 'ai'`) and the ones still pending
  /// (evidence pointed nowhere — never guessed).
  Future<({List<Question> answered, List<PendingQuestion> stillPending})>
  inferAnswers({
    required List<PendingQuestion> pending,
    required String sourceId,
    required String sourceLabel,
  }) async {
    final answered = <Question>[];
    final stillPending = <PendingQuestion>[];
    const batchSize = 20;
    for (var i = 0; i < pending.length; i += batchSize) {
      final batch = pending.sublist(
        i,
        i + batchSize > pending.length ? pending.length : i + batchSize,
      );
      final prompt = buildInferencePrompt(batch);
      final raw = await _client.generateContent(
        prompt: prompt,
        maxOutputTokens: GeminiConfig.maxOutputTokensInference,
      );
      final indices = parseInferenceJson(raw, batch.length);
      for (var j = 0; j < batch.length; j++) {
        final idx = indices[j];
        final p = batch[j];
        if (idx < 0 || idx > 3) {
          stillPending.add(p);
          continue;
        }
        answered.add(
          Question(
            text: p.text,
            options: p.options,
            correctIndex: idx,
            subject: p.subject,
            sourceId: sourceId,
            sourceLabel: sourceLabel,
            explanation: p.explanation,
            page: p.page,
            part: p.part,
            answerSource: 'ai',
            answerVerified: false,
          ),
        );
      }
    }
    return (answered: answered, stillPending: stillPending);
  }
}
