import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/screens/upload_screen.dart';
import 'package:officerpath_ai/services/pdf_import_service.dart';

/// v1.2 dead-end UX + image upload tests.
///
/// The "No MCQs found" dialog must never be a dead end: under the
/// governing spec (19 Nov 2026, AI generation PARKED) it offers
/// MANUAL CORRECTION (for questions found without answers),
/// plain-language diagnostics, and TXT/paste guidance — never AI.
/// The admission-letter case gets its own honest message, and its
/// text is never previewed (privacy) and never persisted.
void main() {
  test('isAdmissionLetterText spots a letter, not a question book', () {
    expect(
      isAdmissionLetterText(
        'PUNJAB PUBLIC SERVICE COMMISSION\n'
        'ADMISSION LETTER\n'
        'Roll No: 12345\n'
        'Candidate: Test Person\n'
        'Instructions: report at the test centre at 8:00 AM.\n'
        'Reporting time: 08:00.',
      ),
      isTrue,
    );
    expect(
      isAdmissionLetterText(
        'Q1. What is the capital of Pakistan?\n'
        'A) Lahore\nB) Karachi\nC) Islamabad\nD) Quetta\nAnswer: C',
      ),
      isFalse,
    );
    expect(isAdmissionLetterText(''), isFalse);
    // "Admission" alone (e.g. a university MCQ about admissions)
    // without a roll number / candidate marker is not a letter.
    expect(
      isAdmissionLetterText(
        'Q1. When was the admission policy announced?\n'
        'A) 2020\nB) 2021\nC) 2022\nD) 2023\nAnswer: B',
      ),
      isFalse,
    );
  });

  test('upload screen source: dead-end dialog offers manual correction '
      '+ diagnostics', () {
    final src = File('lib/screens/upload_screen.dart').readAsStringSync();
    // (a) Manual-correction button (AI generation is parked — never
    // offered as the fallback).
    expect(src, contains('Jawab khud lagayein'));
    expect(src.contains('AI se MCQs banayein'), isFalse);
    expect(src.contains('AI se jawab nikaalein'), isFalse);
    // (b) Plain-language diagnostics.
    expect(src, contains('Diagnostics:'));
    expect(src, contains('Pages parhe gaye:'));
    expect(src, contains('Answer Key:'));
    expect(src, contains('Jawab ke baghair questions:'));
    // (c) TXT / paste guidance.
    expect(src, contains('Try TXT / paste'));
    // Manual-correction offer.
    expect(src, contains('ManualCorrectionDialog'));
    // Admission-letter message (never a dead end either).
    expect(src, contains('admission letter'));
    expect(src, contains('is se test nahi ban sakta'));
    // The dialog never just says OK.
    expect(src, contains("Navigator.pop(context, 'manual')"));
  });

  test('upload screen source: docx + image extensions are allowed', () {
    final src = File('lib/screens/upload_screen.dart').readAsStringSync();
    expect(src, contains("'docx'"));
    expect(src, contains("'jpg'"));
    expect(src, contains("'png'"));
    expect(src, contains('importImage'));
    expect(src, contains('importDocx'));
  });

  test('image upload feeds the same OCR→parse pipeline', () async {
    final result = await PdfImportService.importImage(
      Uint8List.fromList([0xFF, 0xD8, 0xFF]),
      sourceId: 'img-1',
      sourceLabel: 'Page photo',
      onProgress: (_) {},
      isCancelled: () => false,
      runOcr: (jpegBytes) async =>
          'Q1. What is the capital of Pakistan?\n'
          'A) Lahore\nB) Karachi\nC) Islamabad\nD) Quetta\nAnswer: C\n',
    );
    expect(result.pageCount, 1);
    expect(result.ocrPages, [1]);
    expect(result.parsed, 1);
    expect(result.questions.first.text, contains('capital of Pakistan'));
    expect(result.questions.first.correctIndex, 2);
  });

  test('image upload with Urdu text prefers the Tesseract read', () async {
    final result = await PdfImportService.importImage(
      Uint8List.fromList([0xFF, 0xD8, 0xFF]),
      sourceId: 'img-2',
      sourceLabel: 'Urdu page photo',
      onProgress: (_) {},
      isCancelled: () => false,
      // ML Kit reads almost nothing (Latin-only on an Urdu page).
      runOcr: (jpegBytes) async => 'Q92',
      urduBook: true,
      // Tesseract eng+urd reads the Urdu question properly.
      runTesseract: (jpegBytes) async =>
          'Q92. فعل معروف کیا ہے؟\n'
          'A) ماضی\nB) حال\nC) مستقبل\nD) امر\nAnswer: A\n',
    );
    expect(result.parsed, 1);
    expect(result.questions.first.text, contains('فعل معروف'));
    expect(result.ocrMethods[1], contains('Tesseract'));
  });
}
