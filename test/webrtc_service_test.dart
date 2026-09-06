import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:audio_call_app/webrtc_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late WebRTCService webrtcService;
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
            return {'sdp': 'v=0...mock-offer', 'type': 'offer'};
          case 'createAnswer':
            return {'sdp': 'v=0...mock-answer', 'type': 'answer'};
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

    webrtcService = WebRTCService();
  });

  tearDown(() async {
    await webrtcService.endCall();
    webrtcService.dispose();
  });

  group('WebRTCService (Audio-only, Local Candidates Only)', () {
    test('initial state has no active peer connection or streams', () {
      expect(webrtcService.peerConnection, isNull);
      expect(webrtcService.localStream, isNull);
      expect(webrtcService.remoteStream, isNull);
      expect(webrtcService.isMuted, isFalse);
      expect(webrtcService.isSpeakerOn, isFalse);
      expect(webrtcService.isConnected, isFalse);
    });

    test('initializePeerConnection creates peer connection with empty configuration', () async {
      await webrtcService.initializePeerConnection();

      expect(webrtcService.peerConnection, isNotNull);
      expect(webrtcService.localStream, isNotNull);

      // Verify createPeerConnection was called with empty configuration (no STUN/TURN)
      final createCall = methodCalls.firstWhere(
        (c) => c.method == 'createPeerConnection',
      );
      final config = createCall.arguments['configuration'] as Map<dynamic, dynamic>;
      expect(config.containsKey('iceServers'), isFalse);

      // Verify getUserMedia requested audio only (video: false)
      final mediaCall = methodCalls.firstWhere(
        (c) => c.method == 'getUserMedia',
      );
      final constraints = mediaCall.arguments['constraints'] as Map<dynamic, dynamic>;
      expect(constraints['video'], isFalse);
      expect(constraints['audio'], isNotNull);
    });

    test('createOffer produces SDP offer string', () async {
      await webrtcService.initializePeerConnection();
      final offerSdp = await webrtcService.createOffer();

      expect(offerSdp, 'v=0...mock-offer');
      expect(
        methodCalls.any((c) => c.method == 'createOffer'),
        isTrue,
      );
      expect(
        methodCalls.any((c) => c.method == 'setLocalDescription'),
        isTrue,
      );
    });

    test('handleOfferAndCreateAnswer sets remote description and creates answer', () async {
      await webrtcService.initializePeerConnection();
      final answerSdp = await webrtcService.handleOfferAndCreateAnswer('v=0...remote-offer');

      expect(answerSdp, 'v=0...mock-answer');
      expect(
        methodCalls.any((c) => c.method == 'setRemoteDescription'),
        isTrue,
      );
      expect(
        methodCalls.any((c) => c.method == 'createAnswer'),
        isTrue,
      );
    });

    test('handleAnswer sets remote description on caller side', () async {
      await webrtcService.initializePeerConnection();
      await webrtcService.createOffer();
      await webrtcService.handleAnswer('v=0...remote-answer');

      expect(
        methodCalls.any((c) =>
            c.method == 'setRemoteDescription' &&
            c.arguments['description']?['sdp'] == 'v=0...remote-answer'),
        isTrue,
      );
    });

    test('toggleMute and setSpeaker update states', () async {
      expect(webrtcService.isMuted, isFalse);
      webrtcService.toggleMute();
      expect(webrtcService.isMuted, isTrue);

      await webrtcService.setSpeaker(true);
      expect(webrtcService.isSpeakerOn, isTrue);

      await webrtcService.setSpeaker(false);
      expect(webrtcService.isSpeakerOn, isFalse);
    });

    test('endCall cleans up peer connection and streams cleanly', () async {
      await webrtcService.initializePeerConnection();
      expect(webrtcService.peerConnection, isNotNull);

      await webrtcService.endCall();
      expect(webrtcService.peerConnection, isNull);
      expect(webrtcService.localStream, isNull);
      expect(webrtcService.remoteStream, isNull);
    });
  });
}
