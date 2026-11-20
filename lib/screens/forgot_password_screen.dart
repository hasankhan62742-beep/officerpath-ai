import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../widgets/developer_credit_footer.dart';

/// Forgot password (v2.0.0): email -> reset link.
///
/// The link points to `officerpath://reset-password` and opens
/// [ResetPasswordScreen] inside the app.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key, AuthService? authService})
    : _authService = authService;

  final AuthService? _authService;

  AuthService get authService => _authService ?? AuthService();

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  late final AuthService _auth;
  final _email = TextEditingController();
  bool _busy = false;
  bool _sent = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _auth = widget.authService;
  }

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await _auth.sendPasswordResetEmail(_email.text);
    if (!mounted) return;
    setState(() => _busy = false);
    if (result.ok) {
      setState(() => _sent = true);
    } else {
      setState(
        () => _error = result.message ?? 'Email nahi bheja ja saka.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final configured = _auth.isConfigured;
    return Scaffold(
      appBar: AppBar(title: const Text('Forgot password')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (!configured)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: const ListTile(
                leading: Icon(Icons.cloud_off),
                title: Text('Server abhi connect nahi hua'),
                subtitle: Text(
                  'Reset link baad mein bheja ja sakega — server connect '
                  'hote hi dobara koshish karein.',
                ),
              ),
            ),
          if (_sent)
            Card(
              color: Theme.of(context).colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.mark_email_read, size: 40),
                    const SizedBox(height: 12),
                    Text(
                      'Reset link email kar diya gaya hai',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${_email.text.trim()} par reset link bhej diya gaya '
                      'hai — inbox aur spam folder check karein. Link kholte '
                      'hi app mein naya password set kar sakenge.',
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Login par wapas jayein'),
                      ),
                    ),
                  ],
                ),
              ),
            )
          else ...[
            Text(
              'Password bhool gaye?',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 4),
            const Text(
              'Apni email likhein — hum aap ko password reset karne ka '
              'link bhej denge.',
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
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'Email',
                hintText: 'aap@example.com',
              ),
              onSubmitted: (_) => _send(),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: configured && !_busy ? _send : null,
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
                          'Reset link bhejein',
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
