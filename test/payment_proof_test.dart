import 'package:flutter_test/flutter_test.dart';
import 'package:officerpath_ai/services/payment_proof_service.dart';

void main() {
  group('validateTransactionId', () {
    test('accepts typical Easypaisa / JazzCash IDs', () {
      expect(
        PaymentProofService.validateTransactionId('034277172881234'),
        isNull,
      );
      expect(PaymentProofService.validateTransactionId('1234567890'), isNull);
      expect(
        PaymentProofService.validateTransactionId('TXN-2026-1188'),
        isNull,
      );
      expect(PaymentProofService.validateTransactionId('ABC 123 DEF'), isNull);
    });

    test('rejects empty and too-short IDs', () {
      expect(PaymentProofService.validateTransactionId(''), isNotNull);
      expect(PaymentProofService.validateTransactionId('   '), isNotNull);
      expect(PaymentProofService.validateTransactionId(null), isNotNull);
      expect(PaymentProofService.validateTransactionId('12345'), isNotNull);
    });

    test('rejects too-long IDs and illegal characters', () {
      expect(PaymentProofService.validateTransactionId('A' * 31), isNotNull);
      expect(PaymentProofService.validateTransactionId('ABC!123'), isNotNull);
      expect(
        PaymentProofService.validateTransactionId('TXN#123456'),
        isNotNull,
      );
      expect(
        PaymentProofService.validateTransactionId('id_with_underscore1'),
        isNotNull,
      );
    });

    test('6 and 30 chars are the exact boundaries', () {
      expect(PaymentProofService.validateTransactionId('123456'), isNull);
      expect(PaymentProofService.validateTransactionId('A' * 30), isNull);
    });
  });

  group('planLabel / planPrice mapping', () {
    test('all three plans map to the confirmed prices', () {
      expect(PaymentProofService.planPrice('premium_1month'), 600);
      expect(PaymentProofService.planPrice('premium_2months'), 1000);
      expect(PaymentProofService.planPrice('premium_1year'), 5000);
    });

    test('labels name the plan', () {
      expect(
        PaymentProofService.planLabel('premium_1month'),
        contains('1 Month'),
      );
      expect(
        PaymentProofService.planLabel('premium_2months'),
        contains('2 Months'),
      );
      expect(
        PaymentProofService.planLabel('premium_1year'),
        contains('1 Year'),
      );
    });

    test('unknown plan id has no price', () {
      expect(PaymentProofService.planPrice('premium_9months'), isNull);
      expect(PaymentProofService.planPrice(''), isNull);
    });
  });

  group('buildProofPayload (pure)', () {
    test('builds the exact payments row, always pending', () {
      final payload = PaymentProofService.buildProofPayload(
        userId: 'user-123',
        email: 'student@example.com',
        planId: 'premium_2months',
        method: 'JazzCash',
        transactionId: '  03060853742111 ',
        screenshotPath: 'user-123/1234567890_42.jpg',
      );
      expect(payload, {
        'user_id': 'user-123',
        'email': 'student@example.com',
        'plan': 'premium_2months',
        'method': 'JazzCash',
        'transaction_id': '03060853742111',
        'status': 'pending',
        'screenshot_path': 'user-123/1234567890_42.jpg',
      });
    });

    test('null email is kept as null (never a fake address)', () {
      final payload = PaymentProofService.buildProofPayload(
        userId: 'user-123',
        email: null,
        planId: 'premium_1month',
        method: 'Easypaisa',
        transactionId: '1234567890',
        screenshotPath: 'user-123/999.jpg',
      );
      expect(payload['email'], isNull);
      expect(payload['status'], 'pending');
      expect(payload['screenshot_path'], 'user-123/999.jpg');
    });
  });

  group('PaymentProof.fromJson + statusLabel', () {
    test('parses a server row and labels each status', () {
      final proof = PaymentProof.fromJson({
        'id': 'p1',
        'user_id': 'u1',
        'plan': 'premium_1year',
        'method': 'Easypaisa',
        'transaction_id': '1234567890',
        'status': 'pending',
        'email': 'student@example.com',
        'created_at': '2026-11-19T10:00:00.000Z',
      });
      expect(proof.plan, 'premium_1year');
      expect(proof.statusLabel, 'Pending');
      expect(proof.isPending, isTrue);
      expect(proof.createdAt, DateTime.parse('2026-11-19T10:00:00.000Z'));
      expect(
        PaymentProof.fromJson({
          'plan': 'premium_1month',
          'status': 'approved',
        }).statusLabel,
        'Approved',
      );
      expect(
        PaymentProof.fromJson({
          'plan': 'premium_1month',
          'status': 'rejected',
        }).statusLabel,
        'Rejected',
      );
    });
  });

  group('submitPaymentProof with fake gateway (no network)', () {
    test('valid proof inserts and returns the pending proof', () async {
      Map<String, dynamic>? inserted;
      final service = PaymentProofService(
        accountProvider: () => (id: 'user-1', email: 'student@example.com'),
        inserter: (row) async {
          inserted = row;
          return {...row, 'id': 'pay-1', 'created_at': '2026-11-19T10:00:00Z'};
        },
        uploader:
            ({required userId, required fileName, required bytes}) async =>
                'user-1/receipt.jpg',
        isConfigured: () => true,
      );
      final result = await service.submitPaymentProof(
        plan: 'premium_1month',
        method: 'JazzCash',
        transactionId: '1234567890',
        screenshotBytes: [1, 2, 3],
        screenshotName: 'receipt.jpg',
      );
      expect(result.ok, isTrue);
      expect(result.proof?.status, 'pending');
      expect(result.proof?.screenshotPath, 'user-1/receipt.jpg');
      expect(inserted?['user_id'], 'user-1');
      expect(inserted?['email'], 'student@example.com');
      expect(inserted?['status'], 'pending');
      expect(inserted?['screenshot_path'], 'user-1/receipt.jpg');
    });

    test('bad transaction ID never reaches the server', () async {
      var called = false;
      final service = PaymentProofService(
        accountProvider: () => (id: 'user-1', email: 'a@b.co'),
        inserter: (_) async {
          called = true;
          return {};
        },
        isConfigured: () => true,
      );
      final result = await service.submitPaymentProof(
        plan: 'premium_1month',
        method: 'JazzCash',
        transactionId: '12',
      );
      expect(result.ok, isFalse);
      expect(result.error, isNotNull);
      expect(called, isFalse);
    });

    test('signed-out user gets a sign-in error, not a crash', () async {
      final service = PaymentProofService(
        accountProvider: () => null,
        isConfigured: () => true,
      );
      final result = await service.submitPaymentProof(
        plan: 'premium_1month',
        method: 'JazzCash',
        transactionId: '1234567890',
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('sign in'));
    });

    test('hasPendingProof detects a pending proof for the plan', () async {
      final service = PaymentProofService(
        accountProvider: () => (id: 'user-1', email: 'a@b.co'),
        fetcher:
            (_) async => [
              {
                'plan': 'premium_2months',
                'method': 'JazzCash',
                'transaction_id': '1234567890',
                'status': 'pending',
              },
              {
                'plan': 'premium_1month',
                'method': 'Easypaisa',
                'transaction_id': '0987654321',
                'status': 'approved',
              },
            ],
        isConfigured: () => true,
      );
      expect(await service.hasPendingProof('premium_2months'), isTrue);
      expect(await service.hasPendingProof('premium_1month'), isFalse);
      expect(await service.hasPendingProof('premium_1year'), isFalse);
    });
  });
  group('submitPaymentProof duplicate transaction ID (UX check)', () {
    test('same TID as a pending proof is refused, insert never runs', () async {
      var called = false;
      final service = PaymentProofService(
        accountProvider: () => (id: 'user-1', email: 'a@b.co'),
        inserter: (_) async {
          called = true;
          return {};
        },
        fetcher:
            (_) async => [
              {
                'plan': 'premium_1month',
                'method': 'JazzCash',
                'transaction_id': '1234567890',
                'status': 'pending',
              },
            ],
        isConfigured: () => true,
      );
      final result = await service.submitPaymentProof(
        plan: 'premium_1month',
        method: 'JazzCash',
        transactionId: '1234567890',
        // Screenshot supplied so the test reaches the duplicate check
        // (the screenshot is required and checked first); the
        // duplicate refusal happens before any upload.
        screenshotBytes: [1, 2, 3],
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('already submitted'));
      expect(called, isFalse);
    });

    test('same TID as an APPROVED proof is also refused', () async {
      var called = false;
      final service = PaymentProofService(
        accountProvider: () => (id: 'user-1', email: 'a@b.co'),
        inserter: (_) async {
          called = true;
          return {};
        },
        fetcher:
            (_) async => [
              {
                'plan': 'premium_1month',
                'method': 'Easypaisa',
                'transaction_id': '1234567890',
                'status': 'approved',
              },
            ],
        isConfigured: () => true,
      );
      final result = await service.submitPaymentProof(
        plan: 'premium_1month',
        method: 'Easypaisa',
        transactionId: ' 1234567890 ',
        // Screenshot supplied so the test reaches the duplicate check.
        screenshotBytes: [1, 2, 3],
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('already submitted'));
      expect(called, isFalse);
    });

    test('a different TID submits normally', () async {
      var called = false;
      final service = PaymentProofService(
        accountProvider: () => (id: 'user-1', email: 'a@b.co'),
        inserter: (row) async {
          called = true;
          return {...row, 'id': 'pay-9'};
        },
        fetcher:
            (_) async => [
              {
                'plan': 'premium_1month',
                'method': 'JazzCash',
                'transaction_id': '1234567890',
                'status': 'pending',
              },
            ],
        uploader:
            ({required userId, required fileName, required bytes}) async =>
                'user-1/receipt.jpg',
        isConfigured: () => true,
      );
      final result = await service.submitPaymentProof(
        plan: 'premium_1month',
        method: 'JazzCash',
        transactionId: '0987654321',
        screenshotBytes: [1, 2, 3],
        screenshotName: 'receipt.jpg',
      );
      expect(result.ok, isTrue);
      expect(called, isTrue);
    });

    test('list load failure is fail-open: submit proceeds', () async {
      var called = false;
      final service = PaymentProofService(
        accountProvider: () => (id: 'user-1', email: 'a@b.co'),
        inserter: (row) async {
          called = true;
          return {...row, 'id': 'pay-9'};
        },
        fetcher: (_) async => throw Exception('offline'),
        // The duplicate check fails open, so the submit proceeds to
        // the (fake) upload + insert — both fakes are needed.
        uploader:
            ({required userId, required fileName, required bytes}) async =>
                'user-1/receipt.jpg',
        isConfigured: () => true,
      );
      final result = await service.submitPaymentProof(
        plan: 'premium_1month',
        method: 'JazzCash',
        transactionId: '1234567890',
        screenshotBytes: [1, 2, 3],
      );
      expect(result.ok, isTrue);
      expect(called, isTrue);
    });
  });

  group('submitPaymentProof receipt screenshot (required)', () {
    test('missing screenshot is refused; nothing is uploaded or inserted',
        () async {
      var uploadCalled = false;
      var insertCalled = false;
      final service = PaymentProofService(
        accountProvider: () => (id: 'user-1', email: 'a@b.co'),
        inserter: (_) async {
          insertCalled = true;
          return {};
        },
        uploader: ({required userId, required fileName, required bytes}) async {
          uploadCalled = true;
          return 'user-1/receipt.jpg';
        },
        isConfigured: () => true,
      );
      final result = await service.submitPaymentProof(
        plan: 'premium_1month',
        method: 'JazzCash',
        transactionId: '1234567890',
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('receipt screenshot'));
      expect(uploadCalled, isFalse);
      expect(insertCalled, isFalse);
    });

    test('upload failure is refused; insert never runs', () async {
      var insertCalled = false;
      final service = PaymentProofService(
        accountProvider: () => (id: 'user-1', email: 'a@b.co'),
        inserter: (_) async {
          insertCalled = true;
          return {};
        },
        uploader: ({required userId, required fileName, required bytes}) async =>
            throw Exception('offline'),
        isConfigured: () => true,
      );
      final result = await service.submitPaymentProof(
        plan: 'premium_1month',
        method: 'JazzCash',
        transactionId: '1234567890',
        screenshotBytes: [1, 2, 3],
        screenshotName: 'receipt.jpg',
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('Could not upload'));
      expect(insertCalled, isFalse);
    });

    test('upload success stores the returned path in the payload', () async {
      Map<String, dynamic>? inserted;
      String? uploadedName;
      final service = PaymentProofService(
        accountProvider: () => (id: 'user-1', email: 'a@b.co'),
        inserter: (row) async {
          inserted = row;
          return {...row, 'id': 'pay-9'};
        },
        uploader: ({required userId, required fileName, required bytes}) async {
          uploadedName = fileName;
          expect(userId, 'user-1');
          expect(bytes, [1, 2, 3]);
          return 'user-1/1700000000000_42.jpg';
        },
        isConfigured: () => true,
      );
      final result = await service.submitPaymentProof(
        plan: 'premium_1month',
        method: 'JazzCash',
        transactionId: '1234567890',
        screenshotBytes: [1, 2, 3],
        screenshotName: 'receipt.jpg',
      );
      expect(result.ok, isTrue);
      expect(uploadedName, 'receipt.jpg');
      expect(inserted?['screenshot_path'], 'user-1/1700000000000_42.jpg');
      expect(result.proof?.screenshotPath, 'user-1/1700000000000_42.jpg');
    });
  });
}
