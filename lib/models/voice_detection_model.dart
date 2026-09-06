/// Model representing the AI voice detection response from POST /voice-detection.
class VoiceDetectionResult {
  final bool success;
  final double fakeProbability;
  final double bonafideScore;
  final String verdict;
  final String? message;

  const VoiceDetectionResult({
    required this.success,
    required this.fakeProbability,
    required this.bonafideScore,
    required this.verdict,
    this.message,
  });

  factory VoiceDetectionResult.fromJson(Map<String, dynamic> json) {
    return VoiceDetectionResult(
      success: json['success'] as bool? ?? false,
      fakeProbability: (json['fake_probability'] as num?)?.toDouble() ?? 0.0,
      bonafideScore: (json['bonafide_score'] as num?)?.toDouble() ?? 0.0,
      verdict: (json['verdict'] ?? '').toString(),
      message: json['message']?.toString(),
    );
  }

  static String _formatPercentage(double value) {
    final pct = value <= 1.0 ? value * 100 : value;
    final str = pct.toStringAsFixed(2);
    return str.endsWith('.00') ? '${pct.toInt()}%' : '$str%';
  }

  /// Formatted fake probability percentage (e.g. '13.38%').
  String get displayFakeProbability => _formatPercentage(fakeProbability);

  /// Formatted bonafide score percentage (e.g. '86.62%').
  String get displayBonafideScore => _formatPercentage(bonafideScore);

  /// Verdict in uppercase (e.g. 'REAL' or 'FAKE').
  String get displayVerdict {
    final v = verdict.trim().toUpperCase();
    if (v.isNotEmpty) return v;
    return 'UNKNOWN';
  }
}
