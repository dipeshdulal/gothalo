import 'package:flutter/material.dart';

/// The app's shared visual constants — corner radii, spacing, motion.
///
/// These exist because the same values were being re-typed per screen and drifted:
/// card corners ranged 8–16 across four screens, and row padding came in five
/// flavours. A token is not about saving keystrokes; it is what makes two screens
/// look like the same app when neither author is looking at the other.
class Radii {
  Radii._();

  /// Chips, badges, small inline surfaces.
  static const sm = 10.0;

  /// The default for list cards and inline panels.
  static const md = 16.0;

  /// Large containers — sheets, hero cards.
  static const lg = 22.0;

  static const BorderRadius smAll = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdAll = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgAll = BorderRadius.all(Radius.circular(lg));

  /// A fully rounded end — pills, avatars, the composer input.
  static const BorderRadius pill = BorderRadius.all(Radius.circular(999));
}

/// Vertical/horizontal rhythm. Everything is a multiple of 4; the named steps
/// are the ones actually used, so a screen reaching for `10` is a smell.
class Space {
  Space._();

  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;

  /// The gutter between a screen's content and its edges.
  static const gutter = 14.0;
}

/// Motion. One family of durations and one curve, so nothing in the app moves
/// at a speed nothing else moves at.
class Motion {
  Motion._();

  /// State flips — a focus ring, a chip toggle.
  static const fast = Duration(milliseconds: 150);

  /// The default: something appearing, expanding, or sliding into place.
  static const medium = Duration(milliseconds: 260);

  /// Deliberately slow — a full-screen or attention-seeking change.
  static const slow = Duration(milliseconds: 420);

  /// Decelerating: fast off the mark, gentle at rest. Reads as physical
  /// without the overshoot of a spring, which on dense lists looks nervous.
  static const curve = Curves.easeOutCubic;
}

/// Layered translucent fills, in place of ad-hoc `surfaceContainerHigh`.
///
/// Everything in this app sits over a gradient backdrop (see [AppBackground]),
/// so a fully opaque card cuts a flat hole in it. Slight transparency lets the
/// backdrop tint every surface, which is what makes the screens read as one
/// continuous material rather than grey boxes on a picture.
extension AppSurfaces on ColorScheme {
  bool get _dark => brightness == Brightness.dark;

  /// A resting card or list row.
  Color get cardFill =>
      surfaceContainerHigh.withValues(alpha: _dark ? 0.55 : 0.70);

  /// A card that is raised, selected, or being pressed.
  Color get cardFillStrong =>
      surfaceContainerHighest.withValues(alpha: _dark ? 0.75 : 0.88);

  /// An inset well inside a card — a code line, a quoted command.
  Color get sunkenFill => surface.withValues(alpha: _dark ? 0.45 : 0.65);

  /// The hairline that defines a surface's edge. Light-on-dark and
  /// dark-on-light rather than an outline colour, so it reads as a lit edge
  /// instead of a drawn border.
  Color get hairline => _dark
      ? Colors.white.withValues(alpha: 0.08)
      : Colors.black.withValues(alpha: 0.07);

  /// A stronger edge, for a surface that needs to hold its own shape.
  Color get hairlineStrong => _dark
      ? Colors.white.withValues(alpha: 0.14)
      : Colors.black.withValues(alpha: 0.12);
}
