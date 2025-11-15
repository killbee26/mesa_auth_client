import 'models/auth_tokens.dart';

abstract class SessionStorage {
  Future<void> saveTokens(AuthTokens tokens);
  Future<AuthTokens?> loadTokens();
  Future<void> clearTokens();
}