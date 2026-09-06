import 'dart:async';
import 'package:flutter/material.dart';
import '../services/signaling_service.dart';
import '../webrtc_service.dart';

/// Screen displayed during an active 1-to-1 audio call.
class InCallScreen extends StatefulWidget {
  final String otherUserName;
  final String callId;
  final String? otherUserId;
  final SignalingService? signalingService;
  final WebRTCService? webrtcService;
  final VoidCallback? onEndCall;

  const InCallScreen({
    super.key,
    required this.otherUserName,
    required this.callId,
    this.otherUserId,
    this.signalingService,
    this.webrtcService,
    this.onEndCall,
  });

  @override
  State<InCallScreen> createState() => _InCallScreenState();
}

class _InCallScreenState extends State<InCallScreen> {
  late final WebRTCService _webrtc;
  SignalingService? _signaling;
  late CallState _displayState;

  // Call duration timer
  final Stopwatch _stopwatch = Stopwatch();
  Timer? _durationTimer;
  Duration _callDuration = Duration.zero;

  // Subscriptions
  StreamSubscription<CallLifecycleState>? _signalingSubscription;
  VoidCallback? _webrtcListener;

  @override
  void initState() {
    super.initState();
    _webrtc = widget.webrtcService ?? WebRTCService();
    _signaling = widget.signalingService;

    // Default initial displayed status to Connecting... when entered via active call flow
    _displayState = _webrtc.callState == CallState.connected
        ? CallState.connected
        : CallState.connecting;

    // Listen to WebRTC connection state to start duration timer
    _webrtcListener = _handleWebRTCStateChange;
    _webrtc.addListener(_webrtcListener!);

    // Start timer immediately if already connected
    if (_webrtc.callState == CallState.connected) {
      _startTimer();
    }

    // Listen for peer-initiated call termination from SignalingService
    if (_signaling != null) {
      _signalingSubscription = _signaling!.callStateStream.listen((state) {
        if (state == CallLifecycleState.ended ||
            state == CallLifecycleState.failed) {
          _handlePeerEndedCall();
        }
      });
    }
  }

  void _handleWebRTCStateChange() {
    _displayState = _webrtc.callState;
    if (_webrtc.callState == CallState.connected && !_stopwatch.isRunning) {
      _startTimer();
    } else if (_webrtc.callState == CallState.disconnected ||
        _webrtc.callState == CallState.peerDisconnected) {
      _stopTimer();
    }
    if (mounted) setState(() {});
  }

  void _startTimer() {
    if (_stopwatch.isRunning) return;
    _stopwatch.start();
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {
          _callDuration = _stopwatch.elapsed;
        });
      }
    });
  }

  void _stopTimer() {
    _stopwatch.stop();
    _durationTimer?.cancel();
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final hours = d.inHours;
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  String _formatCallState(CallState state) {
    switch (state) {
      case CallState.connecting:
        return 'Connecting...';
      case CallState.connected:
        return 'Connected (${_formatDuration(_callDuration)})';
      case CallState.peerDisconnected:
        return 'Peer Disconnected';
      case CallState.roomFull:
        return 'Room Full';
      case CallState.disconnected:
        return 'Disconnected';
    }
  }

  Color _statusColor(CallState state) {
    switch (state) {
      case CallState.connected:
        return Colors.green;
      case CallState.connecting:
        return Colors.amber;
      case CallState.peerDisconnected:
      case CallState.roomFull:
      case CallState.disconnected:
        return Colors.red;
    }
  }

  Future<void> _handleEndCall() async {
    _stopTimer();

    // 1. Send call_ended via SignalingService
    if (widget.otherUserId != null && widget.otherUserId!.isNotEmpty) {
      _signaling?.endCall(widget.callId, widget.otherUserId!);
    }

    // 2. Tear down WebRTC session
    await _webrtc.endCall();

    if (!mounted) return;

    if (widget.onEndCall != null) {
      widget.onEndCall!();
    } else {
      // Pop back to HomeScreen
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  Future<void> _handlePeerEndedCall() async {
    _stopTimer();
    await _webrtc.endCall();

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Call ended by remote peer.'),
        behavior: SnackBarBehavior.floating,
      ),
    );

    if (widget.onEndCall != null) {
      widget.onEndCall!();
    } else {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  @override
  void dispose() {
    _stopTimer();
    if (_webrtcListener != null) {
      _webrtc.removeListener(_webrtcListener!);
    }
    _signalingSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final String stateText = _formatCallState(_displayState);
    final Color stateColor = _statusColor(_displayState);
    final bool isCallActive = _displayState == CallState.connected;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Header: Contact Name and Call Status / Duration
              Column(
                children: [
                  const SizedBox(height: 16),
                  Text(
                    widget.otherUserName,
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: stateColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        stateText,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: stateColor,
                        ),
                      ),
                    ],
                  ),
                ],
              ),

              // Center: Animated Audio Activity Indicator
              AudioPulseIndicator(
                isActive: isCallActive,
                isMuted: _webrtc.isMuted,
              ),

              // Footer: Call Controls (Mute, Speaker, End Call)
              Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      // Mute / Unmute Button
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton.filledTonal(
                            key: const Key('mute_btn'),
                            iconSize: 32,
                            isSelected: _webrtc.isMuted,
                            onPressed: isCallActive ||
                                    _displayState == CallState.connecting
                                ? () {
                                    _webrtc.toggleMute();
                                    setState(() {});
                                  }
                                : null,
                            icon: Icon(
                              _webrtc.isMuted ? Icons.mic_off : Icons.mic,
                              color: _webrtc.isMuted ? Colors.red : null,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _webrtc.isMuted ? 'Unmute' : 'Mute',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ),

                      // Speakerphone Toggle Button
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton.filledTonal(
                            key: const Key('speaker_btn'),
                            iconSize: 32,
                            isSelected: _webrtc.isSpeakerOn,
                            onPressed: isCallActive ||
                                    _displayState == CallState.connecting
                                ? () async {
                                    await _webrtc.setSpeaker(!_webrtc.isSpeakerOn);
                                    setState(() {});
                                  }
                                : null,
                            icon: Icon(
                              _webrtc.isSpeakerOn
                                  ? Icons.volume_up
                                  : Icons.volume_down,
                              color: _webrtc.isSpeakerOn ? Colors.blue : null,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _webrtc.isSpeakerOn ? 'Speaker' : 'Earpiece',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 36),

                  // End Call Red Button
                  SizedBox(
                    width: 72,
                    height: 72,
                    child: FloatingActionButton(
                      key: const Key('end_call_button'),
                      backgroundColor: Colors.red,
                      foregroundColor: Colors.white,
                      shape: const CircleBorder(),
                      onPressed: _handleEndCall,
                      child: const Icon(Icons.call_end, size: 36),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Animated pulsing circle indicating voice connection and mic status.
class AudioPulseIndicator extends StatefulWidget {
  final bool isActive;
  final bool isMuted;

  const AudioPulseIndicator({
    super.key,
    required this.isActive,
    required this.isMuted,
  });

  @override
  State<AudioPulseIndicator> createState() => _AudioPulseIndicatorState();
}

class _AudioPulseIndicatorState extends State<AudioPulseIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    _scaleAnimation = Tween<double>(begin: 0.90, end: 1.15).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool pulsing = widget.isActive && !widget.isMuted;
    final Color activeColor = widget.isMuted
        ? Colors.grey
        : (widget.isActive ? Colors.green : Colors.amber);

    return AnimatedBuilder(
      animation: _scaleAnimation,
      builder: (context, child) {
        final double scale = pulsing ? _scaleAnimation.value : 1.0;
        return Transform.scale(
          scale: scale,
          child: Container(
            width: 140,
            height: 140,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: activeColor.withValues(alpha: 0.15),
              border: Border.all(
                color: activeColor,
                width: 3,
              ),
            ),
            child: Center(
              child: Icon(
                widget.isMuted ? Icons.mic_off : Icons.record_voice_over,
                size: 64,
                color: activeColor,
              ),
            ),
          ),
        );
      },
    );
  }
}
