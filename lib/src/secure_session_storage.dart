import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'session_storage.dart';
import 'models/auth_tokens.dart';

class SecureSessionStorage implements SessionStorage {
  static const _accessTokenKey = 'access_token';
  static const _refreshTokenKey = 'refresh_token';
  static const _sessionIdKey = 'session_id';
  static const _accessTokenExpiryKey = 'access_token_expiry';
  static const _refreshTokenExpiryKey = 'refresh_token_expiry';
  static const _storageVersionKey = 'storage_version';
  static const _currentVersion = '1.0';

  // Secure storage with better options
  final _secureStorage = const FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      resetOnError: true,
    ),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  @override
  Future<void> saveTokens(AuthTokens tokens) async {
    try {
      // Validate tokens before saving
      if (!_validateTokens(tokens)) {
        throw Exception('Invalid tokens provided');
      }

      // Try secure storage first
      await _saveToSecureStorage(tokens);

      // Save version marker
      final prefs = await _prefs;
      await prefs.setString(_storageVersionKey, _currentVersion);

    } catch (e) {
      print('⚠️ Secure storage failed, using fallback: $e');
      // Fallback to shared preferences with basic obfuscation
      await _saveToPreferences(tokens);
    }
  }

  bool _validateTokens(AuthTokens tokens) {
    return tokens.accessToken.isNotEmpty &&
        tokens.refreshToken.isNotEmpty &&
        tokens.sessionId.isNotEmpty &&
        tokens.accessTokenExpiry.isAfter(DateTime.now().subtract(const Duration(days: 365))) &&
        tokens.refreshTokenExpiry.isAfter(DateTime.now());
  }

  Future<void> _saveToSecureStorage(AuthTokens tokens) async {
    await Future.wait([
      _secureStorage.write(key: _accessTokenKey, value: tokens.accessToken),
      _secureStorage.write(key: _refreshTokenKey, value: tokens.refreshToken),
      _secureStorage.write(key: _sessionIdKey, value: tokens.sessionId),
      _secureStorage.write(
        key: _accessTokenExpiryKey,
        value: tokens.accessTokenExpiry.toIso8601String(),
      ),
      _secureStorage.write(
        key: _refreshTokenExpiryKey,
        value: tokens.refreshTokenExpiry.toIso8601String(),
      ),
    ]);
  }

  Future<void> _saveToPreferences(AuthTokens tokens) async {
    final prefs = await _prefs;

    // Simple obfuscation (NOT encryption, just makes it non-obvious)
    final obfuscated = _obfuscate(tokens.accessToken);

    await Future.wait([
      prefs.setString(_accessTokenKey, obfuscated),
      prefs.setString(_refreshTokenKey, _obfuscate(tokens.refreshToken)),
      prefs.setString(_sessionIdKey, tokens.sessionId),
      prefs.setString(_accessTokenExpiryKey, tokens.accessTokenExpiry.toIso8601String()),
      prefs.setString(_refreshTokenExpiryKey, tokens.refreshTokenExpiry.toIso8601String()),
    ]);
  }

  @override
  Future<AuthTokens?> loadTokens() async {
    try {
      // Check version compatibility
      final prefs = await _prefs;
      final version = prefs.getString(_storageVersionKey);

      if (version != _currentVersion) {
        print('⚠️ Storage version mismatch, clearing old tokens');
        await clearTokens();
        return null;
      }

      // Try secure storage first
      final tokens = await _loadFromSecureStorage();
      if (tokens != null) {
        return tokens;
      }

      // Fallback to preferences
      return await _loadFromPreferences();
    } catch (e) {
      print('❌ Error loading tokens: $e');
      return null;
    }
  }

  Future<AuthTokens?> _loadFromSecureStorage() async {
    try {
      final results = await Future.wait([
        _secureStorage.read(key: _accessTokenKey),
        _secureStorage.read(key: _refreshTokenKey),
        _secureStorage.read(key: _sessionIdKey),
        _secureStorage.read(key: _accessTokenExpiryKey),
        _secureStorage.read(key: _refreshTokenExpiryKey),
      ]);

      final accessToken = results[0];
      final refreshToken = results[1];
      final sessionId = results[2];
      final accessExpiry = results[3];
      final refreshExpiry = results[4];

      if (accessToken == null || refreshToken == null ||
          sessionId == null || accessExpiry == null || refreshExpiry == null) {
        return null;
      }

      return _constructTokens(
        accessToken, refreshToken, sessionId, accessExpiry, refreshExpiry,
      );
    } catch (e) {
      return null;
    }
  }

  Future<AuthTokens?> _loadFromPreferences() async {
    try {
      final prefs = await _prefs;

      final accessToken = prefs.getString(_accessTokenKey);
      final refreshToken = prefs.getString(_refreshTokenKey);
      final sessionId = prefs.getString(_sessionIdKey);
      final accessExpiry = prefs.getString(_accessTokenExpiryKey);
      final refreshExpiry = prefs.getString(_refreshTokenExpiryKey);

      if (accessToken == null || refreshToken == null ||
          sessionId == null || accessExpiry == null || refreshExpiry == null) {
        return null;
      }

      // Deobfuscate
      return _constructTokens(
        _deobfuscate(accessToken),
        _deobfuscate(refreshToken),
        sessionId,
        accessExpiry,
        refreshExpiry,
      );
    } catch (e) {
      return null;
    }
  }

  AuthTokens? _constructTokens(
      String accessToken,
      String refreshToken,
      String sessionId,
      String accessExpiry,
      String refreshExpiry,
      ) {
    final accessTokenExpiry = DateTime.tryParse(accessExpiry);
    final refreshTokenExpiry = DateTime.tryParse(refreshExpiry);

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

  @override
  Future<void> clearTokens() async {
    try {
      // Clear secure storage
      await Future.wait([
        _secureStorage.delete(key: _accessTokenKey),
        _secureStorage.delete(key: _refreshTokenKey),
        _secureStorage.delete(key: _sessionIdKey),
        _secureStorage.delete(key: _accessTokenExpiryKey),
        _secureStorage.delete(key: _refreshTokenExpiryKey),
      ]);
    } catch (e) {
      print('⚠️ Secure storage clear failed: $e');
    }

    // Clear preferences
    try {
      final prefs = await _prefs;
      await Future.wait([
        prefs.remove(_accessTokenKey),
        prefs.remove(_refreshTokenKey),
        prefs.remove(_sessionIdKey),
        prefs.remove(_accessTokenExpiryKey),
        prefs.remove(_refreshTokenExpiryKey),
      ]);
    } catch (e) {
      print('⚠️ Preferences clear failed: $e');
    }
  }

  // Simple obfuscation (NOT security, just makes it non-obvious)
  String _obfuscate(String value) {
    final bytes = utf8.encode(value);
    return base64Url.encode(bytes);
  }

  String _deobfuscate(String value) {
    final bytes = base64Url.decode(value);
    return utf8.decode(bytes);
  }

  /// Verify storage integrity
  Future<bool> verifyIntegrity() async {
    try {
      final tokens = await loadTokens();
      return tokens != null && _validateTokens(tokens);
    } catch (e) {
      return false;
    }
  }
}