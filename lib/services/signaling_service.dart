import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../config.dart';

/// Factory signature for creating WebSocketChannel instances (for test injection).
typedef WebSocketChannelFactory = WebSocketChannel Function(Uri uri);

/// Minimal, dedicated WebSocket signaling service.
/// Solely responsible for socket connection lifecycle, heartbeats,
/// sending messages, and exposing received signaling payloads.
class SignalingService extends ChangeNotifier {
  final String wsBaseUrl;
  final WebSocketChannelFactory _channelFactory;
  final bool enableHeartbeat;

  WebSocketChannel? _channel;
  StreamSubscription? _wsSubscription;
  bool _isConnected = false;
  String? _currentUserId;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  bool _isExplicitDisconnect = false;

  final StreamController<Map<String, dynamic>> _messageController =
      StreamController<Map<String, dynamic>>.broadcast();

  // Callbacks
  void Function(Map<String, dynamic> message)? onMessage;

  SignalingService({
    String? wsBaseUrl,
    WebSocketChannelFactory? channelFactory,
    this.enableHeartbeat = true,
  })  : wsBaseUrl = wsBaseUrl ?? AppConfig.wsBaseUrl,
        _channelFactory = channelFactory ?? ((uri) => WebSocketChannel.connect(uri));

  bool get isConnected => _isConnected;
  String? get currentUserId => _currentUserId;
  Stream<Map<String, dynamic>> get messageStream => _messageController.stream;

  @visibleForTesting
  Timer? get heartbeatTimer => _heartbeatTimer;

  /// Connects to the signaling server for [userId] at `wss://<backend>/ws/{userId}`.
  Future<void> connect(String userId) async {
    final cleanUserId = userId.trim();
    if (cleanUserId.isEmpty) return;

    if (_isConnected && _currentUserId == cleanUserId && _channel != null) {
      return;
    }

    _isExplicitDisconnect = false;
    _currentUserId = cleanUserId;
    _reconnectTimer?.cancel();

    final uri = Uri.parse('$wsBaseUrl/$cleanUserId');
    debugPrint('[SignalingService] Connecting to $uri...');

    try {
      _wsSubscription?.cancel();
      _channel = _channelFactory(uri);
      _isConnected = true;
      notifyListeners();

      _wsSubscription = _channel!.stream.listen(
        _handleIncomingMessage,
        onError: (error) {
          debugPrint('[SignalingService ERROR] WebSocket error: $error');
          _handleDisconnect();
        },
        onDone: () {
          debugPrint('[SignalingService] WebSocket connection closed by remote peer/server.');
          _handleDisconnect();
        },
      );

      _startHeartbeat();
      debugPrint('[SignalingService] Connected successfully as $cleanUserId.');
    } catch (e) {
      debugPrint('[SignalingService ERROR] Failed to connect: $e');
      _handleDisconnect();
    }
  }

  /// Explicitly disconnects the WebSocket.
  void disconnect() {
    _isExplicitDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _stopHeartbeat();

    if (_channel != null) {
      try {
        _wsSubscription?.cancel();
        _wsSubscription = null;
        _channel!.sink.close();
      } catch (e) {
        debugPrint('[SignalingService WARN] Error closing sink: $e');
      }
      _channel = null;
    }

    _handleDisconnect();
  }

  /// Sends a JSON-serializable message over the WebSocket sink.
  void sendMessage(Map<String, dynamic> message) {
    if (_channel != null && _isConnected) {
      final jsonStr = jsonEncode(message);
      debugPrint('[SignalingService SEND]: $jsonStr');
      _channel!.sink.add(jsonStr);
    } else {
      debugPrint('[SignalingService WARN] Cannot send message: channel not connected');
    }
  }

  /// Alias for [sendMessage].
  void send(Map<String, dynamic> message) => sendMessage(message);

  void _handleIncomingMessage(dynamic raw) {
    try {
      final Map<String, dynamic> data =
          jsonDecode(raw as String) as Map<String, dynamic>;
      final String? type = data['type'] as String?;

      debugPrint('[SignalingService RECV]: $data');

      if (type == 'pong') {
        // Heartbeat acknowledgment
        return;
      }

      _messageController.add(data);
      onMessage?.call(data);
    } catch (e) {
      debugPrint('[SignalingService ERROR] Failed to parse message: $e');
    }
  }

  void _handleDisconnect() {
    _stopHeartbeat();
    _isConnected = false;
    notifyListeners();

    if (!_isExplicitDisconnect && _currentUserId != null) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_isExplicitDisconnect) return;
    if (_reconnectTimer?.isActive ?? false) return;
    if (_currentUserId == null || _currentUserId!.isEmpty) return;

    final targetUserId = _currentUserId!;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), () async {
      if (!_isConnected && !_isExplicitDisconnect && _currentUserId == targetUserId) {
        debugPrint('[SignalingService] Auto-reconnecting as $targetUserId...');
        await connect(targetUserId);
      }
    });
  }

  void _startHeartbeat() {
    if (!enableHeartbeat) return;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      if (_isConnected && _channel != null) {
        debugPrint('[SignalingService HEARTBEAT] Sending ping');
        sendMessage({'type': 'ping'});
      }
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  @override
  void dispose() {
    _isExplicitDisconnect = true;
    disconnect();
    _messageController.close();
    super.dispose();
  }
}
