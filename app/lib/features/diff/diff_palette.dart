import 'package:flutter/material.dart';

/// The diff viewer's colours, resolved once per build against the active
/// [ColorScheme].
///
/// Deliberately NOT derived from the app's teal seed. Add/remove is the one
/// place in the app where colour carries meaning rather than brand, and a
/// scheme-derived `error` red plus a hand-picked green drift apart in weight
/// between light and dark — which showed up as deletions shouting and additions
/// whispering in light mode. These are GitHub's diff greens/reds, which are
/// tuned as a *pair* for both themes and are what anyone reading a diff already
/// has calibrated eyes for.
///
/// Two intensities per side: a wash for the whole line and a stronger fill for
/// the words that actually changed. The code itself keeps [ColorScheme.onSurface]
/// rather than being tinted green/red — colouring every character of an added
/// line is what makes the current viewer tiring to read, and the background
/// already says which side the line is on.
class DiffPalette {
  const DiffPalette({
    required this.addBg,
    required this.addWordBg,
    required this.addFg,
    required this.delBg,
    required this.delWordBg,
    required this.delFg,
    required this.codeFg,
    required this.gutterFg,
    required this.surface,
    required this.gapBg,
    required this.gapFg,
  });

  /// Full-line wash for an added/removed line.
  final Color addBg;
  final Color delBg;

  /// The stronger fill behind the intra-line changed words.
  final Color addWordBg;
  final Color delWordBg;

  /// The `+`/`−` marker in the gutter, and the +N/−N counts.
  final Color addFg;
  final Color delFg;

  /// Code text and line numbers.
  final Color codeFg;
  final Color gutterFg;

  /// The diff block's own background, and the collapsed-region row.
  final Color surface;
  final Color gapBg;
  final Color gapFg;

  static DiffPalette of(ColorScheme scheme) {
    final dark = scheme.brightness == Brightness.dark;
    if (dark) {
      return DiffPalette(
        // Alpha over the block surface rather than flat colours, so the wash
        // stays subtle on the near-black backdrop instead of glowing.
        addBg: const Color(0xFF3FB950).withValues(alpha: 0.14),
        addWordBg: const Color(0xFF3FB950).withValues(alpha: 0.34),
        addFg: const Color(0xFF56D364),
        delBg: const Color(0xFFF85149).withValues(alpha: 0.14),
        delWordBg: const Color(0xFFF85149).withValues(alpha: 0.32),
        delFg: const Color(0xFFFF7B72),
        codeFg: const Color(0xFFD7DEE4),
        gutterFg: scheme.onSurfaceVariant.withValues(alpha: 0.55),
        surface: const Color(0xFF0E1416),
        gapBg: Colors.white.withValues(alpha: 0.035),
        gapFg: scheme.onSurfaceVariant,
      );
    }
    return DiffPalette(
      addBg: const Color(0xFFE6FFEC),
      addWordBg: const Color(0xFFABF2BC),
      addFg: const Color(0xFF116329),
      delBg: const Color(0xFFFFEBE9),
      delWordBg: const Color(0xFFFFCECB),
      delFg: const Color(0xFF9E1C23),
      codeFg: const Color(0xFF1F2328),
      gutterFg: const Color(0xFF6E7781),
      surface: Colors.white,
      gapBg: const Color(0xFFF2F5F7),
      gapFg: const Color(0xFF57606A),
    );
  }

  /// Icon + colour for a `files[].status` — the one place the five statuses
  /// from CONTRACT-diff.md get a look, shared by the tree and the flat list.
  static (IconData, Color) statusVisual(String status, ColorScheme scheme) {
    final dark = scheme.brightness == Brightness.dark;
    final green = dark ? const Color(0xFF56D364) : const Color(0xFF116329);
    final red = dark ? const Color(0xFFFF7B72) : const Color(0xFF9E1C23);
    final blue = dark ? const Color(0xFF79B8FF) : const Color(0xFF0550AE);
    return switch (status) {
      // "added" (staged) and "untracked" are the same thing to a reviewer — a
      // file that wasn't there before — and nothing else in the app surfaces
      // the index/worktree distinction, so they share a look. The `NEW` glyph
      // this used to use is unreadable at 16px anyway.
      'added' || 'untracked' => (Icons.add_circle_outline, green),
      'deleted' => (Icons.remove_circle_outline, red),
      'renamed' => (Icons.drive_file_rename_outline, blue),
      _ => (Icons.edit_outlined, blue),
    };
  }
}
