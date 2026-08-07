import 'dart:async';
import 'logger.dart';

class RetryUtils {
  RetryUtils._();

  /// Executes an asynchronous [action], retrying on failure up to [maxAttempts]
  /// with progressive backoff delay.
  static Future<T> retry<T>(
    Future<T> Function() action, {
    int maxAttempts = 3,
    Duration delay = const Duration(seconds: 2),
    bool Function(Object)? retryIf,
  }) async {
    int attempt = 0;
    while (true) {
      attempt++;
      try {
        return await action();
      } catch (e, stack) {
        final shouldRetry = retryIf == null ? true : retryIf(e);
        if (attempt >= maxAttempts || !shouldRetry) {
          rethrow;
        }
        
        final currentDelay = delay * attempt;
        AppLogger.w(
          'Action failed: $e. Retrying in ${currentDelay.inSeconds}s (attempt $attempt of $maxAttempts)...',
          category: LogCategory.api,
          error: e,
          stackTrace: stack,
        );
        
        await Future.delayed(currentDelay);
      }
    }
  }
}
