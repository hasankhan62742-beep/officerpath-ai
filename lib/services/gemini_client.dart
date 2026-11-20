import 'dart:convert';

import 'package:http/http.dart' as http;

import 'gemini_config.dart';
import 'secure_key_store.dart';

/// Minimal Gemini `generateContent` client (v1.2, Option A).
///
/// * The key comes ONLY from [GeminiKeyStore] (secure storage) — it
///   is sent in the `x-goog-api-key` header, never in a URL, never
///   logged, and never sent to any host except
///   `generativelanguage.googleapis.com`.
/// * Redirects are refused (a redirect could carry the header to
///   another host): the client uses a plain `http.Client` with no
///   redirect-following POST — `http.post` follows redirects only for
///   GET/HEAD, and this call is a POST, so a 3xx is surfaced as an
///   error instead of being followed.
/// * Responses are JSON (`responseMimeType: application/json`) for
///   generation/inference, plain text for OCR transcription.
/// * [transport] is the test seam: tests inject a fake that returns
///   canned responses, so no test ever touches the network or a key.
///
/// Error mapping (see [GeminiFailureKind]): no key → prompt Settings;
/// no network → clear message; 429/quota → "free limit reached, try
/// tomorrow or use a paid key"; 404/401/403 → key/model problem.
class GeminiClient {
  GeminiClient({
    GeminiKeyStore? keyStore,
    http.Client? transport,
  }) : _keyStore = keyStore ?? GeminiKeyStore(),
       _transport = transport ?? http.Client();

  final GeminiKeyStore _keyStore;
  final http.Client _transport;

  /// One `generateContent` call. Returns the model's text (the first
  /// candidate's joined parts), or throws [GeminiException].
  Future<String> generateContent({
    required String prompt,
    required int maxOutputTokens,
    List<Map<String, dynamic>>? inlineImages,
  }) async {
    final key = await _keyStore.readKey();
    if (key == null) {
      throw const GeminiException(
        GeminiFailureKind.noKey,
        'Gemini key nahi hai. Settings mein apni free Gemini key '
        'daalein (Google AI Studio se free milti hai).',
      );
    }
    final parts = <Map<String, dynamic>>[
      {'text': prompt},
    ];
    if (inlineImages != null) parts.addAll(inlineImages);
    final body = jsonEncode({
      'contents': [
        {'parts': parts},
      ],
      'generationConfig': {
        'responseMimeType': 'application/json',
        'maxOutputTokens': maxOutputTokens,
        'temperature': GeminiConfig.temperature,
      },
    });
    http.Response resp;
    try {
      resp = await _transport
          .post(
            Uri.parse(GeminiConfig.endpoint),
            headers: {
              'Content-Type': 'application/json',
              'x-goog-api-key': key,
            },
            body: body,
          )
          .timeout(const Duration(seconds: 120));
    } on GeminiException {
      rethrow;
    } catch (_) {
      throw const GeminiException(
        GeminiFailureKind.noInternet,
        'Internet nahi mil raha. Connection check karein aur dobara '
        'koshish karein — key ya book ka data kahin save nahi hua.',
      );
    }
    return _textFromResponse(resp);
  }

  /// Same call, but the model answers in free text (OCR
  /// transcription), not JSON. Only the `responseMimeType` differs.
  Future<String> generateText({
    required String prompt,
    required int maxOutputTokens,
    required List<Map<String, dynamic>> inlineImages,
  }) async {
    final key = await _keyStore.readKey();
    if (key == null) {
      throw const GeminiException(
        GeminiFailureKind.noKey,
        'Gemini key nahi hai. Settings mein apni free Gemini key '
        'daalein (Google AI Studio se free milti hai).',
      );
    }
    final parts = <Map<String, dynamic>>[
      {'text': prompt},
      ...inlineImages,
    ];
    final body = jsonEncode({
      'contents': [
        {'parts': parts},
      ],
      'generationConfig': {
        'maxOutputTokens': maxOutputTokens,
        'temperature': 0.0,
      },
    });
    http.Response resp;
    try {
      resp = await _transport
          .post(
            Uri.parse(GeminiConfig.endpoint),
            headers: {
              'Content-Type': 'application/json',
              'x-goog-api-key': key,
            },
            body: body,
          )
          .timeout(const Duration(seconds: 120));
    } catch (_) {
      throw const GeminiException(
        GeminiFailureKind.noInternet,
        'Internet nahi mil raha. Connection check karein aur dobara '
        'koshish karein.',
      );
    }
    return _textFromResponse(resp);
  }

  String _textFromResponse(http.Response resp) {
    if (resp.statusCode == 200) {
      final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
      final candidates = decoded['candidates'] as List? ?? const [];
      if (candidates.isEmpty) {
        throw const GeminiException(
          GeminiFailureKind.badResponse,
          'Gemini ne koi jawab nahi diya (prompt block ho gaya ho '
          'sakta hai). Text thoda badal kar dobara koshish karein.',
        );
      }
      final content =
          (candidates.first as Map<String, dynamic>)['content']
              as Map<String, dynamic>?;
      final parts = content?['parts'] as List? ?? const [];
      final text = parts
          .whereType<Map<String, dynamic>>()
          .map((p) => p['text'] as String? ?? '')
          .join();
      if (text.trim().isEmpty) {
        throw const GeminiException(
          GeminiFailureKind.badResponse,
          'Gemini ne khaali jawab diya. Dobara koshish karein.',
        );
      }
      return text;
    }
    if (resp.statusCode == 429) {
      throw const GeminiException(
        GeminiFailureKind.quota,
        'Gemini ki free limit khatam ho gayi (429). Kal dobara '
        'koshish karein, ya AI Studio mein paid key use karein.',
      );
    }
    if (resp.statusCode == 404) {
      throw const GeminiException(
        GeminiFailureKind.badKeyOrModel,
        'Gemini model nahi mila (404) — model ka naam badal gaya ho '
        'sakta hai. App update check karein ya key dobara daalein.',
      );
    }
    if (resp.statusCode == 400 ||
        resp.statusCode == 401 ||
        resp.statusCode == 403) {
      throw GeminiException(
        GeminiFailureKind.badKeyOrModel,
        'Gemini key ghalat ya band hai (${resp.statusCode}). Settings '
        'mein key dobara daalein — key AI Studio se free milti hai.',
      );
    }
    if (resp.statusCode >= 300 && resp.statusCode < 400) {
      throw const GeminiException(
        GeminiFailureKind.unknown,
        'Gemini ne redirect diya — request roki gayi (key kahin aur '
        'nahi bheji gayi). Dobara koshish karein.',
      );
    }
    throw GeminiException(
      GeminiFailureKind.unknown,
      'Gemini se error aaya (HTTP ${resp.statusCode}). Thodi der baad '
      'dobara koshish karein.',
    );
  }
}

/// Builds the `inlineData` part for one JPEG page image sent to
/// Gemini vision. The image must already be rendered at
/// [GeminiConfig.visionImageWidth] wide — never a 4K render.
Map<String, dynamic> geminiImagePart(List<int> jpegBytes) => {
  'inlineData': {
    'mimeType': 'image/jpeg',
    'data': base64Encode(jpegBytes),
  },
};
