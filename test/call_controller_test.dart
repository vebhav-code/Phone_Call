import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
  final List<MethodCall> methodCalls = [];

  setUp(() {
    methodCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('FlutterWebRTC.Method'),
      (MethodCall call) async {
        methodCalls.add(call);
        switch (call.method) {
          case 'getUserMedia':
            return {'streamId': 'mock-stream', 'tracks': []};
          case 'createPeerConnection':
            return {'peerConnectionId': 'mock-pc'};
          case 'createOffer':
            return {'sdp': 'v=0...mock-caller-offer', 'type': 'offer'};
          case 'createAnswer':
            return {'sdp': 'v=0...mock-callee-answer', 'type': 'answer'};
          case 'setLocalDescription':
          case 'setRemoteDescription':
          case 'addTrack':
          case 'peerConnectionClose':
          case 'streamDispose':
            return null;
          default:
            return null;
        }
      },
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

  group('CallController (Simple 1-to-1 WebRTC Call Flow)', () {
    test('initial state is idle and has no active call_id', () {
      expect(callController.state, CallState.idle);
      expect(callController.currentCallId, isNull);
      expect(callController.otherUserId, isNull);
    });

    test('Caller Flow: startCall sends call_request without call_id, enters calling state', () async {
      await signalingService.connect('user_a');

      callController.startCall('user_b', 'Bob');

      expect(callController.state, CallState.calling);
      expect(callController.currentCallId, isNull); // Backend authoritative ID not yet received
      expect(callController.otherUserId, 'user_b');
      expect(callController.otherUserName, 'Bob');

      // Verify outgoing call_request has NO call_id
      expect(fakeChannel.sentMessages.length, 1);
      final sent = jsonDecode(fakeChannel.sentMessages.first) as Map<String, dynamic>;
      expect(sent['type'], 'call_request');
      expect(sent['to_user_id'], 'user_b');
      expect(sent.containsKey('call_id'), isFalse);
    });

    test('Caller Flow: backend sends call_accepted -> stores call_id, creates offer, enters connecting', () async {
      await signalingService.connect('user_a');
      callController.startCall('user_b', 'Bob');
      fakeChannel.sentMessages.clear();

      // Callee accepts -> Backend delivers call_accepted with authoritative call_id
      fakeChannel.incomingController.add(jsonEncode({
        'type': 'call_accepted',
        'call_id': 'backend-authoritative-call-123',
      }));

      await Future.delayed(const Duration(milliseconds: 50));

      // State transitions to connecting
      expect(callController.state, CallState.connecting);
      expect(callController.currentCallId, 'backend-authoritative-call-123');

      // Verify SDP offer was dispatched with authoritative call_id
      expect(
        fakeChannel.sentMessages.any((m) {
          final decoded = jsonDecode(m) as Map<String, dynamic>;
          return decoded['type'] == 'offer' &&
              decoded['call_id'] == 'backend-authoritative-call-123' &&
              decoded['to_user_id'] == 'user_b' &&
              decoded['sdp'] == 'v=0...mock-caller-offer';
        }),
        isTrue,
      );
    });

    test('Receiver Flow: receives incoming_call -> enters ringing state with caller info', () async {
      await signalingService.connect('user_b');

      fakeChannel.incomingController.add(jsonEncode({
        'type': 'incoming_call',
        'call_id': 'backend-authoritative-call-456',
        'from_user_id': 'user_a',
        'caller_name': 'Alice',
      }));

      await Future.delayed(const Duration(milliseconds: 20));

      expect(callController.state, CallState.ringing);
      expect(callController.currentCallId, 'backend-authoritative-call-456');
      expect(callController.otherUserId, 'user_a');
      expect(callController.otherUserName, 'Alice');
    });

    test('Receiver Flow: acceptCall sends call_accepted with authoritative call_id', () async {
      await signalingService.connect('user_b');

      fakeChannel.incomingController.add(jsonEncode({
        'type': 'incoming_call',
        'call_id': 'backend-authoritative-call-456',
        'from_user_id': 'user_a',
        'caller_name': 'Alice',
      }));
      await Future.delayed(const Duration(milliseconds: 20));
      fakeChannel.sentMessages.clear();

      await callController.acceptCall();

      expect(callController.state, CallState.connecting);
      expect(fakeChannel.sentMessages.length, 1);
      final sent = jsonDecode(fakeChannel.sentMessages.first) as Map<String, dynamic>;
      expect(sent['type'], 'call_accepted');
      expect(sent['call_id'], 'backend-authoritative-call-456');
      expect(sent['to_user_id'], 'user_a');
    });

    test('Receiver Flow: receiving offer creates answer and sends it with call_id', () async {
      await signalingService.connect('user_b');

      fakeChannel.incomingController.add(jsonEncode({
        'type': 'incoming_call',
        'call_id': 'backend-authoritative-call-456',
        'from_user_id': 'user_a',
        'caller_name': 'Alice',
      }));
      await Future.delayed(const Duration(milliseconds: 20));
      await callController.acceptCall();
      fakeChannel.sentMessages.clear();

      // Caller's offer arrives
      fakeChannel.incomingController.add(jsonEncode({
        'type': 'offer',
        'call_id': 'backend-authoritative-call-456',
        'sdp': 'v=0...remote-caller-offer',
      }));

      await Future.delayed(const Duration(milliseconds: 50));

      // Verify answer was sent with authoritative call_id
      expect(
        fakeChannel.sentMessages.any((m) {
          final decoded = jsonDecode(m) as Map<String, dynamic>;
          return decoded['type'] == 'answer' &&
              decoded['call_id'] == 'backend-authoritative-call-456' &&
              decoded['to_user_id'] == 'user_a' &&
              decoded['sdp'] == 'v=0...mock-callee-answer';
        }),
        isTrue,
      );
    });

    test('Receiver Flow: rejectCall sends call_rejected with call_id and returns to idle', () async {
      await signalingService.connect('user_b');

      fakeChannel.incomingController.add(jsonEncode({
        'type': 'incoming_call',
        'call_id': 'backend-authoritative-call-456',
        'from_user_id': 'user_a',
        'caller_name': 'Alice',
      }));
      await Future.delayed(const Duration(milliseconds: 20));
      fakeChannel.sentMessages.clear();

      callController.rejectCall();

      expect(callController.state, CallState.idle);
      expect(callController.currentCallId, isNull);

      expect(fakeChannel.sentMessages.length, 1);
      final sent = jsonDecode(fakeChannel.sentMessages.first) as Map<String, dynamic>;
      expect(sent['type'], 'call_rejected');
      expect(sent['call_id'], 'backend-authoritative-call-456');
      expect(sent['to_user_id'], 'user_a');
    });

    test('End Call Flow: endCall sends call_ended with call_id, stops WebRTC, returns to idle', () async {
      await signalingService.connect('user_a');
      callController.startCall('user_b', 'Bob');

      fakeChannel.incomingController.add(jsonEncode({
        'type': 'call_accepted',
        'call_id': 'backend-call-777',
      }));
      await Future.delayed(const Duration(milliseconds: 30));
      fakeChannel.sentMessages.clear();

      await callController.endCall();

      expect(callController.state, CallState.idle);
      expect(callController.currentCallId, isNull);
      expect(callController.otherUserId, isNull);

      expect(fakeChannel.sentMessages.length, 1);
      final sent = jsonDecode(fakeChannel.sentMessages.first) as Map<String, dynamic>;
      expect(sent['type'], 'call_ended');
      expect(sent['call_id'], 'backend-call-777');
      expect(sent['to_user_id'], 'user_b');
    });

    test('Remote End Call: receiving call_ended transitions state to ended and cleans up WebRTC', () async {
      await signalingService.connect('user_a');
      callController.startCall('user_b', 'Bob');

      fakeChannel.incomingController.add(jsonEncode({
        'type': 'call_accepted',
        'call_id': 'backend-call-888',
      }));
      await Future.delayed(const Duration(milliseconds: 30));

      // Remote peer ends call
      fakeChannel.incomingController.add(jsonEncode({
        'type': 'call_ended',
        'call_id': 'backend-call-888',
      }));
      await Future.delayed(const Duration(milliseconds: 30));

      expect(callController.state, CallState.ended);
      expect(callController.currentCallId, isNull);
    });

    test('Offline/Busy Handling: call_failed transitions state to ended with reason', () async {
      await signalingService.connect('user_a');
      callController.startCall('user_b', 'Bob');

      fakeChannel.incomingController.add(jsonEncode({
        'type': 'call_failed',
        'reason': 'offline',
      }));
      await Future.delayed(const Duration(milliseconds: 20));

      expect(callController.state, CallState.ended);
      expect(callController.lastFailureReason, 'User is offline');
    });
  });
}
