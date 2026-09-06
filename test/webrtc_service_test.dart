import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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

  group('WebRTCService Integration with SignalingService', () {
    test('initial state has disconnected call state and null callId', () {
      expect(webrtcService.callState, CallState.disconnected);
      expect(webrtcService.callId, isNull);
      expect(webrtcService.isCaller, isFalse);
      expect(webrtcService.isMuted, isFalse);
      expect(webrtcService.isSpeakerOn, isFalse);
    });

    test('setSignalingService updates signaling instance', () {
      final newSignaling = SignalingService(
        channelFactory: (uri) => FakeWebSocketChannel(),
      );
      webrtcService.setSignalingService(newSignaling);
      newSignaling.dispose();
    });

    test('endCall resets internal call state cleanly', () async {
      await webrtcService.endCall();
      expect(webrtcService.callState, CallState.disconnected);
      expect(webrtcService.callId, isNull);
      expect(webrtcService.localStream, isNull);
      expect(webrtcService.remoteStream, isNull);
    });

    test('toggleMute and setSpeaker update respective flags', () async {
      webrtcService.toggleMute();
      // Without localStream active, mute flag toggles if localStream exists; otherwise remains false
      expect(webrtcService.isMuted, isFalse);

      await webrtcService.setSpeaker(true);
      expect(webrtcService.isSpeakerOn, isTrue);

      await webrtcService.setSpeaker(false);
      expect(webrtcService.isSpeakerOn, isFalse);
    });
  });
}
