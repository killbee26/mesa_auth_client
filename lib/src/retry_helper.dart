import 'dart:async';
import 'dart:math';
import 'package:logging/logging.dart';

class RetryHelper {
  static final _log = Logger('RetryHelper');

  /// Executes a function with exponential backoff retry logic
  ///
  /// [maxAttempts] - Maximum number of retry attempts (default: 3)
  /// [initialDelay] - Initial delay before first retry (default: 1 second)
  /// [maxDelay] - Maximum delay between retries (default: 30 seconds)
  /// [shouldRetry] - Optional function to determine if error is retryable
  static Future<T> withRetry<T>({
    required Future<T> Function() operation,
    required String operationName,
    int maxAttempts = 3,
    Duration initialDelay = const Duration(seconds: 1),
    Duration maxDelay = const Duration(seconds: 30),
    bool Function(dynamic error)? shouldRetry,
  }) async {
    int attempt = 0;
    Duration delay = initialDelay;

    while (true) {
      attempt++;

      try {
        _log.info('$operationName: Attempt $attempt/$maxAttempts');
        return await operation();
      } catch (e) {
        // Check if we should retry this error
        final isRetryable = shouldRetry?.call(e) ?? _isNetworkError(e);

        if (!isRetryable || attempt >= maxAttempts) {
          _log.severe('$operationName: Failed after $attempt attempts: $e');
          rethrow;
        }

        // Calculate next delay with exponential backoff + jitter
        final nextDelay = Duration(
          milliseconds: min(
            delay.inMilliseconds * 2,
            maxDelay.inMilliseconds,
          ),
        );

        // Add jitter (random 0-25% of delay)
        final jitter = Random().nextInt(nextDelay.inMilliseconds ~/ 4);
        final delayWithJitter = Duration(
          milliseconds: nextDelay.inMilliseconds + jitter,
        );

        _log.warning(
            '$operationName: Attempt $attempt failed, '
                'retrying in ${delayWithJitter.inSeconds}s: $e'
        );

        await Future.delayed(delayWithJitter);
        delay = nextDelay;
      }
    }
  }

  /// Determines if an error is likely a network/transient error
  static bool _isNetworkError(dynamic error) {
    final errorString = error.toString().toLowerCase();
    return errorString.contains('socket') ||
        errorString.contains('network') ||
        errorString.contains('connection') ||
        errorString.contains('timeout') ||
        errorString.contains('failed host lookup') ||
        errorString.contains('handshake');
  }
}