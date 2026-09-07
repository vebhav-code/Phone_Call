import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Service managing local call history and frequency ranking in SharedPreferences.
class CallHistoryService {
  static const String _prefKey = 'call_frequency_map';

  /// Records a successful or initiated call to [contactUserId].
  static Future<void> recordCall(String contactUserId) async {
    if (contactUserId.isEmpty) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefKey);
      Map<String, dynamic> data = {};
      if (raw != null && raw.isNotEmpty) {
        data = jsonDecode(raw) as Map<String, dynamic>;
      }

      final existing = (data[contactUserId] as Map<String, dynamic>?) ?? {};
      final int currentCount = (existing['count'] as num?)?.toInt() ?? 0;

      data[contactUserId] = {
        'count': currentCount + 1,
        'last_called_at': DateTime.now().toIso8601String(),
      };

      await prefs.setString(_prefKey, jsonEncode(data));
    } catch (_) {
      // Ignored for resilience
    }
  }

  /// Retrieves contact IDs sorted by call frequency (descending) and recency.
  static Future<List<String>> getFrequentContactIds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefKey);
      if (raw == null || raw.isEmpty) return [];

      final data = jsonDecode(raw) as Map<String, dynamic>;
      final entries = data.entries.toList();

      entries.sort((a, b) {
        final valA = a.value as Map<String, dynamic>;
        final valB = b.value as Map<String, dynamic>;
        final countA = (valA['count'] as num?)?.toInt() ?? 0;
        final countB = (valB['count'] as num?)?.toInt() ?? 0;
        if (countA != countB) {
          return countB.compareTo(countA);
        }
        final timeA = DateTime.tryParse(valA['last_called_at']?.toString() ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final timeB = DateTime.tryParse(valB['last_called_at']?.toString() ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0);
        return timeB.compareTo(timeA);
      });

      return entries.map((e) => e.key).toList();
    } catch (_) {
      return [];
    }
  }

  /// Formats the last-called timestamp into a concise human-readable relative label.
  static Future<String?> getLastCalledText(String contactUserId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefKey);
      if (raw == null || raw.isEmpty) return null;

      final data = jsonDecode(raw) as Map<String, dynamic>;
      final entry = data[contactUserId] as Map<String, dynamic>?;
      if (entry == null) return null;

      final dateStr = entry['last_called_at']?.toString();
      if (dateStr == null) return null;
      final date = DateTime.tryParse(dateStr);
      if (date == null) return null;

      final diff = DateTime.now().difference(date);
      if (diff.inMinutes < 1) {
        return 'Just now';
      } else if (diff.inMinutes < 60) {
        return '${diff.inMinutes}m ago';
      } else if (diff.inHours < 24) {
        return '${diff.inHours}h ago';
      } else if (diff.inDays == 1) {
        return 'Yesterday';
      } else {
        return '${diff.inDays}d ago';
      }
    } catch (_) {
      return null;
    }
  }

  /// Clears call history records.
  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefKey);
  }
}
