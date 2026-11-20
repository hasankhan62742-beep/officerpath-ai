import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:officerpath_ai/models/exam.dart';
import 'package:officerpath_ai/models/question.dart';
import 'package:officerpath_ai/services/ai_generation.dart';
import 'package:officerpath_ai/services/ai_usage_caps.dart';
import 'package:officerpath_ai/services/gemini_client.dart';
import 'package:officerpath_ai/services/gemini_config.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';
import 'package:officerpath_ai/services/secure_key_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// v1.2 AI generation + inference tests. Every Gemini call here is
/// MOCKED (a fake http transport returning canned JSON) — the test
/// proves the app-side contract (prompt, validation, dedupe, error
/// mapping, caps, secure key storage), NOT the live model. Live runs
/// are recorded separately (see AUDIT_REPORT.md § v1.2): the
/// coordinator's live runs on the verified subsets returned 4/4
/// (Urdu), 8/8 (Largest/Longest) and 9/9 (Study-of) valid questions.
/// Full-text live runs (19 Nov 2026, /tmp/live_fixtures.py, app's own
/// prompt + validation): fixture A Urdu 4/4 valid (FIXED in v1.2.0 —
/// before the fix the 1-fact pool vetoed everything, 0/1 valid; see
/// test/paste_fixtures_test.dart), fixture B Largest/Longest 30/30
/// valid, fixture C Study-of 26/26 valid.
void main() {
  const studyOfText = '''Mostly asked Questions in Papers (Share with friends)
Study of Blood : Haemotology
Study of Liver : Hepatology
Study of Kidney : Nephrology
Study of Fungi : Mycology
Study of Birds : Ornithology
Study of Dogs : Cynology
Study of Teeth : Odontology
Study of Universe : Cosmology
Study of Universe : Cosmology
For Preparation, Join Sir Tauqeer Classes
Study of Eyes : Opthalmology''';

  /// A canned generation reply: 9 good questions (one per unique
  /// fact, distractors from the pool, as-is spellings) + 1 duplicate
  /// + 1 with an invented distractor ("Zoology" is not in the book).
  String studyOfReply() {
    final facts = [
      ('Blood', 'Haemotology'),
      ('Liver', 'Hepatology'),
      ('Kidney', 'Nephrology'),
      ('Fungi', 'Mycology'),
      ('Birds', 'Ornithology'),
      ('Dogs', 'Cynology'),
      ('Teeth', 'Odontology'),
      ('Universe', 'Cosmology'),
      ('Eyes', 'Opthalmology'),
    ];
    final qs = <Map<String, dynamic>>[];
    for (var i = 0; i < facts.length; i++) {
      final others = [
        for (var j = 0; j < facts.length; j++)
          if (j != i) facts[j].$2,
      ];
      qs.add({
        'question': 'Study of ${facts[i].$1} is called?',
        'options': [facts[i].$2, ...others.take(3)],
        'answer_index': 0,
        'explanation': 'According to the text, Study of ${facts[i].$1} '
            'is ${facts[i].$2}.',
      });
    }
    qs.add(qs.first); // duplicate question text
    qs.add({
      'question': 'Study of Animals is called?',
      'options': ['Zoology', 'Haemotology', 'Hepatology', 'Nephrology'],
      'answer_index': 0,
      'explanation': 'Invented — not in the book.',
    });
    return jsonEncode({'questions': qs});
  }

  http.Client mockTransport(String replyBody, [int status = 200]) {
    // The reply is wrapped the way Gemini wraps it: the model's JSON
    // text sits inside candidates[0].content.parts[0].text.
    final envelope = jsonEncode({
      'candidates': [
        {
          'content': {
            'parts': [
              {'text': replyBody},
            ],
          },
        },
      ],
    });
    return MockClient((request) async {
      // The key must travel ONLY in the header, never in the URL.
      expect(request.url.toString(), isNot(contains('test-key')));
      expect(request.headers['x-goog-api-key'], 'test-key');
      // Response.bytes + UTF-8: the plain Response() constructor
      // encodes as Latin-1 and throws on non-Latin-1 text (em-dash,
      // Urdu script). Real Gemini replies arrive as UTF-8 bytes.
      return http.Response.bytes(
        utf8.encode(envelope),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
  }

  Future<GeminiClient> mockClient(String replyBody, [int status = 200]) async {
    final store = InMemorySecureStore();
    final keyStore = GeminiKeyStore(store);
    await keyStore.saveKey('test-key');
    return GeminiClient(
      keyStore: keyStore,
      transport: mockTransport(replyBody, status),
    );
  }

  group('Fact pool (app-side, before the call)', () {
    test('extractFactPool dedupes, drops noise, keeps as-is spellings',
        () {
      final pool = extractFactPool(studyOfText);
      expect(pool.length, 9, reason: 'duplicate Cosmology → one fact');
      expect(pool.any((f) => f.value == 'Haemotology'), isTrue);
      expect(pool.any((f) => f.value == 'Opthalmology'), isTrue);
      expect(pool.any((f) => f.label.contains('Tauqeer')), isFalse);
      expect(pool.any((f) => f.label.contains('Share')), isFalse);
    });

    test('dedupeFacts is by normalised "Label: Value"', () {
      final facts = dedupeFacts([
        const FactPair(label: 'Study of Universe', value: 'Cosmology'),
        const FactPair(label: 'Study of Universe', value: 'Cosmology'),
        const FactPair(label: 'Study of Universe', value: 'cosmology'),
      ]);
      expect(facts.length, 1);
    });

    test('chunkText never cuts a paragraph and respects the cap', () {
      final text = List.generate(50, (i) => 'Fact $i: Value $i.').join(
        '\n\n',
      );
      final chunks = chunkText(text, 200);
      expect(chunks.length, greaterThan(1));
      for (final c in chunks) {
        expect(c.length, lessThanOrEqualTo(200));
      }
      expect(chunks.join('\n\n'), contains('Fact 49'));
    });
  });

  group('Language match', () {
    test('Urdu-script input is detected; Roman input is not', () {
      expect(
        containsUrduScript('رسول اللہ ﷺ کے اونٹنی کا نام قصواء تھا'),
        isTrue,
      );
      expect(containsUrduScript('Largest Ocean: Pacific'), isFalse);
      expect(
        containsUrduScript('Pehle ek misunderstanding door kar lete hain'),
        isFalse,
      );
    });

    test('Urdu prompt forces Urdu-script output + honorifics', () {
      final prompt = buildGenerationPrompt(
        chunk: 'رسول اللہ ﷺ کے اونٹنی کا نام قصواء تھا',
        facts: const [],
        urdu: true,
      );
      expect(prompt, contains('URDU SCRIPT'));
      expect(prompt, contains('ﷺ'));
      // The prompt must FORBID transliteration, not ask for it.
      expect(prompt, contains('Do NOT transliterate into Roman Urdu'));
    });
  });

  group('Validation (before saving)', () {
    test('validates the Study-of reply: 9 valid, 2 rejected', () {
      final parsed = parseGeneratedJson(studyOfReply());
      final pool = extractFactPool(studyOfText);
      final result = validateGenerated(parsed, factPool: pool);
      expect(result.valid.length, 9);
      expect(result.rejected.length, 2);
      expect(
        result.rejected.any((r) => r.contains('Duplicate')),
        isTrue,
      );
      expect(
        result.rejected.any((r) => r.contains('not from the')),
        isTrue,
      );
      // As-is spellings survive validation.
      expect(
        result.valid.expand((q) => q.options).contains('Haemotology'),
        isTrue,
      );
      expect(
        result.valid.expand((q) => q.options).contains('Hematology'),
        isFalse,
      );
    });

    test('rejects wrong option counts, empty options, bad answers',
        () {
      final result = validateGenerated([
        const GeneratedMcq(
          question: 'Too few',
          options: ['A', 'B', 'C'],
          answerIndex: 0,
        ),
        const GeneratedMcq(
          question: 'Bad index',
          options: ['A', 'B', 'C', 'D'],
          answerIndex: 7,
        ),
        const GeneratedMcq(
          question: 'Dup options',
          options: ['A', 'A', 'C', 'D'],
          answerIndex: 0,
        ),
        const GeneratedMcq(
          question: 'Good one',
          options: ['A', 'B', 'C', 'D'],
          answerIndex: 2,
        ),
      ]);
      expect(result.valid.length, 1);
      expect(result.valid.first.question, 'Good one');
      expect(result.rejected.length, 3);
    });

    test('questionsFromGenerated keeps part/page + answerSource ai',
        () {
      final qs = questionsFromGenerated(
        [
          const GeneratedMcq(
            question: 'Q?',
            options: ['A', 'B', 'C', 'D'],
            answerIndex: 1,
            explanation: 'E',
          ),
        ],
        sourceId: 's1',
        sourceLabel: 'Book',
        part: 'UNO',
        page: 3,
      );
      expect(qs.first.answerSource, 'ai');
      expect(qs.first.part, 'UNO');
      expect(qs.first.page, 3);
      expect(qs.first.correctIndex, 1);
    });
  });

  group('AiGenerationService (mocked Gemini)', () {
    test('generateFromText: Study-of subset → 9 questions, cached shape',
        () async {
      final client = await mockClient(studyOfReply());
      final service = AiGenerationService(client: client);
      final result = await service.generateFromText(
        text: studyOfText,
        sourceId: 'study-of',
        sourceLabel: 'Study of X',
      );
      expect(result.questions.length, 9);
      expect(result.rejected.length, 2);
      expect(
        result.questions.every((q) => q.answerSource == 'ai'),
        isTrue,
      );
    });

    test('generateFromText: Urdu subset keeps Urdu script + ﷺ',
        () async {
      const urduText = '''رسول اللہ ﷺ کے اونٹنی کا نام قصواء تھا
تلواروں میں سب سے مشہور ذوالفقار تھی
آخری حج 10 ہجری میں ادا کیا
وفات 12 ربیع الاول 11 ہجری''';
      final reply = jsonEncode({
        'questions': [
          {
            'question': 'رسول اللہ ﷺ کے اونٹنی کا نام کیا تھا؟',
            'options': ['قصواء', 'ذوالفقار', '10 ہجری', '12 ربیع الاول'],
            'answer_index': 0,
            'explanation': 'متن کے مطابق اونٹنی کا نام قصواء تھا۔',
          },
        ],
      });
      final client = await mockClient(reply);
      final service = AiGenerationService(client: client);
      final result = await service.generateFromText(
        text: urduText,
        sourceId: 'urdu',
        sourceLabel: 'Urdu facts',
      );
      expect(result.questions.length, 1);
      expect(result.questions.first.text, contains('ﷺ'));
      expect(containsUrduScript(result.questions.first.text), isTrue);
    });

    test('inferAnswers: confident answer saved, -1 stays pending',
        () async {
      final reply = jsonEncode({
        'answers': [
          {'answer_index': 2},
          {'answer_index': -1},
        ],
      });
      final client = await mockClient(reply);
      final service = AiGenerationService(client: client);
      final pending = [
        PendingQuestion(
          text: 'What was the death toll?',
          options: ['5', '9', '12', '15'],
          subject: Subject.currentAffairs,
          explanation:
              'At least eight people were confirmed dead, with dozens more reported missing.',
        ),
        PendingQuestion(
          text: 'Unknown one?',
          options: ['A', 'B', 'C', 'D'],
          subject: Subject.gk,
          explanation: '',
        ),
      ];
      final result = await service.inferAnswers(
        pending: pending,
        sourceId: 'f2',
        sourceLabel: 'June 2025',
      );
      expect(result.answered.length, 1);
      expect(result.answered.first.correctIndex, 2);
      expect(result.answered.first.answerSource, 'ai');
      expect(result.stillPending.length, 1);
      expect(result.stillPending.first.text, 'Unknown one?');
    });
  });

  group('GeminiClient error mapping (mocked)', () {
    test('no key → noKey with a Settings next step', () async {
      final client = GeminiClient(
        keyStore: GeminiKeyStore(InMemorySecureStore()),
        transport: mockTransport('{}'),
      );
      try {
        await client.generateContent(
          prompt: 'x',
          maxOutputTokens: 10,
        );
        fail('must throw');
      } on GeminiException catch (e) {
        expect(e.kind, GeminiFailureKind.noKey);
        expect(e.message, contains('Settings'));
      }
    });

    test('429 → quota ("free limit reached")', () async {
      final client = await mockClient('{"error": "quota"}', 429);
      try {
        await client.generateContent(prompt: 'x', maxOutputTokens: 10);
        fail('must throw');
      } on GeminiException catch (e) {
        expect(e.kind, GeminiFailureKind.quota);
        expect(e.message, contains('free limit'));
      }
    });

    test('404 → badKeyOrModel (model retired)', () async {
      final client = await mockClient('{"error": "not found"}', 404);
      try {
        await client.generateContent(prompt: 'x', maxOutputTokens: 10);
        fail('must throw');
      } on GeminiException catch (e) {
        expect(e.kind, GeminiFailureKind.badKeyOrModel);
      }
    });

    test('model id is gemini-3.5-flash-lite (2.5 is 404 for new users)',
        () {
      expect(GeminiConfig.modelId, 'gemini-3.5-flash-lite');
      expect(GeminiConfig.endpoint, contains('gemini-3.5-flash-lite'));
    });
  });

  group('Secure key storage + daily caps', () {
    test('key round-trips in secure storage only', () async {
      SharedPreferences.setMockInitialValues({});
      final store = InMemorySecureStore();
      final keyStore = GeminiKeyStore(store);
      expect(await keyStore.hasKey(), isFalse);
      await keyStore.saveKey('AIza-test-key');
      expect(await keyStore.hasKey(), isTrue);
      expect(await keyStore.readKey(), 'AIza-test-key');
      await keyStore.deleteKey();
      expect(await keyStore.hasKey(), isFalse);
      // The key never touched SharedPreferences.
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getKeys().any((k) => k.toLowerCase().contains('gemini')),
        isFalse,
      );
    });

    test('daily caps: free 2/day, Premium 10/day', () async {
      SharedPreferences.setMockInitialValues({});
      final caps = AiUsageCaps();
      expect(await caps.booksRemainingToday(isPremium: false), 2);
      expect(await caps.booksRemainingToday(isPremium: true), 10);
      await caps.recordAiBookRun();
      await caps.recordAiBookRun();
      expect(await caps.canRunAiBook(isPremium: false), isFalse);
      expect(await caps.canRunAiBook(isPremium: true), isTrue);
    });
  });
}
