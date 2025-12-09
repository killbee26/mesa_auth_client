import 'package:http/http.dart' as http;
import 'dart:convert';
import '../mesa_auth_client.dart';
import 'api_client.dart';
import 'models/auth_tokens.dart';
import 'models/auth_error.dart';

class HttpApiClient implements ApiClient {
  final AuthConfig config;
  String get baseUrl => config.baseUrl;


  HttpApiClient(this.config);

  Future<AuthTokens> _handleResponse(http.Response response) async {
    if (response.statusCode == 200) {
      final Map<String, dynamic> data = json.decode(response.body);

      // TODO: Adjust these keys to match your actual API response
      final accessToken = data['access_token'] as String?;
      final refreshToken = data['refresh_token'] as String?;
      final sessionId = data['session_id'] as String?;
      final accessTokenExpiry = data['access_token_expiry'] as String?;
      final refreshTokenExpiry = data['refresh_token_expiry'] as String?;

      if (accessToken == null || refreshToken == null || sessionId == null || accessTokenExpiry == null || refreshTokenExpiry == null) {
        throw AuthError(code: 'INVALID_RESPONSE', message: 'Missing token data in response');
      }

      final accessTokenExpiryDateTime = DateTime.tryParse(accessTokenExpiry);
      final refreshTokenExpiryDateTime = DateTime.tryParse(refreshTokenExpiry);

       if (accessTokenExpiryDateTime == null || refreshTokenExpiryDateTime == null) {
        throw AuthError(code: 'INVALID_RESPONSE', message: 'Invalid date format in response');
      }


      return AuthTokens(
        accessToken: accessToken,
        refreshToken: refreshToken,
        sessionId: sessionId,
        accessTokenExpiry: accessTokenExpiryDateTime,
        refreshTokenExpiry: refreshTokenExpiryDateTime,
      );
    } else if (response.statusCode == 401 || response.statusCode == 403) {
      throw AuthError(code: 'UNAUTHORIZED', message: 'Invalid credentials');
    } else {
      throw AuthError(code: 'NETWORK_ERROR', message: 'Request failed with status: ${response.statusCode}');
    }
  }


  @override
  Future<AuthTokens> login(String id, String password, String phone) async {
    final url = Uri.parse('$baseUrl/auth/login');
    final response = await http.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'member_id': id, 'password': password, "mobile": phone}),
    );
    return _handleResponse(response);
  }

  @override
  Future<AuthTokens> refresh(String sessionId, String refreshToken) async {
    final url = Uri.parse('$baseUrl/auth/refresh');
    final response = await http.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'session_id': sessionId, 'refresh_token': refreshToken}),
    );
    return _handleResponse(response);
  }

  @override
  Future<void> logout(String sessionId, String authToken) async {
    final url = Uri.parse('$baseUrl/auth/logout');
    final response = await http.post(
      url,
      headers: {'Content-Type': 'application/json',
            'Authorization':'Bearer $authToken'
      },
      body: json.encode({'session_id': sessionId}),
    );

    if (response.statusCode != 200) {
      // Log the error, but don't necessarily throw.  Logout should still clear local data.
      print('Logout request failed with status: ${response.statusCode}');
    }
  }
}