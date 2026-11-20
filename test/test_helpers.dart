import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Skips the current test when a real-book fixture is absent.
///
/// The real sample books live OUTSIDE the repo (copyrighted books /
/// private files) at /home/hatch/workspace/user/files/ on the dev VM
/// and are never present in CI. A test that needs one calls this
/// BEFORE reading it:
///
///   final file = File('/home/hatch/workspace/user/files/Foo.pdf');
///   if (skipIfFixtureMissing(file.path)) return;
///   final bytes = await file.readAsBytes();
///
/// Returns true when the test was skipped. The caller MUST `return`
/// immediately — [markTestSkipped] only marks the test, it does NOT
/// stop execution (proven by test/regression/regression_test.dart,
/// which skipped and then still threw on the next line).
bool skipIfFixtureMissing(String path) {
  if (!File(path).existsSync()) {
    markTestSkipped('fixture absent in this environment: $path');
    return true;
  }
  return false;
}
