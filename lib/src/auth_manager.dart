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
  static const int _maxConsecutiveFailures = 10;

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
    _log.info("⚠️ EXPLICIT LOGOUT - User intentionally logging out");

    _stopExpiryMonitoring();
    _stopPeriodicRefresh();
    _consecutiveRefreshFailures = 0;
    _lastSuccessfulRefresh = null;

    if (_tokens != null) {
      try {
        await api.logout(_tokens!.sessionId, _tokens!.accessToken)
            .timeout(const Duration(seconds: 5));
        _log.info("API logout successful");
      } catch (e) {
        _log.warning("Logout API error (non-critical): $e");
      }
    }

    await storage.clearTokens();
    _tokens = null;
    _setStatus(AuthStatus.sessionInvalid);
    _log.info("Logged out");
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
          maxAttempts: 3,
          initialDelay: const Duration(seconds: 1),
          maxDelay: const Duration(seconds: 10),
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

        // CRITICAL: Only logout on permanent errors from server
        if (_isPermanentError(e)) {
          _log.severe("🚫 Permanent error detected: ${e.code}");
          await _handlePermanentFailure();
          return Future.error(e);
        }

        // For non-permanent errors, check if we should keep trying
        if (_shouldKeepTrying()) {
          _log.warning("⚠️ Temporary failure, will keep trying");
          _setStatus(previousStatus == AuthStatus.authenticated
              ? AuthStatus.authenticated
              : AuthStatus.expiringSoon);
          _scheduleBackgroundRefresh();
        } else {
          _log.severe("🚫 Too many failures, marking session invalid");
          await _handlePermanentFailure();
        }

        return Future.error(e);
      } catch (e) {
        _consecutiveRefreshFailures++;
        _log.severe("❌ Refresh error #$_consecutiveRefreshFailures: $e");

        if (_shouldKeepTrying()) {
          _log.warning("⚠️ Network error, will keep trying");
          _setStatus(previousStatus == AuthStatus.authenticated
              ? AuthStatus.authenticated
              : AuthStatus.expiringSoon);
          _scheduleBackgroundRefresh();
        } else {
          _log.severe("🚫 Too many network failures, marking session invalid");
          await _handlePermanentFailure();
        }

        return Future.error(e);
      }
    });
  }

  bool _shouldKeepTrying() {
    // If we've exceeded max failures AND it's been less than 5 minutes since last success,
    // keep the session alive
    if (_consecutiveRefreshFailures >= _maxConsecutiveFailures) {
      if (_lastSuccessfulRefresh != null) {
        final timeSinceSuccess = DateTime.now().difference(_lastSuccessfulRefresh!);
        if (timeSinceSuccess.inMinutes < 5) {
          _log.info("⏰ Last success was ${timeSinceSuccess.inMinutes}m ago, keeping session");
          return true;
        }
      }
      return false;
    }
    return true;
  }

  void _scheduleBackgroundRefresh() {
    // Schedule a retry in 30 seconds
    _log.info("📅 Scheduling background refresh in 30s");
    Future.delayed(const Duration(seconds: 30), () {
      if (_tokens != null && _currentStatus != AuthStatus.sessionInvalid) {
        _log.info("🔄 Background refresh attempt");
        _performRefresh().catchError((e) {
          _log.warning("Background refresh failed: $e");
        });
      }
    });
  }

  bool _isPermanentError(dynamic error) {
    if (error is AuthError) {
      // These are REAL permanent errors from the server
      return error.code == "SESSION_REVOKED" ||
          error.code == "INVALID_REFRESH_TOKEN" ||
          error.code == "REFRESH_TOKEN_EXPIRED";
    }
    return false;
  }

  Future<void> _handlePermanentFailure() async {
    await storage.clearTokens();
    _tokens = null;
    _consecutiveRefreshFailures = 0;
    _lastSuccessfulRefresh = null;
    _stopExpiryMonitoring();
    _stopPeriodicRefresh();
    _setStatus(AuthStatus.sessionInvalid);
    _log.warning("⚠️ Session permanently invalid");
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