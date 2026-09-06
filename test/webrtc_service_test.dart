import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:audio_call_app/services/api_service.dart';
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

  group('Dynamic ICE Configuration & Caching', () {
    test('fetches and caches ICE servers for TTL duration with user_id', () async {
      await signalingService.connect('turn-user-1');
      int fetchCount = 0;
      final mockClient = MockClient((request) async {
        if (request.url.path == '/turn-credentials') {
          fetchCount++;
          expect(request.url.queryParameters['user_id'], 'turn-user-1');
          return http.Response(
            jsonEncode({
              'iceServers': [
                {'urls': 'stun:stun.l.google.com:19302'},
                {
                  'urls': ['turn:turn.example.com:3478?transport=udp'],
                  'username': 'turn-user',
                  'credential': 'turn-password',
                },
              ],
              'ttl': 3600,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('Not found', 404);
      });

      final apiService = ApiService(client: mockClient);
      final service = WebRTCService(
        signalingService: signalingService,
        apiService: apiService,
      );

      // First call fetches from backend
      final servers1 = await service.getIceServers();
      expect(fetchCount, 1);
      expect(servers1.length, 2);
      expect(servers1[0]['urls'], 'stun:stun.l.google.com:19302');
      expect(servers1[1]['username'], 'turn-user');
      expect(service.cachedIceServers, isNotNull);
      expect(service.iceServersExpiry, isNotNull);

      // Immediate second call uses cache (does not hit network again)
      final servers2 = await service.getIceServers();
      expect(fetchCount, 1);
      expect(servers2.length, 2);

      service.dispose();
    });

    test('falls back to STUN-only when currentUserId is null without calling backend', () async {
      // signalingService is not connected, currentUserId is null
      expect(signalingService.currentUserId, isNull);
      int fetchCount = 0;
      final mockClient = MockClient((request) async {
        fetchCount++;
        return http.Response('Should not be called', 500);
      });

      final apiService = ApiService(client: mockClient);
      final service = WebRTCService(
        signalingService: signalingService,
        apiService: apiService,
      );

      final servers = await service.getIceServers();
      expect(fetchCount, 0); // network request skipped
      expect(servers.length, 1);
      expect(servers[0]['urls'], 'stun:stun.l.google.com:19302');

      service.dispose();
    });

    test('respects timeout and falls back to STUN-only rather than hanging', () async {
      await signalingService.connect('timeout-user');
      final mockClient = MockClient((request) async {
        throw TimeoutException('Request timed out after 5s');
      });

      final apiService = ApiService(client: mockClient);
      final service = WebRTCService(
        signalingService: signalingService,
        apiService: apiService,
      );

      final servers = await service.getIceServers();
      expect(servers.length, 1);
      expect(servers[0]['urls'], 'stun:stun.l.google.com:19302');

      service.dispose();
    });

    test('falls back to default STUN without crashing if fetch returns error', () async {
      await signalingService.connect('error-user');
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({'detail': 'Internal Server Error'}),
          500,
          headers: {'content-type': 'application/json'},
        );
      });

      final apiService = ApiService(client: mockClient);
      final service = WebRTCService(
        signalingService: signalingService,
        apiService: apiService,
      );

      final servers = await service.getIceServers();
      expect(servers.length, 1);
      expect(servers[0]['urls'], 'stun:stun.l.google.com:19302');

      service.dispose();
    });
  });

  group('ICE Restart Resilience', () {
    test('handles first ICE failure by triggering restart on caller side', () async {
      webrtcService.setIsCaller(true);
      webrtcService.setCallStateForTesting(CallState.connected);
      expect(webrtcService.hasAttemptedIceRestart, isFalse);

      webrtcService.handleIceFailureOrTimeout();

      expect(webrtcService.hasAttemptedIceRestart, isTrue);
      // First restart attempt should not immediately mark call as disconnected
      expect(webrtcService.callState, CallState.connected);
    });

    test('callee waits for restart offer and marks hasAttemptedIceRestart', () async {
      webrtcService.setIsCaller(false);
      webrtcService.setCallStateForTesting(CallState.connected);
      expect(webrtcService.hasAttemptedIceRestart, isFalse);

      webrtcService.handleIceFailureOrTimeout();

      expect(webrtcService.hasAttemptedIceRestart, isTrue);
      expect(webrtcService.callState, CallState.connected);
    });

    test('subsequent failure after restart attempt transitions to disconnected', () async {
      webrtcService.setIsCaller(true);
      webrtcService.setCallStateForTesting(CallState.connected);

      // First failure
      webrtcService.handleIceFailureOrTimeout();
      expect(webrtcService.hasAttemptedIceRestart, isTrue);
      expect(webrtcService.callState, CallState.connected);

      // Second failure when restart was already attempted
      webrtcService.handleIceFailureOrTimeout();
      expect(webrtcService.callState, CallState.disconnected);
    });
  });
}
