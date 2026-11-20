import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/auth_service.dart';
import '../services/push_service.dart';
import '../widgets/developer_credit_footer.dart';
import 'auth_screen.dart';

/// Account settings (v2.0.0): change password, change username,
/// logout, and delete account.
///
/// * Change password verifies the CURRENT password first (Supabase
///   updateUser does not check the old password itself).
/// * Delete account asks the user to type DELETE, then calls the
///   server-side `delete-account` Edge Function. When that function
///   is not deployed yet, the UI says so honestly and offers the
///   WhatsApp support path — it never claims deletion worked.
/// * Notifications (v2.0.0): the opt-out toggle for push
///   notifications. Turning it off updates
///   `profiles.notifications_enabled` AND deletes the local FCM token,
///   so nothing can be delivered; the server re-checks the flag
///   before every send as well.
class AccountSettingsScreen extends StatefulWidget {
  const AccountSettingsScreen({super.key, AuthService? authService, PushService? pushService})
    : _authService = authService,
      _pushService = pushService;

  final AuthService? _authService;
  final PushService? _pushService;

  AuthService get authService => _authService ?? AuthService();
  PushService get pushService => _pushService ?? PushService.instance;

  @override
  State<AccountSettingsScreen> createState() =>
      _AccountSettingsScreenState();
}

class _AccountSettingsScreenState extends State<AccountSettingsScreen> {
  late final AuthService _auth;

  final _currentPassword = TextEditingController();
  final _newPassword = TextEditingController();
  final _confirmPassword = TextEditingController();
  final _username = TextEditingController();

  bool _passwordBusy = false;
  bool _usernameBusy = false;
  bool _deleteBusy = false;
  String? _passwordMessage;
  bool _passwordIsError = false;
  String? _usernameMessage;
  bool _usernameIsError = false;

  /// Push opt-out state: null while loading from the server.
  bool? _notificationsEnabled;
  bool _notificationsBusy = false;
  String? _notificationsMessage;

  /// Owner WhatsApp (public business number) for the delete fallback.
  static const String _supportWhatsApp = '923427717288';

  @override
  void initState() {
    super.initState();
    _auth = widget.authService;
    _loadNotificationSetting();
  }

  /// Reads the push opt-out flag. A failure leaves the toggle at its
  /// default (on) and the toggle still works — the save reports its
  /// own failure instead of crashing the screen.
  Future<void> _loadNotificationSetting() async {
    final enabled = await widget.pushService.isNotificationsEnabled();
    if (!mounted) return;
    setState(() => _notificationsEnabled = enabled);
  }

  Future<void> _toggleNotifications(bool value) async {
    if (_notificationsBusy) return;
    setState(() {
      _notificationsBusy = true;
      _notificationsMessage = null;
    });
    final ok = await widget.pushService.setNotificationsEnabled(value);
    if (!mounted) return;
    setState(() {
      _notificationsBusy = false;
      if (ok) {
        _notificationsEnabled = value;
        _notificationsMessage = value
            ? 'Notifications on kar di gayi hain.'
            : 'Notifications band kar di gayi hain — ab koi notification nahi aayegi.';
      } else {
        _notificationsMessage =
            'Setting save nahi ho saki — login check karein aur dobara koshish karein.';
      }
    });
  }

  @override
  void dispose() {
    _currentPassword.dispose();
    _newPassword.dispose();
    _confirmPassword.dispose();
    _username.dispose();
    super.dispose();
  }

  void _snack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _changePassword() async {
    if (_passwordBusy) return;
    if (_newPassword.text != _confirmPassword.text) {
      setState(() {
        _passwordMessage =
            'Naya password aur confirm password aik jaise nahi hain.';
        _passwordIsError = true;
      });
      return;
    }
    setState(() {
      _passwordBusy = true;
      _passwordMessage = null;
    });
    final currentOk = await _auth.reauthenticate(_currentPassword.text);
    if (!mounted) return;
    if (!currentOk) {
      setState(() {
        _passwordBusy = false;
        _passwordMessage = 'Maujooda password ghalat hai.';
        _passwordIsError = true;
      });
      return;
    }
    final result = await _auth.updatePassword(_newPassword.text);
    if (!mounted) return;
    setState(() {
      _passwordBusy = false;
      _passwordMessage = result.ok
          ? 'Password badal gaya hai.'
          : result.message ?? 'Password nahi badla ja saka.';
      _passwordIsError = !result.ok;
    });
    if (result.ok) {
      _currentPassword.clear();
      _newPassword.clear();
      _confirmPassword.clear();
    }
  }

  Future<void> _changeUsername() async {
    if (_usernameBusy) return;
    setState(() {
      _usernameBusy = true;
      _usernameMessage = null;
    });
    final result = await _auth.updateUsername(_username.text);
    if (!mounted) return;
    setState(() {
      _usernameBusy = false;
      _usernameMessage = result.ok
          ? 'Username badal gaya hai.'
          : result.message ?? 'Username nahi badla ja saka.';
      _usernameIsError = !result.ok;
    });
    if (result.ok) _username.clear();
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

  Future<void> _deleteAccount() async {
    final deleteConfirm = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Account delete karein?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Ye action wapas nahi ho sakta. Aap ka account, profile '
                'aur Premium status server se hamesha ke liye delete ho '
                'jayega. Is phone ki books aur history delete NAHI hongi — '
                'woh alag se app data clear karne par jayengi.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: deleteConfirm,
                decoration: const InputDecoration(
                  labelText: 'Confirm karne ke liye DELETE likhein',
                  hintText: 'DELETE',
                ),
                onChanged: (_) => setDialogState(() {}),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              ),
              onPressed: deleteConfirm.text.trim() == 'DELETE'
                  ? () => Navigator.pop(context, true)
                  : null,
              child: const Text('Delete account'),
            ),
          ],
        ),
      ),
    );
    deleteConfirm.dispose();
    if (confirmed != true || !mounted) return;
    setState(() => _deleteBusy = true);
    final result = await _auth.deleteAccount();
    if (!mounted) return;
    setState(() => _deleteBusy = false);
    if (result.status == AuthStatus.success) {
      _snack('Account delete ho gaya hai.');
      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const AuthScreen()),
        (_) => false,
      );
    } else if (result.status == AuthStatus.unavailable) {
      if (!mounted) return;
      final openSupport = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Delete abhi available nahi hai'),
          content: Text(
            result.message ?? AuthService.deleteUnavailableMessage,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Theek hai'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('WhatsApp support'),
            ),
          ],
        ),
      );
      if (openSupport == true) {
        final uri = Uri.parse(
          'https://wa.me/$_supportWhatsApp?text='
          'Assalam-o-Alaikum, main apna OfficerPath AI account delete karna chahta hoon.',
        );
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } else {
      _snack(result.message ?? 'Account delete nahi hua.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Account settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Password badlein',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _currentPassword,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Maujooda password',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _newPassword,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Naya password',
              helperText: 'Kam az kam 8 harf — ek harf aur ek digit lazmi.',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _confirmPassword,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Confirm naya password',
            ),
          ),
          const SizedBox(height: 8),
          if (_passwordMessage != null)
            Text(
              _passwordMessage!,
              style: TextStyle(
                color: _passwordIsError
                    ? theme.colorScheme.error
                    : theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _passwordBusy ? null : _changePassword,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: _passwordBusy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Password save karein'),
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Username badlein',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _username,
            decoration: const InputDecoration(
              labelText: 'Naya username',
              hintText: 'jaise: ali.ahmed',
            ),
          ),
          const SizedBox(height: 8),
          if (_usernameMessage != null)
            Text(
              _usernameMessage!,
              style: TextStyle(
                color: _usernameIsError
                    ? theme.colorScheme.error
                    : theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _usernameBusy ? null : _changeUsername,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: _usernameBusy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Username save karein'),
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Notifications',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          SwitchListTile(
            title: const Text('Notifications'),
            subtitle: const Text(
              'Nayi version aur announcements ki alerts. Band karne par '
              'koi notification nahi aayegi.',
            ),
            value: _notificationsEnabled ?? true,
            onChanged: _notificationsBusy ? null : _toggleNotifications,
            contentPadding: EdgeInsets.zero,
          ),
          if (_notificationsMessage != null)
            Text(
              _notificationsMessage!,
              style: TextStyle(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          const SizedBox(height: 24),
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
          const SizedBox(height: 24),
          Card(
            color: theme.colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Account delete karein',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.error,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Account, profile aur Premium status hamesha ke liye '
                    'delete ho jayega. Ye wapas nahi ho sakta.',
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: theme.colorScheme.error,
                        foregroundColor: theme.colorScheme.onError,
                      ),
                      onPressed: _deleteBusy ? null : _deleteAccount,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: _deleteBusy
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Text('Account delete karein'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const DeveloperCreditFooter(),
        ],
      ),
    );
  }
}
