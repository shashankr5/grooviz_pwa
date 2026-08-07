class AppDurations {
  AppDurations._();

  static const Duration fast = Duration(milliseconds: 150);
  static const Duration normal = Duration(milliseconds: 250);
  static const Duration slow = Duration(milliseconds: 400);

  static const Duration retryDelay = Duration(seconds: 2);
  static const Duration periodicCheck = Duration(seconds: 60);
}
