/// Model representing the AI voice detection response from POST /voice-detection.
class VoiceDetectionResult {
  final bool success;
  final String voiceType;
  final double confidence;
  final String? message;

  const VoiceDetectionResult({
    required this.success,
    required this.voiceType,
    required this.confidence,
    this.message,
  });

  factory VoiceDetectionResult.fromJson(Map<String, dynamic> json) {
    return VoiceDetectionResult(
      success: json['success'] as bool? ?? false,
      voiceType: (json['voice_type'] ?? json['voiceType'] ?? '').toString(),
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
      message: json['message']?.toString(),
    );
  }

  /// Formatted voice type for user display (e.g. 'Human' or 'AI').
  String get displayVoiceType {
    final upper = voiceType.trim().toUpperCase();
    if (upper == 'FAKE' || upper == 'AI' || upper == 'SYNTHETIC' || upper == 'SPOOF') {
      return 'AI';
    }
    if (upper == 'REAL' || upper == 'HUMAN') {
      return 'Human';
    }
    if (voiceType.isNotEmpty) {
      return '${voiceType[0].toUpperCase()}${voiceType.substring(1).toLowerCase()}';
    }
    return voiceType;
  }

  /// Formatted confidence percentage (e.g. '94%' or '91%').
  String get displayConfidence {
    final pct = confidence <= 1.0 ? (confidence * 100).round() : confidence.round();
    return '$pct%';
  }
}
