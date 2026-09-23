import 'package:flutter/widgets.dart';

/// The breakpoints this app makes layout decisions on.
///
/// gothalo began as a phone remote and every screen is still designed for one
/// column. On a wide window that stops working: a list stretched to 1400dp is
/// unreadable, and walking `push`/`pop` through four full-page screens to get
/// back to the agent list is the opposite of what a desktop is good at. The
/// desktop view is therefore an **addition**, not a second design:
///
///  - At or above [desktop] a persistent shell appears (see `DesktopShell`) —
///    a nav rail down the left, and the agent list beside the transcript or
///    terminal you opened, so the two live side by side.
///  - Below it nothing changes: the phone flow is untouched.
///
/// [desktop] deliberately sits **above** the 800x600 surface widget tests use
/// by default. Those tests were written against the phone layout and keep
/// exercising it; desktop behaviour gets its own tests at an explicit size.
class AppBreakpoints {
  AppBreakpoints._();

  /// The narrowest window that gets the desktop shell.
  static const double desktop = 900;
}

extension AdaptiveLayout on BuildContext {
  /// True when there is room for the desktop shell.
  bool get isDesktopLayout =>
      MediaQuery.sizeOf(this).width >= AppBreakpoints.desktop;
}

/// How long a desktop route swap takes.
///
/// Far below the phone's 300ms slide on purpose: on desktop the shell keeps the
/// rail and the list mounted and only the detail column changes, so the swap
/// should read as "this column is now that", not as a screen arriving. Long
/// enough to soften the cut, short enough that it never reads as waiting.
const kDesktopPageTransition = Duration(milliseconds: 80);

/// Caps a screen's content at a readable width and centres it, on desktop only.
///
/// The phone screens were designed against a ~400dp column. Dropped unchanged
/// into a desktop window they stretch: a transcript's prose runs a metre wide
/// and an agent row's title and its age end up as far apart as two columns.
/// Capping the body keeps the column the design was drawn for, centred in the
/// room the window actually has.
///
/// It wraps the **body**, never the whole `Scaffold` — the header bar should
/// still span the window, so it reads as the frame around the content rather
/// than as another centred column. On a phone it returns [child] untouched.
class DesktopWidth extends StatelessWidget {
  const DesktopWidth({super.key, required this.child, this.maxWidth = 880});

  final Widget child;

  /// The widest the content column is allowed to get.
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    if (!context.isDesktopLayout) return child;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}

