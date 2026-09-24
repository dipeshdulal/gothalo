import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The app's wall clock, as a function so a time-dependent surface can be
/// rendered at a fixed instant in tests and in the README screenshots.
///
/// Production reads the real clock. A test overrides it —
/// `nowProvider.overrideWithValue(() => DateTime(2026, 9, 8, 11, 6))` — and the
/// home greeting, today's date, and the activity timeline's hour dividers,
/// entry times and still-running durations all render from that instant instead
/// of the day and time the test happened to run.
///
/// A function rather than a cached `DateTime` on purpose: a value would freeze
/// the greeting and every "blocked 50m" at the moment the provider was first
/// read, instead of following the clock.
final nowProvider = Provider<DateTime Function()>((ref) => DateTime.now);
