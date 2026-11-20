import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../widgets/developer_credit_footer.dart';
import 'forgot_password_screen.dart';
import 'home_screen.dart';

/// New-password screen (v2.0.0), opened from the
/// `officerpath://reset-password` deep link.
///
/// main.dart exchanges the link's code / tokens for a recovery
/// session BEFORE navigating here. When there is no valid session
/// (link expire ho gaya, ya link seedha khola gaya), this screen
/// says so honestly and offers a button back to [ForgotPasswordScreen].
class ResetPasswordScreen extends StatefulWidget {
  const ResetPasswordScreen({super.key, AuthService? authService})
    : _authService = authService;

  final AuthService? _authService;

  AuthService get authService => _authService ?? AuthService();

  @override
  State<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends State<ResetPasswordScreen> {
  late final AuthService _auth;
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _obscure = true;
  bool _obscureConfirm = true;
  bool _busy = false;
  bool _done = false;
  String? _error;
  late final bool _hasSession;

  @override
  void initState() {
    super.initState();
    _auth = widget.authService;
    _hasSession = _auth.isSignedIn;
  }

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    if (_password.text != _confirm.text) {
      setState(
        () => _error = 'Password aur confirm password aik jaise nahi hain.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await _auth.updatePassword(_password.text);
    if (!mounted) return;
    setState(() => _busy = false);
    if (result.ok) {
      setState(() => _done = true);
    } else {
      setState(
        () => _error = result.message ?? 'Password update nahi hua.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Naya password')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (!_hasSession) ...[
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.link_off, size: 40),
                    const SizedBox(height: 12),
                    Text(
                      'Link expire ho gaya hai',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Ye reset link ab kaam nahi karta — ya to is ki muddat '
                      'khatam ho gayi hai ya ye pehle istemal ho chuka hai. '
                      'Naya link mangwayein.',
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () {
                          Navigator.pushReplacement(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  ForgotPasswordScreen(authService: _auth),
                            ),
                          );
                        },
                        child: const Text('Naya reset link mangwayein'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ] else if (_done) ...[
            Card(
              color: Theme.of(context).colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.check_circle, size: 40),
                    const SizedBox(height: 12),
                    Text(
                      'Password badal gaya hai',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Aap ka naya password save ho gaya hai. Ab naye '
                      'password se login karein.',
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () {
                          Navigator.pushReplacement(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const HomeScreen(),
                            ),
                          );
                        },
                        child: const Text('Home par jayein'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ] else ...[
            Text(
              'Naya password set karein',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 4),
            const Text(
              'Kam az kam 8 harf — ek harf aur ek digit lazmi hai.',
            ),
            const SizedBox(height: 16),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  _error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            TextField(
              controller: _password,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: 'Naya password',
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscure ? Icons.visibility : Icons.visibility_off,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _confirm,
              obscureText: _obscureConfirm,
              decoration: InputDecoration(
                labelText: 'Confirm naya password',
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscureConfirm
                        ? Icons.visibility
                        : Icons.visibility_off,
                  ),
                  onPressed: () =>
                      setState(() => _obscureConfirm = !_obscureConfirm),
                ),
              ),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _busy ? null : _save,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: _busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text(
                          'Password save karein',
                          style: TextStyle(fontSize: 16),
                        ),
                ),
              ),
            ),
          ],
          const DeveloperCreditFooter(),
        ],
      ),
    );
  }
}
