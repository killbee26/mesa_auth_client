import 'dart:async';

class RefreshMutex {
  Future<dynamic>? _ongoingRefresh;

  Future<T> run<T>(Future<T> Function() task) async {
    // If a refresh is already ongoing, wait for it instead of starting a new one
    if (_ongoingRefresh != null) {
      try {
        return await _ongoingRefresh as T;
      } catch (e) {
        // If the ongoing refresh failed, we'll retry
        _ongoingRefresh = null;
      }
    }

    // Start new refresh and store the future
    final completer = Completer<T>();
    _ongoingRefresh = completer.future;

    try {
      final result = await task();
      completer.complete(result);
      return result;
    } catch (e) {
      completer.completeError(e);
      rethrow;
    } finally {
      // Clear the ongoing refresh after completion
      _ongoingRefresh = null;
    }
  }
}