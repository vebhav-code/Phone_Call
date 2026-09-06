import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user_model.dart';
import '../services/api_service.dart';

/// Screen allowing users to search for registered users with debounce and add them as contacts.
class AddContactScreen extends StatefulWidget {
  final ApiService? apiService;

  const AddContactScreen({super.key, this.apiService});

  @override
  State<AddContactScreen> createState() => _AddContactScreenState();
}

class _AddContactScreenState extends State<AddContactScreen> {
  final TextEditingController _searchController = TextEditingController();
  late final ApiService _apiService;

  Timer? _debounceTimer;
  String _currentUserId = '';
  List<UserModel> _searchResults = [];
  bool _isLoading = false;
  String? _errorMessage;
  String? _addingContactUserId;

  @override
  void initState() {
    super.initState();
    _apiService = widget.apiService ?? ApiService();
    _loadCurrentUserId();
  }

  Future<void> _loadCurrentUserId() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _currentUserId = prefs.getString('user_id') ?? '';
    });
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _searchController.dispose();
    if (widget.apiService == null) {
      _apiService.dispose();
    }
    super.dispose();
  }

  void _onSearchChanged(String query) {
    _debounceTimer?.cancel();
    final trimmed = query.trim();

    if (trimmed.isEmpty) {
      setState(() {
        _searchResults = [];
        _errorMessage = null;
        _isLoading = false;
      });
      return;
    }

    // Debounce search requests by 400ms as user types
    _debounceTimer = Timer(const Duration(milliseconds: 400), () {
      _handleSearch(trimmed);
    });
  }

  Future<void> _handleSearch(String query) async {
    if (query.isEmpty) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final results = await _apiService.searchUsers(
        query,
        excludeUserId: _currentUserId.isNotEmpty ? _currentUserId : null,
      );
      if (!mounted) return;
      setState(() {
        _searchResults = results;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Search failed: $e';
      });
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _handleAddContact(UserModel user) async {
    if (_currentUserId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Error: User not logged in')),
      );
      return;
    }

    setState(() {
      _addingContactUserId = user.id;
    });

    try {
      await _apiService.addContact(_currentUserId, user.id);
      if (!mounted) return;

      // On add success: pop back to HomeScreen with true to trigger refresh
      Navigator.pop(context, true);
    } on ContactAlreadyAddedException {
      // 409 Conflict: show snackbar, don't crash
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${user.name} is already in your contacts.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.statusCode == 409) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${user.name} is already in your contacts.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to add contact: ${e.message}'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to add contact: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _addingContactUserId = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Add Contact'),
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        child: Column(
          children: [
            // Search Input with Debounce & Clear Button
            TextField(
              key: const Key('search_contact_field'),
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search by name or username',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          _onSearchChanged('');
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onChanged: _onSearchChanged,
              onSubmitted: (val) {
                _debounceTimer?.cancel();
                _handleSearch(val.trim());
              },
            ),
            const SizedBox(height: 16),

            // Search State / Results
            if (_isLoading)
              const Expanded(
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_errorMessage != null)
              Expanded(
                child: Center(
                  child: Text(
                    _errorMessage!,
                    style: TextStyle(color: theme.colorScheme.error),
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            else if (_searchController.text.trim().isEmpty)
              const Expanded(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.person_search, size: 64, color: Colors.grey),
                      SizedBox(height: 12),
                      Text(
                        'Type a name or username to search',
                        style: TextStyle(color: Colors.grey, fontSize: 16),
                      ),
                    ],
                  ),
                ),
              )
            else if (_searchResults.isEmpty)
              Expanded(
                child: Center(
                  child: Text(
                    'No users found for "${_searchController.text.trim()}"',
                    style: TextStyle(color: theme.colorScheme.outline, fontSize: 16),
                  ),
                ),
              )
            else
              Expanded(
                child: ListView.separated(
                  itemCount: _searchResults.length,
                  separatorBuilder: (context, index) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final user = _searchResults[index];
                    final isAdding = _addingContactUserId == user.id;

                    return ListTile(
                      key: Key('user_tile_${user.id}'),
                      leading: CircleAvatar(
                        backgroundColor: theme.colorScheme.secondaryContainer,
                        child: Text(
                          user.name.isNotEmpty ? user.name[0].toUpperCase() : '?',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.onSecondaryContainer,
                          ),
                        ),
                      ),
                      title: Text(
                        user.name,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text('@${user.username}'),
                      trailing: isAdding
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : FilledButton.tonalIcon(
                              key: Key('add_btn_${user.id}'),
                              icon: const Icon(Icons.person_add_alt, size: 18),
                              label: const Text('Add'),
                              onPressed: () => _handleAddContact(user),
                            ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
