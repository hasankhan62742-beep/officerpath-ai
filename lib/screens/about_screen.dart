import 'package:flutter/material.dart';

import '../services/app_update_service.dart';
import '../widgets/developer_credit_footer.dart';
import '../widgets/update_prompt.dart';
import 'account_settings_screen.dart';
import 'profile_screen.dart';

/// About OfficerPath AI.
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  String _version = '';
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    AppUpdateService.instance.currentVersion().then((v) {
      if (mounted) setState(() => _version = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: theme.colorScheme.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'OfficerPath AI',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Apni book se officer tak ka rasta.',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Upload your own MCQ book or past papers, tick the papers '
                    'you prepared today, and take a timed mock test in the '
                    'real commission pattern — PPSC, PMS, CSS MPT, FPSC, '
                    'KPPSC, BPSC, SPSC. No academy fees.',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          ListTile(
            leading: const Icon(Icons.verified),
            title: Text(
              _version.isEmpty
                  ? 'Version — Free launch (Freemium)'
                  : 'Version $_version — Free launch (Freemium)',
            ),
            subtitle: const Text(
              'Free: 3 tests har month. Premium: unlimited tests + unlimited books.',
            ),
          ),
          ListTile(
            leading: const Icon(Icons.system_update_alt),
            title: const Text('Check for updates'),
            subtitle: const Text(
              'Nayi version aaye to app ke andar hi download aur install karein.',
            ),
            trailing: _checking
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.chevron_right),
            onTap: _checking
                ? null
                : () async {
                    setState(() => _checking = true);
                    await checkForUpdatesManually(context);
                    if (mounted) setState(() => _checking = false);
                  },
          ),
          const ListTile(
            leading: Icon(Icons.offline_bolt),
            title: Text('Offline-first'),
            subtitle: Text(
              'Your books and results stay on your phone. Account sirf '
              'login aur Premium ke liye hai — books kabhi server par '
              'nahi jati hain.',
            ),
          ),
          const ListTile(
            leading: Icon(Icons.privacy_tip_outlined),
            title: Text('Privacy'),
            subtitle: Text(
              'Account se sirf aap ki profile (username, email) aur '
              'Premium status server par rehta hai. No tracking, no ads. '
              'Your PDF never leaves your phone — only the MCQs extracted '
              'from it are stored in the app.',
            ),
          ),
          const ListTile(
            leading: Icon(Icons.school),
            title: Text('Exams covered'),
            subtitle: Text(
              'PPSC • PMS • CSS MPT • FPSC • KPPSC • BPSC • SPSC',
            ),
          ),
          const ListTile(
            leading: Icon(Icons.contact_support_outlined),
            title: Text('Support & Premium activation'),
            subtitle: Text(
              'Qadeer Automations — abdulqadeerml.com • '
              'WhatsApp +92 342 7717288',
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Account',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.account_circle_outlined),
            title: const Text('Profile'),
            subtitle: const Text(
              'Username, email, plan aur tests ki history dekhein.',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ProfileScreen()),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.manage_accounts_outlined),
            title: const Text('Account settings'),
            subtitle: const Text(
              'Password ya username badlein, logout ya account delete karein.',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const AccountSettingsScreen(),
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          Text(
            'Made for the aspirants of Pakistan — good luck, future officer.',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          // v1.2: developer credit — last item of the scroll view.
          const DeveloperCreditFooter(),
        ],
      ),
    );
  }
}
