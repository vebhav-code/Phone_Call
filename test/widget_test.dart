import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audio_call_app/main.dart';
import 'package:audio_call_app/screens/add_contact_screen.dart';
import 'package:audio_call_app/screens/home_screen.dart';
import 'package:audio_call_app/screens/incoming_call_screen.dart';
import 'package:audio_call_app/screens/outgoing_call_screen.dart';
import 'package:audio_call_app/screens/registration_screen.dart';
import 'package:audio_call_app/services/signaling_service.dart';
import 'package:audio_call_app/webrtc_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('AudioCallApp & Routing Tests', () {
    testWidgets('AudioCallApp smoke test - verifies registration screen renders by default',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        ChangeNotifierProvider<WebRTCService>(
          create: (_) => WebRTCService(),
          child: const AudioCallApp(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(RegistrationScreen), findsOneWidget);
      expect(find.text('Welcome to WebRTC Call'), findsOneWidget);
      expect(find.text('Get Started'), findsOneWidget);
    });

    testWidgets('AudioCallApp routes to HomeScreen when initialHasUser is true',
        (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({
        'user_id': 'user-123',
        'user_name': 'Test User',
        'username': 'testuser',
      });

      await tester.pumpWidget(
        ChangeNotifierProvider<SignalingService>(
          create: (_) => SignalingService(),
          child: ChangeNotifierProvider<WebRTCService>(
            create: (_) => WebRTCService(),
            child: const AudioCallApp(initialHasUser: true),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.text('Contacts'), findsOneWidget);
    });

    test('AppRoutes.fromScreen maps AppScreen enum correctly', () {
      expect(AppRoutes.fromScreen(AppScreen.registration), AppRoutes.registration);
      expect(AppRoutes.fromScreen(AppScreen.home), AppRoutes.home);
      expect(AppRoutes.fromScreen(AppScreen.addContact), AppRoutes.addContact);
      expect(AppRoutes.fromScreen(AppScreen.outgoingCall), AppRoutes.outgoingCall);
      expect(AppRoutes.fromScreen(AppScreen.incomingCall), AppRoutes.incomingCall);
      expect(AppRoutes.fromScreen(AppScreen.inCall), AppRoutes.inCall);
    });

    testWidgets('onGenerateRoute resolves AddContactScreen',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                return ElevatedButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      AppRoutes.onGenerateRoute(
                        const RouteSettings(name: AppRoutes.addContact),
                        context,
                      )!,
                    );
                  },
                  child: const Text('Go AddContact'),
                );
              },
            ),
          ),
        ),
      );

      await tester.tap(find.text('Go AddContact'));
      await tester.pumpAndSettle();

      expect(find.byType(AddContactScreen), findsOneWidget);
    });

    testWidgets('onGenerateRoute resolves OutgoingCallScreen with arguments',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                return ElevatedButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      AppRoutes.onGenerateRoute(
                        const RouteSettings(
                          name: AppRoutes.outgoingCall,
                          arguments: {
                            'contactName': 'Alice',
                            'callId': 'call-111',
                            'otherUserId': 'user-alice',
                          },
                        ),
                        context,
                      )!,
                    );
                  },
                  child: const Text('Go Outgoing'),
                );
              },
            ),
          ),
        ),
      );

      await tester.tap(find.text('Go Outgoing'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(OutgoingCallScreen), findsOneWidget);
      expect(find.text('Calling Alice...'), findsOneWidget);
    });

    testWidgets('onGenerateRoute resolves IncomingCallScreen with arguments',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                return ElevatedButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      AppRoutes.onGenerateRoute(
                        const RouteSettings(
                          name: AppRoutes.incomingCall,
                          arguments: {
                            'callerName': 'Bob Builder',
                            'callerId': 'user-bob',
                            'callId': 'call-222',
                          },
                        ),
                        context,
                      )!,
                    );
                  },
                  child: const Text('Go Incoming'),
                );
              },
            ),
          ),
        ),
      );

      await tester.tap(find.text('Go Incoming'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(IncomingCallScreen), findsOneWidget);
      expect(find.text('Bob Builder is calling...'), findsOneWidget);
    });

    testWidgets('onGenerateRoute resolves InCallScreen with arguments',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                return ElevatedButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      AppRoutes.onGenerateRoute(
                        const RouteSettings(
                          name: AppRoutes.inCall,
                          arguments: {
                            'otherUserName': 'Charlie',
                            'callId': 'call-333',
                            'otherUserId': 'user-charlie',
                          },
                        ),
                        context,
                      )!,
                    );
                  },
                  child: const Text('Go InCall'),
                );
              },
            ),
          ),
        ),
      );

      await tester.tap(find.text('Go InCall'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(InCallScreen), findsOneWidget);
      expect(find.text('Charlie'), findsOneWidget);
    });
  });

  group('ChangeNotifierProvider Tests', () {
    testWidgets('ChangeNotifierProvider.maybeOf returns null when not present',
        (WidgetTester tester) async {
      SignalingService? service;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              service = ChangeNotifierProvider.maybeOf<SignalingService>(context);
              return const SizedBox();
            },
          ),
        ),
      );

      expect(service, isNull);
    });

    testWidgets('ChangeNotifierProvider provides instance and updates dependents',
        (WidgetTester tester) async {
      final signaling = SignalingService();

      await tester.pumpWidget(
        ChangeNotifierProvider<SignalingService>(
          create: (_) => signaling,
          child: MaterialApp(
            home: Builder(
              builder: (context) {
                final s = ChangeNotifierProvider.of<SignalingService>(context);
                return Text('Connected: ${s.isConnected}');
              },
            ),
          ),
        ),
      );

      expect(find.text('Connected: false'), findsOneWidget);
    });
  });
}
