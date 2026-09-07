import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/contact_model.dart';
import '../services/call_controller.dart';
import 'outgoing_call_screen.dart';

/// Full-screen dial pad view allowing numeric dialing, contact matching, and initiating calls.
class DialPadScreen extends StatefulWidget {
  final List<ContactModel> contacts;
  final CallController? callController;
  final Future<void> Function(ContactModel contact)? onCallContact;
  final Future<void> Function(String phoneNumber)? onCallNumber;

  const DialPadScreen({
    super.key,
    this.contacts = const [],
    this.callController,
    this.onCallContact,
    this.onCallNumber,
  });

  @override
  State<DialPadScreen> createState() => _DialPadScreenState();
}

class _DialPadScreenState extends State<DialPadScreen> {
  String _dialedNumber = '';

  ContactModel? get _matchedContact {
    if (_dialedNumber.trim().isEmpty) return null;
    final cleaned = _dialedNumber.replaceAll(RegExp(r'[^0-9]'), '');
    if (cleaned.isEmpty) return null;

    for (final c in widget.contacts) {
      final contactCleaned =
          c.phoneNumber.replaceAll(RegExp(r'[^0-9]'), '');
      if (contactCleaned.isNotEmpty &&
          (contactCleaned.contains(cleaned) ||
              cleaned.contains(contactCleaned))) {
        return c;
      }
    }
    return null;
  }

  void _onDigitPressed(String digit) {
    HapticFeedback.lightImpact();
    setState(() {
      _dialedNumber += digit;
    });
  }

  void _onBackspace() {
    if (_dialedNumber.isEmpty) return;
    HapticFeedback.lightImpact();
    setState(() {
      _dialedNumber =
          _dialedNumber.substring(0, _dialedNumber.length - 1);
    });
  }

  void _onClear() {
    if (_dialedNumber.isEmpty) return;
    HapticFeedback.mediumImpact();
    setState(() {
      _dialedNumber = '';
    });
  }

  Future<void> _handleCall() async {
    final number = _dialedNumber.trim();
    if (number.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a phone number to call.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final matched = _matchedContact;
    if (matched != null) {
      if (widget.onCallContact != null) {
        Navigator.pop(context);
        await widget.onCallContact!(matched);
        return;
      } else if (widget.callController != null) {
        Navigator.pop(context);
        widget.callController!.startCall(matched.contactUserId, matched.name);
        Navigator.of(context, rootNavigator: true).push(
          MaterialPageRoute(
            builder: (_) => OutgoingCallScreen(
              contactName: matched.name,
              otherUserId: matched.contactUserId,
              callController: widget.callController,
            ),
          ),
        );
        return;
      }
    }

    if (widget.onCallNumber != null) {
      Navigator.pop(context);
      await widget.onCallNumber!(number);
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Calling $number...'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final matched = _matchedContact;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF1E293B)),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Keypad',
          style: TextStyle(
            color: Color(0xFF0F172A),
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Matched Contact Preview
              SizedBox(
                height: 42,
                child: Center(
                  child: matched != null
                      ? Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xFFEFF6FF),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: const Color(0xFFBFDBFE)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CircleAvatar(
                                radius: 10,
                                backgroundColor: const Color(0xFF2563EB),
                                child: Text(
                                  matched.name.isNotEmpty
                                      ? matched.name[0].toUpperCase()
                                      : '?',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                matched.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF1E3A8A),
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ),

              // Dialed Number Display & Backspace
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 8.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(width: 48),
                    Expanded(
                      child: Text(
                        _dialedNumber.isEmpty ? ' ' : _dialedNumber,
                        key: const Key('dialed_number_text'),
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF0F172A),
                          letterSpacing: 2,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 48,
                      child: _dialedNumber.isNotEmpty
                          ? GestureDetector(
                              onLongPress: _onClear,
                              child: IconButton(
                                key: const Key('dialpad_backspace'),
                                icon: const Icon(
                                  Icons.backspace_outlined,
                                  color: Color(0xFF64748B),
                                  size: 24,
                                ),
                                onPressed: _onBackspace,
                                tooltip: 'Delete (Hold to clear)',
                              ),
                            )
                          : null,
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 12),

              // Keypad Grid 3x4
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32.0),
                child: Column(
                  children: [
                    _buildKeypadRow([
                      _KeyData('1', ''),
                      _KeyData('2', 'ABC'),
                      _KeyData('3', 'DEF'),
                    ]),
                    const SizedBox(height: 12),
                    _buildKeypadRow([
                      _KeyData('4', 'GHI'),
                      _KeyData('5', 'JKL'),
                      _KeyData('6', 'MNO'),
                    ]),
                    const SizedBox(height: 12),
                    _buildKeypadRow([
                      _KeyData('7', 'PQRS'),
                      _KeyData('8', 'TUV'),
                      _KeyData('9', 'WXYZ'),
                    ]),
                    const SizedBox(height: 12),
                    _buildKeypadRow([
                      _KeyData('*', ''),
                      _KeyData('0', '+', onLongPress: () => _onDigitPressed('+')),
                      _KeyData('#', ''),
                    ]),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              // Green Call Button
              Center(
                child: SizedBox(
                  width: 64,
                  height: 64,
                  child: ElevatedButton(
                    key: const Key('dialpad_call_button'),
                    onPressed: _handleCall,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF22C55E),
                      foregroundColor: Colors.white,
                      shape: const CircleBorder(),
                      padding: EdgeInsets.zero,
                      elevation: 4,
                      shadowColor: const Color(0xFF22C55E).withValues(alpha: 0.5),
                    ),
                    child: const Icon(Icons.call, size: 30),
                  ),
                ),
              ),

              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildKeypadRow(List<_KeyData> keys) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: keys.map((keyData) {
        return _buildKeypadButton(keyData);
      }).toList(),
    );
  }

  Widget _buildKeypadButton(_KeyData keyData) {
    return GestureDetector(
      onLongPress: keyData.onLongPress,
      child: InkWell(
        key: Key('dialpad_key_${keyData.number}'),
        onTap: () => _onDigitPressed(keyData.number),
        borderRadius: BorderRadius.circular(35),
        child: Container(
          width: 70,
          height: 70,
          decoration: BoxDecoration(
            color: const Color(0xFFF1F5F9),
            shape: BoxShape.circle,
            border: Border.all(
              color: const Color(0xFFE2E8F0),
              width: 1,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                keyData.number,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF0F172A),
                  height: 1.1,
                ),
              ),
              if (keyData.letters.isNotEmpty)
                Text(
                  keyData.letters,
                  style: const TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF64748B),
                    letterSpacing: 1.1,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _KeyData {
  final String number;
  final String letters;
  final VoidCallback? onLongPress;

  _KeyData(this.number, this.letters, {this.onLongPress});
}
