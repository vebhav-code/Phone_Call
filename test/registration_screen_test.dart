import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audio_call_app/main.dart';
import 'package:audio_call_app/screens/home_screen.dart';
import 'package:audio_call_app/screens/registration_screen.dart';
import 'package:audio_call_app/services/api_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('RegistrationScreen Tests', () {
    testWidgets('renders Name and Username TextFields and submit button',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: RegistrationScreen(),
        ),
      );

      expect(find.byKey(const Key('name_field')), findsOneWidget);
      expect(find.byKey(const Key('username_field')), findsOneWidget);
      expect(find.byKey(const Key('register_button')), findsOneWidget);
      expect(find.text('Welcome to WebRTC Call'), findsOneWidget);
    });

    testWidgets('shows validation errors when fields are empty',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: RegistrationScreen(),
        ),
      );

      await tester.tap(find.byKey(const Key('register_button')));
      await tester.pump();

      expect(find.text('Please enter your display name'), findsOneWidget);
    });

    testWidgets('on 409 Conflict shows inline error and does not navigate',
        (WidgetTester tester) async {
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({'detail': "Username 'alice_taken' already exists"}),
          409,
          headers: {'content-type': 'application/json'},
        );
      });

      final apiService = ApiService(client: mockClient);

      await tester.pumpWidget(
        MaterialApp(
          home: RegistrationScreen(apiService: apiService),
        ),
      );

      await tester.enterText(
          find.byKey(const Key('name_field')), 'Alice Smith');
      await tester.enterText(
          find.byKey(const Key('username_field')), 'alice_taken');
      await tester.tap(find.byKey(const Key('register_button')));
      await tester.pumpAndSettle();

      // Inline error displayed on username field
      expect(find.text("Username 'alice_taken' already exists"), findsOneWidget);
      // Did NOT navigate to HomeScreen
      expect(find.byType(HomeScreen), findsNothing);
      expect(find.byType(RegistrationScreen), findsOneWidget);
    });

    testWidgets(
        'on success saves user credentials to SharedPreferences and navigates to HomeScreen',
        (WidgetTester tester) async {
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'id': 'user-uuid-999',
            'name': 'Bob Builder',
            'username': 'bob_builder',
            'created_at': '2026-09-06T12:00:00Z',
          }),
          201,
          headers: {'content-type': 'application/json'},
        );
      });

      final apiService = ApiService(client: mockClient);

      await tester.pumpWidget(
        MaterialApp(
          home: RegistrationScreen(apiService: apiService),
        ),
      );

      await tester.enterText(
          find.byKey(const Key('name_field')), 'Bob Builder');
      await tester.enterText(
          find.byKey(const Key('username_field')), 'bob_builder');
      await tester.tap(find.byKey(const Key('register_button')));
      await tester.pumpAndSettle();

      // Verify SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('user_id'), 'user-uuid-999');
      expect(prefs.getString('user_name'), 'Bob Builder');
      expect(prefs.getString('username'), 'bob_builder');

      // Verify navigation to HomeScreen
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.textContaining('Bob Builder'), findsOneWidget);
      expect(find.textContaining('@bob_builder'), findsOneWidget);
    });
  });

  group('App Launch Routing Tests', () {
    testWidgets('shows RegistrationScreen when user_id is absent in SharedPreferences',
        (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});

      await tester.pumpWidget(
        const AudioCallApp(initialHasUser: false),
      );
      await tester.pumpAndSettle();

      expect(find.byType(RegistrationScreen), findsOneWidget);
      expect(find.byType(HomeScreen), findsNothing);
    });

    testWidgets('shows HomeScreen when user_id is present in SharedPreferences',
        (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({
        'user_id': 'saved-user-123',
        'user_name': 'Existing User',
        'username': 'existing_user',
      });

      await tester.pumpWidget(
        const AudioCallApp(initialHasUser: true),
      );
      await tester.pumpAndSettle();

      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byType(RegistrationScreen), findsNothing);
      expect(find.textContaining('Existing User'), findsOneWidget);
    });
  });
}
