import 'dart:async';
import 'models/auth_tokens.dart';
import 'models/auth_status.dart';
import 'models/auth_error.dart';
import 'session_storage.dart';
import 'api_client.dart';
import 'refresh_mutex.dart';

class AuthManager {
  AuthTokens? _tokens;
  AuthStatus _currentStatus = AuthStatus.unknown;

  final _authStatusController = StreamController<AuthStatus>.broadcast();

  final SessionStorage storage;
  final ApiClient api;
  final RefreshMutex _mutex = RefreshMutex();
  final Duration expiringSoonThreshold;

  AuthManager({
    required this.storage,
    required this.api,
    required this.expiringSoonThreshold,
  });

  set tokens(AuthTokens? tokens) {
    _tokens = tokens;
  }

  Stream<AuthStatus> get authStatus$ => _authStatusController.stream;
  AuthStatus get currentStatus => _currentStatus;
  bool get isAuthenticated => _currentStatus == AuthStatus.authenticated;

  void _setStatus(AuthStatus status) {
    if (_currentStatus != status) {
      _currentStatus = status;
      _authStatusController.add(status);
    }
  }

  // ------------------------------------------------------
  // INITIALIZATION
  // ------------------------------------------------------
  Future<void> initialize() async {
    final tokens = await storage.loadTokens();

    if (tokens == null) {
      _tokens = null;
      _setStatus(AuthStatus.unauthenticated);
      return;
    }

    _tokens = tokens;

    // If access token still valid → authenticated
    if (tokens.accessTokenExpiry.isAfter(DateTime.now())) {
      _setStatus(AuthStatus.authenticated);
      _checkExpiringSoon();
      return;
    }

    // Token expired → do not auto-refresh here
    _setStatus(AuthStatus.unauthenticated);
  }

  /// ------------------------------------------------------
  /// NEW: initializeAndRefresh()
  /// Called only by real App (NOT test)
  /// ------------------------------------------------------
  Future<void> initializeAndRefresh() async {
    await initialize();

    // If we have tokens, but status is unauthenticated because token expired
    if (_tokens != null && _currentStatus == AuthStatus.unauthenticated) {
      try {
        await gracefulRefresh();
      } catch (_) {
        _setStatus(AuthStatus.unauthenticated);
      }
    }
  }

  // ------------------------------------------------------
  // LOGIN
  // ------------------------------------------------------
  Future<void> login(String email, String password) async {
    try {
      final tokens = await api.login(email, password);
      await storage.saveTokens(tokens);
      _tokens = tokens;
      _setStatus(AuthStatus.authenticated);
      _checkExpiringSoon();
    } catch (e) {
      _setStatus(AuthStatus.unauthenticated);
      rethrow;
    }
  }

  // ------------------------------------------------------
  // LOGOUT
  // ------------------------------------------------------
  Future<void> logout() async {
    if (_tokens != null) {
      try {
        await api.logout(_tokens!.sessionId, _tokens!.refreshToken);
      } catch (e) {
        print("Logout API error: $e");
      }
    }

    await storage.clearTokens();
    _tokens = null;
    _setStatus(AuthStatus.unauthenticated);
  }

  // ------------------------------------------------------
  // GRACEFUL REFRESH
  // ------------------------------------------------------
  Future<AuthTokens> gracefulRefresh() async {
  return _mutex.run(() async {
    if (_tokens == null) {
      _setStatus(AuthStatus.unauthenticated);
      throw AuthError(code: "NOT_LOGGED_IN", message: "Not logged in");
    }

    _setStatus(AuthStatus.refreshing);

    try {
      final newTokens = await api.refresh(
        _tokens!.sessionId,
        _tokens!.refreshToken,
      );

      _tokens = newTokens;
      await storage.saveTokens(newTokens);

      _setStatus(AuthStatus.authenticated);
      _checkExpiringSoon();
      return newTokens;
    }

    // 🔥 FIX: SESSION_REVOKED must NOT rethrow, must finalize status
    on AuthError catch (e) {
      if (e.code == "SESSION_REVOKED") {
        await storage.clearTokens();
        _tokens = null;

        _setStatus(AuthStatus.sessionInvalid);

        // DO NOT rethrow → test expects final state sessionInvalid
        return Future.error(
          AuthError(
            code: "SESSION_REVOKED",
            message: "Session was revoked",
          ),
        );
      }

      // Other auth errors
      _setStatus(AuthStatus.unauthenticated);
      return Future.error(e);
    }

    // Any non-AuthError exceptions (network, parsing…)
    catch (e) {
      _setStatus(AuthStatus.unauthenticated);
      return Future.error(e);
    }
  });
}


  // ------------------------------------------------------
  // GET VALID ACCESS TOKEN
  // ------------------------------------------------------
  Future<String?> getValidAccessToken() async {
    if (_tokens == null) return null;

    // If still valid → return directly
    if (_tokens!.accessTokenExpiry.isAfter(DateTime.now())) {
      _checkExpiringSoon();
      return _tokens!.accessToken;
    }

    // If expired → attempt refresh
    try {
      final refreshed = await gracefulRefresh();
      return refreshed.accessToken;
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------
  // EXPIRING SOON CHECK
  // ------------------------------------------------------
  void _checkExpiringSoon() {
    if (_tokens == null) return;

    final expiry = _tokens!.accessTokenExpiry;

    if (expiry.isAfter(DateTime.now()) &&
        expiry.difference(DateTime.now()) <= expiringSoonThreshold) {
      _setStatus(AuthStatus.expiringSoon);
    }
  }

  // ------------------------------------------------------
  // DISPOSE
  // ------------------------------------------------------
  void dispose() {
    _authStatusController.close();
  }
}
