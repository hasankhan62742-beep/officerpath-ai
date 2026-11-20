import 'package:flutter/material.dart';

/// Developer credit — appears at the bottom of EVERY screen in the app.
///
/// Bold and colourful, but pro-level and consistent with the navy + gold
/// officer theme: a thin gold rule, a small gold shield, "Developed by"
/// in muted theme text, and the name in the theme primary (navy in light
/// mode, gold in dark mode — both high-contrast on their background).
/// Same widget, same size, everywhere.
///
/// Placement rule (followed on every screen): the footer is the LAST item
/// of the screen's scroll view, or — on screens whose body is a Column
/// (test screen, Current Affairs) — the last child of the Column, below
/// the buttons / tab content, so it can never cover the timer, options,
/// submit button or list content. [SafeArea] keeps it off the system
/// gesture bar.
class DeveloperCreditFooter extends StatelessWidget {
  const DeveloperCreditFooter({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 1.5,
              width: 72,
              decoration: BoxDecoration(
                color: Theme.of(context).brightness == Brightness.dark
                    ? scheme.primary.withValues(alpha: 0.8)
                    : scheme.primary.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(1),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.shield,
                  size: 14,
                  color: Color(0xFFC9A227),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text.rich(
                    TextSpan(
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                      children: [
                        TextSpan(
                          text: 'Developed by ',
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        TextSpan(
                          text: 'Muhammad Abdul Qadeer',
                          style: TextStyle(color: scheme.primary),
                        ),
                      ],
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
