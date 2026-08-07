// lib/constants/app_config.dart
//
// Build-time stage flag.
// Controls which database/Lambda environment every payload targets.
//
// ── Usage ────────────────────────────────────────────────────────────────────
//   Development:
//     flutter run --dart-define=STAGE=dev
//
//   Production:
//     flutter build apk --dart-define=STAGE=prod
//     flutter build ipa --dart-define=STAGE=prod
//
// ── Default ───────────────────────────────────────────────────────────────────
//   Defaults to 'prod' when --dart-define=STAGE is not passed.
//   This ensures release builds are always production unless explicitly overridden.

class AppConfig {
  AppConfig._(); // not instantiable

  /// The runtime stage read from the STAGE dart-define flag.
  /// Pass --dart-define=STAGE=dev at build/run time for development.
  static const String stage =
      String.fromEnvironment('STAGE', defaultValue: 'prod');
}
