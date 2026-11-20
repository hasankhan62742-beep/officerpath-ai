import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

import '../data/sample_bank.dart';
import '../models/question.dart';

/// Offline-first local storage (sqflite + SharedPreferences).
///
/// Tables:
/// * sources   — books / past papers the user added (built-ins seeded too)
/// * questions — every MCQ, linked to a source
/// * attempts  — finished test results for History + progress chart
///
/// No account, no backend, no network in v1. Everything survives a
/// restart because it lives in the app database on the device.
class StorageService {
  StorageService._();
  static final StorageService instance = StorageService._();

  static const _dbName = 'officerpath.db';
  // v2 (v1.2): questions gain page / part (structure + page-range
  // selection) and answer_source / bold_options (answer-signal
  // transparency). onUpgrade adds them to v1 installs; no data loss.
  // v3 (1.2): the attempts table gains `book_title` — the book the
  // test was drawn from — so history folders are truly per-book.
  // v4 (2.0.1): questions gain answer_verified / confidence /
  // mark_provenance / original_correct_index (verification tracking,
  // added to Question.toMap in v1.3 but NEVER added to this schema —
  // every save of a parsed question crashed on device with
  // "table questions has no column named answer_verified", found by
  // the owner's phone test 20 Nov 2026). onUpgrade adds them to
  // existing installs; no data loss.
  static const _dbVersion = 4;
  static const _seedFlag = 'sample_bank_seeded_v1';

  Database? _db;

  /// Creates the full current schema. Extracted from the [openDatabase]
  /// onCreate callback so tests can drive the real schema on a real
  /// (ffi) database — see test/storage_schema_test.dart. Keep this and
  /// [upgradeSchema] in sync: every column here must also be added by
  /// [upgradeSchema] for older versions.
  @visibleForTesting
  static Future<void> createSchema(Database db, int version) async {
    await db.execute('''
          CREATE TABLE sources(
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            kind TEXT NOT NULL,
            question_count INTEGER NOT NULL DEFAULT 0,
            added_at TEXT NOT NULL,
            is_built_in INTEGER NOT NULL DEFAULT 0
          )
        ''');
    await db.execute('''
          CREATE TABLE questions(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            text TEXT NOT NULL,
            option_a TEXT NOT NULL,
            option_b TEXT NOT NULL,
            option_c TEXT NOT NULL,
            option_d TEXT NOT NULL,
            correct_index INTEGER NOT NULL,
            subject TEXT NOT NULL,
            source_id TEXT NOT NULL,
            source_label TEXT NOT NULL,
            explanation TEXT NOT NULL DEFAULT '',
            page INTEGER NOT NULL DEFAULT 0,
            part TEXT NOT NULL DEFAULT '',
            answer_source TEXT NOT NULL DEFAULT '',
            answer_verified INTEGER NOT NULL DEFAULT 0,
            confidence REAL NOT NULL DEFAULT 0,
            mark_provenance TEXT NOT NULL DEFAULT '',
            original_correct_index INTEGER,
            bold_options TEXT NOT NULL DEFAULT ''
          )
        ''');
    await db.execute(
      'CREATE INDEX idx_questions_source ON questions(source_id)',
    );
    await db.execute('''
          CREATE TABLE attempts(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            exam_id TEXT NOT NULL,
            exam_name TEXT NOT NULL,
            book_title TEXT NOT NULL DEFAULT '',
            total_questions INTEGER NOT NULL,
            correct INTEGER NOT NULL,
            wrong INTEGER NOT NULL,
            skipped INTEGER NOT NULL,
            score REAL NOT NULL,
            percent REAL NOT NULL,
            passed INTEGER NOT NULL,
            duration_seconds INTEGER NOT NULL,
            attempted_at TEXT NOT NULL,
            per_subject_json TEXT NOT NULL DEFAULT '{}',
            wrong_question_ids_json TEXT NOT NULL DEFAULT '[]'
          )
        ''');
  }

  /// Migrates an older database to the current schema. Extracted from
  /// the [openDatabase] onUpgrade callback so tests can drive the real
  /// upgrade path — see test/storage_schema_test.dart.
  @visibleForTesting
  static Future<void> upgradeSchema(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    // v1 → v2: add the page/part/signal columns to existing installs.
    // ADD COLUMN with a DEFAULT is safe on a populated table; the
    // old rows simply read back page 0 / part '' / source ''.
    // v2 → v3: add `book_title` to attempts (old rows read back '').
    // v3 → v4: add the verification-tracking columns to questions
    // (old rows read back unverified / 0 confidence, as fromMap
    // already derives for rows written before v1.3).
    if (oldVersion < 2) {
      await db.execute(
        'ALTER TABLE questions ADD COLUMN page INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute(
        "ALTER TABLE questions ADD COLUMN part TEXT NOT NULL DEFAULT ''",
      );
      await db.execute(
        "ALTER TABLE questions ADD COLUMN answer_source TEXT NOT NULL DEFAULT ''",
      );
      await db.execute(
        "ALTER TABLE questions ADD COLUMN bold_options TEXT NOT NULL DEFAULT ''",
      );
    }
    if (oldVersion < 3) {
      await db.execute(
        "ALTER TABLE attempts ADD COLUMN book_title TEXT NOT NULL DEFAULT ''",
      );
    }
    if (oldVersion < 4) {
      await db.execute(
        'ALTER TABLE questions ADD COLUMN answer_verified INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute(
        'ALTER TABLE questions ADD COLUMN confidence REAL NOT NULL DEFAULT 0',
      );
      await db.execute(
        "ALTER TABLE questions ADD COLUMN mark_provenance TEXT NOT NULL DEFAULT ''",
      );
      await db.execute(
        'ALTER TABLE questions ADD COLUMN original_correct_index INTEGER',
      );
    }
  }

  Future<Database> get _database async {
    if (_db != null) return _db!;
    final dir = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dir, _dbName),
      version: _dbVersion,
      onCreate: createSchema,
      onUpgrade: upgradeSchema,
    );
    return _db!;
  }

  /// Seeds the built-in sample bank once (84 explained MCQs).
  ///
  /// AUDIT C2/F7: the whole seed runs inside ONE transaction and the
  /// seed flag is set only after it commits. If the app is killed
  /// mid-seed (or the flag is ever cleared), the next launch sees the
  /// questions already present and skips — the bank can never double.
  /// [seedFailed] is true when seeding threw, so the UI can show a
  /// retry banner instead of the app dying before runApp().
  bool seedFailed = false;

  Future<void> ensureSeeded() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_seedFlag) == true) return;
    final db = await _database;
    try {
      // Already seeded by an interrupted earlier run? Skip, don't dup.
      final existing = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM questions WHERE source_id LIKE ?',
        ['sample-%'],
      );
      if (((existing.first['c'] as int?) ?? 0) > 0) {
        await prefs.setBool(_seedFlag, true);
        return;
      }
      await db.transaction((txn) async {
        for (final source in SampleBank.sources) {
          await txn.insert(
            'sources',
            source.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        final batch = txn.batch();
        for (final q in SampleBank.questions) {
          batch.insert('questions', q.toMap());
        }
        await batch.commit(noResult: true);
        // Refresh stored counts from the real rows.
        for (final source in SampleBank.sources) {
          final count = await txn.rawQuery(
            'SELECT COUNT(*) AS c FROM questions WHERE source_id = ?',
            [source.id],
          );
          final c = (count.first['c'] as int?) ?? 0;
          await txn.update(
            'sources',
            {'question_count': c},
            where: 'id = ?',
            whereArgs: [source.id],
          );
        }
      });
      await prefs.setBool(_seedFlag, true);
    } catch (_) {
      // Never crash startup: main() runs the app anyway and Home shows
      // a retry banner (see [seedFailed]).
      seedFailed = true;
      rethrow;
    }
  }

  Future<List<BookSource>> getSources() async {
    final db = await _database;
    final rows = await db.query('sources', orderBy: 'is_built_in DESC, title');
    return rows.map(BookSource.fromMap).toList();
  }

  Future<List<Question>> getQuestionsBySources(Set<String> sourceIds) async {
    if (sourceIds.isEmpty) return [];
    final db = await _database;
    final placeholders = List.filled(sourceIds.length, '?').join(',');
    final rows = await db.query(
      'questions',
      where: 'source_id IN ($placeholders)',
      whereArgs: sourceIds.toList(),
    );
    return rows.map(Question.fromMap).toList();
  }

  Future<List<Question>> getQuestionsByIds(List<int> ids) async {
    if (ids.isEmpty) return [];
    final db = await _database;
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await db.query(
      'questions',
      where: 'id IN ($placeholders)',
      whereArgs: ids,
    );
    return rows.map(Question.fromMap).toList();
  }

  Future<int> questionCountForSources(Set<String> sourceIds) async {
    if (sourceIds.isEmpty) return 0;
    final db = await _database;
    final placeholders = List.filled(sourceIds.length, '?').join(',');
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM questions WHERE source_id IN ($placeholders)',
      sourceIds.toList(),
    );
    return (rows.first['c'] as int?) ?? 0;
  }

  /// Detected parts of one saved book (v1.2 selection screen for
  /// already-saved books): distinct `part` values with their question
  /// counts and page spans, from the stored questions. Returns [] for
  /// a book saved before part tracking (all parts '').
  Future<List<({String title, int count, int startPage, int endPage})>>
  getPartsForSource(String sourceId) async {
    final db = await _database;
    final rows = await db.rawQuery(
      'SELECT part, COUNT(*) AS c, MIN(page) AS mn, MAX(page) AS mx '
      'FROM questions WHERE source_id = ? AND part != \'\' '
      'GROUP BY part ORDER BY mn',
      [sourceId],
    );
    return rows
        .map(
          (r) => (
            title: r['part'] as String,
            count: (r['c'] as int?) ?? 0,
            startPage: (r['mn'] as int?) ?? 0,
            endPage: (r['mx'] as int?) ?? 0,
          ),
        )
        .toList();
  }

  /// Highest stored page number for a source (0 when unknown) — the
  /// page-range picker's upper bound for a saved book.
  Future<int> maxPageForSource(String sourceId) async {
    final db = await _database;
    final rows = await db.rawQuery(
      'SELECT MAX(page) AS mx FROM questions WHERE source_id = ?',
      [sourceId],
    );
    return (rows.first['mx'] as int?) ?? 0;
  }

  /// Saves a new source + its parsed questions. Returns questions saved.
  ///
  /// AUDIT F8: one transaction — old questions for this source are
  /// deleted first, so re-adding the same source replaces its questions
  /// instead of appending a second copy. The stored count comes from
  /// COUNT(*) after the insert, never from a stale value.
  Future<int> addSource(BookSource source, List<Question> questions) async {
    final db = await _database;
    await db.transaction((txn) async {
      await txn.delete(
        'questions',
        where: 'source_id = ?',
        whereArgs: [source.id],
      );
      await txn.insert(
        'sources',
        source.copyWithCount(questions.length).toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      final batch = txn.batch();
      for (final q in questions) {
        batch.insert('questions', q.toMap());
      }
      await batch.commit(noResult: true);
      final count = await txn.rawQuery(
        'SELECT COUNT(*) AS c FROM questions WHERE source_id = ?',
        [source.id],
      );
      final c = (count.first['c'] as int?) ?? 0;
      await txn.update(
        'sources',
        {'question_count': c},
        where: 'id = ?',
        whereArgs: [source.id],
      );
    });
    return questions.length;
  }

  Future<void> deleteSource(String sourceId) async {
    final db = await _database;
    // AUDIT F8: both deletes in one transaction — a crash between them
    // can no longer orphan questions.
    await db.transaction((txn) async {
      await txn.delete(
        'questions',
        where: 'source_id = ?',
        whereArgs: [sourceId],
      );
      await txn.delete('sources', where: 'id = ?', whereArgs: [sourceId]);
    });
  }

  Future<int> saveAttempt(AttemptRecord record) async {
    final db = await _database;
    return db.insert('attempts', record.toMap());
  }

  Future<List<AttemptRecord>> getAttempts({int limit = 100}) async {
    final db = await _database;
    final rows = await db.query(
      'attempts',
      orderBy: 'attempted_at DESC',
      limit: limit,
    );
    return rows.map(AttemptRecord.fromMap).toList();
  }

  Future<void> clearAttempts() async {
    final db = await _database;
    await db.delete('attempts');
  }

  Future<String?> getLastExamId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('last_exam_id');
  }

  Future<void> setLastExamId(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_exam_id', id);
  }
}

extension on BookSource {
  BookSource copyWithCount(int count) => BookSource(
    id: id,
    title: title,
    kind: kind,
    questionCount: count,
    addedAtIso: addedAtIso,
    isBuiltIn: isBuiltIn,
  );
}
