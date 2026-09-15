import 'dart:developer' as dev;

enum LogLevel {
  debug,
  info,
  warning,
  error,
}

enum LogCategory {
  general,
  auth,
  websocket,
  api,
  ui,
}

class AppLogger {
  AppLogger._();

  static LogLevel _minLevel = LogLevel.debug;

  /// Set the minimum log level to output.
  static void setMinLevel(LogLevel level) {
    _minLevel = level;
  }

  /// Logs a message at [LogLevel.debug].
  static void d(String message, {LogCategory category = LogCategory.general, Object? error, StackTrace? stackTrace}) {
    _log(LogLevel.debug, category, message, error: error, stackTrace: stackTrace);
  }

  /// Logs a message at [LogLevel.info].
  static void i(String message, {LogCategory category = LogCategory.general, Object? error, StackTrace? stackTrace}) {
    _log(LogLevel.info, category, message, error: error, stackTrace: stackTrace);
  }

  /// Logs a message at [LogLevel.warning].
  static void w(String message, {LogCategory category = LogCategory.general, Object? error, StackTrace? stackTrace}) {
    _log(LogLevel.warning, category, message, error: error, stackTrace: stackTrace);
  }

  /// Logs a message at [LogLevel.error].
  static void e(String message, {LogCategory category = LogCategory.general, Object? error, StackTrace? stackTrace}) {
    _log(LogLevel.error, category, message, error: error, stackTrace: stackTrace);
  }

  static void _log(LogLevel level, LogCategory category, String message, {Object? error, StackTrace? stackTrace}) {
    if (level.index < _minLevel.index) return;

    final levelName = level.name.toUpperCase();
    final catName = category.name.toUpperCase();
    final timeStamp = DateTime.now().toIso8601String().substring(11, 23);

    final logString = '[$timeStamp] [$levelName] [$catName] $message';

    // Output using developer log which avoids stdout truncation and doesn't pollute production prints
    dev.log(
      logString,
      name: 'ScreenSync',
      level: _levelToValue(level),
      error: error,
      stackTrace: stackTrace,
    );

    // If debugging locally under test, print to stdout for visibility in test runner
    assert(() {
      print(logString);
      if (error != null) print('Error: $error');
      if (stackTrace != null) print(stackTrace);
      return true;
    }());
  }

  static int _levelToValue(LogLevel level) {
    switch (level) {
      case LogLevel.debug:
        return 500;
      case LogLevel.info:
        return 800;
      case LogLevel.warning:
        return 900;
      case LogLevel.error:
        return 1000;
    }
  }
}
