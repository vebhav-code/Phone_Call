import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:audio_call_app/screens/in_call_screen.dart';
import 'package:audio_call_app/screens/incoming_call_screen.dart';
import 'package:audio_call_app/screens/outgoing_call_screen.dart';
import 'package:audio_call_app/services/signaling_service.dart';
import 'package:audio_call_app/webrtc_service.dart';
import 'signaling_service_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeWebSocketChannel fakeChannel;
  late SignalingService signalingService;
  late WebRTCService webrtcService;

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('FlutterWebRTC.Method'),
      (MethodCall call) async => null,
    );

    fakeChannel = FakeWebSocketChannel();
    signalingService = SignalingService(
      channelFactory: (uri) => fakeChannel,
    );
    webrtcService = WebRTCService(signalingService: signalingService);
  });

  tearDown(() {
    webrtcService.dispose();
    signalingService.dispose();
  });

  group('OutgoingCallScreen Tests', () {
    testWidgets('renders Calling [name] and pulsing ringing visual',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: OutgoingCallScreen(
            contactName: 'Alice',
            callId: 'call-100',
            signalingService: signalingService,
            webrtcService: webrtcService,
          ),
        ),
      );

      expect(find.text('Calling Alice...'), findsOneWidget);
      expect(find.text('Ringing...'), findsOneWidget);
      expect(find.byKey(const Key('cancel_call_button')), findsOneWidget);
    });

    testWidgets('tapping cancel button sends call_ended and pops',
        (WidgetTester tester) async {
      await signalingService.connect('caller-1');

      bool popped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => OutgoingCallScreen(
                      contactName: 'Alice',
                      callId: 'call-100',
                      otherUserId: 'callee-1',
                      signalingService: signalingService,
                      webrtcService: webrtcService,
                    ),
                  ),
                );
                popped = true;
              },
              child: const Text('Open Outgoing'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Outgoing'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.byKey(const Key('cancel_call_button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(popped, isTrue);
      // Verify call_ended was sent over websocket with to_user_id
      expect(
        fakeChannel.sentMessages.any((m) =>
            m.contains('call_ended') &&
            m.contains('call-100') &&
            m.contains('callee-1')),
        isTrue,
      );
    });
  });

  group('IncomingCallScreen Tests', () {
    testWidgets('renders [name] is calling and Accept/Decline buttons',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: IncomingCallScreen(
            callerName: 'Bob Builder',
            callerId: 'bob-123',
            callId: 'call-200',
            signalingService: signalingService,
            webrtcService: webrtcService,
          ),
        ),
      );

      expect(find.text('Bob Builder is calling...'), findsOneWidget);
      expect(find.text('Incoming Audio Call'), findsOneWidget);
      expect(find.byKey(const Key('accept_call_button')), findsOneWidget);
      expect(find.byKey(const Key('reject_call_button')), findsOneWidget);
    });

    testWidgets('tapping reject button sends call_rejected and pops',
        (WidgetTester tester) async {
      await signalingService.connect('callee-1');

      bool popped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => IncomingCallScreen(
                      callerName: 'Bob',
                      callerId: 'bob-123',
                      callId: 'call-200',
                      signalingService: signalingService,
                      webrtcService: webrtcService,
                    ),
                  ),
                );
                popped = true;
              },
              child: const Text('Open Incoming'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Incoming'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.byKey(const Key('reject_call_button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(popped, isTrue);
      // Verify call_rejected was sent with to_user_id
      expect(
        fakeChannel.sentMessages.any((m) =>
            m.contains('call_rejected') &&
            m.contains('call-200') &&
            m.contains('bob-123')),
        isTrue,
      );
    });

    testWidgets('tapping accept button sends call_accepted and navigates to InCallScreen',
        (WidgetTester tester) async {
      await signalingService.connect('callee-1');

      await tester.pumpWidget(
        MaterialApp(
          home: IncomingCallScreen(
            callerName: 'Bob',
            callerId: 'bob-123',
            callId: 'call-200',
            signalingService: signalingService,
            webrtcService: webrtcService,
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('accept_call_button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // Verify call_accepted was sent
      expect(
        fakeChannel.sentMessages.any((m) =>
            m.contains('call_accepted') &&
            m.contains('call-200') &&
            m.contains('bob-123')),
        isTrue,
      );

      // Verify replaced with InCallScreen showing Bob's name
      expect(find.byType(InCallScreen), findsOneWidget);
      expect(find.text('Bob'), findsOneWidget);
    });
  });

  group('InCallScreen Tests', () {
    testWidgets('renders other user name and controls',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: InCallScreen(
            otherUserName: 'Charlie Chaplin',
            callId: 'call-300',
            otherUserId: 'charlie-123',
            signalingService: signalingService,
            webrtcService: webrtcService,
          ),
        ),
      );

      expect(find.text('Charlie Chaplin'), findsOneWidget);
      expect(find.byKey(const Key('mute_btn')), findsOneWidget);
      expect(find.byKey(const Key('speaker_btn')), findsOneWidget);
      expect(find.byKey(const Key('end_call_button')), findsOneWidget);
    });

    testWidgets('defaults initial displayed status to Connecting... on mount',
        (WidgetTester tester) async {
      // webrtcService.callState is initially CallState.disconnected
      expect(webrtcService.callState, CallState.disconnected);

      await tester.pumpWidget(
        MaterialApp(
          home: InCallScreen(
            otherUserName: 'Charlie',
            callId: 'call-300',
            otherUserId: 'charlie-123',
            signalingService: signalingService,
            webrtcService: webrtcService,
          ),
        ),
      );

      // Verify that "Connecting..." is displayed and "Disconnected" is NOT displayed
      expect(find.text('Connecting...'), findsOneWidget);
      expect(find.text('Disconnected'), findsNothing);
    });

    testWidgets('tapping end call button sends call_ended and triggers callback/pop',
        (WidgetTester tester) async {
      await signalingService.connect('user-1');
      bool endCallCallbackFired = false;

      await tester.pumpWidget(
        MaterialApp(
          home: InCallScreen(
            otherUserName: 'Charlie',
            callId: 'call-300',
            otherUserId: 'charlie-123',
            signalingService: signalingService,
            webrtcService: webrtcService,
            onEndCall: () {
              endCallCallbackFired = true;
            },
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('end_call_button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(endCallCallbackFired, isTrue);
      // Verify call_ended was sent with to_user_id
      expect(
        fakeChannel.sentMessages.any((m) =>
            m.contains('call_ended') &&
            m.contains('call-300') &&
            m.contains('charlie-123')),
        isTrue,
      );
    });
  });
}
