import 'package:shared_preferences/shared_preferences.dart';

import 'gemini_config.dart';

/// Per-user daily AI caps (v1.2 cost guardrail).
///
/// Free users: [GeminiConfig.freeDailyAiBooks] AI books/day.
/// Premium: [GeminiConfig.premiumDailyAiBooks]. Counted on-device in
/// SharedPreferences (a count, not a secret — the key itself never
/// lives here). The date rolls over at local midnight; yesterday's
/// count never blocks today.
///
/// "One AI book" = one generation or inference run over one book's
/// text. Cached questions cost nothing — re-opening a saved book
/// never counts again.
class AiUsageCaps {
  AiUsageCaps({SharedPreferences? prefs}) : _prefsOverride = prefs;

  final SharedPreferences? _prefsOverride;

  static String _todayKey() {
    final now = DateTime.now();
    return 'ai_books_${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  Future<SharedPreferences> get _prefs async =>
      _prefsOverride ?? await SharedPreferences.getInstance();

  Future<int> booksUsedToday() async {
    final prefs = await _prefs;
    return prefs.getInt(_todayKey()) ?? 0;
  }

  /// How many AI books the user may still run today.
  Future<int> booksRemainingToday({required bool isPremium}) async {
    final limit = isPremium
        ? GeminiConfig.premiumDailyAiBooks
        : GeminiConfig.freeDailyAiBooks;
    final used = await booksUsedToday();
    final remaining = limit - used;
    return remaining < 0 ? 0 : remaining;
  }

  Future<bool> canRunAiBook({required bool isPremium}) async =>
      (await booksRemainingToday(isPremium: isPremium)) > 0;

  /// Call AFTER a Gemini run starts (not before — a failed key check
  /// must not burn the day's allowance; a started run counts even if
  /// the model reply is unusable, otherwise retries are free).
  Future<void> recordAiBookRun() async {
    final prefs = await _prefs;
    final key = _todayKey();
    await prefs.setInt(key, (prefs.getInt(key) ?? 0) + 1);
  }
}
