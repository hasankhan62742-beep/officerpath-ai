import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/ai_usage_caps.dart';
import '../services/gemini_config.dart';
import '../services/secure_key_store.dart';
import '../services/subscription_service.dart';
import '../widgets/developer_credit_footer.dart';
import 'account_settings_screen.dart';
import 'profile_screen.dart';

/// AI Settings (v1.2, Option A): the user enters their own free
/// Gemini API key ONCE. The key is stored ONLY in secure storage
/// (Android Keystore) — never in SharedPreferences, never in logs,
/// never sent anywhere except directly to Google's Gemini API.
///
/// Also shows the model, the daily AI caps, and the estimated costs
/// (Nov 2026 rates — labelled as estimates).
class AiSettingsScreen extends StatefulWidget {
  const AiSettingsScreen({super.key});

  @override
  State<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends State<AiSettingsScreen> {
  final _keyController = TextEditingController();
  final _keyStore = GeminiKeyStore();
  bool _hasKey = false;
  bool _loading = true;
  bool _obscure = true;
  int _usedToday = 0;
  int _remainingToday = GeminiConfig.freeDailyAiBooks;
  bool _isPremium = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final hasKey = await _keyStore.hasKey();
    final premium = await SubscriptionService.instance.isPremium();
    final caps = AiUsageCaps();
    final used = await caps.booksUsedToday();
    final remaining = await caps.booksRemainingToday(isPremium: premium);
    if (!mounted) return;
    setState(() {
      _hasKey = hasKey;
      _isPremium = premium;
      _usedToday = used;
      _remainingToday = remaining;
      _loading = false;
    });
  }

  Future<void> _saveKey() async {
    final key = _keyController.text.trim();
    if (key.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pehle key likhein.')),
      );
      return;
    }
    await _keyStore.saveKey(key);
    _keyController.clear();
    await _load();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Key save ho gayi — sirf is phone mein, secure storage mein.',
          ),
        ),
      );
    }
  }

  Future<void> _deleteKey() async {
    await _keyStore.deleteKey();
    await _load();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Key delete kar di gayi.')),
      );
    }
  }

  Future<void> _openAiStudio() async {
    // AUDIT (v2.0.0): launchUrl ka result pehle ignore hota tha — link
    // na khulne par button khamoshi se kuch nahi karta tha (dead
    // button). Ab failure par saaf message dikhta hai.
    final uri = Uri.parse(GeminiConfig.aiStudioUrl);
    final opened = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Link nahi khula — browser mein aistudio.google.com kholein.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('AI Settings — Gemini key')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  color: _hasKey
                      ? theme.colorScheme.primaryContainer
                      : theme.colorScheme.errorContainer,
                  child: ListTile(
                    leading: Icon(
                      _hasKey ? Icons.key : Icons.key_off,
                    ),
                    title: Text(
                      _hasKey
                          ? 'Gemini key save hai'
                          : 'Gemini key nahi hai',
                    ),
                    subtitle: Text(
                      _hasKey
                          ? 'AI generation, answer inference aur best-quality '
                                'Urdu OCR kaam karega.'
                          : 'AI features (MCQ generation, jawab nikaalna, '
                                'best-quality Urdu OCR) ke liye key chahiye.',
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Apni Gemini key daalein',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Key sirf is phone mein secure storage (Keystore) '
                          'mein rehti hai — kahin upload nahi hoti, kisi '
                          'server ko nahi bheji jati, sirf seedha Google '
                          'Gemini ko jati hai.',
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _keyController,
                          obscureText: _obscure,
                          decoration: InputDecoration(
                            labelText: 'Gemini API key',
                            hintText: 'AIza…',
                            border: const OutlineInputBorder(),
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscure
                                    ? Icons.visibility
                                    : Icons.visibility_off,
                              ),
                              onPressed: () =>
                                  setState(() => _obscure = !_obscure),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: _saveKey,
                                icon: const Icon(Icons.save),
                                label: const Text('Save key'),
                              ),
                            ),
                            if (_hasKey) ...[
                              const SizedBox(width: 8),
                              OutlinedButton(
                                onPressed: _deleteKey,
                                child: const Text('Delete'),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: _openAiStudio,
                          icon: const Icon(Icons.open_in_new),
                          label: const Text(
                            'Free key lein — Google AI Studio',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.today),
                    title: const Text('Aaj ki AI limit'),
                    subtitle: Text(
                      'Aaj $_usedToday AI book(s) use hui — '
                      '$_remainingToday baaqi hain '
                      '(${_isPremium ? 'Premium: 10/day' : 'Free: 2/day'}). '
                      'Save ki hui MCQs dobara use karna free hai — '
                      'Gemini sirf nayi book par ek dafa chalta hai.',
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Model aur kharcha (andaza, Nov 2026 rates)',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Model: ${GeminiConfig.modelId}\n'
                          '• 100 MCQs banane ka kharcha: ~\$0.021–0.029 '
                          '(~Rs 6–8)\n'
                          '• Ek scanned Urdu page (best quality): ~\$0.0004 '
                          '(~Rs 0.11)\n'
                          '• Ek jawab nikaalna: ~\$0.00002\n'
                          '• Free tier: 500 requests/day (Google ki taraf '
                          'se, shared) — apni key par aap ka kharcha '
                          'aap ki usage par hai.',
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.account_circle_outlined),
                        title: const Text('Account'),
                        subtitle: const Text(
                          'Profile, password, username aur logout.',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const ProfileScreen(),
                            ),
                          );
                        },
                      ),
                      ListTile(
                        leading: const Icon(Icons.manage_accounts_outlined),
                        title: const Text('Account settings'),
                        subtitle: const Text(
                          'Password ya username badlein.',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  const AccountSettingsScreen(),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
                const DeveloperCreditFooter(),
              ],
            ),
    );
  }
}
