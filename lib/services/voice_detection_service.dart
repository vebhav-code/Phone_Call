import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../models/voice_detection_model.dart';
import 'api_service.dart';

/// States for the 10-second remote voice analysis flow.
enum VoiceAnalysisStatus {
  idle,
  recording,
  analyzing,
  success,
  recordingFailed,
  uploadFailed,
  analysisFailed,
}

/// Abstract recorder interface for capturing remote caller audio.
/// Enables seamless platform handling and isolated testing.
abstract class RemoteAudioRecorder {
  Future<void> start(String path, {MediaStream? remoteStream});
  Future<void> stop();
  Future<void> dispose();
}

/// Default flutter_webrtc implementation capturing remote caller audio.
/// Uses [RecorderAudioChannel.OUTPUT] on native devices to record the caller's incoming voice
/// without recording the receiver's microphone and without interrupting audio playback.
class WebRTCRemoteAudioRecorder implements RemoteAudioRecorder {
  final MediaRecorder _recorder = MediaRecorder();
  bool _isRecording = false;

  @override
  Future<void> start(String path, {MediaStream? remoteStream}) async {
    if (kIsWeb) {
      if (remoteStream == null) {
        throw StateError('Remote MediaStream is required for web audio recording');
      }
      _recorder.startWeb(remoteStream);
      _isRecording = true;
    } else {
      // Intercept the WebRTC audio device module's output audio (remote peer stream)
      await _recorder.start(
        path,
        audioChannel: RecorderAudioChannel.OUTPUT,
      );
      _isRecording = true;
    }
  }

  @override
  Future<void> stop() async {
    if (_isRecording) {
      _isRecording = false;
      await _recorder.stop();
    }
  }

  @override
  Future<void> dispose() async {
    if (_isRecording) {
      try {
        await stop();
      } catch (_) {}
    }
  }
}

/// Manages the 10-second remote caller audio recording lifecycle and backend AI detection.
/// Strictly decoupled from WebRTC connection handling: no error in this service will ever
/// terminate or alter the active WebRTC call.
class VoiceDetectionService extends ChangeNotifier {
  final ApiService apiService;
  final RemoteAudioRecorder recorder;
  final Duration recordingDuration;

  VoiceAnalysisStatus _status = VoiceAnalysisStatus.idle;
  VoiceDetectionResult? _result;
  String? _errorMessage;

  Timer? _recordingTimer;
  File? _tempFile;
  bool _hasStarted = false;
  bool _isRecording = false;
  bool _isCancelled = false;
  bool _isDisposed = false;

  VoiceDetectionService({
    ApiService? apiService,
    RemoteAudioRecorder? recorder,
    this.recordingDuration = const Duration(seconds: 10),
  })  : apiService = apiService ?? ApiService(),
        recorder = recorder ?? WebRTCRemoteAudioRecorder();

  VoiceAnalysisStatus get status => _status;
  VoiceDetectionResult? get result => _result;
  String? get errorMessage => _errorMessage;
  bool get hasStarted => _hasStarted;
  bool get isRecording => _isRecording;

  /// Initiates the single 10-second remote audio recording on the receiver side.
  /// [isCallActive] is checked to ensure call is still ongoing before upload.
  Future<void> startAnalysis({
    MediaStream? remoteStream,
    bool Function()? isCallActive,
  }) async {
    if (_hasStarted || _isDisposed || _isCancelled) return;
    _hasStarted = true;

    _status = VoiceAnalysisStatus.recording;
    _errorMessage = null;
    notifyListeners();

    try {
      final tempDir = Directory.systemTemp;
      final filePath =
          '${tempDir.path}/caller_voice_${DateTime.now().millisecondsSinceEpoch}.mp3';
      _tempFile = File(filePath);

      await recorder.start(filePath, remoteStream: remoteStream);
      _isRecording = true;
      debugPrint('[VoiceDetectionService] Started 10-second remote voice recording to $filePath');
    } catch (e) {
      debugPrint('[VoiceDetectionService ERROR] Recording failed to start: $e');
      _isRecording = false;
      _status = VoiceAnalysisStatus.recordingFailed;
      _errorMessage = 'Voice recording failed';
      _deleteTempFile();
      notifyListeners();
      return;
    }

    _recordingTimer = Timer(recordingDuration, () async {
      await _handleRecordingCompletion(isCallActive);
    });
  }

  Future<void> _handleRecordingCompletion(bool Function()? isCallActive) async {
    if (_isCancelled || _isDisposed) return;

    if (isCallActive != null && !isCallActive()) {
      debugPrint('[VoiceDetectionService] Call ended before 10-second mark. Aborting upload.');
      cancel();
      return;
    }

    // Exactly 10 seconds reached: stop the recording
    debugPrint('[VoiceDetectionService] 10 seconds reached. Stopping recording...');
    _isRecording = false;
    try {
      await recorder.stop();
    } catch (e) {
      debugPrint('[VoiceDetectionService WARN] Error stopping recorder: $e');
    }

    if (_isCancelled || _isDisposed || (isCallActive != null && !isCallActive())) {
      _deleteTempFile();
      return;
    }

    final file = _tempFile;
    if (file == null || !await file.exists() || await file.length() == 0) {
      debugPrint('[VoiceDetectionService ERROR] Recorded file missing or empty');
      _status = VoiceAnalysisStatus.recordingFailed;
      _errorMessage = 'Voice recording failed';
      _deleteTempFile();
      notifyListeners();
      return;
    }

    _status = VoiceAnalysisStatus.analyzing;
    notifyListeners();

    try {
      debugPrint('[VoiceDetectionService] Uploading MP3 to POST /voice-detection...');
      final detectionResult = await apiService.detectVoice(file);

      if (_isCancelled || _isDisposed || (isCallActive != null && !isCallActive())) {
        _deleteTempFile();
        return;
      }

      if (detectionResult.success) {
        debugPrint(
          '[VoiceDetectionService] Voice detected successfully: '
          'type=${detectionResult.voiceType}, confidence=${detectionResult.confidence}',
        );
        _result = detectionResult;
        _status = VoiceAnalysisStatus.success;
      } else {
        debugPrint('[VoiceDetectionService] AI detection returned success: false');
        _status = VoiceAnalysisStatus.analysisFailed;
        _errorMessage = detectionResult.message ?? 'Voice analysis failed';
      }
    } on SocketException catch (e) {
      debugPrint('[VoiceDetectionService ERROR] Network socket error: $e');
      _status = VoiceAnalysisStatus.uploadFailed;
      _errorMessage = 'Voice analysis unavailable';
    } on HttpException catch (e) {
      debugPrint('[VoiceDetectionService ERROR] HTTP error: $e');
      _status = VoiceAnalysisStatus.uploadFailed;
      _errorMessage = 'Voice analysis unavailable';
    } catch (e) {
      debugPrint('[VoiceDetectionService ERROR] Upload/detection failed: $e');
      if (e is ApiException && e.statusCode == 200) {
        _status = VoiceAnalysisStatus.analysisFailed;
        _errorMessage = 'Voice analysis failed';
      } else {
        _status = VoiceAnalysisStatus.uploadFailed;
        _errorMessage = 'Voice analysis unavailable';
      }
    } finally {
      _deleteTempFile();
      notifyListeners();
    }
  }

  /// Cancels any active timer/recording and deletes temp files without uploading.
  void cancel() {
    _isCancelled = true;
    _recordingTimer?.cancel();
    _recordingTimer = null;

    if (_isRecording) {
      _isRecording = false;
      try {
        recorder.stop();
      } catch (_) {}
    }

    _deleteTempFile();
  }

  void _deleteTempFile() {
    final file = _tempFile;
    _tempFile = null;
    if (file != null) {
      try {
        if (file.existsSync()) {
          file.deleteSync();
        }
      } catch (e) {
        debugPrint('[VoiceDetectionService WARN] Error deleting temp file: $e');
      }
    }
  }

  @override
  void notifyListeners() {
    if (!_isDisposed) {
      super.notifyListeners();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    cancel();
    recorder.dispose();
    super.dispose();
  }
}
