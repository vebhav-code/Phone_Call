import 'package:flutter/material.dart';
import '../main.dart' show ChangeNotifierProvider;
import '../services/call_controller.dart';
import 'in_call_screen.dart';

/// Screen displayed while waiting for an outgoing call to be accepted.
class OutgoingCallScreen extends StatefulWidget {
  final String contactName;
  final String? otherUserId;
  final String? callId;
  final CallController? callController;

  const OutgoingCallScreen({
    super.key,
    required this.contactName,
    this.otherUserId,
    this.callId,
    this.callController,
  });

  @override
  State<OutgoingCallScreen> createState() => _OutgoingCallScreenState();
}

class _OutgoingCallScreenState extends State<OutgoingCallScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  CallController? _callController;
  bool _isNavigated = false;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();

    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.45).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeOut),
    );

    _callController = widget.callController;
    _callController?.addListener(_handleCallStateChange);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_callController == null && mounted) {
        _callController = ChangeNotifierProvider.maybeOf<CallController>(context, listen: false);
        _callController?.addListener(_handleCallStateChange);
      }
    });
  }

  void _handleCallStateChange() {
    if (!mounted || _isNavigated || _callController == null) return;

    final state = _callController!.state;
    if (state == CallState.connecting || state == CallState.connected) {
      setState(() {
        _isNavigated = true;
      });
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => InCallScreen(
            otherUserName: widget.contactName,
            otherUserId: widget.otherUserId ?? _callController?.otherUserId,
            callId: _callController?.currentCallId ?? '',
            callController: _callController,
            isReceiver: false,
          ),
        ),
      );
    } else if (state == CallState.ended || state == CallState.idle) {
      setState(() {
        _isNavigated = true;
      });
      final reason = _callController!.lastFailureReason ?? 'Call was rejected or ended';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(reason),
          behavior: SnackBarBehavior.floating,
        ),
      );
      if (mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  void _handleCancel() {
    if (_isNavigated) return;
    setState(() {
      _isNavigated = true;
    });
    _callController?.endCall();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _callController?.removeListener(_handleCallStateChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _isNavigated,
      onPopInvokedWithResult: (bool didPop, dynamic result) {
        if (didPop) return;
        debugPrint('[OutgoingCallScreen] Back button pressed. Cancelling call.');
        _handleCancel();
      },
      child: Scaffold(
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
      ),
    );
  }
}
