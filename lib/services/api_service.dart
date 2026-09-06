import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/contact_model.dart';
import '../models/user_model.dart';

/// Base exception for API client errors.
class ApiException implements Exception {
  final String message;
  final int statusCode;

  const ApiException(this.message, {this.statusCode = 0});

  @override
  String toString() => message;
}

/// Exception thrown when user registration fails because the username is already taken (HTTP 409).
class UsernameTakenException extends ApiException {
  const UsernameTakenException([super.message = 'Username is already taken'])
      : super(statusCode: 409);
}

/// Exception thrown when adding a contact fails because it already exists (HTTP 409).
class ContactAlreadyAddedException extends ApiException {
  const ContactAlreadyAddedException([super.message = 'Contact already added'])
      : super(statusCode: 409);
}

/// Service providing REST API access to user registration, user search,
/// and contact management endpoints on the signaling backend.
class ApiService {
  static const String defaultBaseUrl =
      'https://calling-backend-1jxa.onrender.com';

  final String baseUrl;
  final http.Client _client;
  int _lastTurnTtl = 3600;
  bool? _lastTurnConfigured;

  ApiService({
    this.baseUrl = defaultBaseUrl,
    http.Client? client,
  }) : _client = client ?? http.Client();

  /// Cached TTL in seconds from the most recent TURN credentials response.
  int get lastTurnTtl => _lastTurnTtl;

  /// Whether the backend indicated TURN is configured ("turnConfigured" field).
  bool? get lastTurnConfigured => _lastTurnConfigured;

  /// Fetches TURN/STUN credentials and ICE servers from GET /turn-credentials?user_id=[userId].
  /// Returns the parsed iceServers list (`List<Map<String, dynamic>>`).
  Future<List<Map<String, dynamic>>> fetchTurnCredentials(String userId) async {
    final cleanUserId = userId.trim();
    final uri = Uri.parse('$baseUrl/turn-credentials').replace(
      queryParameters: {'user_id': cleanUserId},
    );
    final response = await _client.get(
      uri,
      headers: {
        'Accept': 'application/json',
        'X-User-Id': cleanUserId,
      },
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final rawList = data['iceServers'] as List<dynamic>? ?? [];
      final ttl = data['ttl'] as int?;
      if (ttl != null && ttl > 0) {
        _lastTurnTtl = ttl;
      }
      _lastTurnConfigured = data['turnConfigured'] as bool?;
      return rawList
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();
    } else {
      throw ApiException(
        _parseErrorMessage(response),
        statusCode: response.statusCode,
      );
    }
  }

  /// Registers a new user with a display name and unique username.
  /// Throws [UsernameTakenException] if HTTP 409 Conflict is returned.
  Future<UserModel> registerUser(String name, String username) async {
    final uri = Uri.parse('$baseUrl/users');
    final response = await _client.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'name': name.trim(),
        'username': username.trim(),
      }),
    );

    if (response.statusCode == 201 || response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return UserModel.fromJson(data);
    } else if (response.statusCode == 409) {
      throw UsernameTakenException(_parseErrorMessage(response));
    } else {
      throw ApiException(
        _parseErrorMessage(response),
        statusCode: response.statusCode,
      );
    }
  }

  /// Searches for users matching [query] by name or username.
  /// Optionally excludes the requesting user via [excludeUserId].
  Future<List<UserModel>> searchUsers(
    String query, {
    String? excludeUserId,
  }) async {
    final queryParams = <String, String>{'q': query};
    if (excludeUserId != null && excludeUserId.trim().isNotEmpty) {
      queryParams['user_id'] = excludeUserId.trim();
    }

    final uri = Uri.parse('$baseUrl/users/search').replace(
      queryParameters: queryParams,
    );

    final response = await _client.get(
      uri,
      headers: {'Accept': 'application/json'},
    );

    if (response.statusCode == 200) {
      final List<dynamic> list = jsonDecode(response.body) as List<dynamic>;
      return list
          .map((item) => UserModel.fromJson(item as Map<String, dynamic>))
          .toList();
    } else {
      throw ApiException(
        _parseErrorMessage(response),
        statusCode: response.statusCode,
      );
    }
  }

  /// Fetches a user's details by their UUID [id].
  Future<UserModel> getUser(String id) async {
    final uri = Uri.parse('$baseUrl/users/${id.trim()}');
    final response = await _client.get(
      uri,
      headers: {'Accept': 'application/json'},
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return UserModel.fromJson(data);
    } else {
      throw ApiException(
        _parseErrorMessage(response),
        statusCode: response.statusCode,
      );
    }
  }

  /// Adds a new contact connection between [userId] and [contactId].
  /// Throws [ContactAlreadyAddedException] if HTTP 409 Conflict is returned.
  Future<ContactModel> addContact(String userId, String contactId) async {
    final uri = Uri.parse('$baseUrl/contacts');
    final response = await _client.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'user_id': userId.trim(),
        'contact_id': contactId.trim(),
      }),
    );

    if (response.statusCode == 201 || response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return ContactModel.fromJson(data);
    } else if (response.statusCode == 409) {
      throw ContactAlreadyAddedException(_parseErrorMessage(response));
    } else {
      throw ApiException(
        _parseErrorMessage(response),
        statusCode: response.statusCode,
      );
    }
  }

  /// Retrieves the contact list for a given [userId].
  Future<List<ContactModel>> getContacts(String userId) async {
    final uri = Uri.parse('$baseUrl/contacts/${userId.trim()}');
    final response = await _client.get(
      uri,
      headers: {'Accept': 'application/json'},
    );

    if (response.statusCode == 200) {
      final List<dynamic> list = jsonDecode(response.body) as List<dynamic>;
      return list
          .map((item) => ContactModel.fromJson(item as Map<String, dynamic>))
          .toList();
    } else {
      throw ApiException(
        _parseErrorMessage(response),
        statusCode: response.statusCode,
      );
    }
  }

  /// Deletes a contact by the contact table's own primary key [contactRecordId].
  Future<void> deleteContact(String contactRecordId) async {
    final uri = Uri.parse('$baseUrl/contacts/${contactRecordId.trim()}');
    final response = await _client.delete(
      uri,
      headers: {'Accept': 'application/json'},
    );

    if (response.statusCode == 204 || response.statusCode == 200) {
      return;
    } else {
      throw ApiException(
        _parseErrorMessage(response),
        statusCode: response.statusCode,
      );
    }
  }

  /// Closes the underlying HTTP client.
  void dispose() {
    _client.close();
  }

  /// Parses error responses into a human-readable message.
  String _parseErrorMessage(http.Response response) {
    if (response.body.isNotEmpty) {
      try {
        final dynamic decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) {
          final detail = decoded['detail'];
          if (detail is String && detail.isNotEmpty) {
            return detail;
          } else if (detail is List && detail.isNotEmpty) {
            return detail
                .map((item) =>
                    item is Map ? (item['msg'] ?? item.toString()) : item.toString())
                .join(', ');
          } else if (decoded['message'] is String) {
            return decoded['message'] as String;
          }
        }
      } catch (_) {
        // Body is not JSON
      }
    }
    return response.reasonPhrase ?? 'Request failed with status ${response.statusCode}';
  }
}
