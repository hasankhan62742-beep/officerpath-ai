import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/auth_service.dart';
import '../services/push_service.dart';
import '../services/storage_service.dart';
import '../widgets/developer_credit_footer.dart';
import 'account_settings_screen.dart';
import 'auth_screen.dart';

/// Profile (v2.0.0): username, email, plan (+ Premium expiry),
/// tests taken (local history), member since, and buttons for
/// Account settings + Logout.
///
/// Tests taken comes from the local sqflite history — login never
/// wipes it. The count read is guarded: a storage failure shows 0
/// instead of crashing the screen.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, AuthService? authService, PushService? pushService})
    : _authService = authService,
      _pushService = pushService;

  final AuthService? _authService;
  final PushService? _pushService;

  AuthService get authService => _authService ?? AuthService();
  PushService get pushService => _pushService ?? PushService.instance;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late final AuthService _auth;
  UserProfile? _profile;
  int _testsTaken = 0;
  bool _loading = true;

  /// Push opt-out state: null while loading from the server.
  bool? _notificationsEnabled;

  @override
  void initState() {
    super.initState();
    _auth = widget.authService;
    _load();
  }

  Future<void> _load() async {
    final profile = await _auth.fetchProfile();
    final notificationsEnabled =
        await widget.pushService.isNotificationsEnabled();
    var testsTaken = 0;
    try {
      testsTaken = (await StorageService.instance.getAttempts()).length;
    } catch (_) {
      testsTaken = 0;
    }
    if (!mounted) return;
    setState(() {
      _profile = profile;
      _notificationsEnabled = notificationsEnabled;
      _testsTaken = testsTaken;
      _loading = false;
    });
  }

  String _formatDate(DateTime? date) {
    if (date == null) return '—';
    return DateFormat('d MMM yyyy').format(date);
  }

  Future<void> _logout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Logout karein?'),
        content: const Text(
          'Aap ka account aur aap ki books phone mein mehfooz rahengi — '
          'dobara login karke wapas aa sakte hain.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Logout'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    await _auth.signOut();
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const AuthScreen()),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profile = _profile;
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  color: theme.colorScheme.primaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 30,
                          backgroundColor: theme.colorScheme.primary,
                          foregroundColor: theme.colorScheme.onPrimary,
                          child: Text(
                            (profile?.username.isNotEmpty == true
                                    ? profile!.username[0]
                                    : '?')
                                .toUpperCase(),
                            style: const TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                profile?.username.isNotEmpty == true
                                    ? profile!.username
                                    : '—',
                                style: theme.textTheme.titleLarge,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                profile?.email ?? '—',
                                style: TextStyle(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                ListTile(
                  leading: const Icon(Icons.workspace_premium),
                  title: Text('Plan: ${profile?.planLabel ?? 'Free'}'),
                  subtitle: profile?.isPremium == true
                      ? Text(
                          'Premium ${_formatDate(profile?.premiumUntil)} tak hai.',
                        )
                      : const Text(
                          'Free: 3 tests har month. Premium se unlimited tests.',
                        ),
                ),
                ListTile(
                  leading: const Icon(Icons.quiz),
                  title: Text('Tests diye gaye: $_testsTaken'),
                  subtitle: const Text(
                    'Is phone par save ki gayi history se.',
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.notifications_outlined),
                  title: Text(
                    'Notifications: ${_notificationsEnabled == null ? '—' : (_notificationsEnabled! ? 'On' : 'Off')}',
                  ),
                  subtitle: const Text(
                    'Nayi version aur announcements ki alerts. Account '
                    'settings se on/off karein.',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => AccountSettingsScreen(
                          authService: _auth,
                          pushService: widget.pushService,
                        ),
                      ),
                    ).then((_) => _load());
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.calendar_month),
                  title: Text(
                    'Member since: ${_formatDate(profile?.createdAt)}',
                  ),
                  subtitle: const Text('Account banane ki tareekh.'),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => AccountSettingsScreen(
                            authService: _auth,
                            pushService: widget.pushService,
                          ),
                        ),
                      ).then((_) => _load());
                    },
                    icon: const Icon(Icons.settings),
                    label: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('Account settings'),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _logout,
                    icon: const Icon(Icons.logout),
                    label: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('Logout'),
                    ),
                  ),
                ),
                const DeveloperCreditFooter(),
              ],
            ),
    );
  }
}
