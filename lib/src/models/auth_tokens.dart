class AuthTokens {
  final String accessToken;
  final String refreshToken;
  final String sessionId;

  final DateTime accessTokenExpiry;
  final DateTime refreshTokenExpiry;

  AuthTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.sessionId,
    required this.accessTokenExpiry,
    required this.refreshTokenExpiry,
  });
}