import 'dart:async';
import 'package:flutter/material.dart';
import '../main.dart' show ChangeNotifierProvider;
import '../services/call_controller.dart';
import '../services/voice_detection_service.dart';

/// Screen displayed during an active 1-to-1 audio call.
class InCallScreen extends StatefulWidget {
  final String otherUserName;
  final String callId;
  final String? otherUserId;
  final CallController? callController;
  final VoidCallback? onEndCall;
  final bool? isReceiver;
  final VoiceDetectionService? voiceDetectionService;

  const InCallScreen({
    super.key,
    required this.otherUserName,
    required this.callId,
    this.otherUserId,
    this.callController,
    this.onEndCall,
    this.isReceiver,
    this.voiceDetectionService,
  });

  @override
  State<InCallScreen> createState() => _InCallScreenState();
}

class _InCallScreenState extends State<InCallScreen> {
  CallController? _callController;

  // Call duration stopwatch
  final Stopwatch _stopwatch = Stopwatch();
  Timer? _durationTimer;
  Duration _callDuration = Duration.zero;

  bool _isEndingCall = false;
  VoiceDetectionService? _voiceDetectionService;
  bool _createdVoiceService = false;

  @override
  void initState() {
    super.initState();
    _callController = widget.callController;
    _callController?.addListener(_handleControllerStateChange);

    final bool initialIsReceiver =
        widget.isReceiver ?? _callController?.isReceiver ?? false;
    if (initialIsReceiver) {
      _initVoiceDetectionService();
    }

    if (_callController?.state == CallState.connected) {
      _startTimer();
      _checkAndStartVoiceDetection();
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_callController == null) {
        _callController =
            ChangeNotifierProvider.maybeOf<CallController>(context, listen: false);
        _callController?.addListener(_handleControllerStateChange);

        final isRecv =
            widget.isReceiver ?? _callController?.isReceiver ?? false;
        if (isRecv && _voiceDetectionService == null) {
          _initVoiceDetectionService();
        }

        if (_callController?.state == CallState.connected) {
          _startTimer();
          _checkAndStartVoiceDetection();
        }
      }
    });
  }

  void _initVoiceDetectionService() {
    _voiceDetectionService = widget.voiceDetectionService ?? VoiceDetectionService();
    if (widget.voiceDetectionService == null) {
      _createdVoiceService = true;
    }
    _voiceDetectionService?.addListener(_handleVoiceDetectionUpdate);
  }

  void _handleVoiceDetectionUpdate() {
    if (mounted) {
      setState(() {});
    }
  }

  void _checkAndStartVoiceDetection() {
    final bool isReceiver =
        widget.isReceiver ?? _callController?.isReceiver ?? false;
    if (!isReceiver) return;

    if (_callController?.state == CallState.connected &&
        _voiceDetectionService != null &&
        !_voiceDetectionService!.hasStarted) {
      _voiceDetectionService!.startAnalysis(
        remoteStream: _callController?.webrtcService.remoteStream,
        isCallActive: () =>
            mounted &&
            !_isEndingCall &&
            _callController?.state == CallState.connected,
      );
    }
  }

  void _handleControllerStateChange() {
    if (!mounted || _isEndingCall || _callController == null) return;

    final state = _callController!.state;
    if (state == CallState.connected && !_stopwatch.isRunning) {
      _startTimer();
      _checkAndStartVoiceDetection();
    } else if (state == CallState.ended || state == CallState.idle) {
      _voiceDetectionService?.cancel();
      _stopTimer();
      _handleCallEnded();
    }
    setState(() {});
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

  Future<void> _handleEndCall() async {
    if (_isEndingCall) return;
    setState(() {
      _isEndingCall = true;
    });

    _voiceDetectionService?.cancel();
    _stopTimer();
    await _callController?.endCall();

    if (!mounted) return;
    if (widget.onEndCall != null) {
      widget.onEndCall!();
    } else {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  void _handleCallEnded() {
    if (_isEndingCall) return;
    setState(() {
      _isEndingCall = true;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Call ended.'),
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
    _callController?.removeListener(_handleControllerStateChange);
    _voiceDetectionService?.removeListener(_handleVoiceDetectionUpdate);
    if (_createdVoiceService) {
      _voiceDetectionService?.dispose();
    } else {
      _voiceDetectionService?.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isConnected = _callController?.state == CallState.connected;
    final stateText = isConnected
        ? 'Connected (${_formatDuration(_callDuration)})'
        : 'Connecting...';
    final stateColor = isConnected ? Colors.green : Colors.amber;
    final isMuted = _callController?.isMuted ?? false;
    final isSpeakerOn = _callController?.isSpeakerOn ?? false;

    return PopScope(
      canPop: _isEndingCall,
      onPopInvokedWithResult: (bool didPop, dynamic result) async {
        if (didPop) return;
        debugPrint('[InCallScreen] Back button pressed. Ending call.');
        await _handleEndCall();
      },
      child: Scaffold(
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
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: stateColor,
                          ),
                        ),
                      ],
                    ),
                    if (_buildVoiceAnalysisStatus() != null) ...[
                      const SizedBox(height: 12),
                      _buildVoiceAnalysisStatus()!,
                    ],
                  ],
                ),

                // Center: Animated Audio Activity Indicator
                AudioPulseIndicator(
                  isActive: isConnected,
                  isMuted: isMuted,
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
                              isSelected: isMuted,
                              onPressed: () {
                                _callController?.toggleMute();
                                setState(() {});
                              },
                              icon: Icon(
                                isMuted ? Icons.mic_off : Icons.mic,
                                color: isMuted ? Colors.red : null,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              isMuted ? 'Unmute' : 'Mute',
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
                              isSelected: isSpeakerOn,
                              onPressed: () async {
                                await _callController?.setSpeaker(!isSpeakerOn);
                                setState(() {});
                              },
                              icon: Icon(
                                isSpeakerOn
                                    ? Icons.volume_up
                                    : Icons.volume_down,
                                color: isSpeakerOn ? Colors.blue : null,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              isSpeakerOn ? 'Speaker' : 'Earpiece',
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
      ),
    );
  }

  Widget? _buildVoiceAnalysisStatus() {
    final isReceiver = widget.isReceiver ?? _callController?.isReceiver ?? false;
    if (!isReceiver || _voiceDetectionService == null) {
      return null;
    }

    final status = _voiceDetectionService!.status;
    final result = _voiceDetectionService!.result;

    switch (status) {
      case VoiceAnalysisStatus.idle:
        return null;

      case VoiceAnalysisStatus.recording:
        return Container(
          key: const Key('voice_analysis_recording'),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black26,
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 8,
                height: 8,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: Colors.redAccent,
                ),
              ),
              SizedBox(width: 8),
              Text(
                'Voice analysis recording...',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.white70,
                ),
              ),
            ],
          ),
        );

      case VoiceAnalysisStatus.analyzing:
        return Container(
          key: const Key('voice_analysis_analyzing'),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black26,
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 8,
                height: 8,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: Colors.blueAccent,
                ),
              ),
              SizedBox(width: 8),
              Text(
                'Analyzing voice...',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.white70,
                ),
              ),
            ],
          ),
        );

      case VoiceAnalysisStatus.success:
        if (result == null) return null;
        final isReal = result.displayVerdict == 'REAL';
        final verdictColor = isReal ? Colors.greenAccent : Colors.redAccent;

        return Container(
          key: const Key('voice_analysis_result'),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black38,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: verdictColor.withValues(alpha: 0.5),
              width: 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Voice Analysis',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Colors.white70,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                result.displayVerdict,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: verdictColor,
                  letterSpacing: 1.0,
                ),
              ),
              const SizedBox(height: 4),
              if (isReal) ...[
                Text(
                  'Bonafide Score: ${result.displayBonafideScore}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.white70,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Fake Probability: ${result.displayFakeProbability}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.white70,
                  ),
                ),
              ] else ...[
                Text(
                  'Fake Probability: ${result.displayFakeProbability}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.white70,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Bonafide Score: ${result.displayBonafideScore}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.white70,
                  ),
                ),
              ],
            ],
          ),
        );

      case VoiceAnalysisStatus.recordingFailed:
        return Container(
          key: const Key('voice_analysis_recording_failed'),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black26,
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Text(
            'Voice recording failed',
            style: TextStyle(
              fontSize: 12,
              color: Colors.amber,
            ),
          ),
        );

      case VoiceAnalysisStatus.uploadFailed:
        return Container(
          key: const Key('voice_analysis_upload_failed'),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black26,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            _voiceDetectionService?.errorMessage != null &&
                    _voiceDetectionService!.errorMessage!.isNotEmpty
                ? 'Voice upload failed: ${_voiceDetectionService!.errorMessage!}'
                : 'Voice upload failed',
            style: const TextStyle(
              fontSize: 12,
              color: Colors.amber,
            ),
          ),
        );

      case VoiceAnalysisStatus.analysisFailed:
        return Container(
          key: const Key('voice_analysis_failed'),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black26,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            _voiceDetectionService?.errorMessage ?? 'Voice analysis failed',
            style: const TextStyle(
              fontSize: 12,
              color: Colors.amber,
            ),
          ),
        );
    }
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
