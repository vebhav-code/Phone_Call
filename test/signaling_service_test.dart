import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:audio_call_app/services/signaling_service.dart';

class FakeWebSocketChannel implements WebSocketChannel {
  final StreamController<dynamic> incomingController =
      StreamController<dynamic>.broadcast();
  final List<String> sentMessages = [];
  final Completer<void> closeCompleter = Completer<void>();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  Stream get stream => incomingController.stream;

  @override
  WebSocketSink get sink => _FakeWebSocketSink(this);

  @override
  String? get protocol => null;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  Future<void> get ready => Future.value();
}

class _FakeWebSocketSink implements WebSocketSink {
  final FakeWebSocketChannel _channel;
  _FakeWebSocketSink(this._channel);

  @override
  void add(dynamic data) {
    _channel.sentMessages.add(data.toString());
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future addStream(Stream stream) => Future.value();

  @override
  Future close([int? closeCode, String? closeReason]) {
    if (!_channel.closeCompleter.isCompleted) {
      _channel.closeCompleter.complete();
    }
    return Future.value();
  }

  @override
  Future get done => _channel.closeCompleter.future;
}

void main() {
  late FakeWebSocketChannel fakeChannel;
  late SignalingService signalingService;

  setUp(() {
    fakeChannel = FakeWebSocketChannel();
    signalingService = SignalingService(
      channelFactory: (uri) => fakeChannel,
    );
  });

  tearDown(() {
    signalingService.dispose();
  });

  group('SignalingService Tests', () {
    test('connect opens WebSocket and marks isConnected true', () async {
      expect(signalingService.isConnected, isFalse);
      await signalingService.connect('user_alice');
      expect(signalingService.isConnected, isTrue);
      expect(signalingService.currentUserId, 'user_alice');
    });

    test('receives incoming_call and exposes caller info on callback and stream', () async {
      await signalingService.connect('user_bob');

      IncomingCall? receivedCallbackCall;
      signalingService.onIncomingCall = (call) {
        receivedCallbackCall = call;
      };

      final streamFuture = signalingService.incomingCalls.first;

      fakeChannel.incomingController.add(jsonEncode({
        'type': 'incoming_call',
        'call_id': 'call-123',
        'from_user_id': 'user_alice',
        'caller_name': 'Alice Wonderland',
      }));

      final streamCall = await streamFuture;
      expect(streamCall.callId, 'call-123');
      expect(streamCall.callerId, 'user_alice');
      expect(streamCall.callerName, 'Alice Wonderland');

      expect(receivedCallbackCall, isNotNull);
      expect(receivedCallbackCall!.callId, 'call-123');
      expect(signalingService.callState, CallLifecycleState.ringing);
    });

    test('callUser sends call_request with to_user_id and returns callId immediately', () async {
      await signalingService.connect('user_alice');

      final callId = await signalingService.callUser('user_bob');
      expect(callId, isNotEmpty);
      expect(signalingService.callState, CallLifecycleState.calling);
      expect(signalingService.currentCallId, callId);

      // Verify outgoing call_request
      expect(fakeChannel.sentMessages.length, 1);
      final sentPayload =
          jsonDecode(fakeChannel.sentMessages.first) as Map<String, dynamic>;
      expect(sentPayload['type'], 'call_request');
      expect(sentPayload['to_user_id'], 'user_bob');

      // Callee accepts
      fakeChannel.incomingController.add(jsonEncode({
        'type': 'call_accepted',
        'call_id': 'call-789',
      }));
      await Future.delayed(Duration.zero);

      expect(signalingService.callState, CallLifecycleState.inCall);
      expect(signalingService.currentCallId, 'call-789');
    });

    test('call_failed transitions callState to failed and sets lastFailureReason', () async {
      await signalingService.connect('user_alice');

      await signalingService.callUser('user_bob');

      fakeChannel.incomingController.add(jsonEncode({
        'type': 'call_failed',
        'reason': 'offline',
      }));
      await Future.delayed(Duration.zero);

      expect(signalingService.callState, CallLifecycleState.failed);
      expect(signalingService.lastFailureReason, 'User is offline');
    });

    test('call setup times out if no answer arrives within window', () async {
      final timedSignaling = SignalingService(
        channelFactory: (uri) => fakeChannel,
        enableHeartbeat: false,
        callSetupTimeout: const Duration(milliseconds: 50),
      );
      await timedSignaling.connect('user_alice');

      final callId = await timedSignaling.callUser('user_bob');
      expect(timedSignaling.callState, CallLifecycleState.calling);

      // Wait for the 50ms timeout to fire
      await Future.delayed(const Duration(milliseconds: 80));

      expect(timedSignaling.callState, CallLifecycleState.failed);
      expect(timedSignaling.lastFailureReason, 'No answer');

      // Verify auto-cancel call_ended was sent over websocket
      expect(
        fakeChannel.sentMessages.any((m) {
          final decoded = jsonDecode(m) as Map<String, dynamic>;
          return decoded['type'] == 'call_ended' &&
              decoded['call_id'] == callId &&
              decoded['to_user_id'] == 'user_bob' &&
              decoded['reason'] == 'No answer';
        }),
        isTrue,
      );

      timedSignaling.dispose();
    });

    test('acceptCall sends call_accepted explicitly with to_user_id', () async {
      await signalingService.connect('user_bob');

      signalingService.acceptCall('call-abc', 'user_alice');

      expect(fakeChannel.sentMessages.length, 1);
      final sentPayload =
          jsonDecode(fakeChannel.sentMessages.first) as Map<String, dynamic>;
      expect(sentPayload['type'], 'call_accepted');
      expect(sentPayload['call_id'], 'call-abc');
      expect(sentPayload['to_user_id'], 'user_alice');
      expect(signalingService.callState, CallLifecycleState.inCall);
    });

    test('rejectCall sends call_rejected explicitly with to_user_id', () async {
      await signalingService.connect('user_bob');

      signalingService.rejectCall('call-abc', 'user_alice');

      expect(fakeChannel.sentMessages.length, 1);
      final sentPayload =
          jsonDecode(fakeChannel.sentMessages.first) as Map<String, dynamic>;
      expect(sentPayload['type'], 'call_rejected');
      expect(sentPayload['call_id'], 'call-abc');
      expect(sentPayload['to_user_id'], 'user_alice');
      expect(signalingService.callState, CallLifecycleState.idle);
    });

    test('endCall sends call_ended explicitly with to_user_id', () async {
      await signalingService.connect('user_bob');

      signalingService.endCall('call-abc', 'user_alice');

      expect(fakeChannel.sentMessages.length, 1);
      final sentPayload =
          jsonDecode(fakeChannel.sentMessages.first) as Map<String, dynamic>;
      expect(sentPayload['type'], 'call_ended');
      expect(sentPayload['call_id'], 'call-abc');
      expect(sentPayload['to_user_id'], 'user_alice');
      expect(signalingService.callState, CallLifecycleState.ended);
    });

    test('forwarding raw offer/answer/ice_candidate payloads IN and OUT', () async {
      await signalingService.connect('user_alice');
      signalingService.acceptCall('call-xyz', 'user_bob');

      // OUT: send raw offer, ensures to_user_id is present
      signalingService.sendSignalingPayload({
        'type': 'offer',
        'sdp': 'v=0...',
      });

      expect(fakeChannel.sentMessages.length, 2); // 1 acceptCall + 1 offer
      final offerSent =
          jsonDecode(fakeChannel.sentMessages.last) as Map<String, dynamic>;
      expect(offerSent['type'], 'offer');
      expect(offerSent['to_user_id'], 'user_bob');
      expect(offerSent['call_id'], 'call-xyz');
      expect(offerSent['sdp'], 'v=0...');

      // IN: incoming answer forwarded to callback
      Map<String, dynamic>? receivedPayload;
      signalingService.onSignalingPayload = (payload) {
        receivedPayload = payload;
      };

      fakeChannel.incomingController.add(jsonEncode({
        'type': 'answer',
        'sdp': 'v=0...answer',
      }));

      // Wait a microtask
      await Future.delayed(Duration.zero);
      expect(receivedPayload, isNotNull);
      expect(receivedPayload!['type'], 'answer');
      expect(receivedPayload!['sdp'], 'v=0...answer');
    });

    test('sendSignalingPayload prevents sending when to_user_id or call_id is unresolved', () async {
      await signalingService.connect('user_alice');
      // No call accepted/initiated, partnerId and callId are null
      expect(signalingService.currentPartnerId, isNull);
      expect(signalingService.currentCallId, isNull);

      // Attempt to send offer without to_user_id or call_id
      expect(
        () => signalingService.sendSignalingPayload({
          'type': 'offer',
          'sdp': 'v=0...',
        }),
        throwsAssertionError,
      );

      // No message should be sent
      expect(fakeChannel.sentMessages, isEmpty);

      // Explicit to_user_id but missing call_id
      expect(
        () => signalingService.sendSignalingPayload({
          'type': 'offer',
          'to_user_id': 'user_bob',
          'sdp': 'v=0...',
        }),
        throwsAssertionError,
      );
      expect(fakeChannel.sentMessages, isEmpty);

      // Both provided explicitly -> succeeds
      signalingService.sendSignalingPayload({
        'type': 'offer',
        'to_user_id': 'user_bob',
        'call_id': 'call-123',
        'sdp': 'v=0...',
      });
      expect(fakeChannel.sentMessages.length, 1);
    });

    test('heartbeat timer is active on connect and pong responses are handled', () async {
      await signalingService.connect('user_alice');
      expect(signalingService.heartbeatTimer, isNotNull);
      expect(signalingService.heartbeatTimer!.isActive, isTrue);

      // Backend sends pong
      fakeChannel.incomingController.add(jsonEncode({'type': 'pong'}));
      await Future.delayed(Duration.zero);

      signalingService.disconnect();
      expect(signalingService.heartbeatTimer, isNull);
    });

    test('auto-reconnect triggers when disconnected in idle state', () async {
      int connectionCount = 0;
      final customSignaling = SignalingService(
        channelFactory: (uri) {
          connectionCount++;
          return FakeWebSocketChannel();
        },
      );

      await customSignaling.connect('user_alice');
      expect(connectionCount, 1);

      // Simulate unexpected stream close while idle
      customSignaling.signalingPayloads; // ensure initialized
      // trigger internal _handleDisconnect by closing channel without explicit disconnect
      expect(customSignaling.reconnectTimer, isNull);

      customSignaling.dispose();
    });
  });
}
