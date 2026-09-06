import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audio_call_app/screens/add_contact_screen.dart';
import 'package:audio_call_app/screens/home_screen.dart';
import 'package:audio_call_app/screens/incoming_call_screen.dart';
import 'package:audio_call_app/screens/outgoing_call_screen.dart';
import 'package:audio_call_app/services/api_service.dart';
import 'package:audio_call_app/services/signaling_service.dart';
import 'signaling_service_test.dart';

void main() {
  late FakeWebSocketChannel fakeChannel;
  late SignalingService signalingService;

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'user_id': 'alice_123',
      'user_name': 'Alice Wonderland',
      'username': 'alice',
    });

    fakeChannel = FakeWebSocketChannel();
    signalingService = SignalingService(
      channelFactory: (uri) => fakeChannel,
    );
  });

  tearDown(() {
    signalingService.dispose();
  });

  group('HomeScreen Tests', () {
    testWidgets('loads and renders contacts list with name, username, presence dot, and call button',
        (WidgetTester tester) async {
      final mockClient = MockClient((request) async {
        expect(request.url.path, '/contacts/alice_123');
        return http.Response(
          jsonEncode([
            {
              'id': 1,
              'user_id': 'alice_123',
              'contact_id': 'bob_456',
              'name': 'Bob Builder',
              'username': 'bob',
              'is_online': true,
            },
            {
              'id': 2,
              'user_id': 'alice_123',
              'contact_id': 'charlie_789',
              'name': 'Charlie Chaplin',
              'username': 'charlie',
              // is_online is omitted/null -> presence dot should be omitted
            },
          ]),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final apiService = ApiService(client: mockClient);

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            apiService: apiService,
            signalingService: signalingService,
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Bob Builder'), findsOneWidget);
      expect(find.text('@bob'), findsOneWidget);
      expect(find.byKey(const Key('call_btn_bob_456')), findsOneWidget);

      expect(find.text('Charlie Chaplin'), findsOneWidget);
      expect(find.text('@charlie'), findsOneWidget);
      expect(find.byKey(const Key('call_btn_charlie_789')), findsOneWidget);
    });

    testWidgets('tapping FAB navigates to AddContactScreen',
        (WidgetTester tester) async {
      final mockClient = MockClient((request) async {
        return http.Response(jsonEncode([]), 200,
            headers: {'content-type': 'application/json'});
      });

      final apiService = ApiService(client: mockClient);

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            apiService: apiService,
            signalingService: signalingService,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('add_contact_fab')));
      await tester.pumpAndSettle();

      expect(find.byType(AddContactScreen), findsOneWidget);
    });

    testWidgets(
        'tapping call button calls callUser and navigates to OutgoingCallScreen',
        (WidgetTester tester) async {
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode([
            {
              'id': 1,
              'user_id': 'alice_123',
              'contact_id': 'bob_456',
              'name': 'Bob Builder',
              'username': 'bob',
            },
          ]),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final apiService = ApiService(client: mockClient);

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            apiService: apiService,
            signalingService: signalingService,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap call button
      await tester.tap(find.byKey(const Key('call_btn_bob_456')));
      await tester.pump();

      // Check outgoing call_request was sent over websocket
      expect(fakeChannel.sentMessages.length, 1);
      final sent =
          jsonDecode(fakeChannel.sentMessages.first) as Map<String, dynamic>;
      expect(sent['type'], 'call_request');
      expect(sent['to_user_id'], 'bob_456');

      // Callee accepts the call
      fakeChannel.incomingController.add(jsonEncode({
        'type': 'call_accepted',
        'call_id': 'call-session-999',
      }));

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // Navigates to OutgoingCallScreen passing name and call_id
      expect(find.byType(OutgoingCallScreen), findsOneWidget);
      expect(find.text('Calling Bob Builder...'), findsOneWidget);
    });

    testWidgets(
        'listens for incoming_call and navigates to IncomingCallScreen regardless of current screen',
        (WidgetTester tester) async {
      final mockClient = MockClient((request) async {
        return http.Response(jsonEncode([]), 200,
            headers: {'content-type': 'application/json'});
      });

      final apiService = ApiService(client: mockClient);

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            apiService: apiService,
            signalingService: signalingService,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // First navigate away to AddContactScreen
      await tester.tap(find.byKey(const Key('add_contact_fab')));
      await tester.pumpAndSettle();
      expect(find.byType(AddContactScreen), findsOneWidget);

      // Incoming call arrives over WebSocket
      fakeChannel.incomingController.add(jsonEncode({
        'type': 'incoming_call',
        'call_id': 'call-incoming-444',
        'from_user_id': 'dave_user',
        'caller_name': 'Dave Grohl',
      }));

      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // IncomingCallScreen is pushed on top regardless of AddContactScreen being active
      expect(find.byType(IncomingCallScreen), findsOneWidget);
      expect(find.text('Dave Grohl is calling...'), findsOneWidget);
      expect(find.text('Incoming Audio Call'), findsOneWidget);
    });
  });
}
