import 'dart:async';

class RefreshMutex {
  Future<T> run<T>(Future<T> Function() task) async {
    Completer<T> completer = Completer<T>();
    Future<T> future = completer.future;

    try {
      T result = await task();
      completer.complete(result);
    } catch (e) {
      completer.completeError(e);
    }

    return future;
  }
}