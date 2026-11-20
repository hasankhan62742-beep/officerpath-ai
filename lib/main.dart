import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'screens/auth_screen.dart';
import 'screens/home_screen.dart';
import 'screens/reset_password_screen.dart';
import 'services/auth_service.dart';
import 'services/deep_link.dart';
import 'services/push_service.dart';
import 'services/storage_service.dart';
import 'services/supabase_config.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Seed the built-in 84-question sample bank on first run.
  // AUDIT C2: seeding must never kill startup — a corrupt DB, full
  // disk or permission failure used to leave a black screen forever.
  // Now the app always starts; Home shows a retry banner if it failed.
  var seedFailed = false;
  try {
    await StorageService.instance.ensureSeeded();
  } catch (_) {
    seedFailed = true;
  }
  // v2.0.0: initialise Supabase ONLY when dart-define values were
  // supplied. A failure here must never kill startup — the app runs
  // offline and the auth screen says so plainly.
  var supabaseReady = false;
  if (SupabaseConfig.isConfigured) {
    try {
      await Supabase.initialize(
        url: SupabaseConfig.url,
        publishableKey: SupabaseConfig.anonKey,
      );
      supabaseReady = true;
    } catch (_) {
      supabaseReady = false;
    }
  }
  // v2.0.0 push notifications (FCM): Firebase is OPTIONAL. When
  // google-services.json is missing or still the placeholder,
  // initialize() returns false and push stays disabled — the app
  // carries on normally. Never throws, never blocks startup.
  try {
    await PushService.instance.initialize();
  } catch (_) {}
  runApp(
    OfficerPathApp(seedFailed: seedFailed, supabaseReady: supabaseReady),
  );
}

class OfficerPathApp extends StatefulWidget {
  const OfficerPathApp({
    super.key,
    this.seedFailed = false,
    this.supabaseReady = false,
  });

  /// True when first-run seeding failed — Home shows a retry banner.
  final bool seedFailed;

  /// True when Supabase initialised successfully at startup.
  final bool supabaseReady;

  @override
  State<OfficerPathApp> createState() => _OfficerPathAppState();
}

class _OfficerPathAppState extends State<OfficerPathApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  late final AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSubscription;

  /// Auth gate, decided once at startup: a live session goes to
  /// Home, everything else to the auth screen. Login/logout screens
  /// navigate themselves afterwards.
  late final bool _signedIn;

  @override
  void initState() {
    super.initState();
    _signedIn = widget.supabaseReady && AuthService().isSignedIn;
    _appLinks = AppLinks();
    _linkSubscription = _appLinks.uriLinkStream.listen(
      _handleDeepLink,
      onError: (_) {},
    );
    // Cold start from a deep link (e.g. the reset email was tapped
    // while the app was closed).
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final initial = await _appLinks.getInitialLink();
        if (initial != null) _handleDeepLink(initial);
      } catch (_) {
        // No initial link — normal launch.
      }
    });
  }

  @override
  void dispose() {
    _linkSubscription?.cancel();
    super.dispose();
  }

  /// Handles `officerpath://reset-password` links: exchanges the
  /// link's code / tokens for a recovery session, then opens the
  /// new-password screen. A link without a usable token still opens
  /// the screen — it explains the link expired.
  Future<void> _handleDeepLink(Uri uri) async {
    final link = parseResetPasswordUri(uri);
    if (!link.isResetLink) return;
    if (!widget.supabaseReady) return;
    try {
      final auth = Supabase.instance.client.auth;
      if (link.code != null) {
        await auth.exchangeCodeForSession(link.code!);
      } else if (link.accessToken != null && link.refreshToken != null) {
        await auth.setSession(
          link.refreshToken!,
          accessToken: link.accessToken,
        );
      }
    } catch (_) {
      // No valid recovery session — ResetPasswordScreen shows the
      // expired-link state instead of crashing.
    }
    _navigatorKey.currentState?.push(
      MaterialPageRoute(builder: (_) => const ResetPasswordScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OfficerPath AI',
      debugShowCheckedModeBanner: false,
      // Officer-grade theme: deep navy + gold. Light by default,
      // dark mode follows the device setting.
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      navigatorKey: _navigatorKey,
      home: _signedIn
          ? HomeScreen(seedFailed: widget.seedFailed)
          : const AuthScreen(),
    );
  }
}
