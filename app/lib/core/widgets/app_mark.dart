import 'package:flutter/material.dart';

/// The app's mark — the same watercolor ram used as the launcher icon —
/// shown small and circular inline in the UI. Until now the ram only ever
/// appeared as the home-screen icon and as a faint 18%-opacity background
/// wash (see [AppBackground]); this is the one place the brand identity
/// shows up *inside* the app itself, at a size where it actually reads.
class AppMark extends StatelessWidget {
  const AppMark({super.key, this.radius = 16});

  final double radius;

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: radius,
      backgroundImage: const AssetImage('assets/icon/ic_legacy.png'),
    );
  }
}
