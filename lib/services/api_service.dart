import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import '../config.dart';
import '../models/contact_model.dart';
import '../models/scam_number_model.dart';
import '../models/user_model.dart';
import '../models/voice_detection_model.dart';

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
  final String baseUrl;
  final String voiceDetectionUrl;
  final String hfToken;
  final http.Client _client;

  ApiService({
    String? baseUrl,
    String? voiceDetectionUrl,
    String? hfToken,
    http.Client? client,
  })  : baseUrl = baseUrl ?? AppConfig.baseUrl,
        voiceDetectionUrl = voiceDetectionUrl ?? AppConfig.voiceDetectionUrl,
        hfToken = hfToken ?? AppConfig.hfToken,
        _client = client ?? http.Client();

  /// Registers a new user with a display name and unique phone number.
  /// Throws [UsernameTakenException] if HTTP 409 Conflict is returned.
  Future<UserModel> registerUser(String name, String phoneNumber) async {
    final uri = Uri.parse('$baseUrl/users');
    final response = await _client.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'name': name.trim(),
        'phone_number': phoneNumber.trim(),
        'username': phoneNumber.trim(),
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

  /// Logs in an existing user by looking up their [phoneNumber].
  /// Returns the authenticated [UserModel].
  Future<UserModel> login(String phoneNumber) async {
    final uri = Uri.parse('$baseUrl/login');
    final response = await _client.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'phone_number': phoneNumber.trim(),
      }),
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

  /// Uploads a WAV audio file to the voice detection endpoint using multipart/form-data.
  Future<VoiceDetectionResult> detectVoice(File audioFile) async {
    final uri = Uri.parse(voiceDetectionUrl);
    final request = http.MultipartRequest('POST', uri);

    if (hfToken.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $hfToken';
    }

    request.files.add(
      await http.MultipartFile.fromPath(
        'audio',
        audioFile.path,
        contentType: MediaType('audio', 'wav'),
      ),
    );

    debugPrint('[VoiceDetection] uploading audio to $voiceDetectionUrl...');

    final streamedResponse = await _client.send(request).timeout(
      const Duration(seconds: 25),
      onTimeout: () {
        throw const ApiException('Voice detection request timed out');
      },
    );
    final response = await http.Response.fromStream(streamedResponse);

    debugPrint('[VoiceDetection] HTTP status = ${response.statusCode}');
    debugPrint('[VoiceDetection] response = ${response.body}');

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return VoiceDetectionResult.fromJson(data);
    }

    throw ApiException(
      _parseErrorMessage(response),
      statusCode: response.statusCode,
    );
  }

  /// Uploads an audio byte buffer to the voice detection endpoint using multipart/form-data.
  Future<VoiceDetectionResult> detectVoiceBytes(
    List<int> bytes, {
    String filename = 'remote_voice.mp3',
  }) async {
    final uri = Uri.parse(voiceDetectionUrl);
    final request = http.MultipartRequest('POST', uri);

    if (hfToken.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $hfToken';
    }

    request.files.add(
      http.MultipartFile.fromBytes(
        'audio',
        bytes,
        filename: filename,
        contentType: MediaType('audio', 'mpeg'),
      ),
    );

    final streamedResponse = await _client.send(request).timeout(
      const Duration(seconds: 25),
      onTimeout: () {
        throw const ApiException('Voice detection request timed out');
      },
    );
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return VoiceDetectionResult.fromJson(data);
    } else {
      throw ApiException(
        _parseErrorMessage(response),
        statusCode: response.statusCode,
      );
    }
  }

  /// Retrieves the list of scam/flagged numbers from the backend.
  /// Falls back to mock list if backend is not available yet.
  Future<List<ScamNumberModel>> getScamNumbers() async {
    final uri = Uri.parse('$baseUrl/scam-numbers');
    try {
      final response = await _client.get(
        uri,
        headers: {'Accept': 'application/json'},
      );

      if (response.statusCode == 200) {
        final dynamic decoded = jsonDecode(response.body);
        if (decoded is List) {
          return decoded
              .map((item) =>
                  ScamNumberModel.fromJson(item as Map<String, dynamic>))
              .toList();
        }
      }
    } catch (_) {
      // Backend /scam-numbers not reachable; fallback to mock data below
    }
    return ScamNumberModel.getMockScamNumbers();
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
          } else if (decoded['error'] is String) {
            return decoded['error'] as String;
          }
        }
      } catch (_) {
        // Body is not JSON
      }
    }
    return response.reasonPhrase ?? 'Request failed with status ${response.statusCode}';
  }
}
