import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/models/exam.dart';
import 'package:officerpath_ai/models/question.dart';
import 'package:officerpath_ai/services/storage_service.dart';
import 'package:sqlite3/open.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The sqlite3 loader's default on Linux is `libsqlite3.so` (the
/// -dev symlink), which plain Ubuntu systems and this VM do not have —
/// only the runtime `libsqlite3.so.0`. Point the loader at it.
/// Runs inside the ffi worker isolate (hence top-level + passed as
/// ffiInit), with a fallback to the default name.
void _ffiInit() {
  open.overrideFor(OperatingSystem.linux, () {
    try {
      return DynamicLibrary.open('libsqlite3.so.0');
    } catch (_) {
      return DynamicLibrary.open('libsqlite3.so');
    }
  });
}

/// Regression test for the 20 Nov 2026 phone-test crash:
/// "File nahi parhi ja saki — DatabaseException(table questions has
/// no column named answer_verified (code 1 SQLITE_ERROR))".
///
/// Root cause: Question.toMap() (v1.3) writes answer_verified,
/// confidence, mark_provenance and original_correct_index, but the
/// questions table (StorageService, v3 schema) never gained those
/// columns — neither onCreate nor onUpgrade. Every save of a parsed
/// question crashed on a real device, while the automated suite passed
/// because no test ever round-tripped a Question through a real
/// database (see the "would need sqflite" note in cross_page_test).
///
/// These tests drive the REAL schema (StorageService.createSchema /
/// upgradeSchema) on a REAL database (sqflite_common_ffi), so this
/// drift can never slip through again.
void main() {
  late DatabaseFactory factory;

  setUpAll(() {
    sqfliteFfiInit();
    factory = createDatabaseFactoryFfi(ffiInit: _ffiInit);
  });

  Question sampleQuestion() => Question(
    text: 'What is the capital of Pakistan?',
    options: const ['Karachi', 'Lahore', 'Islamabad', 'Peshawar'],
    correctIndex: 2,
    subject: Subject.gk,
    sourceId: 'test-source',
    sourceLabel: 'Test Book',
    answerSource: 'asterisk',
    answerVerified: true,
    confidence: 0.9,
    markProvenance: 'asterisk',
    originalCorrectIndex: 2,
  );

  AttemptRecord sampleAttempt() => const AttemptRecord(
    examId: 'test-exam',
    examName: 'Test Exam',
    bookTitle: 'Test Book',
    totalQuestions: 10,
    correct: 7,
    wrong: 2,
    skipped: 1,
    score: 7.0,
    percent: 70.0,
    passed: true,
    durationSeconds: 600,
    attemptedAtIso: '2026-11-20T08:00:00',
  );

  const sampleSource = BookSource(
    id: 'test-source',
    title: 'Test Book',
    kind: 'book',
  );

  Future<Set<String>> tableColumns(Database db, String table) async {
    final info = await db.rawQuery('PRAGMA table_info($table)');
    return info.map((row) => row['name'] as String).toSet();
  }

  group('questions schema v4 (answer_verified crash)', () {
    test('fresh install: Question.toMap() round-trips through the real schema',
        () async {
      final dir = await Directory.systemTemp.createTemp(
        'officerpath_schema_fresh',
      );
      try {
        final db = await factory.openDatabase(
          '${dir.path}/fresh.db',
            options: OpenDatabaseOptions(
              version: 4,
              onCreate: StorageService.createSchema,
              onUpgrade: StorageService.upgradeSchema,
            ),
          );
        final q = sampleQuestion();
        final id = await db.insert('questions', q.toMap());
        final rows = await db.query(
          'questions',
          where: 'id = ?',
          whereArgs: [id],
        );
        expect(rows, hasLength(1));
        final back = Question.fromMap(rows.first);
        expect(back.text, q.text);
        expect(back.options, q.options);
        expect(back.correctIndex, q.correctIndex);
        expect(back.answerVerified, isTrue);
        expect(back.confidence, closeTo(0.9, 0.001));
        expect(back.markProvenance, 'asterisk');
        expect(back.originalCorrectIndex, 2);
        await db.close();
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test(
        'answerless Question (correctIndex -1) round-trips through the real schema',
        () async {
      // No-answers mode (20 Nov 2026): the -1 sentinel must survive
      // a real insert + read — it is the only thing that marks a
      // saved question as "no answer attached".
      final dir = await Directory.systemTemp.createTemp(
        'officerpath_schema_answerless',
      );
      try {
        final db = await factory.openDatabase(
          '${dir.path}/answerless.db',
          options: OpenDatabaseOptions(
            version: 4,
            onCreate: StorageService.createSchema,
            onUpgrade: StorageService.upgradeSchema,
          ),
        );
        final q = Question(
          text: 'What is the capital of Pakistan?',
          options: const ['Karachi', 'Lahore', 'Islamabad', 'Peshawar'],
          correctIndex: -1,
          subject: Subject.gk,
          sourceId: 'test-source',
          sourceLabel: 'Test Book',
          answerSource: '',
        );
        expect(q.hasAnswer, isFalse);
        final id = await db.insert('questions', q.toMap());
        final rows = await db.query(
          'questions',
          where: 'id = ?',
          whereArgs: [id],
        );
        expect(rows, hasLength(1));
        final back = Question.fromMap(rows.first);
        expect(back.correctIndex, -1);
        expect(back.hasAnswer, isFalse);
        expect(back.verificationStatus, 'no-answer');
        expect(back.text, q.text);
        await db.close();
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('schema parity: every toMap key exists as a table column', () async {
      final db = await factory.openDatabase(
        inMemoryDatabasePath,
          options: OpenDatabaseOptions(
            version: 4,
            onCreate: StorageService.createSchema,
            onUpgrade: StorageService.upgradeSchema,
          ),
        );
      final questionCols = await tableColumns(db, 'questions');
      for (final key in sampleQuestion().toMap().keys) {
        expect(
          questionCols,
          contains(key),
          reason:
              'questions table is missing column "$key" written by Question.toMap()',
        );
      }
      final attemptCols = await tableColumns(db, 'attempts');
      for (final key in sampleAttempt().toMap().keys) {
        expect(
          attemptCols,
          contains(key),
          reason:
              'attempts table is missing column "$key" written by AttemptRecord.toMap()',
        );
      }
      final sourceCols = await tableColumns(db, 'sources');
      for (final key in sampleSource.toMap().keys) {
        expect(
          sourceCols,
          contains(key),
          reason:
              'sources table is missing column "$key" written by BookSource.toMap()',
        );
      }
      await db.close();
    });

    test('upgrade v3 -> v4: legacy rows survive and new inserts work',
        () async {
      final dir = await Directory.systemTemp.createTemp(
        'officerpath_schema_v3',
      );
      try {
        final path = '${dir.path}/v3.db';
        // A v3 database, built with the exact pre-fix v3 schema.
        final v3 = await factory.openDatabase(
          path,
          options: OpenDatabaseOptions(
            version: 3,
            onCreate: (db, version) async {
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
                bold_options TEXT NOT NULL DEFAULT ''
              )
            ''');
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
            },
          ),
        );
        await v3.insert('questions', {
          'text': 'Legacy question',
          'option_a': 'A',
          'option_b': 'B',
          'option_c': 'C',
          'option_d': 'D',
          'correct_index': 0,
          'subject': 'General Knowledge',
          'source_id': 'legacy',
          'source_label': 'Legacy Book',
        });
        await v3.close();

        // Reopen as v4: onUpgrade must add the four columns.
        final db = await factory.openDatabase(
          path,
            options: OpenDatabaseOptions(
              version: 4,
              onCreate: StorageService.createSchema,
              onUpgrade: StorageService.upgradeSchema,
            ),
          );
        final legacy = await db.query(
          'questions',
          where: 'source_id = ?',
          whereArgs: ['legacy'],
        );
        expect(legacy, hasLength(1));
        final legacyQuestion = Question.fromMap(legacy.first);
        expect(legacyQuestion.text, 'Legacy question');
        expect(legacyQuestion.correctIndex, 0);

        // The exact insert that crashed on the owner's phone.
        final id = await db.insert('questions', sampleQuestion().toMap());
        expect(id, isNotNull);
        final saved = await db.query(
          'questions',
          where: 'id = ?',
          whereArgs: [id],
        );
        expect(Question.fromMap(saved.first).answerVerified, isTrue);
        await db.close();
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
