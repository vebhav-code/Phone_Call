import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:audio_call_app/screens/in_call_screen.dart';
import 'package:audio_call_app/screens/incoming_call_screen.dart';
import 'package:audio_call_app/screens/outgoing_call_screen.dart';
import 'package:audio_call_app/services/call_controller.dart';
import 'package:audio_call_app/services/signaling_service.dart';
import 'package:audio_call_app/webrtc_service.dart';
import 'signaling_service_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeWebSocketChannel fakeChannel;
  late SignalingService signalingService;
  late WebRTCService webrtcService;
  late CallController callController;

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('FlutterWebRTC.Method'),
      (MethodCall call) async {
        switch (call.method) {
          case 'getUserMedia':
            return {'streamId': 'mock-stream', 'tracks': []};
          case 'createPeerConnection':
            return {'peerConnectionId': 'mock-pc'};
          case 'createOffer':
            return {'sdp': 'v=0...mock-offer', 'type': 'offer'};
          case 'createAnswer':
            return {'sdp': 'v=0...mock-answer', 'type': 'answer'};
          default:
            return null;
        }
      },
    );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.ryanheise.audio_session'),
      (MethodCall call) async => null,
    );

    fakeChannel = FakeWebSocketChannel();
    signalingService = SignalingService(
      channelFactory: (uri) => fakeChannel,
      enableHeartbeat: false,
    );
    webrtcService = WebRTCService();
    callController = CallController(
      signalingService: signalingService,
      webrtcService: webrtcService,
    );
  });

  tearDown(() async {
    await callController.endCall();
    callController.dispose();
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
            callController: callController,
          ),
        ),
      );

      expect(find.text('Calling Alice...'), findsOneWidget);
      expect(find.text('Ringing...'), findsOneWidget);
      expect(find.byKey(const Key('cancel_call_button')), findsOneWidget);
    });

    testWidgets('tapping cancel button calls endCall and pops',
        (WidgetTester tester) async {
      await signalingService.connect('caller-1');
      callController.startCall('callee-1', 'Alice');
      fakeChannel.sentMessages.clear();

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
                      otherUserId: 'callee-1',
                      callController: callController,
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
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byKey(const Key('cancel_call_button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(popped, isTrue);
      expect(callController.state, CallState.idle);
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
            callController: callController,
          ),
        ),
      );

      expect(find.text('Bob Builder is calling...'), findsOneWidget);
      expect(find.text('Incoming Audio Call'), findsOneWidget);
      expect(find.byKey(const Key('accept_call_button')), findsOneWidget);
      expect(find.byKey(const Key('reject_call_button')), findsOneWidget);
    });

    testWidgets('tapping reject button calls rejectCall and pops',
        (WidgetTester tester) async {
      await signalingService.connect('callee-1');

      fakeChannel.incomingController.add(jsonEncode({
        'type': 'incoming_call',
        'call_id': 'call-200',
        'from_user_id': 'bob-123',
        'caller_name': 'Bob',
      }));

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
                      callController: callController,
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
      await tester.pump();

      fakeChannel.sentMessages.clear();

      await tester.tap(find.text('Open Incoming'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byKey(const Key('reject_call_button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(popped, isTrue);
      expect(
        fakeChannel.sentMessages.any((m) {
          final decoded = jsonDecode(m) as Map<String, dynamic>;
          return decoded['type'] == 'call_rejected' &&
              decoded['call_id'] == 'call-200' &&
              decoded['to_user_id'] == 'bob-123';
        }),
        isTrue,
      );
      expect(callController.state, CallState.idle);
    });

    testWidgets('tapping accept button calls acceptCall and replaces with InCallScreen',
        (WidgetTester tester) async {
      await signalingService.connect('callee-1');

      fakeChannel.incomingController.add(jsonEncode({
        'type': 'incoming_call',
        'call_id': 'call-200',
        'from_user_id': 'bob-123',
        'caller_name': 'Bob',
      }));

      await tester.pumpWidget(
        MaterialApp(
          home: IncomingCallScreen(
            callerName: 'Bob',
            callerId: 'bob-123',
            callId: 'call-200',
            callController: callController,
          ),
        ),
      );
      await tester.pump();
      fakeChannel.sentMessages.clear();

      await tester.tap(find.byKey(const Key('accept_call_button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      // Verify call_accepted sent with authoritative call_id
      expect(
        fakeChannel.sentMessages.any((m) {
          final decoded = jsonDecode(m) as Map<String, dynamic>;
          return decoded['type'] == 'call_accepted' &&
              decoded['call_id'] == 'call-200' &&
              decoded['to_user_id'] == 'bob-123';
        }),
        isTrue,
      );

      // Verify replaced with InCallScreen
      expect(find.byType(InCallScreen), findsOneWidget);
      expect(find.text('Bob'), findsOneWidget);
    });
  });

  group('InCallScreen Tests', () {
    testWidgets('renders other user name and controls (Mute, Speaker, End Call)',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: InCallScreen(
            otherUserName: 'Charlie Chaplin',
            callId: 'call-300',
            otherUserId: 'charlie-123',
            callController: callController,
          ),
        ),
      );

      expect(find.text('Charlie Chaplin'), findsOneWidget);
      expect(find.byKey(const Key('mute_btn')), findsOneWidget);
      expect(find.byKey(const Key('speaker_btn')), findsOneWidget);
      expect(find.byKey(const Key('end_call_button')), findsOneWidget);
    });

    testWidgets('tapping end call button sends call_ended and triggers callback/pop',
        (WidgetTester tester) async {
      await signalingService.connect('user-1');
      callController.startCall('charlie-123', 'Charlie');

      fakeChannel.incomingController.add(jsonEncode({
        'type': 'call_accepted',
        'call_id': 'call-300',
      }));

      bool endCallCallbackFired = false;

      await tester.pumpWidget(
        MaterialApp(
          home: InCallScreen(
            otherUserName: 'Charlie',
            callId: 'call-300',
            otherUserId: 'charlie-123',
            callController: callController,
            onEndCall: () {
              endCallCallbackFired = true;
            },
          ),
        ),
      );
      await tester.pump();
      fakeChannel.sentMessages.clear();

      await tester.tap(find.byKey(const Key('end_call_button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(endCallCallbackFired, isTrue);
      expect(
        fakeChannel.sentMessages.any((m) {
          final decoded = jsonDecode(m) as Map<String, dynamic>;
          return decoded['type'] == 'call_ended' &&
              decoded['call_id'] == 'call-300' &&
              decoded['to_user_id'] == 'charlie-123';
        }),
        isTrue,
      );
      expect(callController.state, CallState.idle);
    });

    testWidgets('system back gesture is intercepted by PopScope and triggers _handleEndCall',
        (WidgetTester tester) async {
      await signalingService.connect('user-1');
      callController.startCall('charlie-123', 'Charlie');

      fakeChannel.incomingController.add(jsonEncode({
        'type': 'call_accepted',
        'call_id': 'call-300',
      }));

      bool endCallCallbackFired = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => InCallScreen(
                      otherUserName: 'Charlie',
                      callId: 'call-300',
                      otherUserId: 'charlie-123',
                      callController: callController,
                      onEndCall: () {
                        endCallCallbackFired = true;
                      },
                    ),
                  ),
                );
              },
              child: const Text('Go InCall'),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Go InCall'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final popScope = tester.widget<PopScope>(find.byType(PopScope));
      expect(popScope.canPop, isFalse);

      // Simulate system back button / gesture
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(endCallCallbackFired, isTrue);
      expect(callController.state, CallState.idle);
    });
  });
}
