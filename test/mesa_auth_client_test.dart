import 'package:mesa_auth_client/src/auth_manager.dart';
import 'package:mesa_auth_client/src/api_client.dart';
import 'package:mesa_auth_client/src/session_storage.dart';
import 'package:mesa_auth_client/src/models/auth_tokens.dart';
import 'package:mesa_auth_client/src/models/auth_status.dart';
import 'package:mesa_auth_client/src/models/auth_error.dart';

import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:test/test.dart';

import 'mesa_auth_client_test.mocks.dart';

@GenerateMocks([ApiClient, SessionStorage])
void main() {
  group('AuthManager', () {
    late AuthManager authManager;
    late MockApiClient mockApiClient;
    late MockSessionStorage mockSessionStorage;

    setUp(() {
      mockApiClient = MockApiClient();
      mockSessionStorage = MockSessionStorage();

      authManager = AuthManager(
        api: mockApiClient,
        storage: mockSessionStorage,
        expiringSoonThreshold: Duration(seconds: 30),
      );
    });

    tearDown(() {
      reset(mockApiClient);
      reset(mockSessionStorage);
    });

    test('initialize → no tokens → unauthenticated', () async {
      when(mockSessionStorage.loadTokens()).thenAnswer((_) async => null);

      await authManager.initialize();

      expect(authManager.currentStatus, AuthStatus.unauthenticated);
      verify(mockSessionStorage.loadTokens()).called(1);
    });

    test('initialize → valid tokens → authenticated', () async {
      final now = DateTime.now();
      final tokens = AuthTokens(
        accessToken: 'test',
        refreshToken: 'refresh',
        sessionId: 'session',
        accessTokenExpiry: now.add(Duration(minutes: 5)),
        refreshTokenExpiry: now.add(Duration(days: 30)),
      );

      when(mockSessionStorage.loadTokens()).thenAnswer((_) async => tokens);

      await authManager.initialize();

      expect(authManager.currentStatus, AuthStatus.authenticated);
      verify(mockSessionStorage.loadTokens()).called(1);
    });

    test('initialize → expired tokens → unauthenticated (NO auto-refresh)', () async {
      final now = DateTime.now();
      final expiredTokens = AuthTokens(
        accessToken: 'test',
        refreshToken: 'refresh',
        sessionId: 'session',
        accessTokenExpiry: now.subtract(Duration(minutes: 5)),
        refreshTokenExpiry: now.add(Duration(days: 30)),
      );

      when(mockSessionStorage.loadTokens()).thenAnswer((_) async => expiredTokens);

      await authManager.initialize();

      expect(authManager.currentStatus, AuthStatus.unauthenticated);
      verifyNever(mockApiClient.refresh(any, any)); // important!
    });

    test('initializeAndRefresh → expired tokens → refreshes successfully', () async {
      final now = DateTime.now();

      final expiredTokens = AuthTokens(
        accessToken: 'old',
        refreshToken: 'refresh',
        sessionId: 'session',
        accessTokenExpiry: now.subtract(Duration(minutes: 5)),
        refreshTokenExpiry: now.add(Duration(days: 30)),
      );

      final refreshedTokens = AuthTokens(
        accessToken: 'new_access',
        refreshToken: 'refresh',
        sessionId: 'session',
        accessTokenExpiry: now.add(Duration(minutes: 5)),
        refreshTokenExpiry: now.add(Duration(days: 30)),
      );

      when(mockSessionStorage.loadTokens()).thenAnswer((_) async => expiredTokens);
      when(mockApiClient.refresh(expiredTokens.sessionId, expiredTokens.refreshToken))
          .thenAnswer((_) async => refreshedTokens);
      when(mockSessionStorage.saveTokens(refreshedTokens)).thenAnswer((_) async {});

      await authManager.initializeAndRefresh();

      expect(authManager.currentStatus, AuthStatus.authenticated);
      expect(authManager.isAuthenticated, true);

      verify(mockApiClient.refresh(expiredTokens.sessionId, expiredTokens.refreshToken))
          .called(1);
      verify(mockSessionStorage.saveTokens(refreshedTokens)).called(1);
    });

    test('login → stores tokens and becomes authenticated', () async {
      final now = DateTime.now();

      final tokens = AuthTokens(
        accessToken: 'access',
        refreshToken: 'refresh',
        sessionId: 'session',
        accessTokenExpiry: now.add(Duration(minutes: 5)),
        refreshTokenExpiry: now.add(Duration(days: 30)),
      );

      when(mockApiClient.login(any, any)).thenAnswer((_) async => tokens);
      when(mockSessionStorage.saveTokens(tokens)).thenAnswer((_) async {});

      await authManager.login('email', 'pass');

      expect(authManager.currentStatus, AuthStatus.authenticated);
      verify(mockApiClient.login('email', 'pass')).called(1);
      verify(mockSessionStorage.saveTokens(tokens)).called(1);
    });

    test('logout → clears tokens and becomes unauthenticated', () async {
      final now = DateTime.now();

      final tokens = AuthTokens(
        accessToken: 'access',
        refreshToken: 'refresh',
        sessionId: 'session',
        accessTokenExpiry: now.add(Duration(minutes: 5)),
        refreshTokenExpiry: now.add(Duration(days: 30)),
      );

      when(mockApiClient.login(any, any)).thenAnswer((_) async => tokens);
      when(mockSessionStorage.saveTokens(tokens)).thenAnswer((_) async {});
      when(mockApiClient.logout(tokens.sessionId, tokens.refreshToken))
          .thenAnswer((_) async {});
      when(mockSessionStorage.clearTokens()).thenAnswer((_) async {});

      await authManager.login('email', 'pass');
      await authManager.logout();

      expect(authManager.currentStatus, AuthStatus.unauthenticated);

      verify(mockApiClient.logout(tokens.sessionId, tokens.refreshToken)).called(1);
      verify(mockSessionStorage.clearTokens()).called(1);
    });

    test('gracefulRefresh → refreshes successfully', () async {
      final now = DateTime.now();

      final expired = AuthTokens(
        accessToken: 'old',
        refreshToken: 'refresh',
        sessionId: 'session',
        accessTokenExpiry: now.subtract(Duration(minutes: 5)),
        refreshTokenExpiry: now.add(Duration(days: 30)),
      );

      final newTokens = AuthTokens(
        accessToken: 'new',
        refreshToken: 'refresh',
        sessionId: 'session',
        accessTokenExpiry: now.add(Duration(minutes: 5)),
        refreshTokenExpiry: now.add(Duration(days: 30)),
      );

      when(mockSessionStorage.loadTokens()).thenAnswer((_) async => expired);
      when(mockApiClient.refresh(expired.sessionId, expired.refreshToken))
          .thenAnswer((_) async => newTokens);
      when(mockSessionStorage.saveTokens(newTokens)).thenAnswer((_) async {});

      await authManager.initialize();
      final refreshed = await authManager.gracefulRefresh();

      expect(authManager.currentStatus, AuthStatus.authenticated);
      expect(refreshed, newTokens);

      verify(mockApiClient.refresh(expired.sessionId, expired.refreshToken)).called(1);
      verify(mockSessionStorage.saveTokens(newTokens)).called(1);
    });

    test('gracefulRefresh → SESSION_REVOKED → clears storage and becomes invalid', () async {
      final now = DateTime.now();

      final expired = AuthTokens(
        accessToken: 'old',
        refreshToken: 'refresh',
        sessionId: 'session',
        accessTokenExpiry: now.subtract(Duration(minutes: 5)),
        refreshTokenExpiry: now.add(Duration(days: 30)),
      );

      when(mockSessionStorage.loadTokens()).thenAnswer((_) async => expired);
      when(mockApiClient.refresh(any, any))
          .thenThrow(AuthError(code: "SESSION_REVOKED", message: "revoked"));
      when(mockSessionStorage.clearTokens()).thenAnswer((_) async {});

      await authManager.initialize();

      await expectLater(
        authManager.gracefulRefresh(),
        throwsA(isA<AuthError>()),
      );

      expect(authManager.currentStatus, AuthStatus.sessionInvalid);

      verify(mockSessionStorage.clearTokens()).called(1);
    });

  });
}
