import 'dart:async';
import 'package:flutter/material.dart';
import '../services/signaling_service.dart';
import '../webrtc_service.dart';
import 'in_call_screen.dart';

/// Screen displayed while ringing/waiting for an outgoing call to be accepted.
class OutgoingCallScreen extends StatefulWidget {
  final String contactName;
  final String callId;
  final String? otherUserId;
  final SignalingService? signalingService;
  final WebRTCService? webrtcService;

  const OutgoingCallScreen({
    super.key,
    required this.contactName,
    required this.callId,
    this.otherUserId,
    this.signalingService,
    this.webrtcService,
  });

  @override
  State<OutgoingCallScreen> createState() => _OutgoingCallScreenState();
}

class _OutgoingCallScreenState extends State<OutgoingCallScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  SignalingService? _signaling;
  WebRTCService? _webrtc;
  StreamSubscription<CallLifecycleState>? _callStateSub;
  bool _isNavigated = false;

  @override
  void initState() {
    super.initState();
    _signaling = widget.signalingService;
    _webrtc = widget.webrtcService;

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();

    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.45).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeOut),
    );

    _initCallListeners();
  }

  void _initCallListeners() {
    // If call is already accepted, transition immediately
    if (_signaling != null && _signaling!.callState == CallLifecycleState.inCall) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _onCallAccepted());
      return;
    }

    if (_signaling != null) {
      _callStateSub = _signaling!.callStateStream.listen((state) {
        if (!mounted || _isNavigated) return;

        switch (state) {
          case CallLifecycleState.inCall:
            _onCallAccepted();
            break;

          case CallLifecycleState.failed:
            _onCallFailed('Call failed (peer offline or busy)');
            break;

          case CallLifecycleState.ended:
            _onCallFailed('Call was rejected or ended');
            break;

          default:
            break;
        }
      });
    }
  }

  void _onCallAccepted() {
    if (_isNavigated) return;
    _isNavigated = true;

    // Start WebRTC as caller immediately
    _webrtc?.startAsCaller(widget.callId);

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => InCallScreen(
          otherUserName: widget.contactName,
          callId: widget.callId,
          otherUserId: widget.otherUserId,
          signalingService: _signaling,
          webrtcService: _webrtc,
        ),
      ),
    );
  }

  void _onCallFailed(String reason) {
    if (_isNavigated) return;
    _isNavigated = true;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(reason),
        behavior: SnackBarBehavior.floating,
      ),
    );

    Navigator.of(context).pop();
  }

  void _handleCancel() {
    if (_isNavigated) return;
    _isNavigated = true;

    // Send call_ended via SignalingService
    if (widget.otherUserId != null && widget.otherUserId!.isNotEmpty) {
      _signaling?.endCall(widget.callId, widget.otherUserId!);
    } else {
      _signaling?.endCall(widget.callId, '');
    }

    _webrtc?.endCall();
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _callStateSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.blueGrey.shade900,
      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            const SizedBox(height: 20),

            // Pulsing Ringing Avatar Visual
            Center(
              child: AnimatedBuilder(
                animation: _pulseAnimation,
                builder: (context, child) {
                  return Stack(
                    alignment: Alignment.center,
                    children: [
                      // Expanding ripple wave
                      Container(
                        width: 140 * _pulseAnimation.value,
                        height: 140 * _pulseAnimation.value,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.blue.withValues(
                            alpha: (1.0 - _pulseController.value).clamp(0.0, 1.0) * 0.4,
                          ),
                        ),
                      ),
                      // Core avatar
                      CircleAvatar(
                        radius: 54,
                        backgroundColor: Colors.blue.shade600,
                        child: Text(
                          widget.contactName.isNotEmpty
                              ? widget.contactName[0].toUpperCase()
                              : '?',
                          style: const TextStyle(
                            fontSize: 48,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),

            // Calling Info Text
            Column(
              children: [
                Text(
                  'Calling ${widget.contactName}...',
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 10),
                const Text(
                  'Ringing...',
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.white70,
                  ),
                ),
              ],
            ),

            // Cancel Call Button
            Column(
              children: [
                SizedBox(
                  width: 72,
                  height: 72,
                  child: FloatingActionButton(
                    key: const Key('cancel_call_button'),
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                    shape: const CircleBorder(),
                    onPressed: _handleCancel,
                    child: const Icon(Icons.call_end, size: 36),
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Cancel',
                  style: TextStyle(color: Colors.white70, fontSize: 14),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
