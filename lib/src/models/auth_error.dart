class AuthError implements Exception {
  final String code;
  final String message;

  AuthError({required this.code, required this.message});

  @override
  String toString() {
    return 'AuthError: $code - $message';
  }
}