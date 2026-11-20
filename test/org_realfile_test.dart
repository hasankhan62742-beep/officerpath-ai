import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/book_structure.dart';
import 'package:officerpath_ai/services/mcq_parser.dart';
import 'package:officerpath_ai/services/pdf_text_extractor.dart';

import 'test_helpers.dart';

/// Organisation file (real file, v1.2): an infographic fact-card
/// book — 50 pages, 180 label:value facts, ZERO MCQs (generation
/// only). Converted from tmp_org_probe_test.dart (deleted). The
/// numbers below are the v1.2 run's measured values.
void main() {
  test('organisation file: 180 facts, 0 MCQs, noise filtered', () async {
    final file = File(
      '/home/hatch/workspace/user/files/organization_Sir_Waleed_0300_1111938.pdf',
    );
    if (skipIfFixtureMissing(file.path)) return;
    final bytes = await file.readAsBytes();
    final pages = extractPdfPages(bytes);
    final totalChars = pages.fold<int>(0, (a, p) => a + p.text.length);
    expect(pages.length, 50);
    expect(totalChars, greaterThan(10000));

    final r = parseMcqsFromPages(
      [for (final p in pages) PageText(p.page, p.text)],
      sourceId: 'org',
      sourceLabel: 'organization',
    );
    expect(r.parsed, 0, reason: 'fact cards only — no MCQs to parse');
    expect(r.facts.length, 180);
    expect(r.noiseLinesFiltered, 49);

    final byLabel = <String, String>{};
    for (final f in r.facts) {
      byLabel.putIfAbsent('${f.part}|${f.label}', () => f.value);
    }
    // UNO card (page 2), spellings exactly as printed.
    expect(
      byLabel['UNITED NATIONS ORGANIZATION (UNO)|ESTABLISHED'],
      'OCTOBER 24. 1945',
    );
    expect(
      byLabel['UNITED NATIONS ORGANIZATION (UNO)|MEMBER'],
      '193',
    );
    expect(
      byLabel['UNITED NATIONS ORGANIZATION (UNO)|HEADQUARTER'],
      'NEW YORK (US)',
    );
    expect(
      byLabel['UNITED NATIONS ORGANIZATION (UNO)|GENERAL SECRATARY'],
      'ANTANIO GUTERRES (PURTEEGAL)',
    );
    // FAO card (page 3).
    expect(
      byLabel['FOOD AND AGRICULTURE ORGANIZATION (FAO)|MEMBER'],
      '194',
    );
    expect(
      byLabel['FOOD AND AGRICULTURE ORGANIZATION (FAO)|HEADQUARTER'],
      'ROME, ITALY',
    );
    // Every fact belongs to a card (part), on a real page.
    expect(r.facts.every((f) => f.part.isNotEmpty), isTrue);
    expect(r.facts.every((f) => f.page >= 1 && f.page <= 50), isTrue);
  });
}
