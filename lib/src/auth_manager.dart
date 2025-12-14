import 'dart:async';
import 'package:logging/logging.dart';
import 'package:mesa_auth_client/mesa_auth_client.dart';

import 'models/auth_tokens.dart';
import 'models/auth_status.dart';
import 'models/auth_error.dart';
import 'session_storage.dart';
import 'api_client.dart';
import 'refresh_mutex.dart';
import 'retry_helper.dart';

class AuthManager {
  final _log = Logger('AuthManager');

  AuthTokens? _tokens;
  AuthStatus _currentStatus = AuthStatus.unknown;

  final _authStatusController = StreamController<AuthStatus>.broadcast();
  final RefreshMutex _mutex = RefreshMutex();

  Timer? _expiryCheckTimer;
  Timer? _periodicRefreshTimer;
  int _consecutiveRefreshFailures = 0;

  Future<void> Function()? onLogoutCallback;

  DateTime? _lastSuccessfulRefresh;

  final AuthConfig config;
  final ApiClient api;

  SessionStorage get storage => config.storage;
  Duration get expiringSoonThreshold => config.expiringSoonThreshold;
  AuthTokens? get tokens => _tokens;

  AuthManager({
    required this.config,
    required this.api,
  });

  set tokens(AuthTokens? tokens) {
    _tokens = tokens;
    _log.info("Tokens manually set");
  }

  Stream<AuthStatus> get authStatus$ => _authStatusController.stream;
  AuthStatus get currentStatus => _currentStatus;
  bool get isAuthenticated =>
      _currentStatus == AuthStatus.authenticated ||
          _currentStatus == AuthStatus.expiringSoon;

  void _setStatus(AuthStatus status) {
    if (_currentStatus != status) {
      _currentStatus = status;
      _authStatusController.add(status);
      _log.info("Auth status: $_currentStatus");
    }
  }

  // ------------------------------------------------------
  // INITIALIZATION
  // ------------------------------------------------------
  Future<void> initialize() async {
    _log.info("Initializing AuthManager...");

    try {
      final tokens = await storage.loadTokens();

      if (tokens == null) {
        _tokens = null;
        _setStatus(AuthStatus.unauthenticated);
        _log.info("No tokens → unauthenticated");
        return;
      }

      _tokens = tokens;
      _log.info("Loaded tokens, access expiry: ${tokens.accessTokenExpiry}, refresh expiry: ${tokens.refreshTokenExpiry}");

      // Validate token structure
      if (!_isTokenValid(tokens)) {
        _log.warning("Token validation failed, clearing storage");
        await storage.clearTokens();
        _tokens = null;
        _setStatus(AuthStatus.unauthenticated);
        return;
      }

      // CRITICAL FIX: If we have valid refresh token, consider user authenticated
      // even if access token is expired - we'll refresh it automatically
      if (tokens.refreshTokenExpiry.isAfter(DateTime.now())) {
        // Refresh token is still valid - user should stay logged in
        if (tokens.accessTokenExpiry.isAfter(DateTime.now())) {
          // Access token is also valid
          _setStatus(AuthStatus.authenticated);
          _startExpiryMonitoring();
          _startPeriodicRefresh();
          _log.info("✅ Both tokens valid → authenticated");
        } else {
          // Access token expired but refresh token valid
          // Set as authenticated and schedule immediate refresh
          _setStatus(AuthStatus.authenticated);
          _log.info("✅ Refresh token valid, access token expired → will refresh but staying authenticated");

          // Start monitoring and periodic refresh
          _startExpiryMonitoring();
          _startPeriodicRefresh();
        }
      } else {
        // Refresh token expired - user must re-login
        _log.warning("❌ Refresh token expired → must re-login");
        await storage.clearTokens();
        _tokens = null;
        _setStatus(AuthStatus.unauthenticated);
      }
    } catch (e) {
      _log.severe("Initialization error: $e");
      _setStatus(AuthStatus.unauthenticated);
    }
  }

  bool _isTokenValid(AuthTokens tokens) {
    if (tokens.accessToken.isEmpty || tokens.refreshToken.isEmpty) {
      return false;
    }

    // CRITICAL: Only check if refresh token is valid
    // Access token can be expired - we'll refresh it
    if (tokens.refreshTokenExpiry.isBefore(DateTime.now())) {
      _log.warning("Refresh token expired - this is permanent");
      return false;
    }

    return true;
  }

  Future<void> initializeAndRefresh() async {
    await initialize();

    // If access token is expired but refresh token is valid, refresh immediately
    if (_tokens != null &&
        _tokens!.accessTokenExpiry.isBefore(DateTime.now()) &&
        _tokens!.refreshTokenExpiry.isAfter(DateTime.now())) {
      _log.info("🔄 Access token expired during init, refreshing immediately...");
      try {
        await _performRefresh();
        _log.info("✅ Init refresh successful");
      } catch (e) {
        _log.warning("⚠️ Init refresh failed: $e");
        // CRITICAL: Don't logout on init refresh failure
        // Keep trying in background as long as refresh token is valid
        if (_isPermanentError(e)) {
          await _handlePermanentFailure();
        } else {
          _log.info("📅 Will retry refresh in background");
          _scheduleBackgroundRefresh();
        }
      }
    }
  }

  // ------------------------------------------------------
  // LOGIN
  // ------------------------------------------------------
  Future<void> login(String id, String password, String phone) async {
    _log.info("Login attempt: $phone");

    try {
      final tokens = await RetryHelper.withRetry(
        operation: () => api.login(id, password, phone),
        operationName: 'Login',
        maxAttempts: 2,
        shouldRetry: (error) => !_isPermanentError(error),
      );

      await storage.saveTokens(tokens);
      _tokens = tokens;
      _consecutiveRefreshFailures = 0;
      _lastSuccessfulRefresh = DateTime.now();
      _setStatus(AuthStatus.authenticated);
      _startExpiryMonitoring();
      _startPeriodicRefresh();
      _log.info("Login successful");
    } catch (e) {
      _setStatus(AuthStatus.unauthenticated);
      _log.severe("Login failed: $e");
      rethrow;
    }
  }

  // ------------------------------------------------------
  // LOGOUT
  // ------------------------------------------------------
  Future<void> logout() async {
    _log.info("⚠️ EXPLICIT LOGOUT");

    _stopExpiryMonitoring();
    _stopPeriodicRefresh();
    _consecutiveRefreshFailures = 0;
    _lastSuccessfulRefresh = null;

    final tokensToRevoke = _tokens;

    // API logout
    if (tokensToRevoke != null) {
      try {
        await api
            .logout(tokensToRevoke.sessionId, tokensToRevoke.accessToken)
            .timeout(const Duration(seconds: 5));
        _log.info("✅ API logout successful");
      } catch (e) {
        _log.warning("Logout API error (non-critical): $e");
      }
    }

    // Clear storage and tokens
    await storage.clearTokens();
    _tokens = null;
    _log.info("🔒 Tokens cleared");

    // PowerSync cleanup with timeout (don't block logout)
    if (onLogoutCallback != null) {
      _log.info("🧹 PowerSync cleanup (max 2s timeout)...");
      try {
        await onLogoutCallback!().timeout(
          const Duration(seconds: 2),
          onTimeout: () {
            _log.warning("⚠️ PowerSync cleanup timeout - continuing in background");
          },
        );
        _log.info("✅ PowerSync cleanup completed");
      } catch (e) {
        _log.severe("❌ PowerSync cleanup error (non-critical): $e");
      }
    }

    _setStatus(AuthStatus.sessionInvalid);
    _log.info("✅ Logged out");
  }



  // ------------------------------------------------------
  // REFRESH WITH PERSISTENT RETRY
  // ------------------------------------------------------
  Future<AuthTokens> gracefulRefresh() async {
    if (_tokens == null) {
      _setStatus(AuthStatus.unauthenticated);
      throw AuthError(code: "NOT_LOGGED_IN", message: "Not logged in");
    }

    return _performRefresh();
  }

  Future<AuthTokens> _performRefresh() async {
    if (_tokens == null) {
      throw AuthError(code: "NOT_LOGGED_IN", message: "Not logged in");
    }

    return _mutex.run(() async {
      final previousStatus = _currentStatus;
      _setStatus(AuthStatus.refreshing);
      _log.info("Refreshing tokens (attempt ${_consecutiveRefreshFailures + 1})...");

      try {
        final newTokens = await RetryHelper.withRetry(
          operation: () => api.refresh(_tokens!.sessionId, _tokens!.refreshToken),
          operationName: 'Token Refresh',
          maxAttempts: 5, // Increased from 3
          initialDelay: const Duration(seconds: 2),
          maxDelay: const Duration(seconds: 30),
          shouldRetry: (error) => !_isPermanentError(error),
        );

        _tokens = newTokens;
        await storage.saveTokens(newTokens);
        _consecutiveRefreshFailures = 0;
        _lastSuccessfulRefresh = DateTime.now();

        _log.info("✅ Refresh successful, new expiry: ${newTokens.accessTokenExpiry}");

        _setStatus(AuthStatus.authenticated);
        _startExpiryMonitoring();
        _startPeriodicRefresh();

        return newTokens;
      } on AuthError catch (e) {
        _consecutiveRefreshFailures++;
        _log.severe("❌ AuthError during refresh (failure #$_consecutiveRefreshFailures): ${e.code}");

        // CRITICAL CHANGE: Only logout on EXPLICIT permanent errors
        // Network errors, server errors, timeouts should NOT cause logout
        if (_isPermanentError(e)) {
          _log.severe("🚫 Permanent error detected: ${e.code} - This is a server rejection");
          // Even on permanent error, we'll keep the user "authenticated"
          // but they'll get errors when making API calls
          // They MUST explicitly logout
          _log.warning("⚠️ User must manually logout due to server rejection");
        }

        // NEVER call _handlePermanentFailure() automatically
        // Keep retrying in background
        _log.warning("⚠️ Refresh failed but staying logged in, will retry");
        _setStatus(previousStatus == AuthStatus.authenticated
            ? AuthStatus.authenticated
            : AuthStatus.expiringSoon);
        _scheduleBackgroundRefresh();

        return Future.error(e);
      } catch (e) {
        _consecutiveRefreshFailures++;
        _log.severe("❌ Refresh error #$_consecutiveRefreshFailures: $e");

        // Network/timeout errors - NEVER logout
        _log.warning("⚠️ Network error, staying logged in, will retry");
        _setStatus(previousStatus == AuthStatus.authenticated
            ? AuthStatus.authenticated
            : AuthStatus.expiringSoon);
        _scheduleBackgroundRefresh();

        return Future.error(e);
      }
    });
  }

  bool _shouldKeepTrying() {
    // CRITICAL CHANGE: Always keep trying as long as we have a refresh token
    // Never give up on token refresh attempts
    if (_tokens != null && _tokens!.refreshTokenExpiry.isAfter(DateTime.now())) {
      _log.info("🔄 Refresh token still valid, will keep trying indefinitely");
      return true;
    }
    return false;
  }

  void _scheduleBackgroundRefresh() {
    // CRITICAL: Schedule faster retries (15s instead of 30s)
    _log.info("📅 Scheduling aggressive background refresh in 15s");
    Future.delayed(const Duration(seconds: 15), () {
      if (_tokens != null && _currentStatus != AuthStatus.sessionInvalid) {
        _log.info("🔄 Background refresh attempt");
        _performRefresh().catchError((e) {
          _log.warning("Background refresh failed, will retry again: $e");
        });
      }
    });
  }

  bool _isPermanentError(dynamic error) {
    if (error is AuthError) {
      // CRITICAL: Be very strict about what's "permanent"
      // Most errors should be treated as temporary/retryable
      // Only explicit server rejections are permanent
      return error.code == "SESSION_REVOKED" ||
          error.code == "INVALID_REFRESH_TOKEN" ||
          error.code == "REFRESH_TOKEN_EXPIRED" ||
          error.code == "ACCOUNT_DISABLED" ||
          error.code == "ACCOUNT_DELETED";
    }
    return false;
  }

  Future<void> _handlePermanentFailure() async {
    // CRITICAL CHANGE: Don't clear tokens or logout automatically
    // Just log the issue
    _log.severe("⚠️ Permanent failure detected, but user must manually logout");
    _log.severe("⚠️ Token refresh will keep retrying in case server recovers");

    // Don't clear tokens
    // await storage.clearTokens();
    // _tokens = null;

    _consecutiveRefreshFailures = 0;
    _lastSuccessfulRefresh = null;

    // Don't stop monitoring - keep trying
    // _stopExpiryMonitoring();
    // _stopPeriodicRefresh();

    // Don't set sessionInvalid - stay authenticated
    // _setStatus(AuthStatus.sessionInvalid);

    // Keep the user logged in
    _log.warning("⚠️ User remains logged in despite server errors");
  }


  // ------------------------------------------------------
  // GET VALID ACCESS TOKEN
  // ------------------------------------------------------
  Future<String?> getValidAccessToken() async {
    if (_tokens == null) {
      _log.warning("No tokens available");
      return null;
    }

    // Add buffer time (10 seconds) to prevent race conditions
    final bufferTime = DateTime.now().add(const Duration(seconds: 10));

    if (_tokens!.accessTokenExpiry.isAfter(bufferTime)) {
      return _tokens!.accessToken;
    }

    _log.info("Token expiring soon, refreshing...");
    try {
      final refreshed = await _performRefresh();
      return refreshed.accessToken;
    } catch (e) {
      _log.warning("Failed to refresh token: $e");

      // IMPORTANT: If refresh fails but we still have tokens, return them
      // The API might be lenient or the network might come back
      if (_tokens != null && !_isPermanentError(e)) {
        _log.warning("⚠️ Returning potentially expired token as fallback");
        return _tokens!.accessToken;
      }
      return null;
    }
  }

  // ------------------------------------------------------
  // EXPIRY MONITORING
  // ------------------------------------------------------
  void _startExpiryMonitoring() {
    _stopExpiryMonitoring();

    if (_tokens == null) return;

    final expiry = _tokens!.accessTokenExpiry;
    final now = DateTime.now();

    if (expiry.isBefore(now)) {
      _log.warning("Token already expired, triggering immediate refresh");
      _performRefresh().catchError((e) {
        _log.warning("Auto-refresh failed: $e");
      });
      return;
    }

    final refreshTime = expiry.subtract(expiringSoonThreshold);
    final delay = refreshTime.difference(now);

    if (delay.isNegative) {
      _log.info("Token expiring soon, triggering immediate refresh");
      _performRefresh().catchError((e) {
        _log.warning("Auto-refresh failed: $e");
      });
    } else {
      _log.info("📅 Scheduled refresh in ${delay.inSeconds}s");
      _expiryCheckTimer = Timer(delay, () {
        _log.info("⏰ Timer fired: triggering refresh");
        _performRefresh().catchError((e) {
          _log.warning("Auto-refresh failed: $e");
        });
      });
    }
  }

  void _stopExpiryMonitoring() {
    _expiryCheckTimer?.cancel();
    _expiryCheckTimer = null;
  }

  // ------------------------------------------------------
  // PERIODIC REFRESH (Backup mechanism)
  // ------------------------------------------------------
  void _startPeriodicRefresh() {
    _stopPeriodicRefresh();

    // Refresh every 10 minutes as a backup
    _periodicRefreshTimer = Timer.periodic(
      const Duration(minutes: 10),
          (timer) {
        if (_tokens != null && _currentStatus != AuthStatus.sessionInvalid) {
          _log.info("🔄 Periodic refresh check");
          // Only refresh if token is expiring soon
          final expiresIn = _tokens!.accessTokenExpiry.difference(DateTime.now());
          if (expiresIn.inMinutes < 5) {
            _log.info("Token expiring in ${expiresIn.inMinutes}m, refreshing");
            _performRefresh().catchError((e) {
              _log.warning("Periodic refresh failed: $e");
            });
          }
        }
      },
    );
  }

  void _stopPeriodicRefresh() {
    _periodicRefreshTimer?.cancel();
    _periodicRefreshTimer = null;
  }

  // ------------------------------------------------------
  // HEALTH CHECK
  // ------------------------------------------------------
  bool isHealthy() {
    if (_tokens == null) return false;
    if (_tokens!.refreshTokenExpiry.isBefore(DateTime.now())) return false;
    return isAuthenticated || _currentStatus == AuthStatus.expiringSoon;
  }

  Map<String, dynamic> getHealthMetrics() {
    return {
      'isAuthenticated': isAuthenticated,
      'currentStatus': _currentStatus.toString(),
      'hasTokens': _tokens != null,
      'consecutiveFailures': _consecutiveRefreshFailures,
      'lastSuccessfulRefresh': _lastSuccessfulRefresh?.toIso8601String(),
      'accessTokenExpiry': _tokens?.accessTokenExpiry.toIso8601String(),
      'refreshTokenExpiry': _tokens?.refreshTokenExpiry.toIso8601String(),
      'isHealthy': isHealthy(),
    };
  }

  // ------------------------------------------------------
  // DISPOSE
  // ------------------------------------------------------
  void dispose() {
    _stopExpiryMonitoring();
    _stopPeriodicRefresh();
    _authStatusController.close();
    _log.info("AuthManager disposed");
  }
}