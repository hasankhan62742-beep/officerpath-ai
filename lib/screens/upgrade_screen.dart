import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/activation_service.dart';
import '../services/payment_proof_service.dart';
import '../services/subscription_service.dart';
import '../theme/app_theme.dart';
import '../widgets/developer_credit_footer.dart';

/// Confirmed payment accounts — shown EXACTLY as written, on the
/// Premium screen itself (never only inside WhatsApp).
/// Easypaisa and JazzCash are SEPARATE numbers (corrected 19 Nov 2026).
const String kEasypaisaNumber = '03427717288';
const String kJazzCashNumber = '03060853742';
const String kPaymentName = 'Muhammad Abdul Qadeer';

/// Payment number for the given method ('Easypaisa' or 'JazzCash').
String paymentNumberFor(String method) =>
    method == 'JazzCash' ? kJazzCashNumber : kEasypaisaNumber;

/// Owner's WhatsApp, as shown to the user (same number, +92 format).
const String kOwnerWhatsAppDisplay = '+92 342 7717288';

/// Owner's WhatsApp in international format, for wa.me links.
const String kOwnerWhatsApp = '923427717288';

/// WhatsApp receipt link for a submitted payment proof.
///
/// The receipt screenshot itself goes on WhatsApp — Easypaisa and
/// JazzCash have no lookup API, so the owner's manual check of the
/// screenshot (receiver number + amount + TID) is the only
/// confirmation a payment really arrived. The prefilled message
/// carries the plan, transaction ID and registered email so the
/// owner can match it to the pending payment row. Pure — unit-tested.
Uri receiptWhatsAppUri({
  required PremiumPlan plan,
  required String method,
  required String transactionId,
  required String? email,
}) {
  final message =
      'Assalam-o-Alaikum! OfficerPath AI Premium chahiye.\n'
      'Plan: ${plan.name} (${plan.priceLabel})\n'
      'Payment method: $method\n'
      'Transaction ID: ${transactionId.isEmpty ? '(screenshot attached)' : transactionId}\n'
      'Registered email: ${email ?? '(not signed in)'}\n'
      'Receipt screenshot attached — please send my activation code. Shukriya!';
  return Uri.parse(
    'https://wa.me/$kOwnerWhatsApp?text=${Uri.encodeComponent(message)}',
  );
}

/// Upgrade screen — Free vs Premium (PKR), v2.0 server flow.
///
/// FREE: 3 tests per calendar month. PREMIUM (unlimited tests + unlimited books):
///   * 1 month  = Rs 600   (starter / trial)
///   * 2 months = Rs 1,000 (Rs 500/mo)
///   * 1 year   = Rs 5,000 (Rs 417/mo — BEST VALUE)
///
/// PAYMENT is MANUAL: the student pays Easypaisa / JazzCash to the
/// account shown on this screen, submits the transaction ID here
/// (Step 2 — saved to the server as a pending payment proof, or sent
/// on WhatsApp), the owner verifies it and emails an activation code,
/// and the student redeems the code here (Step 3). The code is checked
/// against the SERVER (single-use, 7-day expiry) via
/// [ActivationService] — the old offline-code path is v1-only and no
/// longer used by this screen. There is no automatic in-app payment —
/// no pay-now button, no card fields. Google Play Billing (automatic
/// card / Google Pay) comes in the later Play Store phase.
class UpgradeScreen extends StatefulWidget {
  const UpgradeScreen({
    super.key,
    this.activationService,
    this.paymentProofService,
    this.subscriptionService,
  });

  /// Injected for widget tests. Production callers omit all three and
  /// the real services are used.
  final ActivationService? activationService;
  final PaymentProofService? paymentProofService;
  final SubscriptionService? subscriptionService;

  @override
  State<UpgradeScreen> createState() => _UpgradeScreenState();
}

class _UpgradeScreenState extends State<UpgradeScreen> {
  ActivationService get _activation =>
      widget.activationService ?? ActivationService();
  PaymentProofService get _proofs =>
      widget.paymentProofService ?? PaymentProofService.instance;
  SubscriptionService get _subscription =>
      widget.subscriptionService ?? SubscriptionService.instance;

  int _testsUsed = 0;
  bool _isPremium = false;
  DateTime? _premiumUntil;
  String? _accountEmail;
  List<PaymentProof> _proofsList = const [];
  String _selectedPlanId = 'premium_1month';
  String _method = 'JazzCash';
  bool _busy = false;
  bool _proofBusy = false;
  String? _redeemError;
  String? _proofError;
  String? _proofMessage;
  // Last successfully submitted proof — the TID field is cleared on
  // submit, so the WhatsApp receipt button falls back to these values
  // and the prefilled message still carries the real TID.
  String? _lastSubmittedTx;
  String? _lastSubmittedPlanId;
  String? _lastSubmittedMethod;
  // Picked receipt screenshot (required for a new submission). The
  // file itself is uploaded by PaymentProofService on submit.
  PlatformFile? _receiptFile;
  final _codeController = TextEditingController();
  final _txController = TextEditingController();
  final _emailController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _codeController.dispose();
    _txController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // Best-effort server refresh — returns false offline / signed out
    // and never throws; the cached plan below still loads.
    await _subscription.refreshPlanFromServer();
    final used = await _subscription.testsUsed();
    final premium = await _subscription.isPremium();
    final until = await _subscription.premiumUntil();
    final email = _proofs.currentAccountEmail();
    if (!mounted) return;
    setState(() {
      _testsUsed = used;
      _isPremium = premium;
      _premiumUntil = until;
      _accountEmail = email;
    });
    _emailController.text = email ?? '';
    await _loadProofs();
  }

  Future<void> _loadProofs() async {
    final proofs = await _proofs.myPayments();
    if (!mounted) return;
    setState(() => _proofsList = proofs);
  }

  /// Copies the payment number for the given method (each method has
  /// its own number) and confirms it visibly — the button must
  /// actually copy.
  Future<void> _copyNumber(String method) async {
    await Clipboard.setData(ClipboardData(text: paymentNumberFor(method)));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Number copied')));
  }

  void _selectPlan(PremiumPlan plan) {
    setState(() {
      _selectedPlanId = plan.id;
      _proofMessage = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Selected ${plan.name} (${plan.priceLabel}). Pay below, then '
          'submit your transaction ID in Step 2.',
        ),
      ),
    );
  }

  Future<void> _submitProof() async {
    final txError = PaymentProofService.validateTransactionId(
      _txController.text,
    );
    if (txError != null) {
      setState(() {
        _proofError = txError;
        _proofMessage = null;
      });
      return;
    }
    setState(() {
      _proofBusy = true;
      _proofError = null;
      _proofMessage = null;
    });
    final submittedPlan = _selectedPlanId;
    final submittedMethod = _method;
    final submittedTx = _txController.text.trim();
    final receiptBytes = await _receiptBytes();
    final result = await _proofs.submitPaymentProof(
      plan: submittedPlan,
      method: submittedMethod,
      transactionId: submittedTx,
      screenshotBytes: receiptBytes,
      screenshotName: _receiptFile?.name,
    );
    if (!mounted) return;
    setState(() => _proofBusy = false);
    if (!result.ok) {
      setState(() => _proofError = result.error ?? 'Could not submit.');
      return;
    }
    // Keep the submitted values for the WhatsApp receipt button — the
    // TID field is cleared below, and the prefilled message must still
    // carry the real TID.
    _lastSubmittedTx = submittedTx;
    _lastSubmittedPlanId = submittedPlan;
    _lastSubmittedMethod = submittedMethod;
    _txController.clear();
    _receiptFile = null;
    await _loadProofs();
    if (!mounted) return;
    setState(
      () =>
          _proofMessage =
              'Proof submitted — Pending approval. IMPORTANT: send your '
              'payment receipt screenshot on WhatsApp to $kOwnerWhatsAppDisplay '
              '(button below) — the owner matches the screenshot (receiver '
              'number + amount + TID) before sending your activation code.',
    );
  }

  /// Picks the receipt screenshot from the gallery (the Easypaisa /
  /// JazzCash receipt screenshot already on the phone). file_picker
  /// is already a dependency — no new package for this.
  Future<void> _pickReceipt() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      if (!mounted) return;
      setState(() {
        _receiptFile = result.files.first;
        _proofError = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(
        () =>
            _proofError =
                'Could not pick the screenshot. Try again from your gallery.',
      );
    }
  }

  /// Bytes of the picked receipt, or null when nothing is picked or
  /// the file cannot be read (the service then reports it as missing).
  Future<List<int>?> _receiptBytes() async {
    final f = _receiptFile;
    if (f == null) return null;
    if (f.bytes != null) return f.bytes;
    if (f.path != null) {
      try {
        return await File(f.path!).readAsBytes();
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  Future<void> _sendProofOnWhatsApp() async {
    // Prefer what is typed now; after a submit the field is cleared,
    // so fall back to the last submitted proof.
    final tx =
        _txController.text.trim().isNotEmpty
            ? _txController.text.trim()
            : (_lastSubmittedTx ?? '');
    final plan = PremiumPlan.byId(_lastSubmittedPlanId ?? _selectedPlanId);
    final method = _lastSubmittedMethod ?? _method;
    final uri = receiptWhatsAppUri(
      plan: plan,
      method: method,
      transactionId: tx,
      email: _accountEmail,
    );
    var ok = false;
    try {
      ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'WhatsApp opened — attach your payment receipt screenshot, and the owner will reply with your activation code.'
              : 'Could not open WhatsApp. Message the owner at $kOwnerWhatsAppDisplay.',
        ),
      ),
    );
  }

  Future<void> _redeemCode() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      setState(() => _redeemError = 'Enter your activation code first.');
      return;
    }
    if (!ActivationService.isValidCodeFormat(code)) {
      setState(
        () =>
            _redeemError =
                'That code doesn\'t look right. Codes look like '
                'OP2-XXXXXX — check the code the owner sent you and try again.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _redeemError = null;
    });
    RedeemResult result;
    try {
      result = await _activation.redeemCode(code);
    } catch (_) {
      result = const RedeemResult(
        success: false,
        message:
            'Could not reach the server. Check your connection and try again.',
      );
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (!result.success) {
      setState(
        () =>
            _redeemError =
                result.message ?? 'Code redeem nahi hua. Dobara koshish karein.',
      );
      return;
    }
    final months = ActivationService.planMonthsForCode(code);
    final planId = switch (months) {
      1 => 'premium_1month',
      2 => 'premium_2months',
      12 => 'premium_1year',
      _ => 'premium',
    };
    await _subscription.applyServerPremium(
      planId,
      result.premiumUntil,
      months: months,
    );
    await _load();
    if (!mounted) return;
    final plan = PremiumPlan.byId(planId);
    showDialog<void>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Premium unlocked!'),
            content: Text(
              '${plan.name} is now active. Unlimited tests + unlimited books — good luck, future officer!',
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Start testing'),
              ),
            ],
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final remaining = SubscriptionService.freeTestLimit - _testsUsed;
    final selectedPlan = PremiumPlan.byId(_selectedPlanId);
    final hasPending = _proofsList.any((p) => p.isPending);
    return Scaffold(
      appBar: AppBar(title: const Text('Upgrade to Premium')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color:
                _isPremium
                    ? theme.colorScheme.primaryContainer
                    // v1.2: goldTint, not goldSoft (dark-mode contrast).
                    : AppTheme.goldTint(context),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _isPremium
                        ? _premiumUntil == null
                            ? 'You are on Premium — unlimited tests.'
                            : 'Premium until ${DateFormat('d MMM yyyy').format(_premiumUntil!)} — unlimited tests.'
                        : 'Free plan: $_testsUsed / ${SubscriptionService.freeTestLimit} tests used this month'
                            '${remaining > 0 ? ' — $remaining left' : ' — limit reached'}',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Free users get 3 tests every month. '
                    'Premium unlocks unlimited tests and unlimited books — '
                    'no academy fees, no per-test charges.',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          // HOW manual payment works — plain words, on the screen,
          // before the plans. No automatic payment: payment is
          // verified manually by the owner.
          Card(
            color: AppTheme.goldTint(context),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Manual payment — verified by the owner',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'There is no automatic in-app payment. Payment is '
                    'verified manually by the owner — Easypaisa and '
                    'JazzCash personal accounts have no auto-verify '
                    'system, so nothing is charged inside this app and '
                    'no card details are ever asked for.',
                  ),
                  const SizedBox(height: 8),
                  const Text('How it works:'),
                  const SizedBox(height: 4),
                  const Text('1. Pick a plan below.'),
                  const Text(
                    '2. Pay the exact amount from your own Easypaisa '
                    'or JazzCash app to the number below.',
                  ),
                  Text(
                    '3. Submit your transaction ID in Step 2 below AND '
                    'send the payment receipt screenshot on WhatsApp '
                    '($kOwnerWhatsAppDisplay) — the owner matches the '
                    'screenshot (receiver number + amount + TID) before '
                    'sending your code.',
                  ),
                  const Text(
                    '4. The owner checks the payment and sends you an '
                    'activation code.',
                  ),
                  const Text('5. Enter the code below — Premium unlocks.'),
                  const SizedBox(height: 8),
                  const Text(
                    'Automatic card and Google Pay purchase will come '
                    'with Play Billing after the Play Store account exists.',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Step 1 — Pay: payment accounts ON the screen, with a copy
          // button for each method. Each method has its own number.
          // The heading sits directly above the card (as in v1) so the
          // rows are in the viewport when scrolled to.
          Text(
            'Step 1 — Pay',
            style: TextStyle(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Pay to — Easypaisa / JazzCash',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                _PaymentMethodRow(
                  method: 'Easypaisa',
                  number: paymentNumberFor('Easypaisa'),
                  icon: Icons.account_balance_wallet,
                  onCopy: () => _copyNumber('Easypaisa'),
                ),
                const Divider(height: 1),
                _PaymentMethodRow(
                  method: 'JazzCash',
                  number: paymentNumberFor('JazzCash'),
                  icon: Icons.phone_android,
                  onCopy: () => _copyNumber('JazzCash'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text('Choose a plan (PKR)', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Payment is manual — Easypaisa or JazzCash only. '
            'No card details are ever stored in this app.',
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          ...PremiumPlan.plans.map(
            (plan) => Card(
              color:
                  plan.id == _selectedPlanId
                      ? AppTheme.goldTint(context)
                      : null,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Wrap, not a fixed Row — plan name + badge
                    // clipped at 360px.
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(plan.name, style: theme.textTheme.titleMedium),
                        if (plan.id == 'premium_1year')
                          const Chip(
                            label: Text(
                              'BEST VALUE',
                              style: TextStyle(
                                color: AppTheme.navyDark,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            backgroundColor: AppTheme.gold,
                          ),
                        if (plan.id == 'premium_1month')
                          const Chip(label: Text('STARTER')),
                        if (plan.id == _selectedPlanId)
                          const Chip(label: Text('SELECTED')),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${plan.priceLabel}  •  ${plan.perMonthLabel}',
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    Text(plan.tagline),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _busy ? null : () => _selectPlan(plan),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Text('Pay manually • ${plan.priceLabel}'),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Step 2 — Submit your payment proof',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'Selected plan: ${selectedPlan.name} (${selectedPlan.priceLabel})',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            'Required: attach the receipt screenshot below AND send it '
            'on WhatsApp to $kOwnerWhatsAppDisplay — approval needs it.',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.error,
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: _method,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Payment method',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'JazzCash',
                        child: Text('JazzCash — 03060853742'),
                      ),
                      DropdownMenuItem(
                        value: 'Easypaisa',
                        child: Text('Easypaisa — 03427717288'),
                      ),
                    ],
                    onChanged: (v) {
                      if (v != null) setState(() => _method = v);
                    },
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _txController,
                    decoration: const InputDecoration(
                      labelText: 'Transaction ID',
                      hintText: 'e.g. 034277172881234',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Receipt screenshot — REQUIRED (the owner matches it
                  // before approving; the same screenshot also goes on
                  // WhatsApp via the button below).
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _pickReceipt,
                          icon: const Icon(Icons.attach_file),
                          label: Text(
                            _receiptFile == null
                                ? 'Attach receipt screenshot (required)'
                                : 'Receipt: ${_receiptFile!.name}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      if (_receiptFile != null) ...[
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: 'Remove screenshot',
                          onPressed:
                              () => setState(() => _receiptFile = null),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _emailController,
                    readOnly: true,
                    decoration: const InputDecoration(
                      labelText: 'Registered account email',
                      hintText: 'Sign in to see your registered email',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  if (_proofError != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _proofError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  if (_proofMessage != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _proofMessage!,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ],
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _proofBusy ? null : _submitProof,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child:
                            _proofBusy
                                ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                                : const Text('Submit proof'),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _sendProofOnWhatsApp,
                      icon: const Icon(Icons.chat),
                      label: const Text(
                        'Send receipt screenshot on WhatsApp',
                      ),
                    ),
                  ),
                  if (hasPending) ...[
                    const SizedBox(height: 8),
                    const Text(
                      'A payment proof is pending approval — the owner '
                      'will send your activation code once it is verified.',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Your payment proofs',
                  style: theme.textTheme.titleMedium,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh proofs',
                onPressed: _loadProofs,
              ),
            ],
          ),
          const SizedBox(height: 4),
          if (_proofsList.isEmpty)
            const Text('No payment proofs submitted yet.')
          else
            Card(
              child: Column(
                children:
                    _proofsList
                        .map(
                          (proof) => ListTile(
                            title: Text(
                              '${PaymentProofService.planLabel(proof.plan)} • ${proof.method}',
                            ),
                            subtitle: Text(
                              'Transaction ID: ${proof.transactionId}',
                            ),
                            trailing: Chip(label: Text(proof.statusLabel)),
                          ),
                        )
                        .toList(),
              ),
            ),
          const SizedBox(height: 16),
          Text('I have an activation code', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text('Step 3 — Redeem your code. Codes are single-use and expire 7 days after they are issued.'),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _codeController,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    labelText: 'Activation code (e.g. OP2-XXXXXX)',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _busy ? null : _redeemCode,
                child: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 14),
                  child: Text('Redeem'),
                ),
              ),
            ],
          ),
          if (_redeemError != null) ...[
            const SizedBox(height: 8),
            Text(
              _redeemError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          if (_busy) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],
          const SizedBox(height: 16),
          Text('Premium includes', style: theme.textTheme.titleMedium),
          const _FeatureTile(
            icon: Icons.all_inclusive,
            text: 'Unlimited tests — no 3/month limit',
          ),
          const _FeatureTile(
            icon: Icons.book,
            text: 'Unlimited books & past papers (Free: 5 books)',
          ),
          const _FeatureTile(
            icon: Icons.assessment,
            text: 'Full result history, subject breakdown & weak topics',
          ),
          const _FeatureTile(
            icon: Icons.school,
            text: 'All 7 exams: PPSC, PMS, CSS MPT, FPSC, KPPSC, BPSC, SPSC',
          ),
          const SizedBox(height: 8),
          Text(
            'Google Play Billing is NOT active — it will be connected '
            'in the later Play Store phase. Prices are in Pakistani Rupees (PKR).',
            style: TextStyle(
              fontSize: 12,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          // v1.2: developer credit — last item of the scroll view.
          const DeveloperCreditFooter(),
        ],
      ),
    );
  }
}

class _FeatureTile extends StatelessWidget {
  const _FeatureTile({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
      title: Text(text),
      contentPadding: EdgeInsets.zero,
      dense: true,
    );
  }
}

/// One payment method row: method name, account number and account
/// holder name (EXACT, per the confirmed details), plus a copy
/// button that copies the number and shows "Number copied".
///
/// The number is plain [Text] (not SelectableText) so widget tests and
/// screen readers find the exact string, and the row uses Flexible +
/// ellipsis so the number + name never clip at 360px.
class _PaymentMethodRow extends StatelessWidget {
  const _PaymentMethodRow({
    required this.method,
    required this.number,
    required this.icon,
    required this.onCopy,
  });

  final String method;
  final String number;
  final IconData icon;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: AppTheme.goldTint(context),
            foregroundColor: Theme.of(context).colorScheme.primary,
            child: Icon(icon),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(method, style: Theme.of(context).textTheme.titleMedium),
                Text(
                  number,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                Text(kPaymentName, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy $method number',
            onPressed: onCopy,
          ),
        ],
      ),
    );
  }
}
