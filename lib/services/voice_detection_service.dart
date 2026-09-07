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
      debugPrint('[VoiceDetection] recording started');
    } catch (e) {
      debugPrint('[VoiceDetection] Recording failed to start: $e');
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
      debugPrint('[VoiceDetection] Call ended before 10-second mark. Aborting upload.');
      cancel();
      return;
    }

    // Exactly 10 seconds reached: stop the recording
    debugPrint('[VoiceDetection] recording stopped');
    _isRecording = false;
    try {
      await recorder.stop();
    } catch (e) {
      debugPrint('[VoiceDetection] Error stopping recorder: $e');
    }

    if (_isCancelled || _isDisposed || (isCallActive != null && !isCallActive())) {
      _deleteTempFile();
      return;
    }

    final file = _tempFile;
    final fileExists = file != null && await file.exists();
    final fileSize = fileExists ? await file.length() : 0;
    final hasMp3Ext = file != null && file.path.toLowerCase().endsWith('.mp3');

    debugPrint('[VoiceDetection] file path = ${file?.path}');
    debugPrint('[VoiceDetection] file exists = $fileExists');
    debugPrint('[VoiceDetection] file size = $fileSize');

    if (!fileExists || fileSize == 0 || !hasMp3Ext) {
      debugPrint('[VoiceDetection] File missing, empty, or not .mp3. Reporting recording failure.');
      _status = VoiceAnalysisStatus.recordingFailed;
      _errorMessage = 'Voice recording failed';
      _deleteTempFile();
      notifyListeners();
      return;
    }

    _status = VoiceAnalysisStatus.analyzing;
    notifyListeners();

    try {
      debugPrint('[VoiceDetection] upload started');
      final detectionResult = await apiService.detectVoice(file);

      if (_isCancelled || _isDisposed || (isCallActive != null && !isCallActive())) {
        _deleteTempFile();
        return;
      }

      final verdictUpper = detectionResult.verdict.trim().toUpperCase();
      final isValidVerdict = verdictUpper == 'REAL' || verdictUpper == 'FAKE';

      if (detectionResult.success && isValidVerdict) {
        debugPrint('[VoiceDetection] parsed verdict = ${detectionResult.verdict}');
        debugPrint('[VoiceDetection] fake probability = ${detectionResult.fakeProbability}');
        debugPrint('[VoiceDetection] bonafide score = ${detectionResult.bonafideScore}');
        _result = detectionResult;
        _status = VoiceAnalysisStatus.success;
      } else {
        debugPrint('[VoiceDetection] parsed verdict = ${detectionResult.verdict}');
        debugPrint('[VoiceDetection] fake probability = ${detectionResult.fakeProbability}');
        debugPrint('[VoiceDetection] bonafide score = ${detectionResult.bonafideScore}');
        debugPrint('[VoiceDetection] Detection failed: message=${detectionResult.message}');
        _status = VoiceAnalysisStatus.analysisFailed;
        _errorMessage = detectionResult.message ?? 'Voice analysis failed';
      }
    } on SocketException catch (e) {
      debugPrint('[VoiceDetection] Network socket error: $e');
      _status = VoiceAnalysisStatus.uploadFailed;
      _errorMessage = '$e';
    } on HttpException catch (e) {
      debugPrint('[VoiceDetection] HTTP error: $e');
      _status = VoiceAnalysisStatus.uploadFailed;
     _errorMessage = '$e';
    } catch (e) {
      debugPrint('[VoiceDetection] Upload/detection error: $e');
      _status = VoiceAnalysisStatus.uploadFailed;
      _errorMessage = '$e';
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
