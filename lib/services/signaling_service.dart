import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Lifecycle states of a 1-to-1 audio call.
enum CallLifecycleState {
  idle,
  calling,
  ringing, // incoming call
  connecting,
  inCall,
  ended,
  failed,
}

/// Represents an incoming call event from a remote peer.
class IncomingCall {
  final String callId;
  final String callerId;
  final String callerName;

  const IncomingCall({
    required this.callId,
    required this.callerId,
    required this.callerName,
  });

  @override
  String toString() =>
      'IncomingCall(callId: $callId, callerId: $callerId, callerName: $callerName)';
}

/// Thrown when a call fails to establish (e.g. peer is offline or busy).
class CallFailedException implements Exception {
  final String reason;
  const CallFailedException(this.reason);

  @override
  String toString() => 'CallFailedException: $reason';
}

/// Thrown when a call is explicitly rejected by the callee.
class CallRejectedException implements Exception {
  final String reason;
  const CallRejectedException([this.reason = 'Call rejected']);

  @override
  String toString() => 'CallRejectedException: $reason';
}

/// Factory signature for creating WebSocketChannel instances (useful for testing).
typedef WebSocketChannelFactory = WebSocketChannel Function(Uri uri);

/// Manages the persistent WebSocket connection to the signaling backend
/// for user presence, call session initiation, and forwarding raw
/// WebRTC payloads (offer, answer, ice_candidate).
class SignalingService extends ChangeNotifier {
  static const String defaultWsBaseUrl =
      'wss://calling-backend-1jxa.onrender.com/ws';

  final String wsBaseUrl;
  final WebSocketChannelFactory _channelFactory;
  final bool enableHeartbeat;
  final Duration callSetupTimeout;

  // Connection state
  WebSocketChannel? _channel;
  StreamSubscription? _wsSubscription;
  bool _isConnected = false;
  String? _currentUserId;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  Timer? _callSetupTimer;
  bool _isExplicitDisconnect = false;

  // Call lifecycle state
  CallLifecycleState _callState = CallLifecycleState.idle;
  String? _currentCallId;
  String? _currentPartnerId;
  IncomingCall? _currentIncomingCall;
  String? _lastFailureReason;

  // Stream controllers
  final StreamController<IncomingCall> _incomingCallController =
      StreamController<IncomingCall>.broadcast();
  final StreamController<Map<String, dynamic>> _signalingPayloadController =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<CallLifecycleState> _callStateController =
      StreamController<CallLifecycleState>.broadcast();

  // Callbacks
  void Function(IncomingCall call)? onIncomingCall;
  void Function(Map<String, dynamic> payload)? onSignalingPayload;
  void Function(CallLifecycleState state)? onCallStateChanged;

  SignalingService({
    this.wsBaseUrl = defaultWsBaseUrl,
    WebSocketChannelFactory? channelFactory,
    this.enableHeartbeat = true,
    this.callSetupTimeout = const Duration(seconds: 35),
  }) : _channelFactory = channelFactory ?? WebSocketChannel.connect;

  // Public getters
  bool get isConnected => _isConnected;
  String? get currentUserId => _currentUserId;
  CallLifecycleState get callState => _callState;
  String? get currentCallId => _currentCallId;
  String? get currentPartnerId => _currentPartnerId;
  IncomingCall? get currentIncomingCall => _currentIncomingCall;
  String? get lastFailureReason => _lastFailureReason;

  Stream<IncomingCall> get incomingCalls => _incomingCallController.stream;
  Stream<Map<String, dynamic>> get signalingPayloads =>
      _signalingPayloadController.stream;
  Stream<CallLifecycleState> get callStateStream =>
      _callStateController.stream;

  @visibleForTesting
  Timer? get heartbeatTimer => _heartbeatTimer;

  @visibleForTesting
  Timer? get reconnectTimer => _reconnectTimer;

  @visibleForTesting
  Timer? get callSetupTimer => _callSetupTimer;

  /// Opens the persistent WebSocket connection for [userId].
  Future<void> connect(String userId) async {
    final cleanUserId = userId.trim();
    if (cleanUserId.isEmpty) return;

    _isExplicitDisconnect = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    if (_isConnected && _currentUserId == cleanUserId) {
      debugPrint('[SignalingService] Already connected as $cleanUserId');
      return;
    }

    // Disconnect any previous connection
    _disconnectInternal();

    _currentUserId = cleanUserId;
    final uri = Uri.parse('$wsBaseUrl/$cleanUserId');
    debugPrint('[SignalingService] Connecting to $uri...');

    try {
      _channel = _channelFactory(uri);
      _isConnected = true;
      notifyListeners();

      _startHeartbeat();

      _wsSubscription = _channel!.stream.listen(
        _handleIncomingMessage,
        onError: (error) {
          debugPrint('[SignalingService ERROR] WebSocket error: $error');
          _handleDisconnect();
        },
        onDone: () {
          debugPrint('[SignalingService] WebSocket closed');
          _handleDisconnect();
        },
      );
    } catch (e) {
      debugPrint('[SignalingService ERROR] Failed to connect: $e');
      _handleDisconnect();
    }
  }

  /// Closes the persistent WebSocket connection explicitly.
  void disconnect() {
    _isExplicitDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _disconnectInternal();
  }

  void _disconnectInternal() {
    _stopHeartbeat();
    _wsSubscription?.cancel();
    _wsSubscription = null;

    if (_channel != null) {
      try {
        _channel!.sink.close();
      } catch (_) {}
      _channel = null;
    }

    _handleDisconnect();
  }

  void _startHeartbeat() {
    if (!enableHeartbeat) return;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      if (_isConnected && _channel != null) {
        debugPrint('[SignalingService HEARTBEAT] Sending ping');
        _sendSignalingMessage({'type': 'ping'});
      }
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  void _scheduleReconnect() {
    if (_isExplicitDisconnect) return;
    if (_reconnectTimer?.isActive ?? false) return;
    if (_callState != CallLifecycleState.idle &&
        _callState != CallLifecycleState.ended &&
        _callState != CallLifecycleState.failed) {
      debugPrint(
        '[SignalingService] Socket dropped while in active call (state: $_callState). Auto-reconnect suppressed.',
      );
      return;
    }
    if (_currentUserId == null || _currentUserId!.isEmpty) return;

    final targetUserId = _currentUserId!;
    debugPrint(
      '[SignalingService] Scheduling auto-reconnect in 3s for user $targetUserId...',
    );
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), () async {
      if (!_isConnected && !_isExplicitDisconnect && _currentUserId == targetUserId) {
        debugPrint('[SignalingService] Auto-reconnecting as $targetUserId...');
        await connect(targetUserId);
      }
    });
  }

  /// Initiates an outgoing call to [contactUserId].
  /// Sends `call_request`, starts the call-setup timeout timer, and returns
  /// immediately with [callId] so the caller UI can navigate to [OutgoingCallScreen]
  /// right away rather than waiting for remote acceptance.
  Future<String> callUser(String contactUserId) async {
    final cleanTargetId = contactUserId.trim();
    if (!_isConnected || _channel == null) {
      _setCallState(CallLifecycleState.failed);
      throw const CallFailedException('WebSocket is not connected');
    }

    if (_callState != CallLifecycleState.idle &&
        _callState != CallLifecycleState.ended &&
        _callState != CallLifecycleState.failed) {
      throw const CallFailedException('Already in an active or pending call');
    }

    final callId = 'call_${DateTime.now().millisecondsSinceEpoch}';
    _currentCallId = callId;
    _currentPartnerId = cleanTargetId;
    _lastFailureReason = null;
    _setCallState(CallLifecycleState.calling);

    _sendSignalingMessage({
      'type': 'call_request',
      'call_id': callId,
      'to_user_id': cleanTargetId,
    });

    _startCallSetupTimeout(cleanTargetId, callId);

    return callId;
  }

  void _startCallSetupTimeout(String targetUserId, String callId) {
    _cancelCallSetupTimeout();
    _callSetupTimer = Timer(callSetupTimeout, () {
      if (_callState == CallLifecycleState.calling && _currentCallId == callId) {
        debugPrint(
          '[SignalingService] Call setup timed out after ${callSetupTimeout.inSeconds}s with no answer from $targetUserId. Auto-cancelling call.',
        );
        _sendSignalingMessage({
          'type': 'call_ended',
          'call_id': callId,
          'to_user_id': targetUserId,
          'reason': 'No answer',
        });
        _lastFailureReason = 'No answer';
        _currentCallId = null;
        _currentPartnerId = null;
        _currentIncomingCall = null;
        _setCallState(CallLifecycleState.failed);
      }
    });
  }

  void _cancelCallSetupTimeout() {
    _callSetupTimer?.cancel();
    _callSetupTimer = null;
  }

  /// Accepts an incoming call with [callId] from [callerId].
  /// Explicitly includes [to_user_id] in the payload.
  void acceptCall(String callId, String callerId) {
    _cancelCallSetupTimeout();
    _currentCallId = callId;
    _currentPartnerId = callerId;
    _currentIncomingCall = null;
    _lastFailureReason = null;

    _sendSignalingMessage({
      'type': 'call_accepted',
      'call_id': callId,
      'to_user_id': callerId,
    });

    _setCallState(CallLifecycleState.inCall);
  }

  /// Rejects an incoming call with [callId] from [callerId].
  /// Explicitly includes [to_user_id] in the payload.
  void rejectCall(String callId, String callerId) {
    _cancelCallSetupTimeout();
    _sendSignalingMessage({
      'type': 'call_rejected',
      'call_id': callId,
      'to_user_id': callerId,
    });

    _currentIncomingCall = null;
    if (_currentCallId == callId) {
      _currentCallId = null;
      _currentPartnerId = null;
    }

    _setCallState(CallLifecycleState.idle);
  }

  /// Ends an active call or cancels an outgoing call.
  /// Explicitly includes [to_user_id] in the payload (falling back to [_currentPartnerId] if omitted).
  void endCall(String callId, [String? otherUserId]) {
    _cancelCallSetupTimeout();
    final targetUserId = (otherUserId != null && otherUserId.trim().isNotEmpty)
        ? otherUserId.trim()
        : (_currentPartnerId ?? '');

    _sendSignalingMessage({
      'type': 'call_ended',
      'call_id': callId,
      'to_user_id': targetUserId,
    });

    _currentCallId = null;
    _currentPartnerId = null;
    _currentIncomingCall = null;
    _setCallState(CallLifecycleState.ended);
  }

  /// Forwards raw offer, answer, or ice_candidate payloads OUT to the remote peer.
  /// Automatically injects [to_user_id] and [call_id] if omitted, validating both before sending.
  void sendSignalingPayload(Map<String, dynamic> payload) {
    final Map<String, dynamic> message = Map<String, dynamic>.from(payload);

    final String? toUserId =
        (message['to_user_id'] ?? _currentPartnerId)?.toString();
    final String? callId =
        (message['call_id'] ?? _currentCallId)?.toString();

    if (toUserId == null || toUserId.trim().isEmpty) {
      final errorMsg =
          '[SignalingService ERROR] Cannot forward signaling payload "${message['type']}": "to_user_id" is null or empty (payload: $payload, currentPartnerId: $_currentPartnerId). Silent message loss prevented.';
      debugPrint(errorMsg);
      assert(false, errorMsg);
      return;
    }

    if (callId == null || callId.trim().isEmpty) {
      final errorMsg =
          '[SignalingService ERROR] Cannot forward signaling payload "${message['type']}": "call_id" is null or empty (payload: $payload, currentCallId: $_currentCallId). Silent message loss prevented.';
      debugPrint(errorMsg);
      assert(false, errorMsg);
      return;
    }

    message['to_user_id'] = toUserId.trim();
    message['call_id'] = callId.trim();

    _sendSignalingMessage(message);
  }

  /// Alias for [sendSignalingPayload].
  void sendPayload(Map<String, dynamic> payload) => sendSignalingPayload(payload);

  /// Sends a raw JSON signaling message through the WebSocket sink.
  void _sendSignalingMessage(Map<String, dynamic> message) {
    if (_channel != null && _isConnected) {
      final jsonStr = jsonEncode(message);
      debugPrint('[SignalingService SEND]: $jsonStr');
      _channel!.sink.add(jsonStr);
    } else {
      debugPrint('[SignalingService WARN] Cannot send message: channel not connected');
    }
  }

  /// Resets the call state to idle (e.g. to dismiss ended/failed call screens).
  void resetCallState() {
    _cancelCallSetupTimeout();
    _currentCallId = null;
    _currentPartnerId = null;
    _currentIncomingCall = null;
    _lastFailureReason = null;
    _setCallState(CallLifecycleState.idle);
  }

  /// Handles incoming WebSocket messages from the signaling server.
  void _handleIncomingMessage(dynamic raw) {
    try {
      final Map<String, dynamic> data =
          jsonDecode(raw as String) as Map<String, dynamic>;
      final String? type = data['type'] as String?;

      debugPrint('[SignalingService RECV]: $data');

      switch (type) {
        case 'incoming_call':
          _cancelCallSetupTimeout();
          final callId = (data['call_id'] ?? '').toString();
          final callerId =
              (data['from_user_id'] ?? data['caller_id'] ?? '').toString();
          final callerName = (data['caller_name'] ??
                  data['callerName'] ??
                  data['from_name'] ??
                  callerId)
              .toString();

          final incoming = IncomingCall(
            callId: callId,
            callerId: callerId,
            callerName: callerName,
          );

          _currentIncomingCall = incoming;
          _currentCallId = callId;
          _currentPartnerId = callerId;
          _setCallState(CallLifecycleState.ringing);

          _incomingCallController.add(incoming);
          onIncomingCall?.call(incoming);
          break;

        case 'call_accepted':
          _cancelCallSetupTimeout();
          final callId =
              (data['call_id'] ?? _currentCallId ?? '').toString();
          if (callId.isNotEmpty) {
            _currentCallId = callId;
          }
          _setCallState(CallLifecycleState.inCall);
          break;

        case 'call_rejected':
          _cancelCallSetupTimeout();
          _lastFailureReason = 'Call was rejected by callee';
          _setCallState(CallLifecycleState.ended);
          _currentCallId = null;
          _currentPartnerId = null;
          _currentIncomingCall = null;
          break;

        case 'call_failed':
          _cancelCallSetupTimeout();
          final reason = (data['reason'] ?? 'call_failed').toString();
          _lastFailureReason = (reason == 'offline')
              ? 'User is offline'
              : (reason == 'busy')
                  ? 'User is busy'
                  : reason;
          _setCallState(CallLifecycleState.failed);
          _currentCallId = null;
          _currentPartnerId = null;
          _currentIncomingCall = null;
          break;

        case 'call_ended':
          _cancelCallSetupTimeout();
          _lastFailureReason =
              data['reason']?.toString() ?? 'Call ended by remote peer';
          _setCallState(CallLifecycleState.ended);
          _currentCallId = null;
          _currentPartnerId = null;
          _currentIncomingCall = null;
          break;

        case 'offer':
        case 'answer':
        case 'ice_candidate':
        case 'ice-candidate':
          // Forward raw WebRTC payloads IN
          _signalingPayloadController.add(data);
          onSignalingPayload?.call(data);
          break;

        case 'pong':
          // Heartbeat response
          break;

        default:
          debugPrint('[SignalingService] Unknown message type: $type');
          break;
      }
    } catch (e, st) {
      debugPrint('[SignalingService ERROR] Failed to parse message: $e\n$st');
    }
  }

  void _handleDisconnect() {
    _cancelCallSetupTimeout();
    _stopHeartbeat();
    _isConnected = false;
    _lastFailureReason = 'WebSocket disconnected';
    notifyListeners();

    if (!_isExplicitDisconnect) {
      _scheduleReconnect();
    }
  }

  void _setCallState(CallLifecycleState state) {
    if (_callState != state) {
      _callState = state;
      notifyListeners();
      _callStateController.add(state);
      onCallStateChanged?.call(state);
    }
  }

  @override
  void dispose() {
    _isExplicitDisconnect = true;
    _cancelCallSetupTimeout();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _stopHeartbeat();
    disconnect();
    _incomingCallController.close();
    _signalingPayloadController.close();
    _callStateController.close();
    super.dispose();
  }
}
