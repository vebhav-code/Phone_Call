import 'dart:io';
import 'package:flutter/foundation.dart';

/// Centralized backend URL configuration.
/// The backend is deployed remotely and accessed via HTTPS and WSS.
class AppConfig {
  static const String baseUrl = 'https://calling-backend-1jxa.onrender.com';
  static const String wsBaseUrl = 'wss://calling-backend-1jxa.onrender.com/ws';
  static const String voiceDetectionUrl =
      'https://juek-ai-voice-detection.hf.space/sender';

  /// Fallback Hugging Face token when not provided via environment or .env
  static const String defaultHfToken = '';

  /// Hugging Face API authorization token.
  /// Resolves in priority order:
  /// 1. Compile-time environment (--dart-define=HF_TOKEN=... or --dart-define-from-file=.env)
  /// 2. System OS environment variable (Platform.environment['HF_TOKEN'])
  /// 3. Local .env file (HF_TOKEN=...)
  /// 4. Fallback defaultHfToken
  static String get hfToken {
    const defineToken = String.fromEnvironment('HF_TOKEN');
    if (defineToken.isNotEmpty) return defineToken;
    if (!kIsWeb) {
      try {
        final envVar = Platform.environment['HF_TOKEN'];
        if (envVar != null && envVar.isNotEmpty) return envVar;
      } catch (_) {}
      try {
        final envFile = File('.env');
        if (envFile.existsSync()) {
          for (final line in envFile.readAsLinesSync()) {
            final trimmed = line.trim();
            if (trimmed.startsWith('HF_TOKEN=')) {
              return trimmed
                  .substring('HF_TOKEN='.length)
                  .trim()
                  .replaceAll('"', '')
                  .replaceAll("'", '');
            }
          }
        }
      } catch (_) {}
    }
    return defaultHfToken;
  }
}

