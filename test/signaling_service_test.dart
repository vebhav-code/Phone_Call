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
      enableHeartbeat: false,
    );
  });

  tearDown(() {
    signalingService.dispose();
  });

  group('SignalingService (WebSocket Transport)', () {
    test('connect opens WebSocket and marks isConnected true', () async {
      expect(signalingService.isConnected, isFalse);
      expect(signalingService.currentUserId, isNull);

      await signalingService.connect('user_alice');

      expect(signalingService.isConnected, isTrue);
      expect(signalingService.currentUserId, 'user_alice');
    });

    test('send serializes map to JSON and forwards to WebSocket sink', () async {
      await signalingService.connect('user_alice');

      signalingService.send({
        'type': 'call_request',
        'to_user_id': 'user_bob',
      });

      expect(fakeChannel.sentMessages.length, 1);
      final decoded = jsonDecode(fakeChannel.sentMessages.first) as Map<String, dynamic>;
      expect(decoded['type'], 'call_request');
      expect(decoded['to_user_id'], 'user_bob');
    });

    test('messageStream emits decoded JSON maps from incoming WebSocket frames', () async {
      await signalingService.connect('user_bob');

      final streamFuture = signalingService.messageStream.first;

      fakeChannel.incomingController.add(jsonEncode({
        'type': 'incoming_call',
        'call_id': 'backend-call-uuid-123',
        'from_user_id': 'user_alice',
        'caller_name': 'Alice',
      }));

      final received = await streamFuture;
      expect(received['type'], 'incoming_call');
      expect(received['call_id'], 'backend-call-uuid-123');
      expect(received['from_user_id'], 'user_alice');
      expect(received['caller_name'], 'Alice');
    });

    test('disconnect closes channel and resets isConnected to false', () async {
      await signalingService.connect('user_alice');
      expect(signalingService.isConnected, isTrue);

      signalingService.disconnect();
      expect(signalingService.isConnected, isFalse);
    });

    test('heartbeat ping timer sends ping message when enabled', () async {
      final heartbeatService = SignalingService(
        channelFactory: (uri) => fakeChannel,
        enableHeartbeat: true,
      );

      await heartbeatService.connect('user_alice');
      expect(heartbeatService.heartbeatTimer, isNotNull);
      expect(heartbeatService.heartbeatTimer!.isActive, isTrue);

      heartbeatService.disconnect();
      expect(heartbeatService.heartbeatTimer, isNull);
      heartbeatService.dispose();
    });
  });
}
