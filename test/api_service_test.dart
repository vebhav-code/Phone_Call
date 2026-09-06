import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:audio_call_app/services/api_service.dart';

void main() {
  group('ApiService Tests', () {
    test('registerUser success (201)', () async {
      final mockClient = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/users');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['name'], 'Alice');
        expect(body['username'], 'alice');

        return http.Response(
          jsonEncode({
            'id': 'user-123',
            'name': 'Alice',
            'username': 'alice',
            'created_at': '2026-09-06T12:00:00Z',
          }),
          201,
          headers: {'content-type': 'application/json'},
        );
      });

      final apiService = ApiService(client: mockClient);
      final user = await apiService.registerUser('Alice', 'alice');

      expect(user.id, 'user-123');
      expect(user.name, 'Alice');
      expect(user.username, 'alice');
    });

    test('registerUser throws UsernameTakenException on 409', () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({'detail': "Username 'alice' already exists"}),
          409,
          headers: {'content-type': 'application/json'},
        );
      });

      final apiService = ApiService(client: mockClient);

      expect(
        () => apiService.registerUser('Alice', 'alice'),
        throwsA(isA<UsernameTakenException>().having(
          (e) => e.message,
          'message',
          contains("Username 'alice' already exists"),
        )),
      );
    });

    test('searchUsers with query and excludeUserId', () async {
      final mockClient = MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/users/search');
        expect(request.url.queryParameters['q'], 'bob');
        expect(request.url.queryParameters['user_id'], 'alice-id');

        return http.Response(
          jsonEncode([
            {
              'id': 'user-456',
              'name': 'Bob Builder',
              'username': 'bob',
            }
          ]),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final apiService = ApiService(client: mockClient);
      final results = await apiService.searchUsers('bob', excludeUserId: 'alice-id');

      expect(results.length, 1);
      expect(results.first.id, 'user-456');
      expect(results.first.name, 'Bob Builder');
    });

    test('getUser success and 404 error', () async {
      final mockClient = MockClient((request) async {
        if (request.url.path == '/users/user-123') {
          return http.Response(
            jsonEncode({
              'id': 'user-123',
              'name': 'Alice',
              'username': 'alice',
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode({'detail': "User with ID 'unknown' not found"}),
          404,
          headers: {'content-type': 'application/json'},
        );
      });

      final apiService = ApiService(client: mockClient);
      final user = await apiService.getUser('user-123');
      expect(user.id, 'user-123');

      expect(
        () => apiService.getUser('unknown'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 404)),
      );
    });

    test('addContact success and 409 Conflict', () async {
      final mockClient = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (body['contact_id'] == 'conflict-id') {
          return http.Response(
            jsonEncode({'detail': 'Contact already exists'}),
            409,
            headers: {'content-type': 'application/json'},
          );
        }

        return http.Response(
          jsonEncode({
            'id': 101,
            'user_id': 'user-1',
            'contact_id': 'user-2',
            'name': 'Bob',
            'username': 'bob',
          }),
          201,
          headers: {'content-type': 'application/json'},
        );
      });

      final apiService = ApiService(client: mockClient);
      final contact = await apiService.addContact('user-1', 'user-2');
      expect(contact.id, 101);
      expect(contact.contactUserId, 'user-2');
      expect(contact.name, 'Bob');

      expect(
        () => apiService.addContact('user-1', 'conflict-id'),
        throwsA(isA<ContactAlreadyAddedException>().having(
          (e) => e.message,
          'message',
          contains('Contact already exists'),
        )),
      );
    });

    test('getContacts success', () async {
      final mockClient = MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/contacts/user-1');

        return http.Response(
          jsonEncode([
            {
              'id': 1,
              'user_id': 'user-1',
              'contact_id': 'user-2',
              'name': 'Bob',
              'username': 'bob',
            },
            {
              'id': 2,
              'user_id': 'user-1',
              'contact_id': 'user-3',
              'name': 'Charlie',
              'username': 'charlie',
            }
          ]),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final apiService = ApiService(client: mockClient);
      final contacts = await apiService.getContacts('user-1');
      expect(contacts.length, 2);
      expect(contacts[0].contactUserId, 'user-2');
      expect(contacts[1].contactUserId, 'user-3');
    });

    test('deleteContact success and error', () async {
      final mockClient = MockClient((request) async {
        expect(request.method, 'DELETE');
        if (request.url.path == '/contacts/101') {
          return http.Response('', 204);
        }
        return http.Response(
          jsonEncode({'detail': 'Contact with ID 999 not found'}),
          404,
          headers: {'content-type': 'application/json'},
        );
      });

      final apiService = ApiService(client: mockClient);
      await expectLater(apiService.deleteContact('101'), completes);

      expect(
        () => apiService.deleteContact('999'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 404)),
      );
    });
  });
}
