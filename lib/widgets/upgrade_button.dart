import 'package:flutter/material.dart';

import '../screens/upgrade_screen.dart';

/// Red UPGRADE button for the top corner (AppBar) of every main screen.
///
/// v1.2 (user, 19 Nov 2026): the button must be RED, CLEAR and in the
/// TOP CORNER — visible on Home, My Books, History, Current Affairs and
/// test setup — never buried in Settings (there is no Settings screen).
/// Tapping it opens [UpgradeScreen] with the three Premium packages and
/// the real free-test count (read from the subscription service there,
/// never hard-coded).
///
/// Always visible, even for Premium users — the Premium screen then
/// shows their active plan instead of the packages. The button is
/// deliberately compact (text only, no icon) so it fits next to the
/// other AppBar actions at 360px wide without clipping the title.
///
/// Colours: solid red #C62828 with white bold text — readable on the
/// navy AppBar in BOTH light and dark mode (the AppBar is navy in
/// light mode, navy-dark in dark mode; white on #C62828 is ~5:1).
/// It does NOT use the theme's FilledButton colours (navy/gold),
/// because the user explicitly asked for RED.
class UpgradeAppBarButton extends StatelessWidget {
  const UpgradeAppBarButton({super.key, this.onReturn});

  /// Called after the Premium screen is popped — e.g. so Home can
  /// reload the free-test count after an activation.
  final VoidCallback? onReturn;

  /// Opens the Premium screen. Shared so every call site uses the
  /// same route (and tests can drive the same path).
  static Future<void> open(BuildContext context, {VoidCallback? onReturn}) {
    return Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const UpgradeScreen()),
    ).then((_) => onReturn?.call());
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      child: Tooltip(
        message: 'Upgrade to Premium',
        child: FilledButton(
          onPressed: () => open(context, onReturn: onReturn),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFFC62828),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            minimumSize: const Size(0, 36),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          child: const Text(
            'UPGRADE',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
        ),
      ),
    );
  }
}
