import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../main.dart' show ChangeNotifierProvider;
import '../models/contact_model.dart';
import '../services/api_service.dart';
import '../services/call_controller.dart';
import '../services/call_history_service.dart';
import '../services/signaling_service.dart';
import '../webrtc_service.dart';
import 'add_contact_screen.dart';
import 'dialpad_screen.dart';
import 'incoming_call_screen.dart';
import 'login_screen.dart';
import 'outgoing_call_screen.dart';

const List<Color> _avatarColors = [
  Color(0xFF2563EB), // Blue
  Color(0xFF0D9488), // Teal
  Color(0xFF7C3AED), // Purple
  Color(0xFFE11D48), // Rose
  Color(0xFFD97706), // Amber
  Color(0xFF059669), // Emerald
  Color(0xFFDB2777), // Pink
  Color(0xFF4F46E5), // Indigo
];

Color _getAvatarColor(String seed) {
  if (seed.isEmpty) return _avatarColors[0];
  final hash = seed.codeUnits.fold<int>(0, (prev, elem) => prev + elem);
  return _avatarColors[hash % _avatarColors.length];
}

/// The main dashboard screen showing the user's contacts and handling incoming/outgoing calls.
class HomeScreen extends StatefulWidget {
  final ApiService? apiService;
  final SignalingService? signalingService;
  final WebRTCService? webrtcService;
  final CallController? callController;

  const HomeScreen({
    super.key,
    this.apiService,
    this.signalingService,
    this.webrtcService,
    this.callController,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final ApiService _apiService;
  CallController? _callController;
  SignalingService? _signalingService;
  WebRTCService? _webrtcService;

  List<ContactModel> _contacts = [];
  List<ContactModel> _frequentContacts = [];
  bool _isLoading = true;
  String? _errorMessage;
  String? _callingContactUserId;
  bool _isNavigatingCall = false;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  // Current authenticated user info
  String _currentUserId = '';
  String _currentUserName = '';
  String _currentPhoneNumber = '';

  @override
  void initState() {
    super.initState();
    _apiService = widget.apiService ?? ApiService();
    _callController = widget.callController;
    _signalingService = widget.signalingService;
    _webrtcService = widget.webrtcService;
    _listenForCalls();
    _initialize();
  }

  bool _createdLocalSignaling = false;
  bool _createdLocalWebRTC = false;
  bool _createdLocalCallController = false;

  Future<void> _initialize() async {
    _callController ??=
        ChangeNotifierProvider.maybeOf<CallController>(context, listen: false);

    if (_signalingService == null) {
      final sharedSignaling = _callController?.signalingService ??
          ChangeNotifierProvider.maybeOf<SignalingService>(context, listen: false);
      if (sharedSignaling != null) {
        _signalingService = sharedSignaling;
      } else {
        _signalingService = SignalingService();
        _createdLocalSignaling = true;
      }
    }

    if (_webrtcService == null) {
      final sharedWebRTC = _callController?.webrtcService ??
          ChangeNotifierProvider.maybeOf<WebRTCService>(context, listen: false);
      if (sharedWebRTC != null) {
        _webrtcService = sharedWebRTC;
      } else {
        _webrtcService = WebRTCService();
        _createdLocalWebRTC = true;
      }
    }

    if (_callController == null && _signalingService != null && _webrtcService != null) {
      _callController = CallController(
        signalingService: _signalingService!,
        webrtcService: _webrtcService!,
      );
      _createdLocalCallController = true;
    }

    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;

    final userId = prefs.getString('user_id') ?? '';
    final userName = prefs.getString('user_name') ?? '';
    final phone = prefs.getString('phone_number') ??
        prefs.getString('username') ??
        '';

    setState(() {
      _currentUserId = userId;
      _currentUserName = userName;
      _currentPhoneNumber = phone;
    });

    if (userId.isNotEmpty) {
      if (!_signalingService!.isConnected) {
        await _signalingService!.connect(userId);
      }
      _listenForCalls();
      await _loadContacts();
    } else {
      setState(() => _isLoading = false);
    }
  }

  void _listenForCalls() {
    _callController?.removeListener(_onCallControllerStateChange);
    _callController?.addListener(_onCallControllerStateChange);
  }

  void _onCallControllerStateChange() {
    if (!mounted || _callController == null || _isNavigatingCall) return;

    if (_callController!.state == CallState.ringing) {
      _isNavigatingCall = true;
      Navigator.of(context, rootNavigator: true)
          .push(
        MaterialPageRoute(
          builder: (_) => IncomingCallScreen(
            callerName: _callController!.otherUserName ?? 'Unknown Caller',
            callerId: _callController!.otherUserId ?? '',
            callId: _callController!.currentCallId ?? '',
            callController: _callController,
          ),
        ),
      )
          .then((_) {
        _isNavigatingCall = false;
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
      await _loadFrequentContacts(contacts);
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

  Future<void> _loadFrequentContacts(List<ContactModel> allContacts) async {
    try {
      final frequentIds = await CallHistoryService.getFrequentContactIds();
      final Map<String, ContactModel> contactMap = {
        for (final c in allContacts) c.contactUserId: c
      };

      final List<ContactModel> frequents = [];
      for (final id in frequentIds) {
        if (contactMap.containsKey(id)) {
          frequents.add(contactMap[id]!);
        }
      }

      if (mounted) {
        setState(() {
          _frequentContacts = frequents;
        });
      }
    } catch (_) {}
  }

  Future<void> _handleCall(ContactModel contact) async {
    if (_signalingService == null || !_signalingService!.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Signaling service is not connected.')),
      );
      return;
    }

    if (_callController == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Call controller is not initialized.')),
      );
      return;
    }

    setState(() {
      _callingContactUserId = contact.contactUserId;
    });

    // Record call for frequency tracking
    await CallHistoryService.recordCall(contact.contactUserId);
    _loadFrequentContacts(_contacts);

    if (!mounted) return;

    try {
      _callController!.startCall(contact.contactUserId, contact.name);

      _isNavigatingCall = true;
      await Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute(
          builder: (_) => OutgoingCallScreen(
            contactName: contact.name,
            otherUserId: contact.contactUserId,
            callController: _callController,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not start call: $e')),
      );
    } finally {
      _isNavigatingCall = false;
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

  void _openDialPad() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DialPadScreen(
          contacts: _contacts,
          callController: _callController,
          onCallContact: _handleCall,
        ),
      ),
    );
  }

  Future<void> _logout() async {
    _callController?.removeListener(_onCallControllerStateChange);
    _callController?.endCall();
    _signalingService?.disconnect();

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('user_id');
    await prefs.remove('user_name');
    await prefs.remove('phone_number');
    await prefs.remove('username');

    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pushReplacement(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
    );
  }

  Widget? _buildPresenceDot(ContactModel contact) {
    if (contact.isOnline == null) {
      return null;
    }
    return Container(
      width: 11,
      height: 11,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: contact.isOnline! ? const Color(0xFF22C55E) : Colors.grey.shade400,
        border: Border.all(color: Colors.white, width: 2),
      ),
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    _callController?.removeListener(_onCallControllerStateChange);
    if (_createdLocalCallController) {
      _callController?.dispose();
    }
    if (_createdLocalWebRTC) {
      _webrtcService?.dispose();
    }
    if (_createdLocalSignaling) {
      _signalingService?.dispose();
    }
    if (widget.apiService == null) {
      _apiService.dispose();
    }
    super.dispose();
  }

  List<ContactModel> get _filteredContacts {
    if (_searchQuery.trim().isEmpty) {
      return _contacts;
    }
    final q = _searchQuery.trim().toLowerCase();
    return _contacts.where((c) {
      return c.name.toLowerCase().contains(q) ||
          c.phoneNumber.toLowerCase().contains(q) ||
          c.username.toLowerCase().contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filtered = _filteredContacts;

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A2540),
        elevation: 0,
        title: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: const Color(0xFF2563EB),
              child: Text(
                _currentUserName.isNotEmpty
                    ? _currentUserName[0].toUpperCase()
                    : 'U',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  fontSize: 16,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Contacts',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                      color: Colors.white,
                    ),
                  ),
                  if (_currentUserName.isNotEmpty)
                    Text(
                      _currentPhoneNumber.isNotEmpty
                          ? '$_currentUserName ($_currentPhoneNumber)'
                          : _currentUserName,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withValues(alpha: 0.75),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            key: const Key('add_contact_appbar_btn'),
            icon: const Icon(Icons.person_add_alt_1, color: Colors.white),
            tooltip: 'Add Contact',
            onPressed: _navigateToAddContact,
          ),
          IconButton(
            key: const Key('logout_btn'),
            icon: const Icon(Icons.logout, color: Colors.white70),
            tooltip: 'Logout',
            onPressed: _logout,
          ),
        ],
      ),
      body: Column(
        children: [
          // Header Search Bar
          Container(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            decoration: const BoxDecoration(
              color: Color(0xFF0A2540),
              borderRadius: BorderRadius.only(
                bottomLeft: Radius.circular(24),
                bottomRight: Radius.circular(24),
              ),
            ),
            child: Container(
              height: 48,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: TextField(
                key: const Key('search_contact_field'),
                controller: _searchController,
                onChanged: (val) {
                  setState(() {
                    _searchQuery = val;
                  });
                },
                decoration: InputDecoration(
                  hintText: 'Search numbers, names & more',
                  hintStyle: const TextStyle(
                    color: Color(0xFF94A3B8),
                    fontSize: 14,
                  ),
                  prefixIcon: const Icon(
                    Icons.search,
                    color: Color(0xFF64748B),
                    size: 22,
                  ),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () {
                            _searchController.clear();
                            setState(() {
                              _searchQuery = '';
                            });
                          },
                        )
                      : null,
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ),

          // Main Body
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _errorMessage != null
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.error_outline,
                                size: 48, color: theme.colorScheme.error),
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
                    : RefreshIndicator(
                        onRefresh: _loadContacts,
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
                          children: [
                            // Frequently Dialed Section
                            if (_searchQuery.isEmpty &&
                                _frequentContacts.isNotEmpty) ...[
                              Row(
                                children: [
                                  const Icon(
                                    Icons.access_time_rounded,
                                    size: 17,
                                    color: Color(0xFF64748B),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    'Frequently Dialed',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.blueGrey.shade700,
                                      letterSpacing: 0.3,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              SizedBox(
                                height: 86,
                                child: ListView.separated(
                                  scrollDirection: Axis.horizontal,
                                  itemCount: _frequentContacts.length,
                                  separatorBuilder: (context, i) =>
                                      const SizedBox(width: 14),
                                  itemBuilder: (context, i) {
                                    final contact = _frequentContacts[i];
                                    final color =
                                        _getAvatarColor(contact.name);
                                    return InkWell(
                                      onTap: () => _handleCall(contact),
                                      borderRadius:
                                          BorderRadius.circular(16),
                                      child: SizedBox(
                                        width: 68,
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            CircleAvatar(
                                              radius: 24,
                                              backgroundColor: color,
                                              child: Text(
                                                contact.name.isNotEmpty
                                                    ? contact.name[0]
                                                        .toUpperCase()
                                                    : '?',
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontWeight:
                                                      FontWeight.bold,
                                                  fontSize: 18,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(height: 6),
                                            Text(
                                              contact.name,
                                              maxLines: 1,
                                              overflow:
                                                  TextOverflow.ellipsis,
                                              textAlign: TextAlign.center,
                                              style: const TextStyle(
                                                fontSize: 12,
                                                fontWeight:
                                                    FontWeight.w600,
                                                color: Color(0xFF1E293B),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                              const SizedBox(height: 18),
                            ],

                            // Contacts List Section Header
                            Row(
                              mainAxisAlignment:
                                  MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'Contacts',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.blueGrey.shade700,
                                    letterSpacing: 0.3,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),

                            if (filtered.isEmpty)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                    vertical: 40.0),
                                child: Center(
                                  child: Column(
                                    children: [
                                      Icon(
                                        Icons.person_search,
                                        size: 48,
                                        color: Colors.grey.shade400,
                                      ),
                                      const SizedBox(height: 10),
                                      Text(
                                        _contacts.isEmpty
                                            ? 'No contacts yet'
                                            : 'No matching contacts found',
                                        style: TextStyle(
                                          color: Colors.grey.shade600,
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              )
                            else
                              ListView.separated(
                                shrinkWrap: true,
                                physics:
                                    const NeverScrollableScrollPhysics(),
                                itemCount: filtered.length,
                                separatorBuilder: (context, index) =>
                                    const SizedBox(height: 8),
                                itemBuilder: (context, index) {
                                  final contact = filtered[index];
                                  final isCalling = _callingContactUserId ==
                                      contact.contactUserId;
                                  final presenceDot =
                                      _buildPresenceDot(contact);
                                  final avatarColor =
                                      _getAvatarColor(contact.name);

                                  final phoneDisplay =
                                      contact.phoneNumber.isNotEmpty
                                          ? contact.phoneNumber
                                          : contact.username;

                                  return Container(
                                    key: Key(
                                        'contact_tile_${contact.contactUserId}'),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius:
                                          BorderRadius.circular(16),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black
                                              .withValues(alpha: 0.03),
                                          blurRadius: 6,
                                          offset: const Offset(0, 2),
                                        ),
                                      ],
                                      border: Border.all(
                                        color: const Color(0xFFE2E8F0),
                                        width: 0.8,
                                      ),
                                    ),
                                    child: ListTile(
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                              horizontal: 14, vertical: 2),
                                      leading: Stack(
                                        clipBehavior: Clip.none,
                                        children: [
                                          CircleAvatar(
                                            radius: 22,
                                            backgroundColor: avatarColor,
                                            child: Text(
                                              contact.name.isNotEmpty
                                                  ? contact.name[0]
                                                      .toUpperCase()
                                                  : '?',
                                              style: const TextStyle(
                                                fontWeight: FontWeight.bold,
                                                color: Colors.white,
                                                fontSize: 16,
                                              ),
                                            ),
                                          ),
                                          if (presenceDot != null)
                                            Positioned(
                                              right: -2,
                                              bottom: -2,
                                              child: presenceDot,
                                            ),
                                        ],
                                      ),
                                      title: Text(
                                        contact.name,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 15,
                                          color: Color(0xFF0F172A),
                                        ),
                                      ),
                                      subtitle: Text(
                                        '$phoneDisplay • Mobile',
                                        style: const TextStyle(
                                          color: Color(0xFF64748B),
                                          fontSize: 13,
                                        ),
                                      ),
                                      trailing: isCalling
                                          ? const SizedBox(
                                              height: 24,
                                              width: 24,
                                              child: CircularProgressIndicator(
                                                  strokeWidth: 2),
                                            )
                                          : IconButton(
                                              key: Key(
                                                  'call_btn_${contact.contactUserId}'),
                                              icon: const Icon(
                                                Icons.call,
                                                color: Color(0xFF16A34A),
                                              ),
                                              tooltip:
                                                  'Call ${contact.name}',
                                              onPressed: () =>
                                                  _handleCall(contact),
                                            ),
                                    ),
                                  );
                                },
                              ),
                          ],
                        ),
                      ),
          ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Mini FAB for Add Contact to keep tests passing and support quick add
          FloatingActionButton.small(
            key: const Key('add_contact_fab'),
            heroTag: 'add_contact_fab_tag',
            backgroundColor: const Color(0xFF0A2540),
            foregroundColor: Colors.white,
            onPressed: _navigateToAddContact,
            tooltip: 'Add Contact',
            child: const Icon(Icons.person_add, size: 20),
          ),
          const SizedBox(height: 12),
          // Main Blue Circle Dialpad FAB
          FloatingActionButton(
            key: const Key('dialpad_fab'),
            heroTag: 'dialpad_fab_tag',
            backgroundColor: const Color(0xFF0066CC),
            foregroundColor: Colors.white,
            shape: const CircleBorder(),
            elevation: 4,
            onPressed: _openDialPad,
            tooltip: 'Dialpad',
            child: const Icon(Icons.dialpad, size: 28),
          ),
        ],
      ),
    );
  }
}
