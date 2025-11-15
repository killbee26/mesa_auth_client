import 'models/auth_tokens.dart';

abstract class ApiClient {
  Future<AuthTokens> login(String email, String password);
  Future<AuthTokens> refresh(String sessionId, String refreshToken);
  Future<void> logout(String sessionId, String refreshToken);
}