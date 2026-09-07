import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audio_call_app/screens/add_contact_screen.dart';
import 'package:audio_call_app/services/api_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'user_id': 'current_user_123',
    });
  });

  group('AddContactScreen Tests', () {
    testWidgets('searches with 400ms debounce and displays user list with Add buttons',
        (WidgetTester tester) async {
      int searchCallCount = 0;
      String? lastQuery;
      String? lastExcludeUserId;

      final mockClient = MockClient((request) async {
        if (request.url.path == '/users/search') {
          searchCallCount++;
          lastQuery = request.url.queryParameters['q'];
          lastExcludeUserId = request.url.queryParameters['user_id'];

          return http.Response(
            jsonEncode([
              {
                'id': 'user-1',
                'name': 'Charlie Chaplin',
                'username': 'charlie',
              },
              {
                'id': 'user-2',
                'name': 'Charlotte Bronte',
                'username': 'charlotte',
              },
            ]),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('', 404);
      });

      final apiService = ApiService(client: mockClient);

      await tester.pumpWidget(
        MaterialApp(
          home: AddContactScreen(apiService: apiService),
        ),
      );
      await tester.pumpAndSettle();

      // Enter query
      await tester.enterText(
          find.byKey(const Key('search_contact_field')), 'char');

      // Before 400ms: debounce timer has not fired yet
      await tester.pump(const Duration(milliseconds: 200));
      expect(searchCallCount, 0);

      // Advance past 400ms debounce
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();

      // Debounced search fired
      expect(searchCallCount, 1);
      expect(lastQuery, 'char');
      expect(lastExcludeUserId, 'current_user_123');

      // Results rendered with Add button
      expect(find.text('Charlie Chaplin'), findsOneWidget);
      expect(find.text('charlie'), findsOneWidget);
      expect(find.byKey(const Key('add_btn_user-1')), findsOneWidget);

      expect(find.text('Charlotte Bronte'), findsOneWidget);
      expect(find.text('charlotte'), findsOneWidget);
      expect(find.byKey(const Key('add_btn_user-2')), findsOneWidget);
    });

    testWidgets('on add success calls addContact and pops with true',
        (WidgetTester tester) async {
      bool addContactCalled = false;
      String? addedUserId;
      String? addedContactId;

      final mockClient = MockClient((request) async {
        if (request.url.path == '/users/search') {
          return http.Response(
            jsonEncode([
              {
                'id': 'target_user_456',
                'name': 'Diana Prince',
                'username': 'diana',
              }
            ]),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.path == '/contacts' && request.method == 'POST') {
          addContactCalled = true;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          addedUserId = body['user_id'];
          addedContactId = body['contact_id'];

          return http.Response(
            jsonEncode({
              'id': 77,
              'user_id': addedUserId,
              'contact_id': addedContactId,
              'name': 'Diana Prince',
              'username': 'diana',
            }),
            201,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('', 404);
      });

      final apiService = ApiService(client: mockClient);
      bool? popResult;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                popResult = await Navigator.push<bool>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => AddContactScreen(apiService: apiService),
                  ),
                );
              },
              child: const Text('Open Add Contact'),
            ),
          ),
        ),
      );

      // Open screen
      await tester.tap(find.text('Open Add Contact'));
      await tester.pumpAndSettle();

      // Search
      await tester.enterText(
          find.byKey(const Key('search_contact_field')), 'diana');
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pumpAndSettle();

      // Tap Add button
      await tester.tap(find.byKey(const Key('add_btn_target_user_456')));
      await tester.pumpAndSettle();

      // Verified addContact was called
      expect(addContactCalled, isTrue);
      expect(addedUserId, 'current_user_123');
      expect(addedContactId, 'target_user_456');

      // Verified popped back with true
      expect(popResult, isTrue);
    });

    testWidgets('on 409 Conflict shows snackbar and does not crash or pop',
        (WidgetTester tester) async {
      final mockClient = MockClient((request) async {
        if (request.url.path == '/users/search') {
          return http.Response(
            jsonEncode([
              {
                'id': 'existing_user_888',
                'name': 'Existing Friend',
                'username': 'friend',
              }
            ]),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.path == '/contacts' && request.method == 'POST') {
          return http.Response(
            jsonEncode({'detail': 'Contact already exists'}),
            409,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('', 404);
      });

      final apiService = ApiService(client: mockClient);

      await tester.pumpWidget(
        MaterialApp(
          home: AddContactScreen(apiService: apiService),
        ),
      );
      await tester.pumpAndSettle();

      // Search
      await tester.enterText(
          find.byKey(const Key('search_contact_field')), 'friend');
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pumpAndSettle();

      // Tap Add
      await tester.tap(find.byKey(const Key('add_btn_existing_user_888')));
      await tester.pumpAndSettle();

      // Shows snackbar
      expect(find.text('Existing Friend is already in your contacts.'),
          findsOneWidget);

      // Remains on AddContactScreen (did not pop or crash)
      expect(find.byType(AddContactScreen), findsOneWidget);
    });
  });
}
