import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audio_call_app/models/contact_model.dart';
import 'package:audio_call_app/screens/dialpad_screen.dart';
import 'package:audio_call_app/screens/login_screen.dart';
import 'package:audio_call_app/screens/main_shell.dart';
import 'package:audio_call_app/screens/scam_screen.dart';
import 'package:audio_call_app/screens/signup_screen.dart';
import 'package:audio_call_app/services/api_service.dart';
import 'package:audio_call_app/services/call_history_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('CallHistoryService Tests', () {
    test('records calls and orders frequent contacts by frequency and recency', () async {
      await CallHistoryService.clear();

      await CallHistoryService.recordCall('user-alice');
      await CallHistoryService.recordCall('user-bob');
      await CallHistoryService.recordCall('user-bob');

      final frequents = await CallHistoryService.getFrequentContactIds();
      expect(frequents.first, 'user-bob');
      expect(frequents.contains('user-alice'), isTrue);

      final bobLabel = await CallHistoryService.getLastCalledText('user-bob');
      expect(bobLabel, isNotNull);
      expect(bobLabel, 'Just now');
    });
  });

  group('ScamNumberModel & ApiService Scam Tests', () {
    test('getScamNumbers returns parsed mock list when backend unreachable', () async {
      final mockClient = MockClient((request) async {
        return http.Response('Not Found', 404);
      });
      final apiService = ApiService(client: mockClient);

      final scamList = await apiService.getScamNumbers();
      expect(scamList.isNotEmpty, isTrue);
      expect(scamList.first.phoneNumber, isNotEmpty);
      expect(scamList.first.verdict, contains('Detected'));
    });

    test('getScamNumbers parses backend response when successful', () async {
      final mockClient = MockClient((request) async {
        expect(request.url.path, '/scam-numbers');
        return http.Response(
          jsonEncode([
            {
              'phone_number': '+1 555 999 8888',
              'verdict': 'AI Detected',
              'confidence': 0.98,
              'caller_name': 'Known Impersonator',
              'reason': 'Synthetic audio fingerprint',
              'flagged_at': '2026-09-07T12:00:00Z',
            }
          ]),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final apiService = ApiService(client: mockClient);

      final scamList = await apiService.getScamNumbers();
      expect(scamList.length, 1);
      expect(scamList.first.phoneNumber, '+1 555 999 8888');
      expect(scamList.first.callerName, 'Known Impersonator');
      expect(scamList.first.confidence, 0.98);
    });

    test('login API sends phone_number and returns UserModel', () async {
      final mockClient = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/login');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['phone_number'], '+15551234567');

        return http.Response(
          jsonEncode({
            'id': 'user-logged-in-1',
            'name': 'Logged In User',
            'phone_number': '+15551234567',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final apiService = ApiService(client: mockClient);

      final user = await apiService.login('+15551234567');
      expect(user.id, 'user-logged-in-1');
      expect(user.name, 'Logged In User');
      expect(user.phoneNumber, '+15551234567');
    });
  });

  group('LoginScreen Tests', () {
    testWidgets('renders phone field and Log In button', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: LoginScreen()),
      );

      expect(find.byKey(const Key('phone_field')), findsOneWidget);
      expect(find.byKey(const Key('login_button')), findsOneWidget);
      expect(find.text('Welcome Back'), findsOneWidget);
      expect(find.byKey(const Key('signup_link')), findsOneWidget);
    });

    testWidgets('validates phone number field when empty', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: LoginScreen()),
      );

      await tester.tap(find.byKey(const Key('login_button')));
      await tester.pump();

      expect(find.text('Please enter your phone number'), findsOneWidget);
    });

    testWidgets('on success saves phone_number and navigates to MainShell', (tester) async {
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'id': 'user-12345',
            'name': 'Alice Caller',
            'phone_number': '+15559876543',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final apiService = ApiService(client: mockClient);

      await tester.pumpWidget(
        MaterialApp(home: LoginScreen(apiService: apiService)),
      );

      await tester.enterText(find.byKey(const Key('phone_field')), '+15559876543');
      await tester.tap(find.byKey(const Key('login_button')));
      await tester.pumpAndSettle();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('user_id'), 'user-12345');
      expect(prefs.getString('phone_number'), '+15559876543');
      expect(find.byType(MainShell), findsOneWidget);
    });
  });

  group('SignupScreen Tests', () {
    testWidgets('renders name, phone fields and Create Account button', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: SignupScreen()),
      );

      expect(find.byKey(const Key('name_field')), findsOneWidget);
      expect(find.byKey(const Key('phone_field')), findsOneWidget);
      expect(find.byKey(const Key('register_button')), findsOneWidget);
      expect(find.text('Create Account'), findsWidgets);
    });
  });

  group('ScamScreen Tests', () {
    testWidgets('renders scam numbers and flagged badges', (tester) async {
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode([
            {
              'phone_number': '+1 800 555 0199',
              'verdict': 'AI Detected',
              'confidence': 0.95,
              'caller_name': 'Tax Scam',
              'reason': 'Voice clone match',
            }
          ]),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final apiService = ApiService(client: mockClient);

      await tester.pumpWidget(
        MaterialApp(home: ScamScreen(apiService: apiService)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Scam Protection'), findsOneWidget);
      expect(find.text('+1 800 555 0199'), findsOneWidget);
      expect(find.text('Tax Scam'), findsOneWidget);
      expect(find.textContaining('AI Detected'), findsWidgets);
    });
  });

  group('DialPadScreen Tests', () {
    testWidgets('typing digits updates display, backspace deletes, and matches contact', (tester) async {
      const contacts = [
        ContactModel(
          id: 1,
          contactUserId: 'bob-uuid',
          name: 'Bob Builder',
          phoneNumber: '5551234',
          username: 'bob',
        ),
      ];

      String? dialed;
      await tester.pumpWidget(
        MaterialApp(
          home: DialPadScreen(
            contacts: contacts,
            onCallContact: (contact) async {
              dialed = contact.phoneNumber;
            },
          ),
        ),
      );

      // Tap 5, 5, 5, 1, 2, 3, 4
      await tester.tap(find.byKey(const Key('dialpad_key_5')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('dialpad_key_5')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('dialpad_key_5')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('dialpad_key_1')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('dialpad_key_2')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('dialpad_key_3')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('dialpad_key_4')));
      await tester.pump();

      // Number matches contact 'Bob Builder'
      expect(find.text('5551234'), findsOneWidget);
      expect(find.text('Bob Builder'), findsOneWidget);

      // Backspace removes last digit
      await tester.tap(find.byKey(const Key('dialpad_backspace')));
      await tester.pump();
      expect(find.text('555123'), findsOneWidget);

      // Tap 4 again
      await tester.tap(find.byKey(const Key('dialpad_key_4')));
      await tester.pump();

      // Tap green call button
      await tester.tap(find.byKey(const Key('dialpad_call_button')));
      await tester.pumpAndSettle();

      expect(dialed, '5551234');
    });
  });

  group('MainShell Tests', () {
    testWidgets('hosts Calls and Scam tabs and switches between them', (tester) async {
      final mockClient = MockClient((request) async {
        return http.Response(jsonEncode([]), 200, headers: {'content-type': 'application/json'});
      });
      final apiService = ApiService(client: mockClient);

      await tester.pumpWidget(
        MaterialApp(
          home: MainShell(apiService: apiService),
        ),
      );
      await tester.pumpAndSettle();

      // Starts on Calls tab
      expect(find.text('Calls'), findsOneWidget);
      expect(find.text('Scam'), findsOneWidget);

      // Switch to Scam tab
      await tester.tap(find.text('Scam'));
      await tester.pumpAndSettle();

      expect(find.text('Scam Protection'), findsOneWidget);
    });
  });
}
