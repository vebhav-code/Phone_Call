/// Centralized backend URL configuration.
/// The backend is deployed remotely and accessed via HTTPS and WSS.
class AppConfig {
  static const String baseUrl = 'https://calling-backend-1jxa.onrender.com';
  static const String wsBaseUrl = 'wss://calling-backend-1jxa.onrender.com/ws';
  static const String voiceDetectionUrl =
      'https://juek-ai-voice-detection.hf.space/sender';
}

