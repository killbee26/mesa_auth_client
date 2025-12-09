import 'models/auth_tokens.dart';

abstract class ApiClient {
  Future<AuthTokens> login(String id, String password, String phone);
  Future<AuthTokens> refresh(String sessionId, String refreshToken);
  Future<void> logout(String sessionId, String refreshToken);
}