import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:audio_session/audio_session.dart';
import 'services/api_service.dart';
import 'services/signaling_service.dart';

enum CallState {
  disconnected,
  connecting,
  connected,
  peerDisconnected,
  roomFull,
}

/// A service that manages WebRTC peer connections, audio streams,
/// and hardware audio routing for 1-on-1 audio calls.
/// Signaling is delegated to an injected [SignalingService].
class WebRTCService extends ChangeNotifier {
  static const List<Map<String, dynamic>> _fallbackIceServers = [
    {
      'urls': 'stun:stun.l.google.com:19302',
    },
  ];

  static const Map<String, dynamic> _audioConstraints = {
    'audio': {
      'echoCancellation': true,
      'noiseSuppression': true,
      'autoGainControl': true,
    },
    'video': false,
  };

  // State properties
  CallState _callState = CallState.disconnected;
  bool _isCaller = false;
  bool _isMuted = false;
  bool _isSpeakerOn = false;
  String? _callId;

  // WebRTC objects
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;

  // External services & subscriptions
  SignalingService? _signalingService;
  StreamSubscription? _signalingSubscription;
  ApiService apiService;

  // Audio session & routing
  AudioSession? _audioSession;
  StreamSubscription? _audioDevicesSubscription;

  // ICE Candidate buffering before remote description is set
  final List<RTCIceCandidate> _iceCandidateQueue = [];
  bool _isRemoteDescriptionSet = false;

  // Disconnect grace period timer for transient network hiccups
  Timer? _disconnectGraceTimer;

  // Cached ICE servers and TTL expiration
  List<Map<String, dynamic>>? _cachedIceServers;
  DateTime? _iceServersExpiry;

  // Flag to attempt at most one ICE restart before giving up
  bool _hasAttemptedIceRestart = false;

  WebRTCService({
    SignalingService? signalingService,
    ApiService? apiService,
  }) : apiService = apiService ?? ApiService() {
    if (signalingService != null) {
      setSignalingService(signalingService);
    }
  }

  /// Sets or updates the [SignalingService] instance used for signaling exchange.
  void setSignalingService(SignalingService signalingService) {
    _signalingSubscription?.cancel();
    _signalingService = signalingService;
    _subscribeToSignaling();
  }

  void _subscribeToSignaling() {
    _signalingSubscription?.cancel();
    if (_signalingService != null) {
      _signalingSubscription =
          _signalingService!.signalingPayloads.listen(handleSignalingPayload);
    }
  }

  /// Fetches ICE servers via [ApiService.fetchTurnCredentials] with caching for the [ttl] duration,
  /// falling back to standard STUN if the request fails, times out, or current user ID is unavailable.
  Future<List<Map<String, dynamic>>> _getIceServers() async {
    final now = DateTime.now();
    if (_cachedIceServers != null &&
        _iceServersExpiry != null &&
        now.isBefore(_iceServersExpiry!)) {
      debugPrint(
        '[WebRTCService] Using cached ICE servers (expires in ${_iceServersExpiry!.difference(now).inSeconds}s)',
      );
      return _cachedIceServers!;
    }

    final String? userId = _signalingService?.currentUserId;
    if (userId == null || userId.trim().isEmpty) {
      debugPrint(
        '[WebRTCService] Signaling currentUserId is null or empty. Skipping TURN fetch and using fallback STUN.',
      );
      return _fallbackIceServers;
    }

    try {
      final servers = await apiService
          .fetchTurnCredentials(userId.trim())
          .timeout(const Duration(seconds: 5));
      if (servers.isNotEmpty) {
        final ttlSeconds =
            apiService.lastTurnTtl > 0 ? apiService.lastTurnTtl : 3600;
        _cachedIceServers = servers;
        _iceServersExpiry = now.add(Duration(seconds: ttlSeconds));
        debugPrint(
          '[WebRTCService] Fetched and cached ${servers.length} ICE servers for ${ttlSeconds}s',
        );
        return servers;
      }
    } on TimeoutException catch (e) {
      debugPrint(
        '[WebRTCService WARN] Timeout fetching TURN credentials after 5s: $e. Falling back to default STUN.',
      );
    } catch (e) {
      debugPrint(
        '[WebRTCService WARN] Failed to fetch TURN credentials from backend: $e. Falling back to default STUN.',
      );
    }

    return _fallbackIceServers;
  }

  // Public getters
  CallState get callState => _callState;
  bool get isMuted => _isMuted;
  bool get isSpeakerOn => _isSpeakerOn;
  String? get callId => _callId;
  @Deprecated('Use callId instead')
  String? get roomId => _callId;
  bool get isCaller => _isCaller;
  MediaStream? get localStream => _localStream;
  MediaStream? get remoteStream => _remoteStream;

  @visibleForTesting
  Future<List<Map<String, dynamic>>> getIceServers() => _getIceServers();

  @visibleForTesting
  List<Map<String, dynamic>>? get cachedIceServers => _cachedIceServers;

  @visibleForTesting
  DateTime? get iceServersExpiry => _iceServersExpiry;

  @visibleForTesting
  bool get hasAttemptedIceRestart => _hasAttemptedIceRestart;

  @visibleForTesting
  void handleIceFailureOrTimeout() => _handleIceFailureOrTimeout();

  @visibleForTesting
  void setIsCaller(bool isCaller) {
    _isCaller = isCaller;
  }

  @visibleForTesting
  void setCallStateForTesting(CallState state) => _setCallState(state);

  void _setCallState(CallState state) {
    if (_callState != state) {
      _callState = state;
      notifyListeners();
    }
  }

  /// Initiates an audio call as the caller.
  /// Prepares local media and peer connection, and sends the SDP offer once
  /// [SignalingService] confirms the call is accepted (`CallLifecycleState.inCall`).
  Future<void> startAsCaller(String callId) async {
    await _initCall(callId: callId, isCaller: true);

    // If SignalingService is not yet in inCall state, await confirmation before sending SDP offer
    if (_signalingService != null &&
        _signalingService!.callState != CallLifecycleState.inCall) {
      debugPrint(
        '[WebRTCService] Call is in state "${_signalingService!.callState}". Waiting for "call_accepted" (inCall) before sending SDP offer...',
      );
      try {
        await _signalingService!.callStateStream
            .firstWhere((state) => state == CallLifecycleState.inCall)
            .timeout(const Duration(seconds: 15));
      } catch (e) {
        debugPrint(
          '[WebRTCService ERROR] Timed out or failed waiting for call acceptance: $e',
        );
        return;
      }
    }

    await _createAndSendOffer();
  }

  /// Joins an existing audio call as the receiver (waits for incoming SDP offer).
  Future<void> startAsCallee(String callId) async {
    await _initCall(callId: callId, isCaller: false);
  }

  /// Backward-compatible alias for [startAsCaller].
  Future<void> startCall(String callId) => startAsCaller(callId);

  /// Backward-compatible alias for [startAsCallee].
  Future<void> joinCall(String callId) => startAsCallee(callId);

  /// Sets up audio hardware session, local media tracks, and peer connection.
  Future<void> _initCall({
    required String callId,
    required bool isCaller,
  }) async {
    // Reset any previous session cleanly
    await endCall();

    _callId = callId;
    _isCaller = isCaller;
    _hasAttemptedIceRestart = false;
    _setCallState(CallState.connecting);

    // Fetch dynamic ICE servers (TURN + STUN) before creating peer connection
    final iceServers = await _getIceServers();
    final bool hasTurn = iceServers.any((server) {
      final dynamic urls = server['urls'];
      if (urls is String) return urls.startsWith('turn:') || urls.startsWith('turns:');
      if (urls is List) return urls.any((u) => u.toString().startsWith('turn:') || u.toString().startsWith('turns:'));
      return false;
    });
    final serverUrls = iceServers.map((s) => s['urls']).toList();
    debugPrint(
      '[WebRTCService ICE] Resolved ${iceServers.length} ICE server(s) [${hasTurn ? "TURN + STUN" : "STUN only"}]: $serverUrls',
    );
    final Map<String, dynamic> iceConfiguration = {
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
    };

    try {
      // 1. Configure audio session for voiceCommunication category
      _audioSession = await AudioSession.instance;
      await _audioSession!.configure(AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
        avAudioSessionCategoryOptions:
            AVAudioSessionCategoryOptions.allowBluetooth |
            AVAudioSessionCategoryOptions.allowBluetoothA2dp,
        avAudioSessionMode: AVAudioSessionMode.voiceChat,
        avAudioSessionRouteSharingPolicy:
            AVAudioSessionRouteSharingPolicy.defaultPolicy,
        avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
        androidAudioAttributes: const AndroidAudioAttributes(
          contentType: AndroidAudioContentType.speech,
          flags: AndroidAudioFlags.none,
          usage: AndroidAudioUsage.voiceCommunication,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gainTransient,
        androidWillPauseWhenDucked: true,
      ));

      // Activate the audio session for call duration
      await _audioSession!.setActive(true);

      // Ensure default audio routing starts on earpiece (unless speaker already requested)
      await Helper.setSpeakerphoneOn(_isSpeakerOn);

      // Listen for device changes (Bluetooth connect/disconnect, wired headsets)
      _audioDevicesSubscription =
          _audioSession!.devicesChangedEventStream.listen((event) {
        _handleAudioDevicesChanged(event);
      });

      // 2. Obtain local audio-only stream with echo cancellation & noise suppression
      _localStream =
          await navigator.mediaDevices.getUserMedia(_audioConstraints);

      // 3. Create and configure RTCPeerConnection with dynamic ICE servers
      _peerConnection = await createPeerConnection(iceConfiguration);

      // Register local audio tracks to peer connection
      for (final track in _localStream!.getAudioTracks()) {
        await _peerConnection!.addTrack(track, _localStream!);
      }

      // Handle local ICE candidates and send them to the signaling server
      // Note: The Render backend filters message types and requires 'ice-candidate'
      _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
        if (candidate.candidate != null && candidate.candidate!.isNotEmpty) {
          debugPrint(
              '[WebRTCService ICE] Generated local candidate (mid: ${candidate.sdpMid}, mLine: ${candidate.sdpMLineIndex}): ${candidate.candidate}');
          _sendSignalingMessage({
            'type': 'ice-candidate',
            'candidate': {
              'candidate': candidate.candidate,
              'sdpMid': candidate.sdpMid,
              'sdpMLineIndex': candidate.sdpMLineIndex,
            },
          });
        }
      };

      // Listen for remote audio track
      _peerConnection!.onTrack = (RTCTrackEvent event) {
        debugPrint(
            '[WebRTCService TRACK] onTrack event received! Stream count: ${event.streams.length}');
        if (event.streams.isNotEmpty) {
          _remoteStream = event.streams[0];
          notifyListeners();
        }
      };

      // Monitor WebRTC connection states
      _peerConnection!.onConnectionState = (RTCPeerConnectionState state) {
        debugPrint('[WebRTCService STATE] onConnectionState -> $state');
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _disconnectGraceTimer?.cancel();
          _hasAttemptedIceRestart = false;
          _setCallState(CallState.connected);
          _logSelectedIceCandidatePair();
        } else if (state ==
            RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
          _handleIceFailureOrTimeout();
        } else if (state ==
            RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          // Give it a chance to self-recover before declaring the call dead
          _disconnectGraceTimer?.cancel();
          _disconnectGraceTimer = Timer(const Duration(seconds: 6), () {
            if (_peerConnection?.connectionState ==
                RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
              _handleIceFailureOrTimeout();
            }
          });
        }
      };

      _peerConnection!.onIceConnectionState = (RTCIceConnectionState state) {
        debugPrint('[WebRTCService STATE] onIceConnectionState -> $state');
        if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
            state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
          _disconnectGraceTimer?.cancel();
          _hasAttemptedIceRestart = false;
          _setCallState(CallState.connected);
        } else if (state ==
            RTCIceConnectionState.RTCIceConnectionStateFailed) {
          _handleIceFailureOrTimeout();
        } else if (state ==
            RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
          // Give it a chance to self-recover before declaring the call dead
          _disconnectGraceTimer?.cancel();
          _disconnectGraceTimer = Timer(const Duration(seconds: 6), () {
            if (_peerConnection?.iceConnectionState ==
                RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
              _handleIceFailureOrTimeout();
            }
          });
        }
      };

      _peerConnection!.onIceGatheringState = (RTCIceGatheringState state) {
        debugPrint('[WebRTCService STATE] onIceGatheringState -> $state');
      };

      _peerConnection!.onSignalingState = (RTCSignalingState state) {
        debugPrint('[WebRTCService STATE] onSignalingState -> $state');
      };

      // Ensure signaling subscription is active
      _subscribeToSignaling();
    } catch (e, stack) {
      debugPrint('[WebRTCService ERROR] Initialization error: $e\n$stack');
      await endCall();
      rethrow;
    }
  }

  /// Public entry point to receive forwarded signaling payloads from [SignalingService].
  Future<void> handleSignalingPayload(Map<String, dynamic> data) async {
    await _handleSignalingMessage(data);
  }

  /// Handles incoming WebRTC signaling messages forwarded from [SignalingService].
  Future<void> _handleSignalingMessage(dynamic message) async {
    debugPrint('[WebRTCService RECV]: $message');
    try {
      final Map<String, dynamic> data = message is Map<String, dynamic>
          ? message
          : (message is String
              ? jsonDecode(message) as Map<String, dynamic>
              : {});
      final String? type = data['type'] as String?;
      debugPrint('[WebRTCService] Parsed message type: "$type"');

      switch (type) {
        case 'offer':
          debugPrint('[WebRTCService] Incoming OFFER received');
          await _handleOffer(data);
          break;

        case 'answer':
          debugPrint('[WebRTCService] Incoming ANSWER received');
          await _handleAnswer(data);
          break;

        case 'ice-candidate':
        case 'ice_candidate':
        case 'candidate':
          await _handleRemoteCandidate(data);
          break;

        case 'peer-disconnected':
          debugPrint('[WebRTCService] Peer disconnected event received');
          _setCallState(CallState.peerDisconnected);
          break;

        default:
          debugPrint('[WebRTCService] Unhandled message type: "$type"');
          break;
      }
    } catch (e, stack) {
      debugPrint(
          '[WebRTCService ERROR] Error processing signaling message: $e\n$stack');
    }
  }

  /// Creates and sends an SDP offer to the remote peer.
  Future<void> _createAndSendOffer() async {
    if (_peerConnection == null) {
      debugPrint(
          '[WebRTCService WARN] Cannot create offer: _peerConnection is null');
      return;
    }
    try {
      debugPrint('[WebRTCService] Creating SDP offer...');
      final RTCSessionDescription offer = await _peerConnection!.createOffer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': false,
      });

      debugPrint(
          '[WebRTCService] Setting local description with offer (sdp length: ${offer.sdp?.length})...');
      await _peerConnection!.setLocalDescription(offer);

      debugPrint(
          '[WebRTCService SEND] Sending OFFER via SignalingService (sdp length: ${offer.sdp?.length})');
      _sendSignalingMessage({
        'type': 'offer',
        'sdp': offer.sdp,
      });
    } catch (e, stack) {
      debugPrint('[WebRTCService ERROR] Error creating offer: $e\n$stack');
    }
  }

  /// Handles an incoming SDP offer from the caller, sets remote description,
  /// flushes queued ICE candidates, and sends back an SDP answer.
  Future<void> _handleOffer(Map<String, dynamic> data) async {
    if (_peerConnection == null) {
      debugPrint(
          '[WebRTCService WARN] Cannot handle offer: _peerConnection is null');
      return;
    }
    try {
      final String sdp =
          (data['sdp'] ?? data['description']?['sdp']) as String;
      final RTCSessionDescription remoteDesc =
          RTCSessionDescription(sdp, 'offer');

      debugPrint(
          '[WebRTCService] Setting remote description for OFFER (sdp length: ${sdp.length})...');
      await _peerConnection!.setRemoteDescription(remoteDesc);
      _isRemoteDescriptionSet = true;
      debugPrint(
          '[WebRTCService] Remote description (OFFER) set successfully! Flushing queued candidates...');
      await _drainQueuedCandidates();

      debugPrint('[WebRTCService] Creating SDP answer...');
      final RTCSessionDescription answer = await _peerConnection!.createAnswer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': false,
      });

      debugPrint(
          '[WebRTCService] Setting local description with answer (sdp length: ${answer.sdp?.length})...');
      await _peerConnection!.setLocalDescription(answer);

      debugPrint(
          '[WebRTCService SEND] Sending ANSWER via SignalingService (sdp length: ${answer.sdp?.length})');
      _sendSignalingMessage({
        'type': 'answer',
        'sdp': answer.sdp,
      });
    } catch (e, stack) {
      debugPrint('[WebRTCService ERROR] Error handling offer: $e\n$stack');
    }
  }

  /// Handles an incoming SDP answer from the callee and sets remote description.
  Future<void> _handleAnswer(Map<String, dynamic> data) async {
    if (_peerConnection == null) {
      debugPrint(
          '[WebRTCService WARN] Cannot handle answer: _peerConnection is null');
      return;
    }
    try {
      final String sdp =
          (data['sdp'] ?? data['description']?['sdp']) as String;
      final RTCSessionDescription remoteDesc =
          RTCSessionDescription(sdp, 'answer');

      debugPrint(
          '[WebRTCService] Setting remote description for ANSWER (sdp length: ${sdp.length})...');
      await _peerConnection!.setRemoteDescription(remoteDesc);
      _isRemoteDescriptionSet = true;
      debugPrint(
          '[WebRTCService] Remote description (ANSWER) set successfully! Flushing queued candidates...');
      await _drainQueuedCandidates();
    } catch (e, stack) {
      debugPrint('[WebRTCService ERROR] Error handling answer: $e\n$stack');
    }
  }

  /// Handles incoming ICE candidates. If remote description is set, adds directly;
  /// otherwise buffers them until remote description is established.
  Future<void> _handleRemoteCandidate(Map<String, dynamic> data) async {
    try {
      String candidateStr;
      String? sdpMid;
      int? sdpMLineIndex;

      final dynamic candidatePayload = data['candidate'];
      if (candidatePayload is Map) {
        candidateStr = (candidatePayload['candidate'] as String?) ?? '';
        sdpMid = candidatePayload['sdpMid'] as String?;
        sdpMLineIndex = candidatePayload['sdpMLineIndex'] as int?;
      } else if (candidatePayload is String) {
        candidateStr = candidatePayload;
        sdpMid = data['sdpMid'] as String?;
        sdpMLineIndex = data['sdpMLineIndex'] as int?;
      } else {
        debugPrint(
            '[WebRTCService ICE WARN] Ignored candidate with unexpected payload: $data');
        return;
      }

      final RTCIceCandidate candidate =
          RTCIceCandidate(candidateStr, sdpMid, sdpMLineIndex);

      if (_isRemoteDescriptionSet && _peerConnection != null) {
        debugPrint(
            '[WebRTCService ICE DIRECT] Remote desc is set. Adding candidate directly: mid=$sdpMid, mLine=$sdpMLineIndex');
        await _peerConnection!.addCandidate(candidate);
      } else {
        _iceCandidateQueue.add(candidate);
        debugPrint(
            '[WebRTCService ICE QUEUE] Remote desc NOT set yet. Queued ICE candidate (total queued: ${_iceCandidateQueue.length})');
      }
    } catch (e, stack) {
      debugPrint(
          '[WebRTCService ERROR] Error handling ICE candidate: $e\n$stack');
    }
  }

  /// Flushes any buffered ICE candidates that arrived before the remote description was set.
  Future<void> _drainQueuedCandidates() async {
    if (_iceCandidateQueue.isEmpty) {
      debugPrint('[WebRTCService ICE FLUSH] Candidate queue is empty.');
      return;
    }
    debugPrint(
        '[WebRTCService ICE FLUSH] Flushing ${_iceCandidateQueue.length} queued ICE candidate(s)...');
    while (_iceCandidateQueue.isNotEmpty) {
      final candidate = _iceCandidateQueue.removeAt(0);
      try {
        await _peerConnection?.addCandidate(candidate);
        debugPrint(
            '[WebRTCService ICE FLUSH] Flushed candidate (mid=${candidate.sdpMid}, mLine=${candidate.sdpMLineIndex}) successfully.');
      } catch (e) {
        debugPrint(
            '[WebRTCService ERROR] Error adding queued ICE candidate: $e');
      }
    }
  }

  /// Forwards an outgoing signaling message through the injected [SignalingService].
  void _sendSignalingMessage(Map<String, dynamic> message) {
    if (_signalingService != null) {
      _signalingService!.sendPayload(message);
    } else {
      debugPrint(
          '[WebRTCService WARN] Cannot send signaling message: signalingService is null');
    }
  }

  /// Toggles the local microphone mute state.
  void toggleMute() {
    if (_localStream != null) {
      _isMuted = !_isMuted;
      for (final track in _localStream!.getAudioTracks()) {
        track.enabled = !_isMuted;
      }
      notifyListeners();
    }
  }

  /// Switches the audio output between speakerphone and earpiece/headset.
  Future<void> setSpeaker(bool enabled) async {
    _isSpeakerOn = enabled;
    await Helper.setSpeakerphoneOn(enabled);
    notifyListeners();
  }

  /// Terminates the current call session, releasing WebRTC peer connection and audio resources.
  Future<void> endCall() async {
    _disconnectGraceTimer?.cancel();
    _disconnectGraceTimer = null;

    // 1. Stop and release local audio stream tracks
    if (_localStream != null) {
      for (final track in _localStream!.getTracks()) {
        await track.stop();
      }
      await _localStream!.dispose();
      _localStream = null;
    }

    // 2. Close and dispose WebRTC peer connection
    if (_peerConnection != null) {
      await _peerConnection!.close();
      await _peerConnection!.dispose();
      _peerConnection = null;
    }

    // 3. Cancel audio device subscription & release audio session
    if (_audioDevicesSubscription != null) {
      await _audioDevicesSubscription!.cancel();
      _audioDevicesSubscription = null;
    }
    if (_audioSession != null) {
      await _audioSession!.setActive(false);
      _audioSession = null;
    }

    // 4. Reset internal state and buffers
    _remoteStream = null;
    _iceCandidateQueue.clear();
    _isRemoteDescriptionSet = false;
    _isCaller = false;
    _isMuted = false;
    _isSpeakerOn = false;
    _callId = null;
    _hasAttemptedIceRestart = false;

    _setCallState(CallState.disconnected);
  }

  /// Handles ICE failure or disconnected timeout by attempting an ICE restart once before failing.
  void _handleIceFailureOrTimeout() {
    _disconnectGraceTimer?.cancel();
    if (!_hasAttemptedIceRestart) {
      _hasAttemptedIceRestart = true;
      if (_isCaller) {
        _performIceRestart();
      } else {
        // Callee waits for the renegotiated offer from the caller
        debugPrint(
          '[WebRTCService] ICE failed/disconnected on callee, waiting for ICE restart offer from caller...',
        );
        _disconnectGraceTimer = Timer(const Duration(seconds: 6), () {
          final iceState = _peerConnection?.iceConnectionState;
          final connState = _peerConnection?.connectionState;
          if (iceState ==
                  RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
              iceState == RTCIceConnectionState.RTCIceConnectionStateFailed ||
              connState ==
                  RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
              connState ==
                  RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
            debugPrint(
              '[WebRTCService] ICE restart window expired on callee, disconnecting.',
            );
            _setCallState(CallState.disconnected);
          }
        });
      }
    } else {
      debugPrint(
        '[WebRTCService] ICE failed or disconnected after restart attempt. Disconnecting.',
      );
      _setCallState(CallState.disconnected);
    }
  }

  /// Triggers an ICE restart as the caller by calling restartIce() and sending a new SDP offer.
  Future<void> _performIceRestart() async {
    debugPrint('[WebRTCService] Triggering ICE restart as caller...');
    try {
      if (_peerConnection != null) {
        await _peerConnection!.restartIce();
        await _createAndSendOffer();
      }
      // Start another grace window for the restart to establish
      _disconnectGraceTimer = Timer(const Duration(seconds: 6), () {
        final iceState = _peerConnection?.iceConnectionState;
        final connState = _peerConnection?.connectionState;
        if (iceState ==
                RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
            iceState == RTCIceConnectionState.RTCIceConnectionStateFailed ||
            connState ==
                RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
            connState == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
          debugPrint(
            '[WebRTCService] ICE restart failed to reconnect in time. Disconnecting.',
          );
          _setCallState(CallState.disconnected);
        }
      });
    } catch (e) {
      debugPrint('[WebRTCService ERROR] Failed to perform ICE restart: $e');
      _setCallState(CallState.disconnected);
    }
  }

  /// Logs the candidate type (host/srflx/relay) of the selected ICE candidate pair once connected.
  Future<void> _logSelectedIceCandidatePair() async {
    if (_peerConnection == null) return;
    try {
      final List<StatsReport> reports = await _peerConnection!.getStats();
      StatsReport? selectedPair;
      final Map<String, StatsReport> candidateMap = {};

      for (final report in reports) {
        if (report.type == 'local-candidate' ||
            report.type == 'remote-candidate') {
          candidateMap[report.id] = report;
        } else if (report.type == 'candidate-pair') {
          final isSelected = report.values['selected'] == true ||
              report.values['selected'] == 'true' ||
              report.values['nominated'] == true ||
              report.values['nominated'] == 'true' ||
              report.values['state'] == 'succeeded';
          if (isSelected) {
            selectedPair = report;
          }
        } else if (report.type == 'googCandidatePair') {
          if (report.values['googActiveConnection'] == 'true' ||
              report.values['googActiveConnection'] == true) {
            selectedPair = report;
          }
        }
      }

      if (selectedPair != null) {
        final localId = (selectedPair.values['localCandidateId'] ??
                selectedPair.values['googLocalAddress'])
            ?.toString();
        final remoteId = (selectedPair.values['remoteCandidateId'] ??
                selectedPair.values['googRemoteAddress'])
            ?.toString();
        final localReport = candidateMap[localId];
        final remoteReport = candidateMap[remoteId];

        final localType = localReport?.values['candidateType'] ??
            selectedPair.values['googLocalCandidateType'] ??
            'unknown';
        final remoteType = remoteReport?.values['candidateType'] ??
            selectedPair.values['googRemoteCandidateType'] ??
            'unknown';

        debugPrint(
          '[WebRTCService ICE] Connected candidate pair: local=$localType <-> remote=$remoteType',
        );
      } else {
        final candidates = reports
            .where((r) =>
                r.type == 'local-candidate' ||
                r.type == 'candidate-pair' ||
                r.type == 'googCandidatePair')
            .map((r) =>
                '${r.type}: ${r.values['candidateType'] ?? r.values['googLocalCandidateType'] ?? r.values['state']}')
            .join(', ');
        debugPrint(
          '[WebRTCService ICE] Active connection stats: $candidates',
        );
      }
    } catch (e) {
      debugPrint(
        '[WebRTCService WARN] Could not inspect candidate pair stats: $e',
      );
    }
  }

  /// Handles Bluetooth headset or wired headset connect/disconnect events.
  // ignore: experimental_member_use
  void _handleAudioDevicesChanged(AudioDevicesChangedEvent event) {
    // Check if a Bluetooth device was newly connected
    // ignore: experimental_member_use
    final bool bluetoothConnected = event.devicesAdded.any((device) =>
        // ignore: experimental_member_use
        device.type == AudioDeviceType.bluetoothSco ||
        // ignore: experimental_member_use
        device.type == AudioDeviceType.bluetoothA2dp ||
        // ignore: experimental_member_use
        device.type == AudioDeviceType.bluetoothLe);

    if (bluetoothConnected) {
      // When a Bluetooth headset connects, disable speakerphone override
      // so the system audio engine directs voice output to the headset
      _isSpeakerOn = false;
      Helper.setSpeakerphoneOn(false);
      notifyListeners();
    } else if (event.devicesRemoved.any((device) =>
        // ignore: experimental_member_use
        device.type == AudioDeviceType.bluetoothSco ||
        // ignore: experimental_member_use
        device.type == AudioDeviceType.bluetoothA2dp ||
        // ignore: experimental_member_use
        device.type == AudioDeviceType.bluetoothLe)) {
      // When Bluetooth headset disconnects, restore the user's active speaker/earpiece choice
      Helper.setSpeakerphoneOn(_isSpeakerOn);
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disconnectGraceTimer?.cancel();
    _disconnectGraceTimer = null;
    _signalingSubscription?.cancel();
    _signalingSubscription = null;
    endCall();
    super.dispose();
  }
}
