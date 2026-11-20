import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:officerpath_ai/services/ai_generation.dart';
import 'package:officerpath_ai/services/gemini_client.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';
import 'package:officerpath_ai/services/secure_key_store.dart';

/// v1.2 paste-text fixtures — the FULL texts the user pasted, not the
/// short subsets in ai_generation_test.dart.
///
/// LIVE RUN (19 Nov 2026, gemini-3.5-flash-lite, app's own prompt,
/// validated with the app's own rules — see /tmp/live_fixtures.py):
///   A Urdu (16 lines): pool=16, model returned 4 questions, 4 valid
///     (FIXED in v1.2.0 — before the fix the pool was 1 and 0 were
///     valid; see the "degenerate pool" history in AUDIT_REPORT.md).
///   B Largest/Longest (33 items): pool=33, returned 30, 30 valid.
///   C Study-of (28 lines): pool=27, returned 26, 26 valid.
///
/// Fixture A fix (v1.2.0, lib change): dash/bullet statement lines
/// are now extracted as facts ([FactPair.isStatement]) without
/// requiring a colon, validation accepts an option stated verbatim
/// inside a statement fact, and the pool constraint is only enforced
/// when the pool actually covers the text (>= 3 facts, or >= half
/// the text's lines) — a single stray-colon fact no longer vetoes
/// the whole book.
void main() {
  const urduText = '''PROPHET MUHAMMAD ﷺ
— رسول اللہ ﷺ کے اونٹنی کا نام قصواء تھا۔
— رسول اللہ ﷺ کے خچر کا نام دُلدُل تھا۔
— رسول اللہ ﷺ کے گدھے کا نام یعفور تھا۔
— رسول اللہ ﷺ کے تلواروں میں سب سے مشہور ذوالفقار تھی۔
— رسول اللہ ﷺ کے موزوں کا رنگ سیاہ تھا۔
— رسول اللہ ﷺ کی انگوٹھی پر کندہ تھا: محمد رسول اللہ
— رسول اللہ ﷺ کے جھنڈے کا نام عُقاب تھا۔
— رسول اللہ ﷺ کے دو پیالوں کا نام شمبر اور عیان تھا۔
— رسول اللہ ﷺ کی دو تلواروں کا نام مخدمہ اور ذوالفقار تھی۔
— رسول اللہ ﷺ کے کمان کا نام کُتوم تھا۔
— رسول اللہ ﷺ کی چمچری کا نام مشتاق تھا۔
— رسول اللہ ﷺ کی ڈھال کا نام ذوالوق تھا۔
— رسول اللہ ﷺ کا بستر چمڑے اور کھجور کی چھال سے بنا تھا۔
— رسول اللہ ﷺ کا لباس سادہ اور عاجزی والا ہوتا تھا۔
— رسول اللہ ﷺ نے اپنا آخری حج 10 ہجری میں ادا کیا۔
— رسول اللہ ﷺ کی وفات 12 ربیع الاول 11 ہجری کو ہوئی۔''';

  // The user's list has 33 items (not 34 — counted line by line).
  const largestText = '''Largest Ocean: Pacific
Largest Desert(hot): Sahara
Largest Country by area: Russia
Largest Democracy: India
Largest Muslim Country by land area: Kazakhstan
Largest Island: Greenland
Largest Peninsula: Arab Peninsula
Largest Lake: Caspian Sea
Largest Freshwater Lake: Superior
Largest Artificial Lake: Volta Lake
Largest Sea: Philippine Sea
Largest Bay (by area): Bay of Bengal
Largest Delta: Ganges-Brahmaputra Delta
Largest Gulf: Gulf of Mexico
Largest River: Amazon
Largest Railway Station: Grand Central Terminal of New York
Largest Active Volcano: Mauna Loa
Largest Library: Congress Library
Largest Glacier: Lambert
Largest Land Mammal: African Elephant
Largest Sea Mammal: Blue Whale
Largest International Organization: United Nations Organization
Largest Bird: Ostrich
Largest Army of the World: People's Republic of China
Largest Joint: Knee
Largest Bone: Femur
Largest Forest: Taiga
Longest Mountain Range in earth: Andes
Longest Bridge: Danyang–Kunshan Grand Bridge
Longest Canal: The Grand Canal (China)
Longest River (Asia): Yangtze
Country with Longest Coastline: Canada
Longest Wall: Great Wall of China''';

  const studyOfText = '''Mostly asked Questions in Papers
(Share with friends)
Study of Blood : Haemotology
Study of Liver : Hepatology
Study of Kidney : Nephrology
Study of Fungi : Mycology
Study of Algae : Phycology
Study of Virus : Virology
Study of Cancer : Oncology
Study of Fruits : Pomology
Study of Birds : Ornithology
Study of Eggs : Oology
Study of Hair : Trichology
Study of Eyes : Opthalmology
Study of Soil : Pedology
Study of Universe : Cosmology
Study of Cell : Cytology
Study of Air : Aerology
Study of Earth : Geology
Study of Fish : Ichthyology
Study of Flags : Vexillology
Laxicography : Art of writing
Study of Skin : Dermotology
Study of Universe : Cosmology
Study of Stars : Astronomy
Study of Sun : Heliology
Study of Bees : Melittology
Study of Lakes : Limnology
For Preparation, Join Sir Tauqeer Classes
Study of Dogs : Cynology
Study of Teeth : Odontology''';

  http.Client mockTransport(String replyBody, [int status = 200]) {
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
      expect(request.url.toString(), isNot(contains('test-key')));
      expect(request.headers['x-goog-api-key'], 'test-key');
      return http.Response.bytes(
        utf8.encode(envelope),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
  }

  Future<GeminiClient> mockClient(String replyBody) async {
    final store = InMemorySecureStore();
    final keyStore = GeminiKeyStore(store);
    await keyStore.saveKey('test-key');
    return GeminiClient(
      keyStore: keyStore,
      transport: mockTransport(replyBody),
    );
  }

  /// Builds a mocked reply from [facts]: one forward question per
  /// fact (options = correct + 3 other values), optionally one
  /// reverse-direction question, plus a duplicate and an invented
  /// distractor that validation must reject.
  String replyFor(
    List<(String, String)> facts, {
    bool reverse = false,
    String? reverseQuestion,
    List<String>? reverseOptions,
  }) {
    final qs = <Map<String, dynamic>>[];
    for (var i = 0; i < facts.length; i++) {
      final others = [
        for (var j = 0; j < facts.length; j++)
          if (j != i) facts[j].$2,
      ];
      qs.add({
        'question': '${facts[i].$1} is called?',
        'options': [facts[i].$2, ...others.take(3)],
        'answer_index': 0,
        'explanation': 'From the text.',
      });
    }
    if (reverse && reverseQuestion != null && reverseOptions != null) {
      qs.add({
        'question': reverseQuestion,
        'options': reverseOptions,
        'answer_index': 0,
        'explanation': 'From the text (reverse direction).',
      });
    }
    qs.add(qs.first); // duplicate question text
    qs.add({
      'question': 'Invented one?',
      'options': ['Mount Everest', facts[0].$2, facts[1].$2, facts[2].$2],
      'answer_index': 0,
      'explanation': 'Invented — not in the text.',
    });
    return jsonEncode({'questions': qs});
  }

  group('Fixture A — Urdu facts (full 16 lines)', () {
    test('fact pool covers the list: 15 statement + 1 colon fact', () {
      final pool = extractFactPool(urduText);
      expect(pool.length, 16);
      // The ring line is still a colon fact (colon path first).
      final ring = pool.where((f) => f.value == 'محمد رسول اللہ');
      expect(ring.length, 1);
      expect(ring.first.label, contains('انگوٹھی'));
      expect(ring.first.isStatement, isFalse);
      // Every dash line is a statement fact — the whole line is the
      // fact, no colon required.
      final statements = pool.where((f) => f.isStatement);
      expect(statements.length, 15);
      expect(
        statements.any((f) => f.label.contains('قصواء')),
        isTrue,
      );
      expect(
        statements.any((f) => f.label.contains('10 ہجری')),
        isTrue,
      );
      // The header line ("PROPHET MUHAMMAD ﷺ") is not a fact.
      expect(pool.any((f) => f.label.contains('PROPHET')), isFalse);
    });

    test('statement facts never swallow MCQ options or questions', () {
      const tricky = '''— A) Something
— (B) Something else
— کیا یہ سوال ہے؟
— ایک لفظ
— رسول اللہ ﷺ کے اونٹنی کا نام قصواء تھا۔''';
      final pool = extractFactPool(tricky);
      expect(pool.length, 1);
      expect(pool.first.isStatement, isTrue);
      expect(pool.first.label, contains('قصواء'));
    });

    test('Urdu detected; prompt forces Urdu script + honorifics', () {
      expect(containsUrduScript(urduText), isTrue);
      final prompt = buildGenerationPrompt(
        chunk: urduText,
        facts: extractFactPool(urduText),
        urdu: true,
      );
      expect(prompt, contains('URDU SCRIPT'));
      expect(prompt, contains('ﷺ'));
      expect(prompt, contains('Do NOT transliterate into Roman Urdu'));
      // Statement facts render as "- <statement>", not "label: value".
      expect(prompt, contains('- رسول اللہ ﷺ کے اونٹنی کا نام قصواء تھا۔'));
      expect(prompt, contains('انگوٹھی پر کندہ تھا: محمد رسول اللہ'));
    });

    test('FIXED: full Urdu text generates 4 valid questions', () async {
      // The reply itself is fine: 4 proper Urdu MCQs, distractors
      // from the text's own facts, honorifics preserved.
      const reply = '''{"questions": [
        {"question": "رسول اللہ ﷺ کے اونٹنی کا نام کیا تھا؟",
         "options": ["قصواء", "دُلدُل", "یعفور", "ذوالفقار"],
         "answer_index": 0,
         "explanation": "متن کے مطابق اونٹنی کا نام قصواء تھا۔"},
        {"question": "رسول اللہ ﷺ کے خچر کا نام کیا تھا؟",
         "options": ["دُلدُل", "قصواء", "یعفور", "ذوالفقار"],
         "answer_index": 0,
         "explanation": "متن کے مطابق خچر کا نام دُلدُل تھا۔"},
        {"question": "رسول اللہ ﷺ نے اپنا آخری حج کب ادا کیا؟",
         "options": ["10 ہجری", "11 ہجری", "12 ربیع الاول", "قصواء"],
         "answer_index": 0,
         "explanation": "متن کے مطابق آخری حج 10 ہجری میں ادا کیا۔"},
        {"question": "رسول اللہ ﷺ کی وفات کب ہوئی؟",
         "options": ["12 ربیع الاول 11 ہجری", "10 ہجری", "ذوالفقار", "قصواء"],
         "answer_index": 0,
         "explanation": "متن کے مطابق وفات 12 ربیع الاول 11 ہجری کو ہوئی۔"}
      ]}''';
      expect(parseGeneratedJson(reply).length, 4);
      final client = await mockClient(reply);
      final service = AiGenerationService(client: client);
      final result = await service.generateFromText(
        text: urduText,
        sourceId: 'urdu-full',
        sourceLabel: 'Prophet Muhammad facts',
      );
      // Before the fix the 1-fact pool vetoed everything (0 valid).
      // Now the 16-fact pool covers the text and every distractor
      // ("قصواء", "10 ہجری" ...) is a word stated in the book.
      expect(result.questions.length, 4);
      expect(result.rejected, isEmpty);
      expect(
        result.questions.every((q) => q.answerSource == 'ai'),
        isTrue,
      );
    });

    test('validation still rejects an invented distractor', () {
      final pool = extractFactPool(urduText);
      final result = validateGenerated([
        const GeneratedMcq(
          question: 'رسول اللہ ﷺ کے اونٹنی کا نام کیا تھا؟',
          options: ['قصواء', 'دُلدُل', 'یعفور', 'نیل آرمسٹرانگ'],
          answerIndex: 0,
        ),
      ], factPool: pool);
      expect(result.valid, isEmpty);
      expect(result.rejected.length, 1);
      expect(result.rejected.first, contains('not from the'));
    });
  });

  group('Degenerate pool guard — one stray fact must not veto a book',
      () {
    test('1 colon fact in long prose: pool not enforced', () async {
      const prose = '''The Mughal Empire ruled India for centuries.
Its founder was Babur, who won the First Battle of Panipat.
Note: the empire declined after Aurangzeb.
The capital was Delhi for most of its history.
Akbar built Fatehpur Sikri as his capital.
The Red Fort was built by Shah Jahan.
The Taj Mahal was built in Agra.
The empire's official language was Persian.''';
      // Only "Note: ..." has a colon — and "note" is excluded, so
      // the pool is empty and generation falls back to prose.
      expect(extractFactPool(prose), isEmpty);
      const reply = '''{"questions": [
        {"question": "Who founded the Mughal Empire?",
         "options": ["Babur", "Akbar", "Shah Jahan", "Aurangzeb"],
         "answer_index": 0,
         "explanation": "From the text."}
      ]}''';
      final client = await mockClient(reply);
      final service = AiGenerationService(client: client);
      final result = await service.generateFromText(
        text: prose,
        sourceId: 'prose',
        sourceLabel: 'Mughal notes',
      );
      expect(result.questions.length, 1);
      expect(result.rejected, isEmpty);
    });

    test('validateGenerated with enforcePool false skips the pool check',
        () {
      final result = validateGenerated([
        const GeneratedMcq(
          question: 'Q?',
          options: ['A', 'B', 'C', 'D'],
          answerIndex: 0,
        ),
      ],
          factPool: const [
            FactPair(label: 'Only', value: 'Fact'),
          ],
          enforcePool: false);
      expect(result.valid.length, 1);
      final enforced = validateGenerated([
        const GeneratedMcq(
          question: 'Q?',
          options: ['A', 'B', 'C', 'D'],
          answerIndex: 0,
        ),
      ],
          factPool: const [
            FactPair(label: 'Only', value: 'Fact'),
          ],
          enforcePool: true);
      expect(enforced.valid, isEmpty);
    });
  });

  group('Fixture B — Largest/Longest (full list)', () {
    test('fact pool is the whole list: 33 items', () {
      final pool = extractFactPool(largestText);
      expect(pool.length, 33);
      expect(
        pool.any(
          (f) => f.label == 'Largest Ocean' && f.value == 'Pacific',
        ),
        isTrue,
      );
      expect(
        pool.any(
          (f) => f.label == 'Longest Wall' && f.value == 'Great Wall of China',
        ),
        isTrue,
      );
      expect(
        pool.any(
          (f) =>
              f.label == 'Largest Railway Station' &&
              f.value == 'Grand Central Terminal of New York',
        ),
        isTrue,
      );
    });

    test('mocked generation: 9 valid (8 forward + 1 reverse), 2 rejected',
        () async {
      final pool = extractFactPool(largestText);
      final facts = pool
          .take(8)
          .map((f) => (f.label, f.value))
          .toList();
      final reply = replyFor(
        facts,
        reverse: true,
        reverseQuestion: 'Pacific is the largest what?',
        reverseOptions: [
          'Largest Ocean',
          'Largest Sea',
          'Largest Lake',
          'Largest River',
        ],
      );
      final client = await mockClient(reply);
      final service = AiGenerationService(client: client);
      final result = await service.generateFromText(
        text: largestText,
        sourceId: 'largest-full',
        sourceLabel: 'Largest/Longest',
      );
      expect(result.questions.length, 9);
      expect(result.rejected.length, 2);
      expect(
        result.questions.any((q) => q.text == 'Pacific is the largest what?'),
        isTrue,
      );
      expect(
        result.questions.every((q) => q.answerSource == 'ai'),
        isTrue,
      );
    });
  });

  group('Fixture C — Study-of (full list)', () {
    test('fact pool: 27 unique, noise dropped, spellings as-is', () {
      final pool = extractFactPool(studyOfText);
      expect(pool.length, 27, reason: '28 lines minus 1 duplicate');
      expect(pool.any((f) => f.value == 'Haemotology'), isTrue);
      expect(pool.any((f) => f.value == 'Opthalmology'), isTrue);
      expect(
        pool.any(
          (f) => f.label == 'Laxicography' && f.value == 'Art of writing',
        ),
        isTrue,
      );
      expect(pool.any((f) => f.label.contains('Tauqeer')), isFalse);
      expect(pool.any((f) => f.label.contains('Share')), isFalse);
      expect(
        pool.where((f) => f.value == 'Cosmology').length,
        1,
        reason: 'Universe/Cosmology appears twice, one fact only',
      );
    });

    test('mocked generation: 10 valid (9 forward + 1 reverse), 2 rejected',
        () async {
      final pool = extractFactPool(studyOfText);
      final facts = pool
          .take(9)
          .map((f) => (f.label, f.value))
          .toList();
      final reply = replyFor(
        facts,
        reverse: true,
        reverseQuestion: 'Haemotology is the study of?',
        reverseOptions: ['Blood', 'Liver', 'Kidney', 'Fungi'],
      );
      final client = await mockClient(reply);
      final service = AiGenerationService(client: client);
      final result = await service.generateFromText(
        text: studyOfText,
        sourceId: 'studyof-full',
        sourceLabel: 'Study of X',
      );
      expect(result.questions.length, 10);
      expect(result.rejected.length, 2);
      expect(
        result.questions.any(
          (q) => q.text == 'Haemotology is the study of?',
        ),
        isTrue,
      );
      // As-is spellings survive into the saved questions.
      expect(
        result.questions.expand((q) => q.options).contains('Haemotology'),
        isTrue,
      );
      expect(
        result.questions.expand((q) => q.options).contains('Hematology'),
        isFalse,
      );
    });
  });
}
