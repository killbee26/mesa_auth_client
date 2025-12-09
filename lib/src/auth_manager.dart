// import 'dart:async';
// import 'package:logging/logging.dart';
// import 'package:mesa_auth_client/mesa_auth_client.dart';

// import 'models/auth_tokens.dart';
// import 'models/auth_status.dart';
// import 'models/auth_error.dart';
// import 'session_storage.dart';
// import 'api_client.dart';
// import 'refresh_mutex.dart';

// class AuthManager {
//   final _log = Logger('AuthManager');

//   AuthTokens? _tokens;
//   AuthStatus _currentStatus = AuthStatus.unknown;

//   final _authStatusController = StreamController<AuthStatus>.broadcast();
//   final RefreshMutex _mutex = RefreshMutex();
  
//   // Debouncing flag to prevent multiple refresh calls
//   bool _refreshInProgress = false;

//   final AuthConfig config;
//   final ApiClient api;

//   SessionStorage get storage => config.storage;
//   Duration get expiringSoonThreshold => config.expiringSoonThreshold;
//   AuthTokens? get tokens => _tokens;

//   AuthManager({
//     required this.config,
//     required this.api,
//   });

//   set tokens(AuthTokens? tokens) {
//     _tokens = tokens;
//     _log.info("Tokens manually set: $_tokens");
//   }

//   Stream<AuthStatus> get authStatus$ => _authStatusController.stream;
//   AuthStatus get currentStatus => _currentStatus;
//   bool get isAuthenticated => _currentStatus == AuthStatus.authenticated;

//   void _setStatus(AuthStatus status) {
//     if (_currentStatus != status) {
//       _currentStatus = status;
//       _authStatusController.add(status);
//       _log.info("Auth status changed: $_currentStatus");
//     }
//   }

//   // ------------------------------------------------------
//   // INITIALIZATION
//   // ------------------------------------------------------
//   Future<void> initialize() async {
//     _log.info("Initializing AuthManager...");
//     final tokens = await storage.loadTokens();

//     if (tokens == null) {
//       _tokens = null;
//       _setStatus(AuthStatus.unauthenticated);
//       _log.info("No tokens found → unauthenticated");
//       return;
//     }

//     _tokens = tokens;
//     _log.info("Loaded tokens: accessToken=${tokens.accessToken.substring(0, 20)}..., refreshToken=${tokens.refreshToken.substring(0, 20)}...");
//     _log.info("Access token expiry: ${tokens.accessTokenExpiry}");

//     if (tokens.accessTokenExpiry.isAfter(DateTime.now())) {
//       _setStatus(AuthStatus.authenticated);
//       _checkExpiringSoon();
//       _log.info("Access token valid → authenticated");
//       return;
//     }

//     // Access token expired but we have a refresh token
//     _log.warning("Access token expired, will attempt refresh...");
//     // Don't set unauthenticated yet - keep tokens for refresh
//   }

//   Future<void> initializeAndRefresh() async {
//     await initialize();
    
//     // If we have tokens but access token is expired, try to refresh
//     if (_tokens != null && _tokens!.accessTokenExpiry.isBefore(DateTime.now())) {
//       _log.info("Access token expired during initialization, attempting refresh...");
//       try {
//         await _performRefresh();
//         _log.info("Successfully refreshed expired token during initialization");
//       } catch (e) {
//         _log.warning("Failed to refresh expired token during initialization: $e");
//         // Clear tokens and set unauthenticated on failure
//         await storage.clearTokens();
//         _tokens = null;
//         _setStatus(AuthStatus.unauthenticated);
//       }
//     } else if (_tokens == null) {
//       _setStatus(AuthStatus.unauthenticated);
//     }
//   }

//   // ------------------------------------------------------
//   // LOGIN
//   // ------------------------------------------------------
//   Future<void> login(String id, String password, String phone) async {
//     _log.info("Attempting login for $phone");
//     try {
//       final tokens = await api.login(id, password, phone);
//       await storage.saveTokens(tokens);
//       _tokens = tokens;
//       _refreshInProgress = false; // Reset flag on new login
//       _setStatus(AuthStatus.authenticated);
//       _checkExpiringSoon();
//       _log.info("Login successful → authenticated");
//     } catch (e) {
//       _setStatus(AuthStatus.unauthenticated);
//       _log.severe("Login failed: $e");
//       rethrow;
//     }
//   }

//   // ------------------------------------------------------
//   // LOGOUT
//   // ------------------------------------------------------
//   Future<void> logout() async {
//     _log.info("Logging out...");
//     if (_tokens != null) {
//       try {
//         await api.logout(_tokens!.sessionId, _tokens!.refreshToken);
//         _log.info("API logout successful");
//       } catch (e) {
//         _log.warning("Logout API error: $e");
//       }
//     }

//     await storage.clearTokens();
//     _tokens = null;
//     _refreshInProgress = false; // Reset flag on logout
//     _setStatus(AuthStatus.unauthenticated);
//     _log.info("Local tokens cleared → unauthenticated");
//   }

//   // ------------------------------------------------------
//   // GRACEFUL REFRESH (with debouncing)
//   // ------------------------------------------------------
//   Future<AuthTokens> gracefulRefresh() async {
//     if (_tokens == null) {
//       _setStatus(AuthStatus.unauthenticated);
//       _log.warning("No tokens available to refresh → unauthenticated");
//       throw AuthError(code: "NOT_LOGGED_IN", message: "Not logged in");
//     }

//     // Debouncing: Skip if refresh is already in progress
//     if (_refreshInProgress) {
//       _log.info("Refresh already in progress, skipping duplicate call");
//       throw AuthError(
//         code: "REFRESH_IN_PROGRESS",
//         message: "Token refresh already in progress",
//       );
//     }

//     return _performRefresh();
//   }

//   // Internal method that does the actual refresh work
//   Future<AuthTokens> _performRefresh() async {
//     if (_tokens == null) {
//       throw AuthError(code: "NOT_LOGGED_IN", message: "Not logged in");
//     }

//     _log.info("Starting token refresh...");
    
//     return _mutex.run(() async {
//       _refreshInProgress = true;
//       _setStatus(AuthStatus.refreshing);
      
//       _log.info("Refreshing tokens for sessionId=${_tokens!.sessionId}");
//       _log.info("Using refreshToken: ${_tokens!.refreshToken.substring(0, 20)}...");

//       try {
//         final newTokens = await api.refresh(
//           _tokens!.sessionId,
//           _tokens!.refreshToken,
//         );

//         _tokens = newTokens;
//         await storage.saveTokens(newTokens);

//         _log.info("New tokens received: accessToken=${newTokens.accessToken.substring(0, 20)}...");
//         _log.info("New access token expiry: ${newTokens.accessTokenExpiry}");

//         _setStatus(AuthStatus.authenticated);
//         _checkExpiringSoon();
//         _log.info("Refresh successful → authenticated");
        
//         return newTokens;
//       } on AuthError catch (e) {
//         _log.severe("AuthError during refresh: ${e.code} - ${e.message}");
        
//         if (e.code == "SESSION_REVOKED" || e.code == "UNAUTHORIZED") {
//           await storage.clearTokens();
//           _tokens = null;
//           _setStatus(e.code == "SESSION_REVOKED" 
//             ? AuthStatus.sessionInvalid 
//             : AuthStatus.unauthenticated);
//           _log.warning("${e.code} → ${_currentStatus}");
//           return Future.error(e);
//         }

//         _setStatus(AuthStatus.unauthenticated);
//         return Future.error(e);
//       } catch (e) {
//         _setStatus(AuthStatus.unauthenticated);
//         _log.severe("Unknown error during refresh: $e");
//         return Future.error(e);
//       } finally {
//         _refreshInProgress = false; // Always reset the flag
//       }
//     });
//   }

//   // ------------------------------------------------------
//   // GET VALID ACCESS TOKEN
//   // ------------------------------------------------------
//   Future<String?> getValidAccessToken() async {
//     if (_tokens == null) {
//       _log.warning("No tokens available");
//       return null;
//     }

//     _log.info("Checking token validity, expires at: ${_tokens!.accessTokenExpiry}");

//     if (_tokens!.accessTokenExpiry.isAfter(DateTime.now())) {
//       _checkExpiringSoon();
//       return _tokens!.accessToken;
//     }

//     _log.info("Access token expired, attempting refresh...");
//     try {
//       final refreshed = await _performRefresh();
//       return refreshed.accessToken;
//     } catch (e) {
//       _log.warning("Failed to get valid access token: $e");
//       return null;
//     }
//   }

//   // ------------------------------------------------------
//   // EXPIRING SOON CHECK
//   // ------------------------------------------------------
//   void _checkExpiringSoon() {
//     if (_tokens == null) return;

//     final expiry = _tokens!.accessTokenExpiry;
//     final diff = expiry.difference(DateTime.now());
//     if (expiry.isAfter(DateTime.now()) && diff <= expiringSoonThreshold) {
//       _setStatus(AuthStatus.expiringSoon);
//       _log.info("Access token expiring soon in ${diff.inSeconds} seconds");
//     }
//   }

//   // ------------------------------------------------------
//   // DISPOSE
//   // ------------------------------------------------------
//   void dispose() {
//     _authStatusController.close();
//     _log.info("AuthManager disposed");
//   }
// }

import 'dart:async';
import 'package:logging/logging.dart';
import 'package:mesa_auth_client/mesa_auth_client.dart';

import 'models/auth_tokens.dart';
import 'models/auth_status.dart';
import 'models/auth_error.dart';
import 'session_storage.dart';
import 'api_client.dart';
import 'refresh_mutex.dart';

class AuthManager {
  final _log = Logger('AuthManager');

  AuthTokens? _tokens;
  AuthStatus _currentStatus = AuthStatus.unknown;

  final _authStatusController = StreamController<AuthStatus>.broadcast();
  final RefreshMutex _mutex = RefreshMutex();
  
  // Debouncing flag to prevent multiple refresh calls
  bool _refreshInProgress = false;

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
    _log.info("Tokens manually set: $_tokens");
  }

  Stream<AuthStatus> get authStatus$ => _authStatusController.stream;
  AuthStatus get currentStatus => _currentStatus;
  bool get isAuthenticated => _currentStatus == AuthStatus.authenticated;

  void _setStatus(AuthStatus status) {
    if (_currentStatus != status) {
      _currentStatus = status;
      _authStatusController.add(status);
      _log.info("Auth status changed: $_currentStatus");
    }
  }

  // ------------------------------------------------------
  // INITIALIZATION
  // ------------------------------------------------------
  Future<void> initialize() async {
    _log.info("Initializing AuthManager...");
    final tokens = await storage.loadTokens();

    if (tokens == null) {
      _tokens = null;
      _setStatus(AuthStatus.unauthenticated);
      _log.info("No tokens found → unauthenticated");
      return;
    }

    _tokens = tokens;
    _log.info("Loaded tokens: accessToken=${tokens.accessToken.substring(0, 20)}..., refreshToken=${tokens.refreshToken.substring(0, 20)}...");
    _log.info("Access token expiry: ${tokens.accessTokenExpiry}");

    if (tokens.accessTokenExpiry.isAfter(DateTime.now())) {
      _setStatus(AuthStatus.authenticated);
      _checkExpiringSoon();
      _log.info("Access token valid → authenticated");
      return;
    }

    // Access token expired but we have a refresh token
    _log.warning("Access token expired, will attempt refresh...");
    // Don't set unauthenticated yet - keep tokens for refresh
  }

  Future<void> initializeAndRefresh() async {
    await initialize();
    
    // If we have tokens but access token is expired, try to refresh
    if (_tokens != null && _tokens!.accessTokenExpiry.isBefore(DateTime.now())) {
      _log.info("Access token expired during initialization, attempting refresh...");
      try {
        await _performRefresh();
        _log.info("Successfully refreshed expired token during initialization");
      } catch (e) {
        _log.warning("Failed to refresh expired token during initialization: $e");
        // Clear tokens and set unauthenticated on failure
        await storage.clearTokens();
        _tokens = null;
        _setStatus(AuthStatus.unauthenticated);
      }
    } else if (_tokens == null) {
      _setStatus(AuthStatus.unauthenticated);
    }
  }

  // ------------------------------------------------------
  // LOGIN
  // ------------------------------------------------------
  Future<void> login(String id, String password, String phone) async {
    _log.info("Attempting login for $phone");
    try {
      final tokens = await api.login(id, password, phone);
      await storage.saveTokens(tokens);
      _tokens = tokens;
      _refreshInProgress = false; // Reset flag on new login
      _setStatus(AuthStatus.authenticated);
      _checkExpiringSoon();
      _log.info("Login successful → authenticated");
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
    _log.info("Logging out...");
    
    if (_tokens != null) {
      try {
        await api.logout(_tokens!.sessionId, _tokens!.accessToken);
        _log.info("API logout successful");
      } catch (e) {
        _log.warning("Logout API error: $e");
      }
    }

    await storage.clearTokens();
    _tokens = null;
    _refreshInProgress = false; // Reset flag on logout
    _setStatus(AuthStatus.unauthenticated);
    _log.info("Local tokens cleared → unauthenticated");
  }

  // ------------------------------------------------------
  // GRACEFUL REFRESH (with debouncing)
  // ------------------------------------------------------
  Future<AuthTokens> gracefulRefresh() async {
    if (_tokens == null) {
      _setStatus(AuthStatus.unauthenticated);
      _log.warning("No tokens available to refresh → unauthenticated");
      throw AuthError(code: "NOT_LOGGED_IN", message: "Not logged in");
    }

    // Debouncing: Skip if refresh is already in progress
    if (_refreshInProgress) {
      _log.info("Refresh already in progress, skipping duplicate call");
      throw AuthError(
        code: "REFRESH_IN_PROGRESS",
        message: "Token refresh already in progress",
      );
    }

    return _performRefresh();
  }

  // Internal method that does the actual refresh work
  Future<AuthTokens> _performRefresh() async {
    if (_tokens == null) {
      throw AuthError(code: "NOT_LOGGED_IN", message: "Not logged in");
    }

    _log.info("Starting token refresh...");
    
    return _mutex.run(() async {
      _refreshInProgress = true;
      _setStatus(AuthStatus.refreshing);
      
      _log.info("Refreshing tokens for sessionId=${_tokens!.sessionId}");
      _log.info("Using refreshToken: ${_tokens!.refreshToken.substring(0, 20)}...");

      try {
        final newTokens = await api.refresh(
          _tokens!.sessionId,
          _tokens!.refreshToken,
        );

        _tokens = newTokens;
        await storage.saveTokens(newTokens);

        _log.info("New tokens received: accessToken=${newTokens.accessToken.substring(0, 20)}...");
        _log.info("New access token expiry: ${newTokens.accessTokenExpiry}");

        _setStatus(AuthStatus.authenticated);
        _checkExpiringSoon();
        _log.info("Refresh successful → authenticated");
        
        return newTokens;
      } on AuthError catch (e) {
        _log.severe("AuthError during refresh: ${e.code} - ${e.message}");
        
        if (e.code == "SESSION_REVOKED" || e.code == "UNAUTHORIZED") {
          await storage.clearTokens();
          _tokens = null;
          _setStatus(e.code == "SESSION_REVOKED" 
            ? AuthStatus.sessionInvalid 
            : AuthStatus.unauthenticated);
          _log.warning("${e.code} → ${_currentStatus}");
          return Future.error(e);
        }

        _setStatus(AuthStatus.unauthenticated);
        return Future.error(e);
      } catch (e) {
        _setStatus(AuthStatus.unauthenticated);
        _log.severe("Unknown error during refresh: $e");
        return Future.error(e);
      } finally {
        _refreshInProgress = false; // Always reset the flag
      }
    });
  }

  // ------------------------------------------------------
  // GET VALID ACCESS TOKEN
  // ------------------------------------------------------
  Future<String?> getValidAccessToken() async {
    if (_tokens == null) {
      _log.warning("No tokens available");
      return null;
    }

    _log.info("Checking token validity, expires at: ${_tokens!.accessTokenExpiry}");

    if (_tokens!.accessTokenExpiry.isAfter(DateTime.now())) {
      _checkExpiringSoon();
      return _tokens!.accessToken;
    }

    _log.info("Access token expired, attempting refresh...");
    try {
      final refreshed = await _performRefresh();
      return refreshed.accessToken;
    } catch (e) {
      _log.warning("Failed to get valid access token: $e");
      return null;
    }
  }

  // ------------------------------------------------------
  // EXPIRING SOON CHECK
  // ------------------------------------------------------
  void _checkExpiringSoon() {
    if (_tokens == null) return;

    final expiry = _tokens!.accessTokenExpiry;
    final diff = expiry.difference(DateTime.now());
    if (expiry.isAfter(DateTime.now()) && diff <= expiringSoonThreshold) {
      _setStatus(AuthStatus.expiringSoon);
      _log.info("Access token expiring soon in ${diff.inSeconds} seconds");
      
      // Automatically trigger refresh when expiring soon
      _log.info("Triggering automatic token refresh...");
      _performRefresh().catchError((e) {
        _log.warning("Automatic refresh failed: $e");
      });
    }
  }

  // ------------------------------------------------------
  // DISPOSE
  // ------------------------------------------------------
  void dispose() {
    _authStatusController.close();
    _log.info("AuthManager disposed");
  }
}