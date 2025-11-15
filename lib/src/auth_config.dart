import 'session_storage.dart';

class AuthConfig {
  final String baseUrl;
  final Duration expiringSoonThreshold;
  final Duration refreshTimeout;
  final SessionStorage storage;

  AuthConfig({
    required this.baseUrl,
    required this.storage,
    this.expiringSoonThreshold = const Duration(seconds: 30),
    this.refreshTimeout = const Duration(seconds: 5),
  });
}