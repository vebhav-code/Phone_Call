import 'package:flutter/material.dart';
import '../main.dart' show ChangeNotifierProvider;
import '../services/call_controller.dart';
import 'in_call_screen.dart';

/// Screen displayed when an incoming call arrives from a remote peer.
class IncomingCallScreen extends StatefulWidget {
  final String callerName;
  final String callerId;
  final String callId;
  final CallController? callController;

  const IncomingCallScreen({
    super.key,
    required this.callerName,
    required this.callerId,
    required this.callId,
    this.callController,
  });

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  CallController? _callController;
  bool _isActionTaken = false;

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
    if (!mounted || _isActionTaken || _callController == null) return;
    final state = _callController!.state;
    if (state == CallState.ended || state == CallState.idle) {
      setState(() {
        _isActionTaken = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Call cancelled by caller.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      if (mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  Future<void> _handleAccept() async {
    if (_isActionTaken) return;
    setState(() {
      _isActionTaken = true;
    });

    await _callController?.acceptCall();

    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => InCallScreen(
          otherUserName: widget.callerName,
          callId: widget.callId,
          otherUserId: widget.callerId,
          callController: _callController,
        ),
      ),
    );
  }

  void _handleReject() {
    if (_isActionTaken) return;
    setState(() {
      _isActionTaken = true;
    });

    _callController?.rejectCall();
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
      canPop: _isActionTaken,
      onPopInvokedWithResult: (bool didPop, dynamic result) {
        if (didPop) return;
        debugPrint('[IncomingCallScreen] Back button pressed. Rejecting call.');
        _handleReject();
      },
      child: Scaffold(
        backgroundColor: Colors.blueGrey.shade900,
        body: SafeArea(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              const SizedBox(height: 20),

              // Pulsing Caller Avatar
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
                            color: Colors.green.withValues(
                              alpha: (1.0 - _pulseController.value).clamp(0.0, 1.0) * 0.4,
                            ),
                          ),
                        ),
                        CircleAvatar(
                          radius: 54,
                          backgroundColor: Colors.blue.shade700,
                          child: Text(
                            widget.callerName.isNotEmpty
                                ? widget.callerName[0].toUpperCase()
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

              // Caller Info Text
              Column(
                children: [
                  Text(
                    '${widget.callerName} is calling...',
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Incoming Audio Call',
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.white70,
                    ),
                  ),
                ],
              ),

              // Accept / Reject Action Buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // Reject Button
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FloatingActionButton.large(
                        key: const Key('reject_call_button'),
                        heroTag: 'reject_call_fab',
                        backgroundColor: Colors.red,
                        onPressed: _handleReject,
                        child: const Icon(Icons.call_end, size: 36, color: Colors.white),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Decline',
                        style: TextStyle(color: Colors.white70, fontSize: 14),
                      ),
                    ],
                  ),

                  // Accept Button
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FloatingActionButton.large(
                        key: const Key('accept_call_button'),
                        heroTag: 'accept_call_fab',
                        backgroundColor: Colors.green,
                        onPressed: _handleAccept,
                        child: const Icon(Icons.call, size: 36, color: Colors.white),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Accept',
                        style: TextStyle(color: Colors.white70, fontSize: 14),
                      ),
                    ],
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
