import 'package:flutter/material.dart';

/// The app's shared visual constants — corner radii, spacing, motion.
///
/// The language is terminal-native: flat surfaces held by hairlines, tight
/// corners, dense rows. Radii never pass 8 — the 18–22dp card corner is the
/// Material tell this design removes, not something it approximates.
class Radii {
  Radii._();

  /// Chips, tags, small inline surfaces.
  static const xs = 4.0;

  /// Buttons, inputs, menu rows.
  static const sm = 6.0;

  /// The default for list rows and panels — the largest radius in the language.
  static const md = 8.0;

  static const BorderRadius xsAll = BorderRadius.all(Radius.circular(xs));
  static const BorderRadius smAll = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdAll = BorderRadius.all(Radius.circular(md));
}

/// Vertical/horizontal rhythm. Rows sit closer than a Material list — density
/// is the point, a phone should show more agents per screen without feeling
/// cramped. Everything is a multiple of 2; the named steps are the ones
/// actually used.
class Space {
  Space._();

  static const xs = 2.0;
  static const sm = 4.0;
  static const md = 8.0;
  static const lg = 12.0;
  static const xl = 16.0;

  /// The gutter between a screen's content and its edges.
  static const gutter = 12.0;
}

/// Motion. One family of durations and one curve, so nothing in the app moves
/// at a speed nothing else moves at. Short on purpose: a dense terminal UI
/// should flip, not glide.
class Motion {
  Motion._();

  /// State flips — a toggle, a chevron.
  static const fast = Duration(milliseconds: 120);

  /// The default: something appearing or expanding.
  static const medium = Duration(milliseconds: 200);

  /// Deliberately slow — a full-screen or attention-seeking change.
  static const slow = Duration(milliseconds: 320);

  /// Decelerating: fast off the mark, gentle at rest. Reads as physical
  /// without the overshoot of a spring, which on dense lists looks nervous.
  static const curve = Curves.easeOutCubic;
}

/// Flat, opaque fills for every surface, in place of Material's elevation and
/// translucency. A panel reads as a panel because of its hairline, not because
/// it floats or tints what is behind it.
extension AppSurfaces on ColorScheme {
  bool get _dark => brightness == Brightness.dark;

  /// A resting panel or list row — a tone or two off the backdrop.
  Color get panelFill =>
      _dark ? const Color(0xFF11181A) : const Color(0xFFFBFCFC);

  /// A raised/selected panel — the focused pane.
  Color get panelFillRaised =>
      _dark ? const Color(0xFF172022) : const Color(0xFFFFFFFF);

  /// An inset well inside a panel — a code line, a quoted command.
  Color get wellFill =>
      _dark ? const Color(0xFF0B1011) : const Color(0xFFF1F3F2);

  /// The 1px hairline that holds every surface's edge. Light-on-dark and
  /// dark-on-light rather than an outline colour, so it reads as a lit edge
  /// instead of a drawn border.
  Color get hairline => _dark
      ? Colors.white.withValues(alpha: 0.08)
      : Colors.black.withValues(alpha: 0.08);

  /// A stronger edge, for a surface that needs to hold its own shape — the
  /// header bar's rule, a focused control.
  Color get hairlineStrong => _dark
      ? Colors.white.withValues(alpha: 0.16)
      : Colors.black.withValues(alpha: 0.14);
}
