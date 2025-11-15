import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'session_storage.dart';
import 'models/auth_tokens.dart';


class SecureSessionStorage implements SessionStorage {
  final _secureStorage = FlutterSecureStorage();
  final Future<SharedPreferences> _sharedPreferences = SharedPreferences.getInstance();

  // Keys for storing data
  static const _accessTokenKey = 'access_token';
  static const _refreshTokenKey = 'refresh_token';
  static const _sessionIdKey = 'session_id';
  static const _accessTokenExpiryKey = 'access_token_expiry';
  static const _refreshTokenExpiryKey = 'refresh_token_expiry';

  @override
  Future<void> saveTokens(AuthTokens tokens) async {
    try {
      await _secureStorage.write(key: _accessTokenKey, value: tokens.accessToken);
      await _secureStorage.write(key: _refreshTokenKey, value: tokens.refreshToken);
      await _secureStorage.write(key: _sessionIdKey, value: tokens.sessionId);
      await _secureStorage.write(key: _accessTokenExpiryKey, value: tokens.accessTokenExpiry.toIso8601String());
      await _secureStorage.write(key: _refreshTokenExpiryKey, value: tokens.refreshTokenExpiry.toIso8601String());
    } catch (e) {
      // If secure storage fails, fallback to shared preferences
      print('Failed to save to secure storage: $e, falling back to shared preferences');
      final prefs = await _sharedPreferences;
      await prefs.setString(_accessTokenKey, tokens.accessToken);
      await prefs.setString(_refreshTokenKey, tokens.refreshToken);
      await prefs.setString(_sessionIdKey, tokens.sessionId);
      await prefs.setString(_accessTokenExpiryKey, tokens.accessTokenExpiry.toIso8601String());
      await prefs.setString(_refreshTokenExpiryKey, tokens.refreshTokenExpiry.toIso8601String());
    }
  }

  @override
  Future<AuthTokens?> loadTokens() async {
    try {
      final accessToken = await _secureStorage.read(key: _accessTokenKey);
      final refreshToken = await _secureStorage.read(key: _refreshTokenKey);
      final sessionId = await _secureStorage.read(key: _sessionIdKey);
      final accessTokenExpiryString = await _secureStorage.read(key: _accessTokenExpiryKey);
      final refreshTokenExpiryString = await _secureStorage.read(key: _refreshTokenExpiryKey);

      if (accessToken == null || refreshToken == null || sessionId == null || accessTokenExpiryString == null || refreshTokenExpiryString == null) {
        // Try loading from shared preferences if secure storage fails
        final prefs = await _sharedPreferences;
        final accessToken = prefs.getString(_accessTokenKey);
        final refreshToken = prefs.getString(_refreshTokenKey);
        final sessionId = prefs.getString(_sessionIdKey);
        final accessTokenExpiryString = prefs.getString(_accessTokenExpiryKey);
        final refreshTokenExpiryString = prefs.getString(_refreshTokenExpiryKey);

        if (accessToken == null || refreshToken == null || sessionId == null || accessTokenExpiryString == null || refreshTokenExpiryString == null) {
          return null;
        }

        final accessTokenExpiry = DateTime.tryParse(accessTokenExpiryString);
        final refreshTokenExpiry = DateTime.tryParse(refreshTokenExpiryString);

        if (accessTokenExpiry == null || refreshTokenExpiry == null) {
          return null;
        }

        return AuthTokens(
          accessToken: accessToken,
          refreshToken: refreshToken,
          sessionId: sessionId,
          accessTokenExpiry: accessTokenExpiry,
          refreshTokenExpiry: refreshTokenExpiry,
        );
      }

      final accessTokenExpiry = DateTime.tryParse(accessTokenExpiryString);
      final refreshTokenExpiry = DateTime.tryParse(refreshTokenExpiryString);

      if (accessTokenExpiry == null || refreshTokenExpiry == null) {
        return null;
      }

      return AuthTokens(
        accessToken: accessToken,
        refreshToken: refreshToken,
        sessionId: sessionId,
        accessTokenExpiry: accessTokenExpiry,
        refreshTokenExpiry: refreshTokenExpiry,
      );
    } catch (e) {
      // Handle exceptions, e.g., if secure storage is not available
      print('Error loading tokens: $e');
      return null;
    }
  }

  @override
  Future<void> clearTokens() async {
    try {
      await _secureStorage.delete(key: _accessTokenKey);
      await _secureStorage.delete(key: _refreshTokenKey);
      await _secureStorage.delete(key: _sessionIdKey);
      await _secureStorage.delete(key: _accessTokenExpiryKey);
      await _secureStorage.delete(key: _refreshTokenExpiryKey);
    } catch (e) {
      // If secure storage fails, fallback to shared preferences
      print('Failed to clear from secure storage: $e, falling back to shared preferences');
      final prefs = await _sharedPreferences;
      await prefs.remove(_accessTokenKey);
      await prefs.remove(_refreshTokenKey);
      await prefs.remove(_sessionIdKey);
      await prefs.remove(_accessTokenExpiryKey);
      await prefs.remove(_refreshTokenExpiryKey);
    }
  }
}