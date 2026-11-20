import 'dart:async';

import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../widgets/developer_credit_footer.dart';
import 'forgot_password_screen.dart';
import 'home_screen.dart';

/// Login / signup in one screen (v2.0.0).
///
/// * Login tab: email + password, "Forgot password?" link, Google button.
/// * Signup tab: username (live uniqueness hint), email, password,
///   confirm password. After signup, the "verification email bheji
///   gayi hai" state with a Resend button.
/// * When the server is not configured ([AuthService.isConfigured] is
///   false) a banner says so plainly and the auth buttons stay
///   disabled — never a dead button, never a crash.
///
/// On successful login the user goes to [HomeScreen] (replace).
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, AuthService? authService})
    : _authService = authService;

  final AuthService? _authService;

  AuthService get authService => _authService ?? AuthService();

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen>
    with SingleTickerProviderStateMixin {
  late final AuthService _auth;
  late final TabController _tabs;

  // Login fields.
  final _loginEmail = TextEditingController();
  final _loginPassword = TextEditingController();

  // Signup fields.
  final _username = TextEditingController();
  final _signupEmail = TextEditingController();
  final _signupPassword = TextEditingController();
  final _signupConfirm = TextEditingController();

  bool _obscureLogin = true;
  bool _obscureSignup = true;
  bool _obscureConfirm = true;
  bool _busy = false;
  bool _googleBusy = false;
  String? _error;
  String? _usernameHint;
  bool _usernameOk = false;
  Timer? _usernameTimer;

  /// After signup: the verification-email state.
  bool _verificationSent = false;
  String _pendingEmail = '';

  @override
  void initState() {
    super.initState();
    _auth = widget.authService;
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    _loginEmail.dispose();
    _loginPassword.dispose();
    _username.dispose();
    _signupEmail.dispose();
    _signupPassword.dispose();
    _signupConfirm.dispose();
    _usernameTimer?.cancel();
    super.dispose();
  }

  void _showError(String message) {
    setState(() => _error = message);
  }

  void _goHome() {
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const HomeScreen()),
    );
  }

  Future<void> _login() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await _auth.signInWithEmail(
      email: _loginEmail.text,
      password: _loginPassword.text,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (result.status == AuthStatus.success) {
      _goHome();
    } else {
      _showError(result.message ?? 'Login nahi hua — dobara koshish karein.');
    }
  }

  Future<void> _signup() async {
    if (_busy) return;
    if (_signupPassword.text != _signupConfirm.text) {
      _showError('Password aur confirm password aik jaise nahi hain.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await _auth.signUpWithEmail(
      email: _signupEmail.text,
      password: _signupPassword.text,
      username: _username.text,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (result.status == AuthStatus.success) {
      _goHome();
    } else if (result.status == AuthStatus.needsEmailVerification) {
      setState(() {
        _verificationSent = true;
        _pendingEmail = _signupEmail.text.trim();
      });
    } else {
      _showError(result.message ?? 'Account nahi bana — dobara koshish karein.');
    }
  }

  Future<void> _googleSignIn() async {
    if (_googleBusy) return;
    setState(() {
      _googleBusy = true;
      _error = null;
    });
    final result = await _auth.signInWithGoogle();
    if (!mounted) return;
    setState(() => _googleBusy = false);
    if (result.status == AuthStatus.success) {
      _goHome();
    } else if (result.status == AuthStatus.cancelled) {
      // User cancelled the Google sheet — no error, nothing to show.
    } else {
      _showError(result.message ?? 'Google login nahi hua.');
    }
  }

  Future<void> _resendVerification() async {
    final result = await _auth.resendVerificationEmail(_pendingEmail);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.ok
              ? 'Verification email dobara bhej di gayi hai.'
              : result.message ?? 'Email nahi bheji ja saki.',
        ),
      ),
    );
  }

  /// Live username hint: format error first, then a debounced
  /// server uniqueness check (500 ms after the last keystroke).
  void _onUsernameChanged(String value) {
    _usernameTimer?.cancel();
    final formatError = AuthService.validateUsername(value);
    if (formatError != null) {
      setState(() {
        _usernameHint = formatError;
        _usernameOk = false;
      });
      return;
    }
    setState(() {
      _usernameHint = 'Check ho raha hai…';
      _usernameOk = false;
    });
    _usernameTimer = Timer(const Duration(milliseconds: 500), () async {
      final available = await _auth.checkUsernameAvailable(value);
      if (!mounted) return;
      setState(() {
        if (available == null) {
          _usernameHint = null;
        } else if (available) {
          _usernameHint = 'Username available hai.';
          _usernameOk = true;
        } else {
          _usernameHint = 'Ye username pehle se liya gaya hai.';
          _usernameOk = false;
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final configured = _auth.isConfigured;
    return Scaffold(
      appBar: AppBar(
        title: const Text('OfficerPath AI'),
        bottom: TabBar(
          controller: _tabs,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          indicatorColor: const Color(0xFFC9A227),
          tabs: const [
            Tab(text: 'Login'),
            Tab(text: 'Signup'),
          ],
        ),
      ),
      body: Column(
        children: [
          if (!configured)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              color: Theme.of(context).colorScheme.errorContainer,
              child: const Text(
                'Server abhi connect nahi hua — login/signup baad mein hoga. '
                'App offline chal rahi hai.',
                textAlign: TextAlign.center,
              ),
            ),
          if (_verificationSent)
            Expanded(child: _buildVerificationState())
          else
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: [
                  _buildLoginTab(configured),
                  _buildSignupTab(configured),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildVerificationState() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
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
                  'Verification email bheji gayi hai',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  '$_pendingEmail par ek link bheja gaya hai — inbox '
                  'check karein (spam folder bhi). Link kholte hi account '
                  'verify ho jayega, phir login karein.',
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton(
                        onPressed: _resendVerification,
                        child: const Text('Resend email'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () {
                          setState(() {
                            _verificationSent = false;
                            _tabs.index = 0;
                          });
                        },
                        child: const Text('Login par jayein'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const DeveloperCreditFooter(),
      ],
    );
  }

  Widget _errorBanner() {
    if (_error == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        _error!,
        style: TextStyle(
          color: Theme.of(context).colorScheme.error,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _googleButton(bool enabled) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: enabled && !_googleBusy ? _googleSignIn : null,
        icon: _googleBusy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.account_circle),
        label: const Padding(
          padding: EdgeInsets.symmetric(vertical: 10),
          child: Text('Google se login karein'),
        ),
      ),
    );
  }

  Widget _buildLoginTab(bool configured) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Wapas khush aamdeed',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 4),
        const Text('Apne account se login karein aur tayyari jari rakhein.'),
        const SizedBox(height: 16),
        _errorBanner(),
        TextField(
          controller: _loginEmail,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(
            labelText: 'Email',
            hintText: 'aap@example.com',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _loginPassword,
          obscureText: _obscureLogin,
          decoration: InputDecoration(
            labelText: 'Password',
            suffixIcon: IconButton(
              icon: Icon(
                _obscureLogin ? Icons.visibility : Icons.visibility_off,
              ),
              onPressed: () => setState(() => _obscureLogin = !_obscureLogin),
            ),
          ),
          onSubmitted: (_) => _login(),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      ForgotPasswordScreen(authService: _auth),
                ),
              );
            },
            child: const Text('Forgot password?'),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: configured && !_busy ? _login : null,
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
                  : const Text('Login', style: TextStyle(fontSize: 16)),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: const [
            Expanded(child: Divider()),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Text('ya'),
            ),
            Expanded(child: Divider()),
          ],
        ),
        const SizedBox(height: 12),
        _googleButton(configured),
        const DeveloperCreditFooter(),
      ],
    );
  }

  Widget _buildSignupTab(bool configured) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Naya account banayein',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 4),
        const Text(
          'Username aap ki pehchan hai — 3 se 20 harf, sirf harf, digit, '
          'underscore aur dot.',
        ),
        const SizedBox(height: 16),
        _errorBanner(),
        TextField(
          controller: _username,
          decoration: InputDecoration(
            labelText: 'Username',
            hintText: 'jaise: ali.ahmed',
            helperText: _usernameHint,
            helperStyle: TextStyle(
              color: _usernameOk
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.error,
            ),
            suffixIcon: _usernameOk
                ? const Icon(Icons.check_circle, color: Colors.green)
                : null,
          ),
          onChanged: _onUsernameChanged,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _signupEmail,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(
            labelText: 'Email',
            hintText: 'aap@example.com',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _signupPassword,
          obscureText: _obscureSignup,
          decoration: InputDecoration(
            labelText: 'Password',
            helperText: 'Kam az kam 8 harf — ek harf aur ek digit lazmi.',
            suffixIcon: IconButton(
              icon: Icon(
                _obscureSignup ? Icons.visibility : Icons.visibility_off,
              ),
              onPressed: () =>
                  setState(() => _obscureSignup = !_obscureSignup),
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _signupConfirm,
          obscureText: _obscureConfirm,
          decoration: InputDecoration(
            labelText: 'Confirm password',
            suffixIcon: IconButton(
              icon: Icon(
                _obscureConfirm ? Icons.visibility : Icons.visibility_off,
              ),
              onPressed: () =>
                  setState(() => _obscureConfirm = !_obscureConfirm),
            ),
          ),
          onSubmitted: (_) => _signup(),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: configured && !_busy ? _signup : null,
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
                      'Account banayein',
                      style: TextStyle(fontSize: 16),
                    ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: const [
            Expanded(child: Divider()),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Text('ya'),
            ),
            Expanded(child: Divider()),
          ],
        ),
        const SizedBox(height: 12),
        _googleButton(configured),
        const DeveloperCreditFooter(),
      ],
    );
  }
}
