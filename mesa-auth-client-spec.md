Purpose

A Dart client library providing secure JWT authentication, refresh token handling, session management, and reactive auth state monitoring, tailored for your backend microservices + PowerSync.

1. Core Responsibilities

Manage:

Access token

Refresh token

Session ID

Expiry timestamps

Persist session securely with token storage.

Automatically refresh access tokens using a graceful refresh strategy.

Integrate with PowerSync via:

fetchCredentials()

invalidateCredentials()

Expose a reactive auth state stream.

Provide high-level authentication APIs:

login

logout

refresh

loadSessionOnStartup

Provide robust error handling:

network errors

expired tokens

revoked sessions

server-side invalidated sessions

2. Package Structure
lib/
  ├─ auth_client.dart
  ├─ src/
  │    ├─ auth_manager.dart
  │    ├─ session_storage.dart
  │    ├─ api_client.dart
  │    ├─ refresh_mutex.dart
  │    ├─ models/
  │    │    ├─ auth_tokens.dart
  │    │    ├─ auth_status.dart
  │    │    ├─ auth_error.dart
  │    └─ powersync_connector.dart
  └─ dart_auth_client.dart

3. Models
3.1 AuthTokens
class AuthTokens {
  final String accessToken;
  final String refreshToken;
  final String sessionId;

  final DateTime accessTokenExpiry;
  final DateTime refreshTokenExpiry;

  AuthTokens(...);
}

3.2 AuthStatus
enum AuthStatus {
  unknown,        // not loaded yet
  authenticated,  
  expiringSoon,   // optional (< 30s)
  refreshing,
  unauthenticated,
  sessionInvalid, // blacklisted / revoked
}

3.3 AuthError
class AuthError implements Exception {
  final String code;     // e.g. NOT_LOGGED_IN, NETWORK_ERROR, SESSION_REVOKED
  final String message;
}

4. Session Storage (Secure)

Interface:

abstract class SessionStorage {
  Future<void> saveTokens(AuthTokens tokens);
  Future<AuthTokens?> loadTokens();
  Future<void> clearTokens();
}


Implementation options:

FlutterSecureStorage (mobile)

SharedPreferences (fallback)

Web LocalStorage (if needed)

Tokens should always be encrypted / secure.

5. API Client

Endpoints (all configurable):

POST /auth/login → returns tokens

POST /auth/refresh → returns tokens

POST /auth/logout → revokes refresh token + session ID

Methods:

Future<AuthTokens> login(String email, String password);
Future<AuthTokens> refresh(String sessionId, String refreshToken);
Future<void> logout(String sessionId, String refreshToken);


Handle:

network errors

401 / 403 responses

JSON parsing errors

backend error objects

6. Auth Manager (Core Brain of Library)
Responsibilities

Holds session in memory

Refreshes tokens via RefreshMutex

Exposes authStatus$

Exposes full auth lifecycle API

6.1 State
AuthTokens? _tokens;
AuthStatus _currentStatus = AuthStatus.unknown;

final _authStatusController = StreamController<AuthStatus>.broadcast();


State setter:

void _setStatus(AuthStatus status);

6.2 Public API of AuthManager
class AuthManager {
  Stream<AuthStatus> get authStatus$;
  AuthStatus get currentStatus;

  Future<void> initialize();   // Load from storage
  Future<void> login(...);
  Future<void> logout();

  Future<AuthTokens?> getValidAccessToken(); 
  Future<AuthTokens> gracefulRefresh();   

  bool get isAuthenticated;
}

6.3 Initialization Flow
initialize()

Load tokens from storage.

If none → status = unauthenticated.

If access token still valid → authenticated.

If expired → call gracefulRefresh().

Status transitions:

unknown → refreshing → authenticated
unknown → unauthenticated

6.4 Login Flow
Future<void> login(email, password) async {
  final tokens = await api.login(...);
  await storage.saveTokens(tokens);
  _tokens = tokens;
  _setStatus(AuthStatus.authenticated);
}

6.5 Logout Flow
Future<void> logout() async {
  if (_tokens != null) {
    await api.logout(_tokens!.sessionId, _tokens!.refreshToken);
  }

  await storage.clearTokens();
  _tokens = null;
  _setStatus(AuthStatus.unauthenticated);
}

6.6 Token Auto-Refresh (Graceful)

No timers. No redundant refreshes. Prevents parallel refresh calls.

A RefreshMutex holds the running refresh future:

class RefreshMutex {
  Future<T> run<T>(Future<T> Function() task);
}

gracefulRefresh()
Future<AuthTokens> gracefulRefresh() async {
  return _mutex.run(() async {
    if (_tokens == null) throw AuthError("NOT_LOGGED_IN");

    _setStatus(AuthStatus.refreshing);

    try {
      final newTokens = await api.refresh(
        _tokens!.sessionId,
        _tokens!.refreshToken,
      );

      _tokens = newTokens;
      await storage.saveTokens(newTokens);

      _setStatus(AuthStatus.authenticated);
      return newTokens;

    } on AuthError catch (e) {
      if (e.code == "SESSION_REVOKED") {
        await storage.clearTokens();
        _tokens = null;
        _setStatus(AuthStatus.sessionInvalid);
        rethrow;
      }
      rethrow;
    }
  });
}

6.7 Retrieving a Valid Access Token
Future<String?> getValidAccessToken() async {
  if (_tokens == null) return null;

  if (_tokens!.accessTokenExpiry.isAfter(DateTime.now())) {
    return _tokens!.accessToken;
  }

  try {
    final refreshed = await gracefulRefresh();
    return refreshed.accessToken;
  } catch (_) {
    return null;
  }
}

7. PowerSync Integration

A PowerSyncAuthConnector implementation.

fetchCredentials()

Uses latest token; auto-refresh if needed:

final token = await authManager.getValidAccessToken();
return PowerSyncCredentials(
  endpoint: Env.powersyncUrl,
  token: token,
  userId: user.id,
  expiresAt: tokens.accessTokenExpiry,
);

invalidateCredentials()

Called by PowerSync when token rejected:

@override
Future<void> invalidateCredentials() async {
  try {
    _setStatus(AuthStatus.refreshing);
    await authManager.gracefulRefresh();
  } catch (_) {
    await authManager.logout();
  }
}

8. Reactive Authentication Stream
Stream<AuthStatus> authStatus$

Emits:

unknown

authenticated

expiringSoon (optional)

refreshing

unauthenticated

sessionInvalid

Updates only on actual change.

Example usage:

auth.authStatus$.listen((status) {
  switch (status) {
    case AuthStatus.authenticated:
      // navigate to dashboard
      break;

    case AuthStatus.refreshing:
      // show loading overlay
      break;

    case AuthStatus.unauthenticated:
      // go to login page
      break;

    case AuthStatus.sessionInvalid:
      dialog("Session revoked");
      break;
  }
});

9. Error Handling Rules
Error Codes

"NETWORK_ERROR"

"SESSION_REVOKED"

"INVALID_REFRESH_TOKEN"

"TOKEN_EXPIRED"

"NOT_LOGGED_IN"

Behaviors
Error	Action	Stream event
refresh token invalid	clear storage + logout	sessionInvalid
session revoked in Redis	clear storage	sessionInvalid
access token expired	trigger gracefulRefresh()	refreshing → authenticated
backend returns 500	retry handled by caller	no state change
10. Configuration Options
class AuthConfig {
  final String baseUrl;
  final Duration expiringSoonThreshold; // default: 30s
  final Duration refreshTimeout;        // default: 5s
  final SessionStorage storage;
}

11. Public Entry Point

dart_auth_client.dart exports:

export 'src/auth_manager.dart';
export 'src/models/auth_tokens.dart';
export 'src/models/auth_status.dart';
export 'src/models/auth_error.dart';
export 'src/powersync_connector.dart';

12. Optional Future Extensions

biometric login guard

OAuth login providers

multi-device session sync

token replay detection

SSO session linking