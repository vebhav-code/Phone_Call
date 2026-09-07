/// Model representing a phone number flagged as AI-detected / scam / fake.
class ScamNumberModel {
  final String phoneNumber;
  final String verdict;
  final double confidence;
  final String? callerName;
  final String? reason;
  final DateTime? flaggedAt;

  const ScamNumberModel({
    required this.phoneNumber,
    this.verdict = 'AI Detected',
    this.confidence = 0.95,
    this.callerName,
    this.reason,
    this.flaggedAt,
  });

  factory ScamNumberModel.fromJson(Map<String, dynamic> json) {
    DateTime? parsedDate;
    final dateRaw = json['flagged_at'] ?? json['flaggedAt'] ?? json['created_at'];
    if (dateRaw is String && dateRaw.isNotEmpty) {
      parsedDate = DateTime.tryParse(dateRaw);
    }

    double parsedConfidence = 0.95;
    final confRaw = json['confidence'];
    if (confRaw is num) {
      parsedConfidence = confRaw.toDouble();
    } else if (confRaw is String) {
      parsedConfidence = double.tryParse(confRaw) ?? 0.95;
    }

    return ScamNumberModel(
      phoneNumber: (json['phone_number'] ?? json['phoneNumber'] ?? '').toString(),
      verdict: (json['verdict'] ?? 'AI Detected').toString(),
      confidence: parsedConfidence,
      callerName: json['caller_name']?.toString() ?? json['name']?.toString(),
      reason: json['reason']?.toString() ?? json['message']?.toString(),
      flaggedAt: parsedDate,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'phone_number': phoneNumber,
      'verdict': verdict,
      'confidence': confidence,
      if (callerName != null) 'caller_name': callerName,
      if (reason != null) 'reason': reason,
      if (flaggedAt != null) 'flagged_at': flaggedAt!.toIso8601String(),
    };
  }

  /// Default mock fallback scam records for standalone preview or when backend is unavailable.
  static List<ScamNumberModel> getMockScamNumbers() {
    final now = DateTime.now();
    return [
      ScamNumberModel(
        phoneNumber: '+1 (800) 555-0192',
        callerName: 'Suspected Tax Agency Impersonator',
        verdict: 'AI Detected',
        confidence: 0.97,
        reason: 'Synthetic voice clone detected with robotic cadence',
        flaggedAt: now.subtract(const Duration(hours: 3)),
      ),
      ScamNumberModel(
        phoneNumber: '+1 (888) 234-9871',
        callerName: 'Fake Bank Fraud Dept',
        verdict: 'AI Detected',
        confidence: 0.94,
        reason: 'Deepfake voice pattern matching known spoofing campaign',
        flaggedAt: now.subtract(const Duration(hours: 14)),
      ),
      ScamNumberModel(
        phoneNumber: '+1 (917) 555-8321',
        callerName: 'Urgent Tech Support Scam',
        verdict: 'Flagged',
        confidence: 0.89,
        reason: 'Automated robocall audio signature detected',
        flaggedAt: now.subtract(const Duration(days: 1, hours: 2)),
      ),
      ScamNumberModel(
        phoneNumber: '+44 20 7946 0192',
        callerName: 'Cryptocurrency Investment Scheme',
        verdict: 'AI Detected',
        confidence: 0.92,
        reason: 'High acoustic distortion and AI vocal synthesis artifacts',
        flaggedAt: now.subtract(const Duration(days: 2)),
      ),
    ];
  }
}
