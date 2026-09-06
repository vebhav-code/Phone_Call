import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:audio_session/audio_session.dart';

/// Minimal WebRTC service managing audio streams, peer connection,
/// and local device audio routing for 1-to-1 audio calling.
/// Configured for direct local candidate exchange.
class WebRTCService extends ChangeNotifier {
  // Pure local ICE configuration with no external ICE servers
  static const Map<String, dynamic> _webrtcConfiguration = <String, dynamic>{};

  static const Map<String, dynamic> _audioConstraints = {
    'audio': {
      'echoCancellation': true,
      'noiseSuppression': true,
      'autoGainControl': true,
    },
    'video': false,
  };

  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  AudioSession? _audioSession;

  final List<RTCIceCandidate> _candidateQueue = [];
  bool _isRemoteDescriptionSet = false;
  bool _isMuted = false;
  bool _isSpeakerOn = false;

  // Callbacks for CallController
  void Function(RTCIceCandidate candidate)? onLocalCandidate;
  void Function(MediaStream stream)? onRemoteStream;
  void Function(RTCPeerConnectionState state)? onConnectionState;

  bool get isMuted => _isMuted;
  bool get isSpeakerOn => _isSpeakerOn;
  bool get isConnected =>
      _peerConnection?.connectionState ==
      RTCPeerConnectionState.RTCPeerConnectionStateConnected;

  MediaStream? get localStream => _localStream;
  MediaStream? get remoteStream => _remoteStream;
  RTCPeerConnection? get peerConnection => _peerConnection;

  /// Initializes hardware audio session, acquires local microphone stream,
  /// and creates RTCPeerConnection with no external ICE servers.
  Future<void> initializePeerConnection() async {
    await endCall(); // Clean up any previous session

    debugPrint('[WebRTCService] Initializing audio session & microphone...');
    // 1. Configure audio session for voice call
    try {
      _audioSession = await AudioSession.instance;
      await _audioSession?.configure(const AudioSessionConfiguration.speech());
      await _audioSession?.setActive(true);
    } catch (e) {
      debugPrint('[WebRTCService WARN] AudioSession configuration: $e');
    }

    // 2. Acquire local audio stream (microphone only)
    _localStream = await navigator.mediaDevices.getUserMedia(_audioConstraints);
    debugPrint('[WebRTCService] Acquired local microphone audio stream.');

    // 3. Create peer connection with empty configuration
    _peerConnection = await createPeerConnection(_webrtcConfiguration);
    debugPrint('[WebRTCService] Created RTCPeerConnection (local candidates only).');

    // Add local tracks to peer connection
    for (final track in _localStream!.getAudioTracks()) {
      await _peerConnection!.addTrack(track, _localStream!);
    }

    // Handle local ICE candidates
    _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
      if (candidate.candidate != null && candidate.candidate!.isNotEmpty) {
        debugPrint(
          '[WebRTCService ICE] Local candidate generated: ${candidate.candidate}',
        );
        onLocalCandidate?.call(candidate);
      }
    };

    // Handle remote track
    _peerConnection!.onTrack = (RTCTrackEvent event) {
      debugPrint('[WebRTCService TRACK] Remote audio track received!');
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams[0];
        onRemoteStream?.call(_remoteStream!);
        notifyListeners();
      }
    };

    // Handle connection state changes
    _peerConnection!.onConnectionState = (RTCPeerConnectionState state) {
      debugPrint('[WebRTCService STATE] onConnectionState -> $state');
      onConnectionState?.call(state);
      notifyListeners();
    };

    _isMuted = false;
    _isSpeakerOn = false;
    _isRemoteDescriptionSet = false;
    _candidateQueue.clear();
    notifyListeners();
  }

  /// Creates and sets local SDP offer, returning the offer string.
  Future<String> createOffer() async {
    if (_peerConnection == null) {
      throw StateError('PeerConnection is not initialized');
    }
    debugPrint('[WebRTCService] Creating SDP offer...');
    final RTCSessionDescription offer = await _peerConnection!.createOffer({
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': false,
    });
    await _peerConnection!.setLocalDescription(offer);
    debugPrint('[WebRTCService] Local description set with offer.');
    return offer.sdp ?? '';
  }

  /// Sets remote SDP offer, creates and sets local SDP answer, returning answer string.
  Future<String> handleOfferAndCreateAnswer(String offerSdp) async {
    if (_peerConnection == null) {
      throw StateError('PeerConnection is not initialized');
    }
    debugPrint('[WebRTCService] Setting remote description (offer)...');
    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(offerSdp, 'offer'),
    );
    _isRemoteDescriptionSet = true;
    await _drainCandidateQueue();

    debugPrint('[WebRTCService] Creating SDP answer...');
    final RTCSessionDescription answer = await _peerConnection!.createAnswer({
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': false,
    });
    await _peerConnection!.setLocalDescription(answer);
    debugPrint('[WebRTCService] Local description set with answer.');
    return answer.sdp ?? '';
  }

  /// Sets remote SDP answer (called on caller side).
  Future<void> handleAnswer(String answerSdp) async {
    if (_peerConnection == null) return;
    debugPrint('[WebRTCService] Setting remote description (answer)...');
    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(answerSdp, 'answer'),
    );
    _isRemoteDescriptionSet = true;
    await _drainCandidateQueue();
  }

  /// Adds a remote ICE candidate, buffering if remote description is not yet set.
  Future<void> addRemoteCandidate(RTCIceCandidate candidate) async {
    if (_isRemoteDescriptionSet && _peerConnection != null) {
      try {
        await _peerConnection!.addCandidate(candidate);
      } catch (e) {
        debugPrint('[WebRTCService ERROR] Failed to add candidate: $e');
      }
    } else {
      _candidateQueue.add(candidate);
    }
  }

  Future<void> _drainCandidateQueue() async {
    while (_candidateQueue.isNotEmpty && _peerConnection != null) {
      final candidate = _candidateQueue.removeAt(0);
      try {
        await _peerConnection!.addCandidate(candidate);
      } catch (e) {
        debugPrint('[WebRTCService ERROR] Failed to drain candidate: $e');
      }
    }
  }

  /// Toggles microphone mute.
  void toggleMute() {
    _isMuted = !_isMuted;
    if (_localStream != null) {
      for (final track in _localStream!.getAudioTracks()) {
        track.enabled = !_isMuted;
      }
    }
    notifyListeners();
  }

  /// Toggles or sets speakerphone on/off.
  Future<void> setSpeaker(bool enabled) async {
    _isSpeakerOn = enabled;
    await Helper.setSpeakerphoneOn(enabled);
    notifyListeners();
  }

  /// Ends current call session and releases all WebRTC audio/peer connection resources.
  Future<void> endCall() async {
    debugPrint('[WebRTCService] Tearing down WebRTC session & audio tracks...');
    _candidateQueue.clear();
    _isRemoteDescriptionSet = false;

    // Stop local tracks
    if (_localStream != null) {
      for (final track in _localStream!.getTracks()) {
        try {
          await track.stop();
        } catch (e) {
          debugPrint('[WebRTCService WARN] Error stopping track: $e');
        }
      }
      try {
        await _localStream!.dispose();
      } catch (e) {
        debugPrint('[WebRTCService WARN] Error disposing local stream: $e');
      }
      _localStream = null;
    }

    // Close peer connection
    if (_peerConnection != null) {
      try {
        await _peerConnection!.close();
      } catch (e) {
        debugPrint('[WebRTCService WARN] Error closing peer connection: $e');
      }
      try {
        await _peerConnection!.dispose();
      } catch (e) {
        debugPrint('[WebRTCService WARN] Error disposing peer connection: $e');
      }
      _peerConnection = null;
    }

    // Release audio session
    if (_audioSession != null) {
      try {
        await _audioSession!.setActive(false);
      } catch (_) {}
      _audioSession = null;
    }

    _remoteStream = null;
    _isMuted = false;
    _isSpeakerOn = false;
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  bool _isDisposed = false;

  @override
  void notifyListeners() {
    if (!_isDisposed) {
      super.notifyListeners();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
    endCall();
  }
}
