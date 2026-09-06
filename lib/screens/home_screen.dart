import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../main.dart' show ChangeNotifierProvider;
import '../models/contact_model.dart';
import '../services/api_service.dart';
import '../services/signaling_service.dart';
import '../webrtc_service.dart';
import 'add_contact_screen.dart';
import 'incoming_call_screen.dart';
import 'outgoing_call_screen.dart';
import 'registration_screen.dart';

/// The main dashboard screen showing the user's contacts and handling incoming/outgoing calls.
class HomeScreen extends StatefulWidget {
  final ApiService? apiService;
  final SignalingService? signalingService;
  final WebRTCService? webrtcService;

  const HomeScreen({
    super.key,
    this.apiService,
    this.signalingService,
    this.webrtcService,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final ApiService _apiService;
  SignalingService? _signalingService;
  WebRTCService? _webrtcService;
  StreamSubscription? _incomingCallSubscription;

  List<ContactModel> _contacts = [];
  bool _isLoading = true;
  String? _errorMessage;
  String? _callingContactUserId;

  // Current authenticated user info
  String _currentUserId = '';
  String _currentUserName = '';
  String _currentUsername = '';

  @override
  void initState() {
    super.initState();
    _apiService = widget.apiService ?? ApiService();
    _signalingService = widget.signalingService;
    _webrtcService = widget.webrtcService;
    _initialize();
  }

  Future<void> _initialize() async {
    _signalingService ??=
        ChangeNotifierProvider.maybeOf<SignalingService>(context, listen: false) ??
        SignalingService();
    _webrtcService ??=
        ChangeNotifierProvider.maybeOf<WebRTCService>(context, listen: false) ??
        WebRTCService(signalingService: _signalingService);

    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;

    final userId = prefs.getString('user_id') ?? '';
    final userName = prefs.getString('user_name') ?? '';
    final username = prefs.getString('username') ?? '';

    setState(() {
      _currentUserId = userId;
      _currentUserName = userName;
      _currentUsername = username;
    });

    if (userId.isNotEmpty) {
      if (!_signalingService!.isConnected) {
        await _signalingService!.connect(userId);
      }
      _listenForIncomingCalls();
      await _loadContacts();
    } else {
      setState(() => _isLoading = false);
    }
  }

  void _listenForIncomingCalls() {
    _incomingCallSubscription?.cancel();
    if (_signalingService != null) {
      _incomingCallSubscription =
          _signalingService!.incomingCalls.listen((call) {
        if (!mounted) return;

        _webrtcService ??=
            ChangeNotifierProvider.maybeOf<WebRTCService>(context, listen: false) ??
            WebRTCService(signalingService: _signalingService);

        // Navigate to IncomingCallScreen regardless of what screen is currently showing
        Navigator.of(context, rootNavigator: true).push(
          MaterialPageRoute(
            builder: (_) => IncomingCallScreen(
              callerName: call.callerName,
              callerId: call.callerId,
              callId: call.callId,
              signalingService: _signalingService,
              webrtcService: _webrtcService,
            ),
          ),
        );
      });
    }
  }

  Future<void> _loadContacts() async {
    if (_currentUserId.isEmpty) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final contacts = await _apiService.getContacts(_currentUserId);
      setState(() {
        _contacts = contacts;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to load contacts: $e';
      });
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _handleCall(ContactModel contact) async {
    if (_signalingService == null || !_signalingService!.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Signaling service is not connected.')),
      );
      return;
    }

    setState(() {
      _callingContactUserId = contact.contactUserId;
    });

    try {
      final callId = await _signalingService!.callUser(contact.contactUserId);
      if (!mounted) return;

      _webrtcService ??=
          ChangeNotifierProvider.maybeOf<WebRTCService>(context, listen: false) ??
          WebRTCService(signalingService: _signalingService);

      // Navigate to OutgoingCallScreen immediately once call_request is dispatched.
      // OutgoingCallScreen displays the ringing UI and listens for acceptance/rejection/timeout.
      Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute(
          builder: (_) => OutgoingCallScreen(
            contactName: contact.name,
            callId: callId,
            otherUserId: contact.contactUserId,
            signalingService: _signalingService,
            webrtcService: _webrtcService,
          ),
        ),
      );
    } on CallFailedException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Call failed: ${e.reason}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not start call: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _callingContactUserId = null;
        });
      }
    }
  }

  Future<void> _navigateToAddContact() async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AddContactScreen(apiService: _apiService),
      ),
    );

    if (result == true) {
      _loadContacts();
    }
  }

  Future<void> _logout() async {
    _incomingCallSubscription?.cancel();
    _signalingService?.disconnect();

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('user_id');
    await prefs.remove('user_name');
    await prefs.remove('username');

    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const RegistrationScreen()),
    );
  }

  Widget? _buildPresenceDot(ContactModel contact) {
    // Only display online dot if presence information is available.
    // If not available (null), omit rather than faking it.
    if (contact.isOnline == null) {
      return null;
    }
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: contact.isOnline! ? Colors.green : Colors.grey.shade400,
      ),
    );
  }

  @override
  void dispose() {
    _incomingCallSubscription?.cancel();
    _signalingService?.disconnect();
    if (widget.apiService == null) {
      _apiService.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Contacts',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
            ),
            if (_currentUserName.isNotEmpty)
              Text(
                '$_currentUserName (@$_currentUsername)',
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else if (_currentUsername.isNotEmpty)
              Text(
                '@$_currentUsername',
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        actions: [
          IconButton(
            key: const Key('add_contact_appbar_btn'),
            icon: const Icon(Icons.person_add_alt_1),
            tooltip: 'Add Contact',
            onPressed: _navigateToAddContact,
          ),
          IconButton(
            key: const Key('logout_btn'),
            icon: const Icon(Icons.logout),
            tooltip: 'Logout',
            onPressed: _logout,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
                      const SizedBox(height: 12),
                      Text(
                        _errorMessage!,
                        style: TextStyle(color: theme.colorScheme.error),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        onPressed: _loadContacts,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              : _contacts.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.people_outline,
                            size: 64,
                            color: theme.colorScheme.outline,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'No contacts yet',
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: theme.colorScheme.outline,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Tap the button below to add your first contact.',
                            style: TextStyle(color: theme.colorScheme.outline),
                          ),
                        ],
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _loadContacts,
                      child: ListView.separated(
                        itemCount: _contacts.length,
                        separatorBuilder: (context, index) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final contact = _contacts[index];
                          final isCallingThisContact =
                              _callingContactUserId == contact.contactUserId;
                          final presenceDot = _buildPresenceDot(contact);

                          return ListTile(
                            key: Key('contact_tile_${contact.contactUserId}'),
                            leading: Stack(
                              children: [
                                CircleAvatar(
                                  radius: 22,
                                  backgroundColor: theme.colorScheme.primaryContainer,
                                  child: Text(
                                    contact.name.isNotEmpty
                                        ? contact.name[0].toUpperCase()
                                        : '?',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: theme.colorScheme.onPrimaryContainer,
                                    ),
                                  ),
                                ),
                                if (presenceDot != null)
                                  Positioned(
                                    right: 0,
                                    bottom: 0,
                                    child: presenceDot,
                                  ),
                              ],
                            ),
                            title: Text(
                              contact.name,
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                            subtitle: Text('@${contact.username}'),
                            trailing: isCallingThisContact
                                ? const SizedBox(
                                    height: 24,
                                    width: 24,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : IconButton(
                                    key: Key('call_btn_${contact.contactUserId}'),
                                    icon: const Icon(Icons.call, color: Colors.green),
                                    tooltip: 'Call ${contact.name}',
                                    onPressed: () => _handleCall(contact),
                                  ),
                          );
                        },
                      ),
                    ),
      floatingActionButton: FloatingActionButton(
        key: const Key('add_contact_fab'),
        onPressed: _navigateToAddContact,
        tooltip: 'Add Contact',
        child: const Icon(Icons.person_add),
      ),
    );
  }
}


