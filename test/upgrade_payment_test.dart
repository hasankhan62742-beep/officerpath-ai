import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:officerpath_ai/screens/upgrade_screen.dart';
import 'package:officerpath_ai/services/payment_proof_service.dart';
import 'package:officerpath_ai/services/secure_key_store.dart';
import 'package:officerpath_ai/services/subscription_service.dart';
import 'package:officerpath_ai/theme/app_theme.dart';
import 'package:officerpath_ai/widgets/developer_credit_footer.dart';
import 'package:officerpath_ai/widgets/upgrade_button.dart';

/// v1.2 — Upgrade button (red, top corner) + manual payment screen.
///
/// The Upgrade screen itself is pumpable (SharedPreferences mock for
/// the free-test counter + in-memory secure store for the premium
/// cache).
/// Home / My Books / History / Current Affairs / Setup need sqflite,
/// so they are covered by a source check (the shared button widget is
/// imported and placed in the AppBar) while the button itself is
/// rendered for real at 360x640 in both themes.

void _setSmallPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(360, 640);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _pumpUpgradeScreen(WidgetTester tester, {ThemeData? theme}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? AppTheme.light,
      darkTheme: AppTheme.dark,
      home: const UpgradeScreen(),
    ),
  );
  await tester.pumpAndSettle();
}

/// The Upgrade screen's vertical ListView scrollable — NOT the
/// activation-code TextField's horizontal "editable" Scrollable, which
/// is also a ListView descendant once it is built.
final Finder _listScrollable = find.byWidgetPredicate(
  (widget) =>
      widget is Scrollable && widget.axisDirection == AxisDirection.down,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SubscriptionService.instance.resetForTest();
    // Premium cache lives in secure storage — inject the in-memory
    // fake (see subscription_test.dart).
    SubscriptionService.instance.secureStoreOverride =
        InMemorySecureStore();
  });

  group('UpgradeAppBarButton', () {
    testWidgets('renders red UPGRADE at 360px, light mode, no overflow', (
      tester,
    ) async {
      _setSmallPhone(tester);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            appBar: AppBar(
              title: const Text('OfficerPath AI'),
              actions: const [UpgradeAppBarButton()],
            ),
            body: const Text('body'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('UPGRADE'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.descendant(
          of: find.byType(UpgradeAppBarButton),
          matching: find.byType(FilledButton),
        ),
      );
      expect(
        button.style?.backgroundColor?.resolve({}),
        const Color(0xFFC62828),
        reason: 'the user asked for a RED button',
      );
      expect(
        button.style?.foregroundColor?.resolve({}),
        Colors.white,
        reason: 'white text on red, readable in light and dark mode',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders at 360px in dark mode, no overflow', (tester) async {
      _setSmallPhone(tester);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            appBar: AppBar(
              title: const Text('Current Affairs — Rozana'),
              actions: const [UpgradeAppBarButton()],
            ),
            body: const Text('body'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('UPGRADE'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping UPGRADE opens the Premium screen', (tester) async {
      _setSmallPhone(tester);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            appBar: AppBar(actions: const [UpgradeAppBarButton()]),
            body: const Text('body'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('UPGRADE'));
      await tester.pumpAndSettle();
      expect(find.byType(UpgradeScreen), findsOneWidget);
      // Plans sit below the fold — scroll them into view.
      await tester.scrollUntilVisible(
        find.text('Choose a plan (PKR)'),
        500,
        scrollable: _listScrollable,
      );
      await tester.pumpAndSettle();
      expect(find.text('Choose a plan (PKR)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('UpgradeScreen — plans, free limit, payment', () {
    testWidgets('shows all three plans with correct prices + BEST VALUE', (
      tester,
    ) async {
      _setSmallPhone(tester);
      await _pumpUpgradeScreen(tester);
      // The ListView builds lazily — scroll each card into view and
      // assert it while it is built.
      await tester.scrollUntilVisible(
        find.text('Premium — 1 Month'),
        500,
        scrollable: _listScrollable,
      );
      await tester.pumpAndSettle();
      expect(find.text('Premium — 1 Month'), findsOneWidget);
      expect(find.text('Rs 600  •  Rs 600 / month'), findsOneWidget);
      expect(find.text('Pay manually • Rs 600'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Premium — 2 Months'),
        500,
        scrollable: _listScrollable,
      );
      await tester.pumpAndSettle();
      expect(find.text('Premium — 2 Months'), findsOneWidget);
      expect(find.text('Rs 1000  •  Rs 500 / month'), findsOneWidget);
      expect(find.text('Pay manually • Rs 1000'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Premium — 1 Year'),
        500,
        scrollable: _listScrollable,
      );
      await tester.pumpAndSettle();
      expect(find.text('Premium — 1 Year'), findsOneWidget);
      expect(find.text('Rs 5000  •  Rs 417 / month'), findsOneWidget);
      expect(find.text('Pay manually • Rs 5000'), findsOneWidget);
      expect(find.text('BEST VALUE'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('free-limit state reads the real count (0 used)', (
      tester,
    ) async {
      _setSmallPhone(tester);
      await _pumpUpgradeScreen(tester);
      expect(find.text('Free plan: 0 / 3 tests used this month — 3 left'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('free-limit state reads the real count (3 used)', (
      tester,
    ) async {
      _setSmallPhone(tester);
      // Drive the real counter — never a hard-coded label.
      final sub = SubscriptionService.instance;
      await sub.recordTestGenerated();
      await sub.recordTestGenerated();
      await sub.recordTestGenerated();
      expect(await sub.testsUsed(), 3);
      await _pumpUpgradeScreen(tester);
      expect(
        find.text('Free plan: 3 / 3 tests used this month — limit reached'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('payment details show the exact number and name', (
      tester,
    ) async {
      _setSmallPhone(tester);
      await _pumpUpgradeScreen(tester);
      await tester.scrollUntilVisible(
        find.text('Pay to — Easypaisa / JazzCash'),
        500,
        scrollable: _listScrollable,
      );
      await tester.pumpAndSettle();
      expect(find.text('Easypaisa'), findsOneWidget);
      expect(find.text('JazzCash'), findsOneWidget);
      // Each method shows its own number; exact name on both rows.
      expect(find.text('03427717288'), findsOneWidget);
      expect(find.text('03060853742'), findsOneWidget);
      expect(find.text('Muhammad Abdul Qadeer'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('manual-verification wording is present, no auto-pay claim', (
      tester,
    ) async {
      _setSmallPhone(tester);
      await _pumpUpgradeScreen(tester);
      await tester.scrollUntilVisible(
        find.text('Manual payment — verified by the owner'),
        500,
        scrollable: _listScrollable,
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('There is no automatic in-app payment'),
        findsWidgets,
      );
      expect(
        find.textContaining('Payment is verified manually by the owner'),
        findsWidgets,
      );
      expect(
        find.textContaining('Automatic card and Google Pay purchase'),
        findsOneWidget,
      );
      expect(find.textContaining('+92 342 7717288'), findsWidgets);
      // No "Pay now" / instant-activation promise anywhere on screen.
      expect(find.textContaining('Pay now'), findsNothing);
      expect(find.textContaining('instant activation'), findsNothing);
      // Plan buttons say "Pay manually" — scroll the last one into
      // view (the ListView builds lazily) and check its label.
      await tester.scrollUntilVisible(
        find.text('Pay manually • Rs 5000'),
        500,
        scrollable: _listScrollable,
      );
      await tester.pumpAndSettle();
      expect(find.text('Pay manually • Rs 5000'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('copy button copies the number and confirms it', (
      tester,
    ) async {
      _setSmallPhone(tester);
      // Widget tests have no real clipboard: without a mock handler
      // the Clipboard.setData platform call never resolves and the
      // SnackBar never appears (on a real phone it resolves at once).
      // Capture what the button copies.
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await _pumpUpgradeScreen(tester);
      await tester.scrollUntilVisible(
        find.byTooltip('Copy Easypaisa number'),
        500,
        scrollable: _listScrollable,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Copy Easypaisa number'));
      // Two frames, not pumpAndSettle: the Clipboard round-trip needs
      // a frame to resolve, and pumpAndSettle would run the SnackBar's
      // 4s timer out and dismiss it before the assertion.
      await tester.pump();
      await tester.pump();
      expect(copied, '03427717288');
      expect(find.text('Number copied'), findsOneWidget);
      // JazzCash row copies its own number too.
      await tester.tap(find.byTooltip('Copy JazzCash number'));
      await tester.pump();
      await tester.pump();
      expect(copied, '03060853742');
      expect(find.text('Number copied'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('activation code entry + footer still present at 360px', (
      tester,
    ) async {
      _setSmallPhone(tester);
      await _pumpUpgradeScreen(tester);
      await tester.scrollUntilVisible(
        find.text('I have an activation code'),
        500,
        scrollable: _listScrollable,
      );
      await tester.pumpAndSettle();
      expect(find.text('Redeem'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byType(DeveloperCreditFooter),
        500,
        scrollable: _listScrollable,
      );
      await tester.pumpAndSettle();
      expect(find.byType(DeveloperCreditFooter), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('dark mode: no overflow across the whole screen', (
      tester,
    ) async {
      _setSmallPhone(tester);
      await _pumpUpgradeScreen(tester, theme: AppTheme.dark);
      // Assert the payment rows while they are built — scrolling to
      // the footer drops them from the lazy ListView.
      await tester.scrollUntilVisible(
        find.text('Pay to — Easypaisa / JazzCash'),
        500,
        scrollable: _listScrollable,
      );
      await tester.pumpAndSettle();
      expect(find.text('03427717288'), findsOneWidget);
      expect(find.text('03060853742'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byType(DeveloperCreditFooter),
        500,
        scrollable: _listScrollable,
      );
      await tester.pumpAndSettle();
      expect(find.byType(DeveloperCreditFooter), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Upgrade button wiring (source check for sqflite screens)', () {
    test('red UPGRADE button is in every main screen AppBar', () {
      const screens = {
        'home_screen': 'Home',
        'upload_screen': 'My Books',
        'history_screen': 'History',
        'current_affairs_screen': 'Current Affairs',
        'setup_screen': 'test setup',
      };
      for (final entry in screens.entries) {
        final source = File('lib/screens/${entry.key}.dart').readAsStringSync();
        expect(
          source,
          contains('UpgradeAppBarButton'),
          reason: '${entry.value} AppBar must carry the red UPGRADE button',
        );
        expect(
          source,
          contains('widgets/upgrade_button.dart'),
          reason: '${entry.key}.dart must import the shared button',
        );
      }
    });

    test('Upgrade screen source: exact payment details, no Pay now', () {
      final source = File('lib/screens/upgrade_screen.dart').readAsStringSync();
      expect(source, contains("kEasypaisaNumber = '03427717288'"));
      expect(source, contains("kJazzCashNumber = '03060853742'"));
      expect(source, contains("kPaymentName = 'Muhammad Abdul Qadeer'"));
      expect(source, contains('Number copied'));
      expect(source, contains('Clipboard.setData'));
      expect(source, contains('no automatic in-app payment'));
      expect(source, contains('Pay manually'));
      expect(source, isNot(contains('Pay now')));
      // Activation codes + footer untouched.
      expect(source, contains('OP2-XXXXXX'));
      expect(source, contains('DeveloperCreditFooter'));
    });
  });

  group('receiptWhatsAppUri (pure)', () {
    test('builds the wa.me link with plan, TID and email', () {
      final uri = receiptWhatsAppUri(
        plan: PremiumPlan.byId('premium_2months'),
        method: 'JazzCash',
        transactionId: '03060853742111',
        email: 'student@example.com',
      );
      expect(uri.scheme, 'https');
      expect(uri.host, 'wa.me');
      expect(uri.path, '/923427717288');
      final text = uri.queryParameters['text'] ?? '';
      expect(text, contains('2 Months'));
      expect(text, contains('JazzCash'));
      expect(text, contains('03060853742111'));
      expect(text, contains('student@example.com'));
    });

    test('empty TID falls back to the screenshot note, never blank', () {
      final uri = receiptWhatsAppUri(
        plan: PremiumPlan.byId('premium_1month'),
        method: 'Easypaisa',
        transactionId: '',
        email: null,
      );
      final text = uri.queryParameters['text'] ?? '';
      expect(text, contains('(screenshot attached)'));
      expect(text, contains('(not signed in)'));
    });
  });

  group('UpgradeScreen — receipt screenshot + WhatsApp', () {
    Future<void> pumpWithProofService(
      WidgetTester tester,
      PaymentProofService service,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          home: UpgradeScreen(paymentProofService: service),
        ),
      );
      await tester.pumpAndSettle();
    }

    PaymentProofService fakeProofService() => PaymentProofService(
      accountProvider: () => (id: 'user-1', email: 'student@example.com'),
      inserter:
          (row) async => {
            ...row,
            'id': 'pay-1',
            'created_at': '2026-11-19T10:00:00Z',
          },
      fetcher: (_) async => [],
      uploader:
          ({required userId, required fileName, required bytes}) async =>
              'user-1/receipt.jpg',
      isConfigured: () => true,
    );

    // A plain final (not a getter): getters cannot be declared inside
    // a group() callback — `Finder get tidField` never compiled.
    final Finder tidField = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == 'Transaction ID',
    );

    Future<void> scrollToStep2(WidgetTester tester) async {
      await tester.scrollUntilVisible(
        find.text('Step 2 — Submit your payment proof'),
        500,
        scrollable: _listScrollable,
      );
      await tester.pumpAndSettle();
    }

    testWidgets('attach button + required instruction are visible', (
      tester,
    ) async {
      _setSmallPhone(tester);
      await _pumpUpgradeScreen(tester);
      await scrollToStep2(tester);
      expect(
        find.text('Attach receipt screenshot (required)'),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'attach the receipt screenshot below AND send it on WhatsApp',
        ),
        findsOneWidget,
      );
      expect(find.text('Send receipt screenshot on WhatsApp'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('submit without a receipt shows the screenshot error', (
      tester,
    ) async {
      _setSmallPhone(tester);
      await pumpWithProofService(tester, fakeProofService());
      await scrollToStep2(tester);
      await tester.enterText(tidField, '1234567890');
      await tester.scrollUntilVisible(
        find.text('Submit proof'),
        500,
        scrollable: _listScrollable,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Submit proof'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Please attach your payment receipt screenshot'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('pick receipt, submit, WhatsApp next step is shown', (
      tester,
    ) async {
      _setSmallPhone(tester);
      // The fake picker carries the receipt bytes directly (no temp
      // file): async dart:io (Directory.createTemp) HANGS inside
      // widget tests on this VM — proven by a minimal repro
      // (usc_minimal_test.dart): plain Dart creates the temp dir in
      // 9ms, but the widget-test binding never delivers the async
      // completion, so the test stalls forever. The screen's
      // _receiptBytes() prefers f.bytes when present.
      FilePicker.platform = _FakeReceiptPicker(
        PlatformFile(
          name: 'receipt.jpg',
          bytes: Uint8List.fromList([1, 2, 3]),
          size: 3,
        ),
      );
      await pumpWithProofService(tester, fakeProofService());
      await scrollToStep2(tester);
      await tester.tap(find.text('Attach receipt screenshot (required)'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Receipt: receipt.jpg'), findsOneWidget);
      await tester.enterText(tidField, '1234567890');
      await tester.scrollUntilVisible(
        find.text('Submit proof'),
        500,
        scrollable: _listScrollable,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Submit proof'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          'send your payment receipt screenshot on WhatsApp',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Send receipt screenshot on WhatsApp'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });
}

/// Fake file picker for widget tests: returns one canned receipt file.
/// Extends (not implements) FilePicker so the platform-interface token
/// check passes.
class _FakeReceiptPicker extends FilePicker {
  _FakeReceiptPicker(this.file);

  final PlatformFile file;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async => FilePickerResult([file]);
}
